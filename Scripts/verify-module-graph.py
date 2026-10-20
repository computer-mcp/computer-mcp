#!/usr/bin/env python3
"""Verify the gateway module graph described in Documentation/Decisions/ModuleArchitecture.md.

Scripts/module-graph.json declares the layers (bottom-up), the dependencies permitted
between targets of the same layer, macOS platform boundaries and test ownership.

Package mode reads `swift package dump-package` and applies the layer, permission and
neutrality rules to declared target dependencies. Test support libraries are unranked,
neutral, and may be dependencies of test targets only. The package boundary gate also
uses the source import and macOS path checks defined here.

Usage: verify-module-graph.py [package] [--graph FILE] [--package-json FILE]
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
IMPORT = re.compile(r"^\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?(\w+)", re.M)
STRING_START = re.compile(r'(#*)("""|")')


def skip_string(text, index):
    """Index just past the string literal starting at index (including raw and multi-line forms)."""
    match = STRING_START.match(text, index)
    hashes, quote = match.group(1), match.group(2)
    index = match.end()
    close, escape = quote + hashes, "\\" + hashes
    while index < len(text):
        if text.startswith(close, index):
            return index + len(close)
        if text.startswith(escape + "(", index):
            index = skip_group(text, index + len(escape) + 1)
            continue
        if text.startswith(escape, index):
            index += len(escape) + 1
            continue
        if quote == '"' and text[index] == "\n":
            return index
        index += 1
    return index


def skip_group(text, index):
    """Index just past the parenthesized group whose opening parenthesis precedes index."""
    depth = 1
    while index < len(text) and depth:
        if STRING_START.match(text, index) and text[index] in "\"#":
            index = skip_string(text, index)
            continue
        depth += {"(": 1, ")": -1}.get(text[index], 0)
        index += 1
    return index


def code_text(text):
    """Remove comments and string literal text in one pass, keeping interpolated expressions."""
    out, index, length = [], 0, len(text)
    while index < length:
        if text.startswith("//", index):
            end = text.find("\n", index)
            index = length if end < 0 else end
            out.append(" ")
        elif text.startswith("/*", index):
            depth, index = 1, index + 2
            while index < length and depth:
                if text.startswith("/*", index):
                    depth, index = depth + 1, index + 2
                elif text.startswith("*/", index):
                    depth, index = depth - 1, index + 2
                else:
                    index += 1
            out.append(" ")
        elif text[index] in "\"#" and STRING_START.match(text, index):
            match = STRING_START.match(text, index)
            hashes = match.group(1)
            end = skip_string(text, index)
            literal, escape, parts, cursor = text[index:end], "\\" + hashes + "(", [], 0
            while True:
                start = literal.find(escape, cursor)
                if start < 0:
                    break
                group_end = skip_group(literal, start + len(escape))
                parts.append(code_text(literal[start + len(escape):group_end - 1]))
                cursor = group_end
            out.append(" " + " ".join(parts) + " ")
            index = end
        else:
            out.append(text[index])
            index += 1
    return "".join(out)


LINUX_C_LIBRARIES = {"Glibc", "Musl"}


def imports(text):
    """Imported modules, each paired with whether its innermost #if chain also imports a
    Linux C library, which makes the chain a platform C library selection."""
    found, chains = [], []
    for line in code_text(text).splitlines():
        stripped = line.strip()
        if stripped.startswith("#if"):
            chains.append({"imports": [], "selects": False})
        elif stripped.startswith("#endif"):
            if chains:
                chain = chains.pop()
                for index in chain["imports"]:
                    found[index] = (found[index][0], chain["selects"])
        else:
            match = IMPORT.match(line)
            if match:
                found.append((match.group(1), False))
                if chains:
                    chains[-1]["imports"].append(len(found) - 1)
                    chains[-1]["selects"] |= match.group(1) in LINUX_C_LIBRARIES
    return set(found)


STRING_LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')


def macos_paths(text, graph):
    """(line, literal) for string literals that name a macOS system location. Standard
    POSIX paths listed in posix_paths are not macOS locations."""
    prefixes = tuple(graph.get("macos_path_prefixes", []))
    allowed = set(graph.get("posix_paths", []))
    found = []
    for number, line in enumerate(text.splitlines(), 1):
        for literal in STRING_LITERAL.findall(line):
            if literal.startswith(prefixes) and literal not in allowed:
                found.append((number, literal))
    return found


def macos_imports(text, graph):
    """macOS modules a neutral source imports. A module in conditional_macos_imports is
    permitted only where an #if chain selects between it and a Linux C library."""
    macos = set(graph.get("macos_imports", []))
    conditional = set(graph.get("conditional_macos_imports", []))
    return {name for name, selects in imports(text)
            if name in macos and not (selects and name in conditional)}


class Rules:
    def __init__(self, graph):
        self.layer = {}
        for position, layer in enumerate(graph["layers"]):
            for target in layer["targets"]:
                self.layer[target] = position
        self.allowed = {tuple(edge.split("->")) for edge in graph.get("allow", [])}
        self.macos_only = set(graph["macos_only"])

    def violations(self, source, target):
        problems = []
        if source not in self.layer:
            problems.append(f"unranked target: {source}")
        elif target not in self.layer:
            problems.append(f"unranked target: {target}")
        elif self.layer[target] > self.layer[source]:
            problems.append(f"upward: {source} -> {target}")
        elif self.layer[target] == self.layer[source] and (source, target) not in self.allowed:
            problems.append(f"same-layer dependency not permitted: {source} -> {target}")
        if source not in self.macos_only and target in self.macos_only:
            problems.append(f"neutral to macOS: {source} -> {target}")
        return problems


def package(graph, package_json):
    rules = Rules(graph)
    if package_json:
        description = json.loads(pathlib.Path(package_json).read_text())
    else:
        description = json.loads(subprocess.run(["/usr/bin/swift", "package", "dump-package"], cwd=ROOT,
                                                check=True, capture_output=True, text=True).stdout)
    names = {t["name"] for t in description["targets"]}
    support = set(graph.get("test_support", []))
    problems = []
    for target in description["targets"]:
        if target["type"] == "test":
            continue
        for dependency in target.get("dependencies", []):
            reference = dependency.get("byName") or dependency.get("target")
            if reference and reference[0] in support and target["name"] not in support:
                problems.append(f"test support outside tests: {target['name']} -> {reference[0]}")
            if reference and target["name"] in support and reference[0] in rules.macos_only:
                problems.append(f"neutral test support to macOS: {target['name']} -> {reference[0]}")
        if target["name"] in support:
            continue
        if target["name"] not in rules.layer:
            problems.append(f"unranked target: {target['name']}")
            continue
        for dependency in target.get("dependencies", []):
            reference = dependency.get("byName") or dependency.get("target")
            if reference and reference[0] in names and reference[0] not in support:
                problems.extend(rules.violations(target["name"], reference[0]))
    return list(dict.fromkeys(problems))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", nargs="?", choices=["package"], default="package")
    parser.add_argument("--graph", default=ROOT / "Scripts/module-graph.json")
    parser.add_argument("--package-json")
    args = parser.parse_args()
    graph = json.loads(pathlib.Path(args.graph).read_text())
    problems = package(graph, args.package_json)
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        print(f"Module graph check failed: {len(problems)} problem(s).", file=sys.stderr)
        return 1
    print(f"Module graph check passed ({args.mode}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
