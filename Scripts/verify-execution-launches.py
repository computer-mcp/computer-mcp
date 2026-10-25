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


def code(source, swift=True):
    """Blanks comments and literal text, keeping line numbers and interpolated code.

    Swift block comments nest, and string interpolations (\\( or \\#( in raw strings)
    are code again until their closing parenthesis. C sources also have character literals.
    """
    out = list(source)
    length = len(source)

    def blank(start, stop):
        for index in range(start, stop):
            if out[index] != "\n":
                out[index] = " "

    # Each frame is ("code", depth) or ("string", hashes, multiline).
    stack = [("code", 0)]
    index = 0
    while index < length:
        frame = stack[-1]
        char = source[index]
        if frame[0] == "string":
            _, hashes, multiline = frame
            closer = ('"""' if multiline else '"') + "#" * hashes
            opener = "\\" + "#" * hashes + "("
            if source.startswith(opener, index):
                blank(index, index + len(opener))
                index += len(opener)
                stack.append(("code", 1))
            elif source.startswith("\\" + "#" * hashes, index):
                # An escape: one character after the backslash and the string's hashes.
                stop = min(index + 2 + hashes, length)
                blank(index, stop)
                index = stop
            elif source.startswith(closer, index):
                blank(index, index + len(closer))
                index += len(closer)
                stack.pop()
            else:
                blank(index, index + 1)
                index += 1
            continue
        if source.startswith("//", index):
            stop = source.find("\n", index)
            stop = length if stop < 0 else stop
            blank(index, stop)
            index = stop
        elif source.startswith("/*", index):
            depth, stop = 1, index + 2
            while stop < length and depth:
                if swift and source.startswith("/*", stop):
                    depth, stop = depth + 1, stop + 2
                elif source.startswith("*/", stop):
                    depth, stop = depth - 1, stop + 2
                else:
                    stop += 1
            blank(index, stop)
            index = stop
        elif swift and char == "#" and source[index:].lstrip("#").startswith('"'):
            hashes = len(source[index:]) - len(source[index:].lstrip("#"))
            quote = index + hashes
            multiline = source.startswith('"""', quote)
            stop = quote + (3 if multiline else 1)
            blank(index, stop)
            index = stop
            stack.append(("string", hashes, multiline))
        elif char == '"':
            multiline = swift and source.startswith('"""', index)
            stop = index + (3 if multiline else 1)
            blank(index, stop)
            index = stop
            stack.append(("string", 0, multiline))
        elif not swift and char == "'":
            stop = index + 1
            while stop < length and source[stop] != "'":
                stop += 2 if source[stop] == "\\" else 1
            blank(index, stop + 1)
            index = stop + 1
        elif char == "(" and len(stack) > 1:
            stack[-1] = ("code", frame[1] + 1)
            index += 1
        elif char == ")" and len(stack) > 1:
            if frame[1] == 1:
                blank(index, index + 1)
                stack.pop()
            else:
                stack[-1] = ("code", frame[1] - 1)
            index += 1
        else:
            index += 1
    return "".join(out)


def violations(root):
    for path in sorted((root / "Sources").rglob("*")):
        if path.suffix not in {".swift", ".c", ".h", ".m", ".mm"}:
            continue
        relative = path.relative_to(root).as_posix()
        if relative in IMPLEMENTATION:
            continue
        source = code(path.read_text(), swift=path.suffix == ".swift")
        for match in LAUNCH.finditer(source):
            line = source[:match.start()].count("\n") + 1
            yield f"{relative}:{line}: {match.group().strip()}"


if __name__ == "__main__":
    failures = list(violations(ROOT))
    if failures:
        print("\n".join(failures), file=sys.stderr)
        sys.exit("Execution launch gate failed: host subprocesses must use ExecutionLauncher.")
    print("Execution launch gate passed.")
