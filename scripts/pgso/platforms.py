"""The PGSO targets and the platform module that builds each one.

A platform module provides, for its target:

- `TARGET`, `DISPLAY_NAME`, `HOST_ARCH`, the only host architecture it
  builds on, and `LIBLLVM_NAME`, the LLVM C library `ir_size.py` loads;
- `check_host()`, which returns the host architecture after checking the host
  can build and run the target natively;
- `discover_tools(zig, clang)`, which returns the platform's native tools and
  the LLVM profile runtime;
- `read_control_identity(toolchain, binary, log)` and
  `control_identity_from_evidence(control)`: the control's properties the
  candidate must match, as the evidence fields the control records;
- `link_instrumented(toolchain, paths, compiler_runtime, control)`, which links
  and checks the instrumented executable;
- `public_api_flags(toolchain, paths)`, the symbols the outlined-IR cleanup
  keeps external;
- `link_candidate_binary(toolchain, paths)`, which links the candidate object
  into the final executable;
- `inspect_candidate(toolchain, paths, control)`, which checks the candidate's
  layout against the control and returns its metadata, and
  `candidate_evidence(metadata)`, the evidence fields for that metadata.
"""
from __future__ import annotations

from types import ModuleType

from scripts.pgso import macos
from scripts.pgso.model import PgsoError

_PLATFORMS: dict[str, ModuleType] = {macos.TARGET: macos}


def for_target(target: str) -> ModuleType:
    try:
        return _PLATFORMS[target]
    except KeyError:
        raise PgsoError(f"unsupported target: {target}") from None
