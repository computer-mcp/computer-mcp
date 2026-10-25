#!/usr/bin/env python3
"""Keep production subprocess creation inside the execution launcher's OS implementation."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
IMPLEMENTATION = {
    "Sources/ComputerMCPPlatformDarwin/DarwinExecutionPlatform.swift",
    "Sources/ComputerMCPPlatformDarwin/DarwinExecutionSentinel.swift",
    "Sources/ComputerMCPPlatformDarwin/DarwinExecutionOwnership.swift",
    "Sources/ComputerMCPPlatformPOSIX/POSIXExecutionPlatform.swift",
}
# Any use of Foundation's Process type, not only its constructors, can start a child
# (for example `let child: Process = .init()` or `Process.launchedProcess`).
LAUNCH = re.compile(
    r"\bProcess\b"
    r"|\bNSTask\b"
    r"|\bposix_spawnp?\s*\("
    r"|\bv?fork\s*\("
    r"|\bSubprocess\s*\.\s*run\s*\("
    r"|\bimport\s+Subprocess\b"
)


def code(source):
    """Blanks comments and string literals, keeping line numbers."""
    blank = lambda match: re.sub(r"[^\n]", " ", match.group())
    source = re.sub(r"/\*.*?\*/", blank, source, flags=re.S)
    source = re.sub(r'"""(?:.|\n)*?"""', blank, source)
    source = re.sub(r'"(?:\\.|[^"\\\n])*"', blank, source)
    return re.sub(r"//[^\n]*", blank, source)


def violations(root):
    for path in sorted((root / "Sources").rglob("*")):
        if path.suffix not in {".swift", ".c", ".h", ".m", ".mm"}:
            continue
        relative = path.relative_to(root).as_posix()
        if relative in IMPLEMENTATION:
            continue
        source = code(path.read_text())
        for match in LAUNCH.finditer(source):
            line = source[:match.start()].count("\n") + 1
            yield f"{relative}:{line}: {match.group().strip()}"


if __name__ == "__main__":
    failures = list(violations(ROOT))
    if failures:
        print("\n".join(failures), file=sys.stderr)
        sys.exit("Execution launch gate failed: host subprocesses must use ExecutionLauncher.")
    print("Execution launch gate passed.")
