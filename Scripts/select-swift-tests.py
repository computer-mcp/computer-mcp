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
FUNCTION_BLOCK = re.compile(r"^func \w+[^\n]*\}$|^func \w+[\s\S]*?^\}$", re.MULTILINE)
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


def declarations(source):
    """Pair each top-level declaration's outline with its complete code."""
    parts, groups, outline, start = [], [], [], 0
    closing = {"(": ")", "[": "]", "{": "}"}
    for index, character in enumerate(source + "\n"):
        if character in closing:
            if not groups:
                outline.append(character + closing[character])
            groups.append(closing[character])
        elif character in ")]}":
            if not groups or groups.pop() != character:
                return []
        elif not groups and character == "\n":
            declaration = " ".join("".join(outline).split())
            if declaration:
                parts.append((declaration, source[start:index]))
            outline.clear()
            start = index + 1
        elif not groups:
            outline.append(character)
    return [] if groups else parts


def suite_names(source):
    declared = []
    for outline, body in declarations(source):
        if re.fullmatch(r"(?:@testable )?import [\w.]+|#(?:if|elseif|else|endif)(?: [^;{}]+)?|@Suite(?:\(\))?", outline):
            continue
        suite = SUITE.fullmatch(re.sub(r"^@Suite(?:\(\))? ", "", outline))
        if not suite and not re.fullmatch(r"(?:private|fileprivate) (?:final )?(?:struct|class|enum|func) \w+[^;{}]*\{\}", outline):
            return set()
        declared.append((suite[1] if suite else None, body))
    names = {name for name, _ in declared if name}
    for name in names:
        if any(re.search(rf"\b{name}\b", body) for other, body in declared if other != name):
            return set()
    return names


def file_suites(base, status, path, directory, code_text):
    current = capture("git", "show", f"HEAD:{path}")
    if status == "M":
        previous = capture("git", "show", f"{base}:{path}")
        # Compare original blobs so changes inside strings count. Only a complete,
        # unchanged function may be treated like a file-local helper.
        unchanged = set(FUNCTION_BLOCK.findall(previous)) & set(FUNCTION_BLOCK.findall(current))
        helpers = set()
        for block in unchanged:
            parts = declarations(code_text(block))
            if len(parts) == 1 and re.fullmatch(r"func \w+[^;{}]*\{\}", parts[0][0]):
                helpers.add(block)

        def localize(match):
            return ("private " if match[0] in helpers else "") + match[0]

        current = FUNCTION_BLOCK.sub(localize, current)
        previous_names = suite_names(code_text(FUNCTION_BLOCK.sub(localize, previous)))
        if not previous_names:
            return set()
    names = suite_names(code_text(current))
    if not names or (status == "M" and not previous_names <= names):
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
    selected = {test for test in inventory if re.search(pattern, test)}
    reason = f"{len(selected)} tests matching {', '.join(prefixes)}"
    debug = [SWIFT, "test", "--no-parallel", "--skip-build", "--filter", pattern]
    if sys.platform == "darwin":
        runner = runpy.run_path(str(SCRIPTS / "run-swift-tests.py"))
        optimized = runner["OPTIMIZED_TEST"]
        if optimized not in inventory:
            raise FullRun("SwiftPM discovery is missing the optimized test")
        if optimized in selected:
            commands = [debug + ["--skip", runner["OPTIMIZED_PATTERN"]]] if len(selected) > 1 else []
            commands.append([sys.executable, "Scripts/run-swift-tests.py", "--optimized-only"])
            return f"{reason} (release build for {optimized})", commands
    return reason, [debug]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", nargs="?", help="base commit to compare with HEAD")
    parser.add_argument("--list-only", action="store_true", help="print the plan without running tests")
    args = parser.parse_args()
    try:
        reason, commands = selected_plan(args.base)
        plan = f"Selected tests for changed paths: {reason}"
    except (FullRun, subprocess.CalledProcessError, OSError, ValueError, KeyError, StopIteration) as failure:
        reason = str(failure) if isinstance(failure, FullRun) else "could not resolve the diff, package graph, or test inventory"
        plan = f"Full test suite: {reason}"
        commands = [[sys.executable, "Scripts/run-swift-tests.py"] if sys.platform == "darwin"
                    else [SWIFT, "test", "--no-parallel"]]
    print(plan, flush=True)
    for command in commands:
        print(f"Command: {shlex.join(command)}", flush=True)
    if args.list_only:
        return 0
    try:
        for command in commands:
            status = subprocess.run(command, cwd=ROOT).returncode
            if status:
                return status if status > 0 else 128 - status
    except OSError as failure:
        print(failure, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
