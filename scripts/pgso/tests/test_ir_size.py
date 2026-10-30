from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

from scripts.pgso.pipeline import _require_bitcode_header
from scripts.pgso.toolchain import IR_SIZE_SCRIPT

LLVM_BIN = pathlib.Path(os.environ.get("FX_PGSO_LLVM_BIN", "/opt/homebrew/opt/llvm@22/bin"))
LIBLLVM = (LLVM_BIN.parent / "lib" / ("libLLVM.dylib" if sys.platform == "darwin" else "libLLVM.so")).resolve()
AVAILABLE = (LLVM_BIN / "llvm-as").is_file() and LIBLLVM.is_file()

# The production module layout; alignment decisions depend on it.
TARGET = (
    'target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"\n'
    'target triple = "aarch64-apple-macosx15.0.0-unknown"\n'
)
MEMCPY = "declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)\n"
ERROR_UNION = (
    "%Payload = type { [64 x i8] }\n"
    "@error_return = internal unnamed_addr constant { %Payload, i16, [6 x i8] } "
    "{ %Payload undef, i16 653, [6 x i8] undef }, align 8\n"
)


class LlvmCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(prefix="fx-pgso-ir-size-")
        self.root = pathlib.Path(self.temporary_directory.name)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def assemble(self, name: str, ir: str) -> pathlib.Path:
        source = self.root / f"{name}.ll"
        source.write_text(TARGET + ir)
        output = self.root / f"{name}.bc"
        subprocess.run([str(LLVM_BIN / "llvm-as"), str(source), "-o", str(output)], check=True)
        return output

    def run_pass(self, command: str, source: pathlib.Path) -> tuple[subprocess.CompletedProcess, pathlib.Path]:
        output = self.root / f"{source.stem}.{command}.bc"
        result = subprocess.run(
            [sys.executable, str(IR_SIZE_SCRIPT), "--libllvm", str(LIBLLVM), command, str(source), str(output)],
            capture_output=True,
            text=True,
        )
        return result, output

    def cleaned_ir(self, bitcode: pathlib.Path) -> str:
        cleaned = self.root / f"{bitcode.stem}.clean.bc"
        subprocess.run(
            [str(LLVM_BIN / "opt"), "-passes=globaldce,verify", str(bitcode), "-o", str(cleaned)],
            check=True,
        )
        return subprocess.run(
            [str(LLVM_BIN / "llvm-dis"), str(cleaned), "-o", "-"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout


@unittest.skipUnless(AVAILABLE, "pinned LLVM 21 with libLLVM is not installed")
class IrSizeTests(LlvmCase):
    def test_error_union_return_copy_becomes_one_code_store(self) -> None:
        source = self.assemble(
            "error_union",
            ERROR_UNION + MEMCPY + "define void @fail(ptr align 8 %out) {\n"
            "  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 @error_return, i64 72, i1 false)\n"
            "  ret void\n}\n",
        )
        result, output = self.run_pass("sparse-constants", source)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("", result.stderr)
        self.assertIn('"rewritten_copies": 1', result.stdout)
        ir = self.cleaned_ir(output)
        self.assertNotIn("llvm.memcpy.p0.p0.i64(ptr", ir.split("declare")[0])
        self.assertNotIn("@error_return", ir)
        self.assertIn("getelementptr inbounds i8, ptr %out, i64 64", ir)
        self.assertIn("store i16 653, ptr", ir)
        self.assertTrue(ir.split("store i16 653")[1].splitlines()[0].endswith("align 2"))

    def test_defined_zero_bytes_are_still_stored(self) -> None:
        source = self.assemble(
            "zeros",
            "@state = internal unnamed_addr constant { i64, [56 x i8] } { i64 0, [56 x i8] undef }\n"
            + MEMCPY
            + "define void @init(ptr align 8 %out) {\n"
            "  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 @state, i64 64, i1 false)\n"
            "  ret void\n}\n",
        )
        result, output = self.run_pass("sparse-constants", source)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("store i64 0, ptr %out, align 8", self.cleaned_ir(output))

    def test_constants_with_other_uses_or_unsafe_copies_are_untouched(self) -> None:
        cases = {
            "loaded": "  %v = load i16, ptr getelementptr inbounds (i8, ptr @error_return, i64 64)\n"
            "  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 @error_return, i64 72, i1 false)\n",
            "volatile": "  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 @error_return, i64 72, i1 true)\n",
            "split_leaf": "  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 @error_return, i64 65, i1 false)\n",
            "variable": "  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 @error_return, i64 %n, i1 false)\n",
        }
        for name, body in cases.items():
            with self.subTest(case=name):
                source = self.assemble(
                    name,
                    ERROR_UNION + MEMCPY + f"define void @f(ptr align 8 %out, i64 %n) {{\n{body}  ret void\n}}\n",
                )
                result, output = self.run_pass("sparse-constants", source)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertIn('"rewritten_copies": 0', result.stdout)
                self.assertIn("@error_return", self.cleaned_ir(output))

    def test_shared_std_helpers_become_noinline(self) -> None:
        cases = (
            ("mem.Allocator.free__func_12", True),
            ("mem.Allocator.free", True),
            ("mem.Allocator.remap__func_7", True),
            ("Io.Writer.writeAll", True),
            ("Io.Writer.writeByte", True),
            ('"array_list.Aligned(u8,null).deinit"', True),
            ('"array_list.Aligned(u16,null).deinit"', True),
            ('"array_list.Aligned(u8,null).append"', False),
            ("mem.eql__func_4", True),
            ("mem.eqlBytes", False),
            ("Io.Mutex.lockUncancelable", True),
            ("Io.Mutex.unlock", True),
            ("Io.Mutex.tryLock", False),
            ("mem.Allocator.dupe", False),
        )
        body = "".join(f"define internal void @{name}(ptr %p) {{\n  ret void\n}}\n" for name, _ in cases)
        calls = "".join(f"  call void @{name}(ptr %p)\n" for name, _ in cases)
        source = self.assemble("helpers", body + f"define void @use(ptr %p) {{\n{calls}  ret void\n}}\n")
        result, output = self.run_pass("outline-helpers", source)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn(f'"marked_functions": {sum(marked for _, marked in cases)}', result.stdout)
        # The pipeline validates this output before it records the identity.
        _require_bitcode_header(output)
        ir = subprocess.run(
            [str(LLVM_BIN / "llvm-dis"), str(output), "-o", "-"], check=True, capture_output=True, text=True
        ).stdout
        attributes = {
            line.split("=", 1)[0].strip(): line for line in ir.splitlines() if line.startswith("attributes #")
        }
        for name, expected in cases:
            definition = next(line for line in ir.splitlines() if line.startswith("define") and f"@{name}(" in line)
            group = definition.rsplit("#", 1)[1].split()[0] if "#" in definition else None
            marked = group is not None and "noinline" in attributes.get(f"attributes #{group}", "")
            self.assertEqual(expected, marked, definition)

    def test_helper_pass_fails_closed_without_the_allocator_free_helper(self) -> None:
        source = self.assemble(
            "no_free",
            "define internal void @Io.Writer.writeAll(ptr %p) {\n  ret void\n}\n"
            "define void @main(ptr %p) {\n  call void @Io.Writer.writeAll(ptr %p)\n  ret void\n}\n",
        )
        result, output = self.run_pass("outline-helpers", source)

        self.assertEqual(1, result.returncode)
        self.assertIn("no out-of-line helper matched", result.stderr)
        self.assertFalse(output.exists())


def _blob_layout(ir: str) -> tuple[bytes, dict[str, int]]:
    """The overlaid blob's bytes and each alias's offset into it."""
    line = next(l for l in ir.splitlines() if l.startswith("@pgso.overlaid_constants = "))
    literal = line.split(' c"', 1)[1].rsplit('"', 1)[0]
    raw, i = bytearray(), 0
    while i < len(literal):
        if literal[i] == "\\":
            raw.append(int(literal[i + 1:i + 3], 16))
            i += 3
        else:
            raw.append(ord(literal[i]))
            i += 1
    offsets = {}
    for l in ir.splitlines():
        if " alias " in l and "@pgso.overlaid_constants" in l:
            name = l.split(" =", 1)[0].lstrip("@")
            offsets[name] = int(l.rsplit("i64 ", 1)[1].rstrip(")")) if "getelementptr" in l else 0
    return bytes(raw), offsets


# Cold (minsize) copies of three error-union results and one null optional.
OVERLAY = (
    "%Big = type { [120 x i8] }\n"
    "%Small = type { [40 x i8] }\n"
    "@big_a = internal unnamed_addr constant { %Big, i16, [6 x i8] } { %Big undef, i16 653, [6 x i8] undef }, align 8\n"
    "@big_b = internal unnamed_addr constant { %Big, i16, [6 x i8] } { %Big undef, i16 17, [6 x i8] undef }, align 8\n"
    "@small = internal unnamed_addr constant { %Small, i16, [6 x i8] } { %Small undef, i16 9, [6 x i8] undef }, align 8\n"
    "@none = internal unnamed_addr constant { %Big, i8, [7 x i8] } { %Big undef, i8 0, [7 x i8] undef }, align 8\n"
    + MEMCPY
    + "define void @cold(ptr %out, i2 %which) minsize {\n"
    "  switch i2 %which, label %d [ i2 0, label %a i2 1, label %b i2 -2, label %s ]\n"
    "a:\n  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 @big_a, i64 %n.a, i1 false)\n  ret void\n"
    "b:\n  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 @big_b, i64 %n.a, i1 false)\n  ret void\n"
    "s:\n  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 @small, i64 %n.a, i1 false)\n  ret void\n"
    "d:\n  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 @none, i64 %n.a, i1 false)\n  ret void\n"
    "}\n"
).replace("%n.a", "128")


@unittest.skipUnless(AVAILABLE, "pinned LLVM with libLLVM is not installed")
class OverlayConstantTests(LlvmCase):
    def text(self, bitcode: pathlib.Path) -> str:
        return subprocess.run(
            [str(LLVM_BIN / "llvm-dis"), str(bitcode), "-o", "-"], check=True, capture_output=True, text=True
        ).stdout

    def test_mostly_undefined_constants_share_one_blob_and_keep_their_bytes(self) -> None:
        source = self.assemble(
            "overlay",
            OVERLAY
            + "define i16 @code_a() minsize {\n  %v = load i16, ptr getelementptr inbounds (i8, ptr @big_a, i64 120), align 8\n  ret i16 %v\n}\n"
            "define i16 @code_b() minsize {\n  %v = load i16, ptr getelementptr inbounds (i8, ptr @big_b, i64 120), align 8\n  ret i16 %v\n}\n"
            "define i8 @tag() minsize {\n  %v = load i8, ptr getelementptr inbounds (i8, ptr @none, i64 120), align 8\n  ret i8 %v\n}\n",
        )
        result, output = self.run_pass("overlay-constants", source)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("", result.stderr)
        self.assertIn('"members": 4', result.stdout)
        ir = self.cleaned_ir(output)
        blob, offsets = _blob_layout(ir)
        self.assertEqual({"big_a", "big_b", "small", "none"}, set(offsets))
        self.assertLess(len(blob), 3 * 128 + 48)
        for name, offset in offsets.items():
            self.assertEqual(0, offset % 8, name)
            self.assertLessEqual(offset + (48 if name == "small" else 128), len(blob), name)
        self.assertEqual(653, int.from_bytes(blob[offsets["big_a"] + 120:][:2], "little"))
        self.assertEqual(17, int.from_bytes(blob[offsets["big_b"] + 120:][:2], "little"))
        self.assertEqual(9, int.from_bytes(blob[offsets["small"] + 40:][:2], "little"))
        self.assertEqual(0, blob[offsets["none"] + 120])
        # Loads through the aliases still fold to the original defined bytes.
        folded = self.root / "folded.bc"
        subprocess.run([str(LLVM_BIN / "opt"), "-passes=instsimplify", str(output), "-o", str(folded)], check=True)
        folded_ir = self.text(folded)
        self.assertIn("ret i16 653", folded_ir)
        self.assertIn("ret i16 17", folded_ir)
        self.assertIn("ret i8 0", folded_ir)

    def test_small_and_hot_members_read_zeros_in_their_undefined_bytes(self) -> None:
        source = self.assemble(
            "guarded",
            OVERLAY
            + "define i16 @hot() {\n  %v = load i16, ptr getelementptr inbounds (i8, ptr @big_b, i64 120), align 8\n  ret i16 %v\n}\n",
        )
        result, output = self.run_pass("overlay-constants", source)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('"guarded_members": 2', result.stdout)
        blob, offsets = _blob_layout(self.cleaned_ir(output))
        for name, size, code_at in (("small", 48, 40), ("big_b", 128, 120)):
            extent = bytearray(blob[offsets[name]:offsets[name] + size])
            extent[code_at:code_at + 2] = b"\0\0"
            self.assertEqual(bytes(size), bytes(extent), name)

    def test_pointer_address_and_placed_constants_are_untouched(self) -> None:
        source = self.assemble(
            "kept",
            "@target = global i64 0\n"
            "@relocated = internal unnamed_addr constant { ptr, [120 x i8] } { ptr @target, [120 x i8] undef }, align 8\n"
            "@compared = internal unnamed_addr constant { [120 x i8], i16, [6 x i8] } { [120 x i8] undef, i16 3, [6 x i8] undef }, align 8\n"
            "@named = internal unnamed_addr constant { [120 x i8], i16, [6 x i8] } { [120 x i8] undef, i16 4, [6 x i8] undef }, section \"__TEXT,__fx\", align 8\n"
            "@significant = internal constant { [120 x i8], i16, [6 x i8] } { [120 x i8] undef, i16 5, [6 x i8] undef }, align 8\n"
            "declare void @use(ptr)\n"
            "define i1 @f(ptr %p) minsize {\n"
            "  call void @use(ptr @relocated)\n  call void @use(ptr @named)\n  call void @use(ptr @significant)\n"
            "  %c = icmp eq ptr %p, @compared\n  ret i1 %c\n}\n",
        )
        result, output = self.run_pass("overlay-constants", source)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('"members": 0', result.stdout)
        ir = self.cleaned_ir(output)
        self.assertNotIn("@pgso.overlaid_constants", ir)
        for name in ("relocated", "compared", "named", "significant"):
            self.assertIn(f"@{name} = internal", ir)

    def test_constants_listed_as_used_stay_globals(self) -> None:
        source = self.assemble(
            "used",
            OVERLAY + '@llvm.used = appending global [1 x ptr] [ptr @big_a], section "llvm.metadata"\n',
        )
        result, output = self.run_pass("overlay-constants", source)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('"members": 3', result.stdout)
        ir = self.cleaned_ir(output)
        self.assertIn("@big_a = internal unnamed_addr constant", ir)
        self.assertIn("[ptr @big_a]", ir)
        self.assertEqual({"big_b", "small", "none"}, set(_blob_layout(ir)[1]))


if __name__ == "__main__":
    unittest.main()


# Two regions that differ only in an instruction's constant, 16 or 8898, next
# to a constant expression that nests the constant 16.
NESTED_CONSTANT = """@real_io = internal global { ptr, ptr, i8 } zeroinitializer, align 8
@sink = global i64 0
""" + "".join(
    f"""define i64 @{name}(ptr %app) {{
  %flag = load i8, ptr getelementptr inbounds (i8, ptr @real_io, i64 16), align 8
  %field = getelementptr inbounds i8, ptr %app, i64 {offset}
  %v = load i64, ptr %field, align 8
  %f = zext i8 %flag to i64
  %s = add i64 %v, %f
  store i64 %s, ptr @sink, align 8
  ret i64 %s
}}
"""
    for name, offset in (("first", 16), ("second", 8898))
)

# `low` is in bounds when x < 4; `high` is out of bounds when end > len.
REVERSED_COMPARE = "@sink = global i64 0\n" + "".join(
    f"""define i64 @{name}(ptr %app, {parameters}) {{
  %v = load i64, ptr %app, align 8
  %c = {compare}
  %z = zext i1 %c to i64
  %s = add i64 %v, %z
  store i64 %s, ptr @sink, align 8
  ret i64 %s
}}
"""
    for name, parameters, compare in (
        ("low", "i64 %x", "icmp ult i64 %x, 4"),
        ("high", "i64 %end, i64 %len", "icmp ugt i64 %end, %len"),
    )
)


@unittest.skipUnless(AVAILABLE, "pinned LLVM with libLLVM is not installed")
class OutlinedConstantTests(LlvmCase):
    def outline(self, source: pathlib.Path) -> pathlib.Path:
        output = self.root / f"{source.stem}.outlined.bc"
        subprocess.run(
            [str(LLVM_BIN / "opt"), "-passes=iroutliner", "-ir-outlining-no-cost", str(source), "-o", str(output)],
            check=True,
        )
        return output

    def check(self, bitcode: pathlib.Path) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(IR_SIZE_SCRIPT), "--libllvm", str(LIBLLVM), "check-outlined", str(bitcode)],
            capture_output=True,
            text=True,
        )

    def text(self, bitcode: pathlib.Path) -> str:
        return subprocess.run(
            [str(LLVM_BIN / "llvm-dis"), str(bitcode), "-o", "-"], check=True, capture_output=True, text=True
        ).stdout

    def test_check_rejects_a_nested_constant_the_outliner_folded_into_a_parameter(self) -> None:
        outlined = self.outline(self.assemble("nested", NESTED_CONSTANT))

        result = self.check(outlined)

        self.assertEqual(1, result.returncode, result.stdout)
        self.assertIn("folded a nested constant into a parameter", result.stderr)

    def test_expanded_expressions_keep_each_region_constant(self) -> None:
        result, expanded = self.run_pass("expand-constant-exprs", self.assemble("nested", NESTED_CONSTANT))
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('"rewritten_operands": 2', result.stdout)
        outlined = self.outline(expanded)

        check = self.check(outlined)

        self.assertEqual(0, check.returncode, check.stderr)
        self.assertIn('"outlined_functions": 1', check.stdout)
        ir = self.text(outlined)
        self.assertEqual(2, ir.count("getelementptr inbounds i8, ptr @real_io, i64 16"))
        self.assertIn("i64 8898", ir)
        self.assertNotIn("@real_io, i64 %", ir)

    def test_outliner_passes_a_greater_than_region_its_operands_unreversed(self) -> None:
        ir = self.text(self.outline(self.assemble("reversed", REVERSED_COMPARE)))

        self.assertIn("icmp ult i64 %1, %2", ir)
        self.assertIn("call void @outlined_ir_func_0(ptr %app, i64 %end, i64 %len,", ir)

    def test_swapped_compares_keep_each_region_comparison(self) -> None:
        result, swapped = self.run_pass("swap-compares", self.assemble("reversed", REVERSED_COMPARE))
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('"swapped_compares": 1', result.stdout)

        ir = self.text(self.outline(swapped))

        self.assertIn("icmp ult i64 %1, %2", ir)
        self.assertIn("call void @outlined_ir_func_0(ptr %app, i64 %x, i64 4,", ir)
        self.assertIn("call void @outlined_ir_func_0(ptr %app, i64 %len, i64 %end,", ir)

    def test_swap_compares_rewrites_every_greater_than_predicate_and_keeps_flags(self) -> None:
        compares = (
            ("icmp ugt i64 %a, %b", "icmp ult i64 %b, %a"),
            ("icmp samesign uge i64 %a, %b", "icmp samesign ule i64 %b, %a"),
            ("icmp sgt i64 %a, 7", "icmp slt i64 7, %a"),
            ("icmp sge i64 %a, %b", "icmp sle i64 %b, %a"),
            ("fcmp nnan ogt double %x, %y", "fcmp nnan olt double %y, %x"),
            ("fcmp oge double %x, %y", "fcmp ole double %y, %x"),
            ("fcmp ugt double %x, %y", "fcmp ult double %y, %x"),
            ("fcmp uge double %x, %y", "fcmp ule double %y, %x"),
        )
        kept = ("icmp ult i64 %a, %b", "icmp eq i64 %a, %b", "fcmp olt double %x, %y")
        body = "".join(f"  %c{i} = {compare}\n  store volatile i1 %c{i}, ptr %out\n" for i, compare in enumerate(
            [compare for compare, _ in compares] + list(kept)
        ))
        source = self.assemble(
            "compares",
            f"define void @f(i64 %a, i64 %b, double %x, double %y, ptr %out) {{\n{body}  ret void\n}}\n",
        )

        result, output = self.run_pass("swap-compares", source)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn(f'"swapped_compares": {len(compares)}', result.stdout)
        ir = self.cleaned_ir(output)
        for i, (_, swapped) in enumerate(compares):
            self.assertIn(f"%c{i} = {swapped}", ir)
        for i, compare in enumerate(kept, start=len(compares)):
            self.assertIn(f"%c{i} = {compare}", ir)
        for predicate in ("ugt", "uge", "sgt", "sge", "ogt", "oge"):
            self.assertNotIn(f" {predicate} ", ir)

    def test_phi_and_intrinsic_expressions_stay_constant_and_call_arguments_expand(self) -> None:
        source = self.assemble(
            "kept",
            "@g = global [4 x i64] zeroinitializer\n"
            + MEMCPY
            + "declare void @use(ptr)\n"
            "define ptr @f(i1 %c, ptr %out) {\n"
            "entry:\n"
            "  call void @llvm.memcpy.p0.p0.i64(ptr %out, ptr getelementptr inbounds (i8, ptr @g, i64 8), i64 8, i1 false)\n"
            "  call void @use(ptr getelementptr inbounds (i8, ptr @g, i64 16))\n"
            "  br i1 %c, label %a, label %b\n"
            "a:\n  br label %b\n"
            "b:\n"
            "  %p = phi ptr [ getelementptr inbounds (i8, ptr @g, i64 24), %a ], [ %out, %entry ]\n"
            "  ret ptr %p\n}\n",
        )

        result, output = self.run_pass("expand-constant-exprs", source)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('"rewritten_operands": 1', result.stdout)
        ir = self.cleaned_ir(output)
        self.assertIn("ptr getelementptr inbounds (i8, ptr @g, i64 8)", ir)
        self.assertIn("[ getelementptr inbounds (i8, ptr @g, i64 24), %a ]", ir)
        self.assertIn("%pgso.expr = getelementptr inbounds i8, ptr @g, i64 16", ir)
        self.assertIn("call void @use(ptr %pgso.expr)", ir)


@unittest.skipUnless(AVAILABLE, "pinned LLVM with libLLVM is not installed")
class MinsizeFunctionTests(LlvmCase):
    def test_lists_the_defined_functions_and_those_marked_minsize(self) -> None:
        source = self.assemble(
            "attributes",
            "define void @cold() minsize optsize { ret void }\n"
            "define void @hot() { ret void }\n"
            "declare void @external()\n",
        )
        output = self.root / "attributes.json"

        result = subprocess.run(
            [sys.executable, str(IR_SIZE_SCRIPT), "--libllvm", str(LIBLLVM), "minsize-functions", str(source), str(output)],
            capture_output=True,
            text=True,
        )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual({"defined": ["cold", "hot"], "minsize": ["cold"]}, json.loads(output.read_text()))
        self.assertEqual(
            {"pass": "minsize-functions", "defined_functions": 2, "minsize_functions": 1},
            json.loads(result.stdout),
        )


@unittest.skipUnless(AVAILABLE, "pinned LLVM with libLLVM is not installed")
class NoOutlineTests(LlvmCase):
    IR = (
        "define void @startup() { ret void }\n"
        "define void @other() { ret void }\n"
        "declare void @external()\n"
    )

    def no_outline(self, source: pathlib.Path, names: str) -> tuple[subprocess.CompletedProcess, pathlib.Path]:
        functions = self.root / "functions.txt"
        functions.write_text(names)
        output = self.root / "marked.bc"
        result = subprocess.run(
            [sys.executable, str(IR_SIZE_SCRIPT), "--libllvm", str(LIBLLVM), "--functions", str(functions),
             "no-outline", str(source), str(output)],
            capture_output=True,
            text=True,
        )
        return result, output

    def test_marks_only_the_listed_defined_functions(self) -> None:
        result, output = self.no_outline(self.assemble("functions", self.IR), "startup\nexternal\nmissing\n")

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(
            {"pass": "no-outline", "listed_functions": 3, "marked_functions": 1},
            json.loads(result.stdout),
        )
        text = subprocess.run(
            [str(LLVM_BIN / "llvm-dis"), str(output), "-o", "-"], check=True, capture_output=True, text=True
        ).stdout
        startup = next(line for line in text.splitlines() if line.startswith("define void @startup"))
        other = next(line for line in text.splitlines() if line.startswith("define void @other"))
        group = startup.split("#")[1].split()[0]
        self.assertIn('"nooutline"', next(line for line in text.splitlines() if line.startswith(f"attributes #{group} ")))
        self.assertNotIn("#", other)

    def test_fails_when_no_listed_function_is_defined(self) -> None:
        result, output = self.no_outline(self.assemble("functions", self.IR), "external\nmissing\n")

        self.assertEqual(1, result.returncode)
        self.assertIn("is defined", result.stderr)
        self.assertFalse(output.exists())
