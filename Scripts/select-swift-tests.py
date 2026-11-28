#!/usr/bin/env python3
"""Plan and run the root Swift package tests affected by a committed diff."""

import argparse
import json
from pathlib import Path, PurePosixPath
import re
import runpy
import shlex
import subprocess
import sys


SCRIPTS = Path(__file__).resolve().parent
ROOT = SCRIPTS.parent
SWIFT = "/usr/bin/swift" if sys.platform == "darwin" else "swift"
TEST = re.compile(r"[A-Za-z_]\w*(?:\.[^\s/]+)?/[^\s/]+", re.ASCII)
SUITE = re.compile(r"(?:final )?(?:struct|class|enum) ([A-Za-z_]\w*)\s*(?:: [^;{}]+)?\s*\{\}", re.ASCII)
SOURCE_SUFFIXES = {".swift", ".c", ".h", ".modulemap"}

# These adapters locate the bootstrap executable at runtime.
RUNTIME_CONSUMERS = {
    "computer-mcp-execution-bootstrap": {"ComputerMCPPlatformPOSIX", "ComputerMCPPlatformDarwin"},
}


class FullRun(Exception):
    pass


def capture(*command):
    return subprocess.run(command, cwd=ROOT, check=True, capture_output=True).stdout.decode("utf-8")


def changed_paths(base):
    if not base:
        raise FullRun("missing base commit")
    try:
        base = capture("git", "rev-parse", "--verify", "--quiet", "--end-of-options", base + "^{commit}").strip()
        raw = capture("git", "diff", "--no-ext-diff", "--raw", "--find-renames", "-z", base, "HEAD", "--")
    except (subprocess.CalledProcessError, OSError, ValueError):
        raise FullRun("base commit or its diff is unavailable") from None
    if not raw:
        raise FullRun("the base and HEAD have no changed paths")

    fields = iter(raw.rstrip("\0").split("\0"))
    changes = []
    for header in fields:
        old, new, _, _, status = header.split()
        if old[1:] not in {"000000", "100644", "100755"} or new not in {"000000", "100644", "100755"}:
            raise FullRun("diff contains a non-regular file")
        if status.startswith("R"):
            changes.extend(("R", PurePosixPath(next(fields))) for _ in range(2))
        elif status in {"A", "D", "M"}:
            changes.append((status, PurePosixPath(next(fields))))
        else:
            raise FullRun(f"unsupported Git diff status {status}")
    return base, changes


def affected_modules(targets, changed):
    names = targets.keys()
    consumers = {name: set(RUNTIME_CONSUMERS.get(name, ())) & names for name in names}
    for name, target in targets.items():
        for dependency in target["dependencies"]:
            reference = dependency.get("target") or dependency.get("byName")
            if reference and reference[0] in names:
                consumers[reference[0]].add(name)

    modules = set()
    for source in changed:
        affected = {source}
        pending = [source]
        while pending:
            added = consumers[pending.pop()] - affected
            affected.update(added)
            pending.extend(added)
        tests = {name for name in affected if targets[name]["type"] == "test"}
        if not tests:
            raise FullRun(f"source target {source} has no known test consumers")
        modules.update(tests)
    return modules


def suite_names(source):
    """Recognize suite-only files by inspecting top-level declarations."""
    names, groups, outline = set(), [], []
    closing = {"(": ")", "[": "]", "{": "}"}
    for character in source + "\n":
        if character in closing:
            if not groups:
                outline.append(character + closing[character])
            groups.append(closing[character])
        elif character in ")]}":
            if not groups or groups.pop() != character:
                return set()
        elif not groups and character == "\n":
            declaration = " ".join("".join(outline).split())
            outline.clear()
            if not declaration or re.fullmatch(
                r"(?:@testable )?import [\w.]+|#(?:if|elseif|else|endif)(?: [^;{}]+)?",
                declaration,
            ):
                continue
            if declaration in {"@Suite", "@Suite()"}:
                continue
            declaration = re.sub(r"^@Suite(?:\(\))? ", "", declaration)
            match = SUITE.fullmatch(declaration)
            if match:
                names.add(match[1])
            elif not re.fullmatch(
                r"(?:private|fileprivate) (?:final )?(?:struct|class|enum|func) \w+[^;{}]*\{\}", declaration
            ):
                return set()
        elif not groups:
            outline.append(character)
    return names if not groups else set()


def file_suites(base, status, path, directory, code_text):
    names = suite_names(code_text(capture("git", "show", f"HEAD:{path}")))
    if not names:
        return set()
    if status == "M":
        # Removing a suite or a shared declaration can affect sibling suites.
        previous = suite_names(code_text(capture("git", "show", f"{base}:{path}")))
        if not previous or not previous <= names:
            return set()
    # A suite type can also supply helpers to sibling files in its target.
    patterns = [argument for name in sorted(names) for argument in ("-e", name)]
    references = subprocess.run(
        ["git", "grep", "-l", "-w", "-F", *patterns, base, "HEAD", "--",
         f":(literal){directory}", f":(exclude,literal){path}"],
        cwd=ROOT, capture_output=True,
    )
    if references.returncode not in {0, 1}:
        raise FullRun("could not check whether a test suite is shared")
    return names if references.returncode == 1 else set()


def selected_plan(base):
    base, changes = changed_paths(base)
    if any(path.parts[0] not in {"Sources", "Tests"} for _, path in changes):
        raise FullRun("diff touches a path outside the root package targets")

    package = json.loads(capture(SWIFT, "package", "dump-package"))
    targets = {target["name"]: target for target in package["targets"]}
    directories = {
        PurePosixPath(target.get("path") or ("Tests/" if target["type"] == "test" else "Sources/") + name): name
        for name, target in targets.items()
    }
    modules, sources, test_files = set(), set(), []
    has_deletions = any(status == "D" for status, _ in changes)
    for status, path in changes:
        owners = [directory for directory in directories if directory in path.parents]
        if len(owners) != 1:
            raise FullRun(f"no unique package target owns {str(path)!r} on this platform")
        directory = owners[0]
        module = directories[directory]
        target = targets[module]
        if target["type"] == "test":
            inputs = target.get("exclude", []) + [resource["path"] for resource in target.get("resources", [])]
            is_input = any(path.is_relative_to(directory / item) for item in inputs)
            if status in {"D", "R"} or (status == "A" and has_deletions) or path.suffix != ".swift" or is_input:
                modules.add(module)
            else:
                test_files.append((status, path, directory, module))
        elif path.parts[0] == "Tests":
            raise FullRun(f"diff touches shared test input {str(path)!r}")
        elif path.suffix in SOURCE_SUFFIXES:
            sources.add(module)
        else:
            raise FullRun(f"diff touches an unclassified source input {str(path)!r}")

    modules.update(affected_modules(targets, sources))
    optimized = None
    if sys.platform == "darwin":
        optimized = runpy.run_path(str(SCRIPTS / "run-swift-tests.py"))["OPTIMIZED_TEST"]
        if optimized.split(".", 1)[0] in modules:
            raise FullRun("the macOS optimized test requires the full runner")

    inventory = set(capture(SWIFT, "test", "list").splitlines())
    if not inventory or any(not TEST.fullmatch(test) for test in inventory):
        raise FullRun("SwiftPM returned an empty or unrecognized test inventory")

    def discovered(name):
        return any(test.startswith((name + ".", name + "/")) for test in inventory)

    suites = set()
    if test_files:
        code_text = runpy.run_path(str(SCRIPTS / "verify-module-graph.py"))["code_text"]
        for status, path, directory, module in test_files:
            if module in modules:
                continue
            names = {f"{module}.{name}" for name in file_suites(base, status, path, directory, code_text)}
            if names and all(map(discovered, names)):
                suites.update(names)
            else:
                modules.add(module)

    prefixes = sorted(modules | {name for name in suites if name.split(".", 1)[0] not in modules})
    if not prefixes or not all(map(discovered, prefixes)):
        raise FullRun("a selected module or suite has no discovered tests")

    pattern = r"^(?:" + "|".join(map(re.escape, prefixes)) + r")[./]"
    if optimized and (optimized not in inventory or re.search(pattern, optimized)):
        raise FullRun("the macOS optimized test requires the full runner")
    return ", ".join(prefixes), [SWIFT, "test", "--no-parallel", "--skip-build", "--filter", pattern]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", nargs="?", help="base commit to compare with HEAD")
    parser.add_argument("--list-only", action="store_true", help="print the plan without running tests")
    args = parser.parse_args()
    try:
        reason, command = selected_plan(args.base)
        plan = f"Selected tests for changed paths: {reason}"
    except (FullRun, subprocess.CalledProcessError, OSError, ValueError, KeyError, StopIteration) as failure:
        reason = str(failure) if isinstance(failure, FullRun) else "could not resolve the diff, package graph, or test inventory"
        plan = f"Full test suite: {reason}"
        command = ([sys.executable, "Scripts/run-swift-tests.py"] if sys.platform == "darwin"
                   else [SWIFT, "test", "--no-parallel"])
    print(f"{plan}\nCommand: {shlex.join(command)}", flush=True)
    if args.list_only:
        return 0
    try:
        status = subprocess.run(command, cwd=ROOT).returncode
    except OSError as failure:
        print(failure, file=sys.stderr)
        return 1
    return status if status >= 0 else 128 - status


if __name__ == "__main__":
    sys.exit(main())
