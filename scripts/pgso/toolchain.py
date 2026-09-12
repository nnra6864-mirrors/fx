from __future__ import annotations

import dataclasses
import os
import pathlib
import platform
import re
import shutil
import subprocess

from scripts.pgso.model import PgsoError


REQUIRED_ZIG_VERSION = "0.16.0"
REQUIRED_LLVM_VERSION = "21.1.8"
SUPPORTED_TARGET = "aarch64-macos"


def _resolve_executable(command: str, display_name: str) -> pathlib.Path:
    resolved = shutil.which(command)
    if resolved is None:
        raise PgsoError(f"missing executable: {display_name}")
    return pathlib.Path(resolved).resolve()


def _capture(argv: tuple[str, ...], stage: str) -> str:
    try:
        result = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise PgsoError(f"could not query {stage}: {error}") from error
    if result.returncode != 0:
        raise PgsoError(
            f"could not query {stage}: exit code {result.returncode}: "
            f"{result.stderr.strip()}"
        )
    return result.stdout.strip()


def _llvm_version(tool: pathlib.Path, display_name: str) -> str:
    output = _capture((str(tool), "--version"), f"{display_name} version")
    match = re.search(r"\b\d+\.\d+\.\d+\b", output)
    if match is None:
        raise PgsoError(f"could not parse LLVM version from {display_name}: {output}")
    version = match.group(0)
    if version != REQUIRED_LLVM_VERSION:
        raise PgsoError(
            f"PGSO requires LLVM {REQUIRED_LLVM_VERSION}; "
            f"{display_name} reported {version}"
        )
    return version


@dataclasses.dataclass(frozen=True)
class Toolchain:
    zig: pathlib.Path
    llvm_bin: pathlib.Path
    opt: pathlib.Path
    llc: pathlib.Path
    llvm_profdata: pathlib.Path
    llvm_ar: pathlib.Path
    clang: pathlib.Path
    ld64_lld: pathlib.Path
    strip: pathlib.Path
    codesign: pathlib.Path
    otool: pathlib.Path
    xcrun: pathlib.Path
    sdk: pathlib.Path
    sdk_version: str
    profile_runtime: pathlib.Path
    zig_version: str
    llvm_version: str
    target: str
    host_arch: str

    @classmethod
    def discover(
        cls,
        zig: str,
        llvm_bin: str,
        target: str,
    ) -> "Toolchain":
        if target != SUPPORTED_TARGET:
            raise PgsoError(f"unsupported target: {target}")
        if platform.system() != "Darwin":
            raise PgsoError("PGSO requires a Darwin host")
        host_arch = platform.machine()
        if host_arch != "arm64":
            raise PgsoError("PGSO requires an arm64 host")

        zig_path = _resolve_executable(zig, "zig")
        zig_version = _capture((str(zig_path), "version"), "Zig version")
        if zig_version != REQUIRED_ZIG_VERSION:
            raise PgsoError(
                f"PGSO requires Zig {REQUIRED_ZIG_VERSION}; "
                f"zig reported {zig_version}"
            )

        llvm_root = pathlib.Path(llvm_bin).expanduser().resolve()
        if not llvm_root.is_dir():
            raise PgsoError(f"LLVM bin root does not exist: {llvm_root}")

        llvm_tools: dict[str, pathlib.Path] = {}
        for name in ("opt", "llc", "llvm-profdata", "llvm-ar", "clang"):
            candidate = llvm_root / name
            if not candidate.is_file() or not os.access(candidate, os.X_OK):
                raise PgsoError(f"missing executable: {name}")
            resolved = candidate.resolve()
            if resolved.parent != llvm_root:
                raise PgsoError(
                    f"LLVM tool escapes configured root: {name}: {resolved}"
                )
            llvm_tools[name] = resolved

        versions = {
            name: _llvm_version(path, name)
            for name, path in llvm_tools.items()
        }
        llvm_version = versions["opt"]
        linker_command = shutil.which("ld64.lld")
        if linker_command is None:
            raise PgsoError("missing executable: ld64.lld")
        linker_path = pathlib.Path(linker_command)
        # LLD selects its Mach-O driver from argv[0], including through symlinks.
        ld64_lld = linker_path.parent.resolve() / linker_path.name
        _llvm_version(ld64_lld, "ld64.lld")

        strip = _resolve_executable("strip", "strip")
        codesign = _resolve_executable("codesign", "codesign")
        otool = _resolve_executable("otool", "otool")
        xcrun = _resolve_executable("xcrun", "xcrun")

        sdk_output = _capture(
            (str(xcrun), "--sdk", "macosx", "--show-sdk-path"),
            "macOS SDK path",
        )
        sdk = pathlib.Path(sdk_output).expanduser().resolve()
        if not sdk.is_dir():
            raise PgsoError(f"macOS SDK does not exist: {sdk}")
        sdk_version = _capture(
            (str(xcrun), "--sdk", "macosx", "--show-sdk-version"),
            "macOS SDK version",
        )
        if re.fullmatch(r"\d+\.\d+(?:\.\d+)?", sdk_version) is None:
            raise PgsoError(f"invalid macOS SDK version: {sdk_version}")

        resource_output = _capture(
            (str(llvm_tools["clang"]), "--print-resource-dir"),
            "clang resource directory",
        )
        resource_dir = pathlib.Path(resource_output).expanduser().resolve()
        profile_runtime = (
            resource_dir / "lib" / "darwin" / "libclang_rt.profile_osx.a"
        )
        if not profile_runtime.is_file() or profile_runtime.stat().st_size == 0:
            raise PgsoError(
                f"missing LLVM profile runtime: {profile_runtime}"
            )

        return cls(
            zig=zig_path,
            llvm_bin=llvm_root,
            opt=llvm_tools["opt"],
            llc=llvm_tools["llc"],
            llvm_profdata=llvm_tools["llvm-profdata"],
            llvm_ar=llvm_tools["llvm-ar"],
            clang=llvm_tools["clang"],
            ld64_lld=ld64_lld,
            strip=strip,
            codesign=codesign,
            otool=otool,
            xcrun=xcrun,
            sdk=sdk,
            sdk_version=sdk_version,
            profile_runtime=profile_runtime.resolve(),
            zig_version=zig_version,
            llvm_version=llvm_version,
            target=target,
            host_arch=host_arch,
        )
