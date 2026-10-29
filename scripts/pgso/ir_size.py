#!/usr/bin/env python3
"""Size passes for PGSO bitcode, run through the pinned LLVM C library.

    ir_size.py --libllvm <libLLVM.dylib> outline-helpers <in.bc> <out.bc>
    ir_size.py --libllvm <libLLVM.dylib> sparse-constants <in.bc> <out.bc>
    ir_size.py --libllvm <libLLVM.dylib> overlay-constants <in.bc> <out.bc>
    ir_size.py --libllvm <libLLVM.dylib> expand-constant-exprs <in.bc> <out.bc>
    ir_size.py --libllvm <libLLVM.dylib> swap-compares <in.bc> <out.bc>
    ir_size.py --libllvm <libLLVM.dylib> check-outlined <in.bc>

outline-helpers marks small shared std helpers as noinline: the allocator's
slice free, remap, and aligned allocation, the writer's write, writeAll,
writeByte, and allocating writer setup and teardown, the byte list's append,
every list's teardown, slice equality and prefix checks, case-insensitive
ASCII equality, and the Io mutex's lock and unlock.
Zig inlines them at thousands of call sites (free alone at about
11,000 in fx); one out-of-line copy per instantiation keeps the same checks,
poisoning, and calls. Run it on the emitted bitcode, before instrumentation,
so training and profile use see the same inlining.

sparse-constants rewrites copies from mostly undefined internal constants
into stores of their defined scalar leaves. Zig materializes `return error.X`
from a function returning a large `E!T` as a constant `{ T undef, code,
padding undef }` copied into the result. Copying undefined bytes is refined
by leaving the destination bytes unchanged, so only the defined bytes are
stored. Run `opt -passes=globaldce,verify` afterwards to drop dead constants.

overlay-constants packs the mostly undefined internal constants that are
still referenced, the same `return error.X` results plus `return null` results
`{ T undef, i8 0 }`, into one shared constant. They are `unnamed_addr`, so
only their contents matter, and an undefined byte may hold any value: two
constants can overlap wherever neither defines a byte the other defines
differently. Each keeps its alignment and its full size inside the blob and
becomes an alias of its offset, so every reference stays its own symbol. A
constant that hot code uses, or one small enough for codegen to expand its
copies into stores, never gets another constant's nonzero byte in its
undefined bytes, so those copies still read zeros and compile as before.
Constants that hold relocated pointers, compare or convert their address,
live in a named section, are thread-local, or are listed in llvm.used stay as
they are. Run it after sparse-constants, then `opt -passes=globaldce,verify`.

expand-constant-exprs rebuilds each constant expression an instruction uses
as an operand, such as `getelementptr (i8, ptr @g, i64 16)`, as an
instruction of its own. LLVM's IR outliner does not see constants nested in
a constant expression when it matches regions, so two regions that differ
only in an instruction's constant, one with 16 and one with 8898, can share a
parameter that also replaces the nested 16: the second region then reads
`@g + 8898`. With the expressions rebuilt as instructions, every constant is
an operand the outliner compares. Run it on each partition right before
`opt -passes=iroutliner`, with no pass between that could fold them back.
PHI nodes, landing pads, call targets, and intrinsic calls keep their
expressions: the outliner never moves an intrinsic call or a PHI's incoming
constant into a region, and a call target must stay a direct callee.

swap-compares rewrites each greater-than comparison, such as `icmp ugt %a,
%b`, as the less-than comparison with its operands swapped, `icmp ult %b,
%a`, keeping its flags and debug location. LLVM's IR outliner matches the two
forms as one region by reversing the operands it compares, but it passes the
reversed region's operands to the outlined function in their original order,
so that region computes `a < b` instead of `a > b`. A PGSO build of the
current source turned a skill file read's bounds check around this way and
panicked on the first chunk. With no greater-than comparison left, the
outliner matches only comparisons written the same way. Run it on each
partition right before `opt -passes=iroutliner`, after expand-constant-exprs.

check-outlined fails when an outlined function holds a constant expression
that the outliner rebuilt from a parameter: an instruction LLVM named
`constexpr`, or a constant expression with a non-constant operand. After
expand-constant-exprs neither should exist, so any hit is a form this guard
does not cover.

Every command prints a JSON summary on stdout and exits nonzero when the
input cannot be read. outline-helpers also fails when no allocator free helper
matches, because that means std naming changed and the pass went stale.
"""
from __future__ import annotations

import argparse
import bisect
import ctypes as C
import json
import pathlib
import re
import sys

OUT_OF_LINE_HELPERS = (
    r"mem\.Allocator\.free(?:__func_\d+)?",
    r"mem\.Allocator\.(?:remap|allocBytesAligned)__func_\d+",
    r"Io\.Writer\.(?:writeAll|write|writeByte|Allocating\.deinit|Allocating\.initCapacity)",
    r"array_list\.Aligned\(u8,null\)\.appendSlice",
    r"array_list\.Aligned\(.*\)\.deinit",
    r"mem\.eql__func_\d+",
    r"mem\.startsWith(?:__func_\d+)?",
    r"ascii\.eqlIgnoreCase",
    r"Io\.Mutex\.(?:lock|lockUncancelable|unlock)",
)

MIN_CONSTANT_BYTES = 32
MAX_DEFINED_BYTES = 128
MAX_LEAVES = 16
MEMCPY_SITE_BYTES = 16
STORE_BYTES = 8
# overlay-constants: at most this share of a member's bytes may be defined
# and nonzero, and members below OVERLAY_GUARD_BYTES (the largest copy
# AArch64 expands into stores in size-optimized code) keep zeros in their
# undefined bytes.
OVERLAY_MAX_NONZERO_SHARE = 0.25
OVERLAY_GUARD_BYTES = 64
OVERLAY_MAX_ALIGN = 16
OVERLAY_BLOB = b"pgso.overlaid_constants"

P = C.c_void_p
STRUCT, ARRAY, INTEGER, POINTER = 10, 11, 8, 12
FLOATS = (1, 2, 3)
INTERNAL_LINKAGE, PRIVATE_LINKAGE = 8, 9
FUNCTION_INDEX = 0xFFFFFFFF
GET_ELEMENT_PTR = 29
PTR_TO_INT, INT_TO_PTR = 39, 40
GLOBAL_UNNAMED_ADDR = 2
CASTS = {30: "trunc", 39: "ptrtoint", 40: "inttoptr", 41: "bitcast", 60: "addrspacecast", 69: "ptrtoaddr"}
OUTLINED_PREFIX = "outlined_ir_func"

# LLVMIntPredicate and LLVMRealPredicate values: each greater-than predicate
# that LLVM's IR similarity analysis reverses, mapped to its swapped form.
SWAPPED_INT_PREDICATES = {34: 36, 35: 37, 38: 40, 39: 41}  # ugt, uge, sgt, sge
SWAPPED_REAL_PREDICATES = {2: 4, 3: 5, 10: 12, 11: 13}  # ogt, oge, ugt, uge


class PassError(Exception):
    pass


class _Skip(Exception):
    pass


class Llvm:
    def __init__(self, library: pathlib.Path) -> None:
        self.lib = C.CDLL(str(library))
        f = self._fn
        self.ContextCreate = f("LLVMContextCreate", P)
        self.CreateMemBuf = f("LLVMCreateMemoryBufferWithContentsOfFile", C.c_int, C.c_char_p, C.POINTER(P), C.POINTER(C.c_char_p))
        self.ParseBC = f("LLVMParseBitcodeInContext2", C.c_int, P, P, C.POINTER(P))
        self.WriteBC = f("LLVMWriteBitcodeToFile", C.c_int, P, C.c_char_p)
        self.GetDL = f("LLVMGetDataLayoutStr", C.c_char_p, P)
        self.CreateTD = f("LLVMCreateTargetData", P, C.c_char_p)
        self.FirstGlobal = f("LLVMGetFirstGlobal", P, P)
        self.NextGlobal = f("LLVMGetNextGlobal", P, P)
        self.FirstFunction = f("LLVMGetFirstFunction", P, P)
        self.NextFunction = f("LLVMGetNextFunction", P, P)
        self.IsDeclaration = f("LLVMIsDeclaration", C.c_int, P)
        self.GetLinkage = f("LLVMGetLinkage", C.c_int, P)
        self.IsGlobalConstant = f("LLVMIsGlobalConstant", C.c_int, P)
        self.GetInitializer = f("LLVMGetInitializer", P, P)
        self.GlobalValueType = f("LLVMGlobalGetValueType", P, P)
        self.ABISize = f("LLVMABISizeOfType", C.c_ulonglong, P, P)
        self.ABIAlign = f("LLVMABIAlignmentOfType", C.c_uint, P, P)
        self.OffsetOfElement = f("LLVMOffsetOfElement", C.c_ulonglong, P, P, C.c_uint)
        self.TypeOf = f("LLVMTypeOf", P, P)
        self.TypeKind = f("LLVMGetTypeKind", C.c_int, P)
        self.CountStructElems = f("LLVMCountStructElementTypes", C.c_uint, P)
        self.ArrayLen = f("LLVMGetArrayLength2", C.c_ulonglong, P)
        self.ElementType = f("LLVMGetElementType", P, P)
        self.AggElem = f("LLVMGetAggregateElement", P, P, C.c_uint)
        self.IsUndef = f("LLVMIsUndef", C.c_int, P)
        self.IsNull = f("LLVMIsNull", C.c_int, P)
        self.IsConstant = f("LLVMIsConstant", C.c_int, P)
        self.IsAConstantInt = f("LLVMIsAConstantInt", P, P)
        self.IsAConstantFP = f("LLVMIsAConstantFP", P, P)
        self.FirstUse = f("LLVMGetFirstUse", P, P)
        self.NextUse = f("LLVMGetNextUse", P, P)
        self.GetUser = f("LLVMGetUser", P, P)
        self.IsACallInst = f("LLVMIsACallInst", P, P)
        self.CalledValue = f("LLVMGetCalledValue", P, P)
        self.GetValueName2 = f("LLVMGetValueName2", C.c_char_p, P, C.POINTER(C.c_size_t))
        self.GetOperand = f("LLVMGetOperand", P, P, C.c_uint)
        self.ConstZExt = f("LLVMConstIntGetZExtValue", C.c_ulonglong, P)
        self.Int8Ty = f("LLVMInt8TypeInContext", P, P)
        self.Int64Ty = f("LLVMInt64TypeInContext", P, P)
        self.ConstInt = f("LLVMConstInt", P, P, C.c_ulonglong, C.c_int)
        self.CreateBuilder = f("LLVMCreateBuilderInContext", P, P)
        self.PositionBefore = f("LLVMPositionBuilderBefore", None, P, P)
        self.BuildGEP2 = f("LLVMBuildInBoundsGEP2", P, P, P, P, C.POINTER(P), C.c_uint, C.c_char_p)
        self.BuildStore = f("LLVMBuildStore", P, P, P, P)
        self.SetAlignment = f("LLVMSetAlignment", None, P, C.c_uint)
        self.Erase = f("LLVMInstructionEraseFromParent", None, P)
        self.EnumAttrKind = f("LLVMGetEnumAttributeKindForName", C.c_uint, C.c_char_p, C.c_size_t)
        self.CreateEnumAttr = f("LLVMCreateEnumAttribute", P, P, C.c_uint, C.c_ulonglong)
        self.AddAttr = f("LLVMAddAttributeAtIndex", None, P, C.c_uint, P)
        self.GetEnumAttrAt = f("LLVMGetEnumAttributeAtIndex", P, P, C.c_uint, C.c_uint)
        self.CallSiteEnumAttr = f("LLVMGetCallSiteEnumAttribute", P, P, C.c_uint, C.c_uint)
        self.EnumAttrValue = f("LLVMGetEnumAttributeValue", C.c_ulonglong, P)
        self.FirstBlock = f("LLVMGetFirstBasicBlock", P, P)
        self.NextBlock = f("LLVMGetNextBasicBlock", P, P)
        self.FirstInstruction = f("LLVMGetFirstInstruction", P, P)
        self.NextInstruction = f("LLVMGetNextInstruction", P, P)
        self.NumOperands = f("LLVMGetNumOperands", C.c_int, P)
        self.SetOperand = f("LLVMSetOperand", None, P, C.c_uint, P)
        self.IsAConstantExpr = f("LLVMIsAConstantExpr", P, P)
        self.ConstOpcode = f("LLVMGetConstOpcode", C.c_int, P)
        self.IsAPHINode = f("LLVMIsAPHINode", P, P)
        self.IsALandingPad = f("LLVMIsALandingPadInst", P, P)
        self.IsAInvoke = f("LLVMIsAInvokeInst", P, P)
        self.IsACallBr = f("LLVMIsACallBrInst", P, P)
        self.IsAIntrinsic = f("LLVMIsAIntrinsicInst", P, P)
        self.GEPSourceType = f("LLVMGetGEPSourceElementType", P, P)
        self.GEPNoWrapFlags = f("LLVMGEPGetNoWrapFlags", C.c_uint, P)
        self.BuildGEPNoWrap = f("LLVMBuildGEPWithNoWrapFlags", P, P, P, P, C.POINTER(P), C.c_uint, C.c_char_p, C.c_uint)
        self.BuildCast = f("LLVMBuildCast", P, P, C.c_int, P, P, C.c_char_p)
        self.BuildFreeze = f("LLVMBuildFreeze", P, P, P, C.c_char_p)
        self.IsAInstruction = f("LLVMIsAInstruction", P, P)
        self.IsAICmpInst = f("LLVMIsAICmpInst", P, P)
        self.IsAFCmpInst = f("LLVMIsAFCmpInst", P, P)
        self.ICmpPredicate = f("LLVMGetICmpPredicate", C.c_int, P)
        self.FCmpPredicate = f("LLVMGetFCmpPredicate", C.c_int, P)
        self.BuildICmp = f("LLVMBuildICmp", P, P, C.c_int, P, P, C.c_char_p)
        self.BuildFCmp = f("LLVMBuildFCmp", P, P, C.c_int, P, P, C.c_char_p)
        self.ICmpSameSign = f("LLVMGetICmpSameSign", C.c_int, P)
        self.SetICmpSameSign = f("LLVMSetICmpSameSign", None, P, C.c_int)
        self.FastMathFlags = f("LLVMGetFastMathFlags", C.c_uint, P)
        self.SetFastMathFlags = f("LLVMSetFastMathFlags", None, P, C.c_uint)
        self.DebugLoc = f("LLVMInstructionGetDebugLoc", P, P)
        self.SetDebugLoc = f("LLVMInstructionSetDebugLoc", None, P, P)
        self.ReplaceAllUses = f("LLVMReplaceAllUsesWith", None, P, P)
        self.SetValueName2 = f("LLVMSetValueName2", None, P, C.c_char_p, C.c_size_t)
        self.GetUnnamedAddress = f("LLVMGetUnnamedAddress", C.c_int, P)
        self.SetUnnamedAddress = f("LLVMSetUnnamedAddress", None, P, C.c_int)
        self.GetSection = f("LLVMGetSection", C.c_char_p, P)
        self.IsThreadLocal = f("LLVMIsThreadLocal", C.c_int, P)
        self.IsExternallyInitialized = f("LLVMIsExternallyInitialized", C.c_int, P)
        self.GetComdat = f("LLVMGetComdat", P, P)
        self.GetAlignment = f("LLVMGetAlignment", C.c_uint, P)
        self.IsAConstantDataSequential = f("LLVMIsAConstantDataSequential", P, P)
        self.GetAsString = f("LLVMGetAsString", C.c_void_p, P, C.POINTER(C.c_size_t))
        self.IntWidth = f("LLVMGetIntTypeWidth", C.c_uint, P)
        self.IsAGlobalValue = f("LLVMIsAGlobalValue", P, P)
        self.InstOpcode = f("LLVMGetInstructionOpcode", C.c_int, P)
        self.InstParent = f("LLVMGetInstructionParent", P, P)
        self.BlockParent = f("LLVMGetBasicBlockParent", P, P)
        self.GetNamedGlobal = f("LLVMGetNamedGlobal", P, P, C.c_char_p)
        self.AddGlobal = f("LLVMAddGlobal", P, P, P, C.c_char_p)
        self.AddAlias2 = f("LLVMAddAlias2", P, P, P, C.c_uint, P, C.c_char_p)
        self.SetInitializer = f("LLVMSetInitializer", None, P, P)
        self.SetGlobalConstant = f("LLVMSetGlobalConstant", None, P, C.c_int)
        self.SetLinkage = f("LLVMSetLinkage", None, P, C.c_int)
        self.ArrayType2 = f("LLVMArrayType2", P, P, C.c_ulonglong)
        self.ConstString = f("LLVMConstStringInContext2", P, P, C.c_char_p, C.c_size_t, C.c_int)
        self.ConstGEP2 = f("LLVMConstInBoundsGEP2", P, P, P, C.POINTER(P), C.c_uint)
        self.DeleteGlobal = f("LLVMDeleteGlobal", None, P)

    def _fn(self, name, res, *args):
        fn = getattr(self.lib, name)
        fn.restype = res
        fn.argtypes = list(args)
        return fn

    def load(self, path: pathlib.Path):
        ctx = self.ContextCreate()
        buf, msg, mod = P(), C.c_char_p(), P()
        if self.CreateMemBuf(str(path).encode(), C.byref(buf), C.byref(msg)):
            raise PassError(f"cannot read {path}")
        if self.ParseBC(ctx, buf, C.byref(mod)):
            raise PassError(f"cannot parse bitcode {path}")
        return ctx, mod

    def save(self, mod, path: pathlib.Path) -> None:
        if self.WriteBC(mod, str(path).encode()):
            raise PassError(f"cannot write bitcode {path}")

    def name(self, value) -> str:
        n = C.c_size_t()
        s = self.GetValueName2(value, C.byref(n))
        return s.decode("utf-8", "replace") if s else ""

    def kind(self, attribute: str) -> int:
        raw = attribute.encode()
        return self.EnumAttrKind(raw, len(raw))


def outline_helpers(llvm: Llvm, source: pathlib.Path, output: pathlib.Path) -> dict:
    ctx, mod = llvm.load(source)
    patterns = [re.compile(p) for p in OUT_OF_LINE_HELPERS]
    noinline = llvm.kind("noinline")
    always = llvm.kind("alwaysinline")
    per_pattern = [0] * len(patterns)
    fn = llvm.FirstFunction(mod)
    while fn:
        if not llvm.IsDeclaration(fn):
            name = llvm.name(fn)
            index = next((i for i, p in enumerate(patterns) if p.fullmatch(name)), None)
            if index is not None:
                if llvm.GetEnumAttrAt(fn, FUNCTION_INDEX, always):
                    raise PassError(f"helper is alwaysinline: {name}")
                llvm.AddAttr(fn, FUNCTION_INDEX, llvm.CreateEnumAttr(ctx, noinline, 0))
                per_pattern[index] += 1
        fn = llvm.NextFunction(fn)
    if per_pattern[0] == 0:
        raise PassError("no out-of-line helper matched; std naming may have changed")
    llvm.save(mod, output)
    return {
        "pass": "outline-helpers",
        "marked_functions": sum(per_pattern),
        "marked_by_pattern": dict(zip(OUT_OF_LINE_HELPERS, per_pattern)),
    }


def _leaves(llvm: Llvm, td, value, base: int, out: list) -> None:
    if llvm.IsUndef(value):
        return
    ty = llvm.TypeOf(value)
    kind = llvm.TypeKind(ty)
    if kind == STRUCT:
        for i in range(llvm.CountStructElems(ty)):
            _leaves(llvm, td, llvm.AggElem(value, i), base + llvm.OffsetOfElement(td, ty, i), out)
        return
    if kind == ARRAY:
        element = llvm.ElementType(ty)
        stride = llvm.ABISize(td, element)
        count = llvm.ArrayLen(ty)
        if count * stride > 4096 and not llvm.IsNull(value):
            raise _Skip("large defined array")
        for i in range(count):
            item = llvm.AggElem(value, i)
            if not item:
                raise _Skip("unreadable array element")
            _leaves(llvm, td, item, base + i * stride, out)
            if len(out) > MAX_LEAVES:
                raise _Skip("too many defined leaves")
        return
    scalar = (
        (kind == INTEGER and llvm.IsAConstantInt(value))
        or (kind == POINTER and llvm.IsConstant(value))
        or (kind in FLOATS and llvm.IsAConstantFP(value))
    )
    if not scalar:
        raise _Skip(f"unsupported leaf kind {kind}")
    out.append((base, value, llvm.ABISize(td, ty), llvm.ABIAlign(td, ty)))
    if len(out) > MAX_LEAVES or sum(leaf[2] for leaf in out) > MAX_DEFINED_BYTES:
        raise _Skip("too many defined bytes")


def sparse_constants(llvm: Llvm, source: pathlib.Path, output: pathlib.Path) -> dict:
    ctx, mod = llvm.load(source)
    td = llvm.CreateTD(llvm.GetDL(mod))
    i8, i64 = llvm.Int8Ty(ctx), llvm.Int64Ty(ctx)
    builder = llvm.CreateBuilder(ctx)
    align_kind = llvm.kind("align")
    summary = {"pass": "sparse-constants", "rewritten_constants": 0, "rewritten_copies": 0, "constant_bytes": 0}
    glob = llvm.FirstGlobal(mod)
    while glob:
        following = llvm.NextGlobal(glob)
        try:
            if llvm.GetLinkage(glob) not in (INTERNAL_LINKAGE, PRIVATE_LINKAGE) or not llvm.IsGlobalConstant(glob):
                raise _Skip("not an internal constant")
            init = llvm.GetInitializer(glob)
            if not init:
                raise _Skip("no initializer")
            size = llvm.ABISize(td, llvm.GlobalValueType(glob))
            if size < MIN_CONSTANT_BYTES:
                raise _Skip("small")
            copies = []
            use = llvm.FirstUse(glob)
            if not use:
                raise _Skip("unused")
            while use:
                user = llvm.GetUser(use)
                if not llvm.IsACallInst(user):
                    raise _Skip("non-call use")
                if not llvm.name(llvm.CalledValue(user)).startswith("llvm.memcpy.p0.p0."):
                    raise _Skip("non-copy call use")
                if llvm.GetOperand(user, 1) != glob or llvm.GetOperand(user, 0) == glob:
                    raise _Skip("constant is not only the copy source")
                length, volatile = llvm.GetOperand(user, 2), llvm.GetOperand(user, 3)
                if not llvm.IsAConstantInt(length) or not 0 < llvm.ConstZExt(length) <= size:
                    raise _Skip("variable or oversized copy")
                if not llvm.IsAConstantInt(volatile) or llvm.ConstZExt(volatile) != 0:
                    raise _Skip("volatile copy")
                copies.append((user, llvm.ConstZExt(length)))
                use = llvm.NextUse(use)
            leaves: list = []
            _leaves(llvm, td, init, 0, leaves)
            extra = 0
            for _, length in copies:
                if any(offset < length < offset + width for offset, _, width, _ in leaves):
                    raise _Skip("copy splits a defined leaf")
                inside = sum(1 for offset, _, width, _ in leaves if offset + width <= length)
                extra += max(0, STORE_BYTES * inside - MEMCPY_SITE_BYTES)
            if extra >= size:
                raise _Skip("stores would cost more than the constant")
            for call, length in copies:
                destination = llvm.GetOperand(call, 0)
                attribute = llvm.CallSiteEnumAttr(call, 1, align_kind)
                destination_align = llvm.EnumAttrValue(attribute) if attribute else 1
                llvm.PositionBefore(builder, call)
                for offset, value, width, natural in leaves:
                    if offset + width > length:
                        continue
                    pointer = destination
                    if offset:
                        index = (P * 1)(llvm.ConstInt(i64, offset, 0))
                        pointer = llvm.BuildGEP2(builder, i8, destination, index, 1, b"")
                    store = llvm.BuildStore(builder, value, pointer)
                    alignment = natural
                    while alignment > 1 and (offset % alignment or destination_align % alignment):
                        alignment //= 2
                    llvm.SetAlignment(store, max(alignment, 1))
                llvm.Erase(call)
                summary["rewritten_copies"] += 1
            summary["rewritten_constants"] += 1
            summary["constant_bytes"] += size
        except _Skip:
            pass
        glob = following
    llvm.save(mod, output)
    return summary


def _image(llvm: Llvm, td, value, base: int, image: bytearray, defined: bytearray) -> None:
    """Record the defined bytes of a constant; undefined bytes stay unset."""
    if llvm.IsUndef(value):
        return
    ty = llvm.TypeOf(value)
    size = llvm.ABISize(td, ty)
    if llvm.IsNull(value):
        defined[base:base + size] = b"\1" * size
        return
    kind = llvm.TypeKind(ty)
    if kind == STRUCT:
        for i in range(llvm.CountStructElems(ty)):
            _image(llvm, td, llvm.AggElem(value, i), base + llvm.OffsetOfElement(td, ty, i), image, defined)
        return
    if kind == ARRAY:
        element = llvm.ElementType(ty)
        if llvm.IsAConstantDataSequential(value):
            if llvm.TypeKind(element) != INTEGER or llvm.IntWidth(element) != 8:
                raise _Skip("dense numeric array")
            length = C.c_size_t()
            raw = C.string_at(llvm.GetAsString(value, C.byref(length)), length.value)
            image[base:base + len(raw)] = raw
            defined[base:base + len(raw)] = b"\1" * len(raw)
            return
        stride = llvm.ABISize(td, element)
        for i in range(llvm.ArrayLen(ty)):
            item = llvm.AggElem(value, i)
            if not item:
                raise _Skip("unreadable array element")
            _image(llvm, td, item, base + i * stride, image, defined)
        return
    if kind == INTEGER and llvm.IsAConstantInt(value) and llvm.IntWidth(ty) <= 64:
        width = (llvm.IntWidth(ty) + 7) // 8
        image[base:base + width] = llvm.ConstZExt(value).to_bytes(8, "little")[:width]
        defined[base:base + size] = b"\1" * size
        return
    if kind == POINTER and llvm.IsAConstantExpr(value) and llvm.ConstOpcode(value) == INT_TO_PTR:
        inner = llvm.GetOperand(value, 0)
        if llvm.IsAConstantInt(inner):
            image[base:base + 8] = llvm.ConstZExt(inner).to_bytes(8, "little")
            defined[base:base + 8] = b"\1" * 8
            return
    raise _Skip("relocated or unsupported leaf")


def _address_used(llvm: Llvm, value, depth: int = 0) -> bool:
    """True when a use compares the address or converts it to an integer."""
    use = llvm.FirstUse(value)
    while use:
        user = llvm.GetUser(use)
        if llvm.IsAInstruction(user):
            if llvm.IsAICmpInst(user) or llvm.InstOpcode(user) == PTR_TO_INT:
                return True
        elif llvm.IsAConstantExpr(user) and llvm.ConstOpcode(user) == PTR_TO_INT:
            return True
        elif not llvm.IsAGlobalValue(user) and (depth >= 4 or _address_used(llvm, user, depth + 1)):
            return True
        use = llvm.NextUse(use)
    return False


def _used_by_hot_code(llvm: Llvm, value, minsize: int, depth: int = 0) -> bool:
    use = llvm.FirstUse(value)
    while use:
        user = llvm.GetUser(use)
        if llvm.IsAInstruction(user):
            if not llvm.GetEnumAttrAt(llvm.BlockParent(llvm.InstParent(user)), FUNCTION_INDEX, minsize):
                return True
        elif not llvm.IsAGlobalValue(user) and (depth >= 4 or _used_by_hot_code(llvm, user, minsize, depth + 1)):
            return True
        use = llvm.NextUse(use)
    return False


def _listed_as_used(llvm: Llvm, mod) -> set:
    """Globals that llvm.used or llvm.compiler.used keep; an alias cannot
    stand in for them there."""
    listed = set()
    for name in (b"llvm.used", b"llvm.compiler.used"):
        used = llvm.GetNamedGlobal(mod, name)
        init = llvm.GetInitializer(used) if used else None
        if init:
            for i in range(llvm.NumOperands(init)):
                listed.add(llvm.GetOperand(init, i))
    return listed


def _overlay_members(llvm: Llvm, mod, td, minsize: int) -> list:
    members = []
    listed = _listed_as_used(llvm, mod)
    glob = llvm.FirstGlobal(mod)
    while glob:
        try:
            if glob in listed:
                raise _Skip("listed as used")
            if llvm.GetLinkage(glob) not in (INTERNAL_LINKAGE, PRIVATE_LINKAGE) or not llvm.IsGlobalConstant(glob):
                raise _Skip("not an internal constant")
            if llvm.GetUnnamedAddress(glob) != GLOBAL_UNNAMED_ADDR:
                raise _Skip("significant address")
            if llvm.GetSection(glob) or llvm.IsThreadLocal(glob) or llvm.GetComdat(glob) or llvm.IsExternallyInitialized(glob):
                raise _Skip("placed constant")
            size = llvm.ABISize(td, llvm.GlobalValueType(glob))
            align = max(llvm.GetAlignment(glob), 1)
            init = llvm.GetInitializer(glob)
            if not init or size < MIN_CONSTANT_BYTES or align > OVERLAY_MAX_ALIGN or not llvm.FirstUse(glob):
                raise _Skip("not a candidate")
            image, defined = bytearray(size), bytearray(size)
            _image(llvm, td, init, 0, image, defined)
            leaves = [(offset, image[offset]) for offset in range(size) if defined[offset]]
            nonzero = sum(1 for _, byte in leaves if byte)
            if nonzero > OVERLAY_MAX_NONZERO_SHARE * size or _address_used(llvm, glob):
                raise _Skip("dense or address used")
            guarded = size < OVERLAY_GUARD_BYTES or _used_by_hot_code(llvm, glob, minsize)
            members.append((nonzero, size, align, guarded, leaves, glob))
        except _Skip:
            pass
        glob = llvm.NextGlobal(glob)
    # The members with the most nonzero bytes are the hardest to place.
    members.sort(key=lambda m: (-m[0], -m[1], -m[2]))
    return members


def _pack(members: list) -> tuple[bytearray, list[int]]:
    """First fit: each member at the lowest aligned offset where its defined
    bytes agree with the blob and no guarded member's undefined byte would
    receive a nonzero byte."""
    blob, defined, guard = bytearray(), bytearray(), bytearray()
    nonzero_at: list[int] = []
    offsets = []
    for _, size, align, guarded, leaves, _ in members:
        own = {offset: byte for offset, byte in leaves if byte}
        base = 0
        while True:
            end = len(blob)
            ok = all(
                base + offset >= end
                or not (defined[base + offset] and blob[base + offset] != byte)
                and not (byte and guard[base + offset] and not defined[base + offset])
                for offset, byte in leaves
            )
            if ok and guarded:
                i = bisect.bisect_left(nonzero_at, base)
                while ok and i < len(nonzero_at) and nonzero_at[i] < base + size:
                    ok = own.get(nonzero_at[i] - base) == blob[nonzero_at[i]]
                    i += 1
            if ok:
                break
            base += align
        grow = base + size - len(blob)
        if grow > 0:
            blob.extend(bytes(grow))
            defined.extend(bytes(grow))
            guard.extend(bytes(grow))
        for offset, byte in leaves:
            if byte and not (defined[base + offset] and blob[base + offset] == byte):
                bisect.insort(nonzero_at, base + offset)
            blob[base + offset] = byte
            defined[base + offset] = 1
        if guarded:
            mine = {offset for offset, _ in leaves}
            for offset in range(size):
                if offset not in mine:
                    guard[base + offset] = 1
        offsets.append(base)
    return blob, offsets


def overlay_constants(llvm: Llvm, source: pathlib.Path, output: pathlib.Path) -> dict:
    ctx, mod = llvm.load(source)
    td = llvm.CreateTD(llvm.GetDL(mod))
    i8, i64 = llvm.Int8Ty(ctx), llvm.Int64Ty(ctx)
    members = _overlay_members(llvm, mod, td, llvm.kind("minsize"))
    summary = {
        "pass": "overlay-constants",
        "members": len(members),
        "guarded_members": sum(1 for m in members if m[3]),
        "member_bytes": sum(m[1] for m in members),
        "blob_bytes": 0,
    }
    if members:
        blob_bytes, offsets = _pack(members)
        summary["blob_bytes"] = len(blob_bytes)
        blob = llvm.AddGlobal(mod, llvm.ArrayType2(i8, len(blob_bytes)), OVERLAY_BLOB)
        llvm.SetInitializer(blob, llvm.ConstString(ctx, bytes(blob_bytes), len(blob_bytes), 1))
        llvm.SetGlobalConstant(blob, 1)
        llvm.SetLinkage(blob, INTERNAL_LINKAGE)
        llvm.SetUnnamedAddress(blob, GLOBAL_UNNAMED_ADDR)
        llvm.SetAlignment(blob, max(m[2] for m in members))
        for (_, _, _, _, _, glob), base in zip(members, offsets):
            index = (P * 1)(llvm.ConstInt(i64, base, 0))
            target = llvm.ConstGEP2(i8, blob, index, 1) if base else blob
            # One alias per member keeps each reference its own symbol, so
            # codegen does not share a blob base across a function's offsets.
            name = llvm.name(glob).encode()
            llvm.SetValueName2(glob, b"", 0)
            alias = llvm.AddAlias2(mod, llvm.GlobalValueType(glob), 0, target, name)
            llvm.SetLinkage(alias, INTERNAL_LINKAGE)
            llvm.SetUnnamedAddress(alias, GLOBAL_UNNAMED_ADDR)
            llvm.ReplaceAllUses(glob, alias)
            llvm.DeleteGlobal(glob)
    summary["saved_bytes"] = summary["member_bytes"] - summary["blob_bytes"]
    llvm.save(mod, output)
    return summary


def _instructions(llvm: Llvm, fn):
    block = llvm.FirstBlock(fn)
    while block:
        inst = llvm.FirstInstruction(block)
        while inst:
            following = llvm.NextInstruction(inst)
            yield inst
            inst = following
        block = llvm.NextBlock(block)


def _expandable_operands(llvm: Llvm, inst) -> range:
    count = llvm.NumOperands(inst)
    if llvm.IsAPHINode(inst) or llvm.IsALandingPad(inst) or llvm.IsAIntrinsic(inst):
        return range(0)
    if llvm.IsACallInst(inst) or llvm.IsAInvoke(inst) or llvm.IsACallBr(inst):
        # The last operand is the callee.
        return range(count - 1)
    return range(count)


def _rebuild(llvm: Llvm, builder, expression, before, summary: dict):
    """An instruction before `before` computing `expression`, or None when its
    opcode is not one this pass rebuilds. The builder folds an instruction
    whose operands are all constants back into an expression, so each one is
    built on a frozen placeholder and then given the constant."""
    opcode = llvm.ConstOpcode(expression)
    if opcode != GET_ELEMENT_PTR and opcode not in CASTS:
        summary["kept_expressions"] += 1
        return None
    operands = []
    for i in range(llvm.NumOperands(expression)):
        operand = llvm.GetOperand(expression, i)
        if llvm.IsAConstantExpr(operand):
            operand = _rebuild(llvm, builder, operand, before, summary) or operand
        operands.append(operand)
    llvm.PositionBefore(builder, before)
    placeholder = llvm.BuildFreeze(builder, operands[0], b"")
    if opcode == GET_ELEMENT_PTR:
        indices = (P * (len(operands) - 1))(*operands[1:])
        inst = llvm.BuildGEPNoWrap(
            builder,
            llvm.GEPSourceType(expression),
            placeholder,
            indices,
            len(operands) - 1,
            b"pgso.expr",
            llvm.GEPNoWrapFlags(expression),
        )
    else:
        inst = llvm.BuildCast(builder, opcode, placeholder, llvm.TypeOf(expression), b"pgso.expr")
    if not inst or inst == placeholder:
        raise PassError(f"constant expression with opcode {opcode} did not become an instruction")
    llvm.SetOperand(inst, 0, operands[0])
    llvm.Erase(placeholder)
    summary["rebuilt_instructions"] += 1
    return inst


def expand_constant_exprs(llvm: Llvm, source: pathlib.Path, output: pathlib.Path) -> dict:
    ctx, mod = llvm.load(source)
    builder = llvm.CreateBuilder(ctx)
    summary = {"pass": "expand-constant-exprs", "rewritten_operands": 0, "rebuilt_instructions": 0, "kept_expressions": 0}
    fn = llvm.FirstFunction(mod)
    while fn:
        if not llvm.IsDeclaration(fn):
            for inst in _instructions(llvm, fn):
                for index in _expandable_operands(llvm, inst):
                    operand = llvm.GetOperand(inst, index)
                    if not llvm.IsAConstantExpr(operand):
                        continue
                    rebuilt = _rebuild(llvm, builder, operand, inst, summary)
                    if rebuilt:
                        llvm.SetOperand(inst, index, rebuilt)
                        summary["rewritten_operands"] += 1
        fn = llvm.NextFunction(fn)
    llvm.save(mod, output)
    return summary


def _swapped_compare(llvm: Llvm, builder, inst):
    """The less-than form of `inst` before it, or None when `inst` is not a
    greater-than comparison."""
    if llvm.IsAICmpInst(inst):
        predicate = SWAPPED_INT_PREDICATES.get(llvm.ICmpPredicate(inst))
        build = llvm.BuildICmp
    elif llvm.IsAFCmpInst(inst):
        predicate = SWAPPED_REAL_PREDICATES.get(llvm.FCmpPredicate(inst))
        build = llvm.BuildFCmp
    else:
        return None
    if predicate is None:
        return None
    llvm.PositionBefore(builder, inst)
    swapped = build(builder, predicate, llvm.GetOperand(inst, 1), llvm.GetOperand(inst, 0), b"")
    if llvm.IsAICmpInst(swapped):
        llvm.SetICmpSameSign(swapped, llvm.ICmpSameSign(inst))
    elif llvm.IsAFCmpInst(swapped):
        llvm.SetFastMathFlags(swapped, llvm.FastMathFlags(inst))
    else:
        # The builder folded two constants into one.
        return swapped
    location = llvm.DebugLoc(inst)
    if location:
        llvm.SetDebugLoc(swapped, location)
    return swapped


def swap_compares(llvm: Llvm, source: pathlib.Path, output: pathlib.Path) -> dict:
    ctx, mod = llvm.load(source)
    builder = llvm.CreateBuilder(ctx)
    summary = {"pass": "swap-compares", "swapped_compares": 0}
    fn = llvm.FirstFunction(mod)
    while fn:
        if not llvm.IsDeclaration(fn):
            for inst in _instructions(llvm, fn):
                swapped = _swapped_compare(llvm, builder, inst)
                if swapped is None:
                    continue
                name = llvm.name(inst).encode()
                llvm.ReplaceAllUses(inst, swapped)
                llvm.Erase(inst)
                if name and llvm.IsAInstruction(swapped):
                    llvm.SetValueName2(swapped, name, len(name))
                summary["swapped_compares"] += 1
        fn = llvm.NextFunction(fn)
    llvm.save(mod, output)
    return summary


def _holds_parameter(llvm: Llvm, expression) -> bool:
    for i in range(llvm.NumOperands(expression)):
        operand = llvm.GetOperand(expression, i)
        if not llvm.IsConstant(operand):
            return True
        if llvm.IsAConstantExpr(operand) and _holds_parameter(llvm, operand):
            return True
    return False


def check_outlined(llvm: Llvm, source: pathlib.Path) -> dict:
    _, mod = llvm.load(source)
    summary = {"pass": "check-outlined", "outlined_functions": 0}
    findings = []
    fn = llvm.FirstFunction(mod)
    while fn:
        name = llvm.name(fn)
        if not llvm.IsDeclaration(fn) and name.startswith(OUTLINED_PREFIX):
            summary["outlined_functions"] += 1
            for inst in _instructions(llvm, fn):
                if llvm.name(inst).startswith("constexpr"):
                    findings.append(f"{name}: rebuilt constant expression {llvm.name(inst)}")
                for index in range(llvm.NumOperands(inst)):
                    operand = llvm.GetOperand(inst, index)
                    if llvm.IsAConstantExpr(operand) and _holds_parameter(llvm, operand):
                        findings.append(f"{name}: constant expression with a parameter operand")
        fn = llvm.NextFunction(fn)
    if findings:
        raise PassError("IR outliner folded a nested constant into a parameter: " + "; ".join(findings[:8]))
    return summary


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--libllvm", required=True, type=pathlib.Path)
    parser.add_argument(
        "command",
        choices=("outline-helpers", "sparse-constants", "overlay-constants", "expand-constant-exprs", "swap-compares", "check-outlined"),
    )
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path, nargs="?")
    args = parser.parse_args(argv)
    if (args.output is None) != (args.command == "check-outlined"):
        parser.error("check-outlined takes only an input; the other commands need an output")
    try:
        llvm = Llvm(args.libllvm)
        if args.command == "check-outlined":
            summary = check_outlined(llvm, args.source)
        else:
            run = {
                "outline-helpers": outline_helpers,
                "sparse-constants": sparse_constants,
                "overlay-constants": overlay_constants,
                "expand-constant-exprs": expand_constant_exprs,
                "swap-compares": swap_compares,
            }[args.command]
            summary = run(llvm, args.source, args.output)
    except (OSError, PassError) as error:
        sys.stderr.write(f"ir_size: {error}\n")
        return 1
    sys.stdout.write(json.dumps(summary, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
