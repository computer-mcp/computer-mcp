#!/usr/bin/env python3
"""Verify the gateway module graph described in Documentation/Decisions/ModuleArchitecture.md.

Scripts/module-graph.json declares the layers (bottom-up), the dependencies permitted
between targets of the same layer, the macOS-only targets and imports, and the planned
allocation of the declarations that remain in the shared residual target.

Modes:
  plan     Read every target directory under Sources/. Declarations in an extracted
           target directory belong to that target; declarations in the residual target
           are allocated by the planned rules. Fail on cycles, dependencies the layer
           rules do not permit, neutral targets that reference macOS-only targets, and
           macOS imports in extracted neutral targets, also inside #if blocks; only the
           modules in conditional_macos_imports may appear there, and only in an #if
           chain that also imports Glibc or Musl.
           Every residual Swift test source must be allocated to a test target whose
           owner is in layers.
  package  Read `swift package dump-package` and apply the same layer, permission and
           neutrality rules to the declared target dependencies. Test support libraries
           are unranked, neutral, and may be dependencies of test targets only.

Plan mode resolves names lexically from top-level declarations, their direct member
types, module-qualified names and non-private free functions; it does not perform
full Swift name lookup. Once a target exists, the compiler enforces its imports and
package mode enforces its declared dependencies.

Usage: verify-module-graph.py [plan|package] [--graph FILE] [--sources DIR] [--tests DIR] [--package-json FILE]
"""
import argparse
import collections
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MODIFIERS = r"(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:package|public|internal|private|fileprivate|final|indirect|nonisolated|open|static)\s+)*"
DECL = re.compile(r"^" + MODIFIERS + r"(struct|class|enum|actor|protocol|typealias)\s+([A-Z]\w*)")
EXT = re.compile(r"^" + MODIFIERS + r"extension\s+([A-Z][\w.]*)")
FREE = re.compile(r"^" + MODIFIERS + r"(?:func|let|var)\s+(\w+)")
IMPORT = re.compile(r"^\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?(\w+)", re.M)
IDENTIFIER = re.compile(r"\b[A-Z]\w*\b")
FUNC = re.compile(MODIFIERS + r"func\s")
PRIVATE = re.compile(r"(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:private|fileprivate)\s")
COMMENT = re.compile(r"//[^\n]*|/\*.*?\*/", re.S)
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


MEMBER = re.compile(r"[{}]|\b(?:struct|class|enum|actor|protocol|typealias|func)\s+([A-Za-z_]\w*)")
SCOPE = re.compile(r"[{}]|\b(?:let|var)\s+([A-Za-z_]\w*)|(?<![.\w])([A-Za-z_]\w*)\b")


def member_names(text, path, index):
    """Record direct member types and functions, keyed by dotted declaration path."""
    # The first body opened in a chunk belongs to the chunk's own declaration or extension.
    stack, pending, depth = [path], path, 0
    for token in MEMBER.finditer(text):
        if token.group(0) == "{":
            depth += 1
            stack = stack[:depth] + [pending or stack[-1] + ".{}"]
            pending = None
        elif token.group(0) == "}":
            depth -= 1
            stack = stack[:depth + 1]
        else:
            if depth >= 1:
                index[stack[depth]].add(token.group(1))
            pending = f"{stack[depth]}.{token.group(1)}" if depth >= 1 else path


def free_references(text, functions):
    """Free-function names used in text that are not shadowed by a binding in an enclosing block."""
    found, scopes = set(), [set()]
    for token in SCOPE.finditer(text):
        if token.group(0) == "{":
            scopes.append(set())
        elif token.group(0) == "}":
            if len(scopes) > 1:
                scopes.pop()
        elif token.group(1):
            scopes[-1].add(token.group(1))
        elif token.group(2) in functions and not any(token.group(2) in scope for scope in scopes):
            found.add(token.group(2))
    return found


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


def chunks(path, directory):
    """Split a Swift file into top-level declaration, extension and free-symbol chunks."""
    text = path.read_text()
    out, current = [], None
    for line in text.splitlines():
        decl, ext, free = DECL.match(line), EXT.match(line), FREE.match(line)
        if decl or ext or free:
            if current:
                out.append(current)
            if decl:
                current = {"kind": "decl", "name": decl.group(2), "lines": [line]}
            elif ext:
                current = {"kind": "ext", "name": ext.group(1).split(".")[0], "path": ext.group(1), "lines": [line]}
            else:
                current = {"kind": "free", "name": free.group(1), "lines": [line]}
        elif current is not None:
            current["lines"].append(line)
        else:
            current = {"kind": "prelude", "name": "", "lines": [line]}
    if current:
        out.append(current)
    for chunk in out:
        chunk["text"] = code_text("\n".join(chunk.pop("lines")))
        chunk["file"] = path.name
        chunk["directory"] = directory
        chunk["source"] = text
    return out


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


def allocate(chunk, graph):
    """Planned target of a chunk: type and extension overrides, then file relocations,
    then the chunk's own target directory, then the residual target's file rules."""
    if chunk["kind"] in ("decl", "free") and chunk["name"] in graph.get("types", {}):
        return graph["types"][chunk["name"]]
    if chunk["kind"] == "ext":
        key = f'{chunk["file"]}:{chunk["name"]}'
        if key in graph.get("extensions", {}):
            return graph["extensions"][key]
    relocated = graph.get("relocations", {}).get(f'{chunk["directory"]}/{chunk["file"]}')
    if relocated:
        return relocated
    if chunk["directory"] != graph["residual"]:
        return chunk["directory"]
    for pattern, target in graph["files"].items():
        if re.search(pattern, chunk["file"]):
            return target
    return None


def strongly_connected(edges):
    nodes = set(edges) | {t for targets in edges.values() for t in targets}
    index, low, stack, on_stack, result, counter = {}, {}, [], set(), [], [0]

    def visit(node):
        index[node] = low[node] = counter[0]
        counter[0] += 1
        stack.append(node)
        on_stack.add(node)
        for successor in sorted(edges.get(node, ())):
            if successor not in index:
                visit(successor)
                low[node] = min(low[node], low[successor])
            elif successor in on_stack:
                low[node] = min(low[node], index[successor])
        if low[node] == index[node]:
            component = []
            while True:
                member = stack.pop()
                on_stack.discard(member)
                component.append(member)
                if member == node:
                    break
            result.append(sorted(component))

    sys.setrecursionlimit(10000)
    for node in sorted(nodes):
        if node not in index:
            visit(node)
    return [c for c in result if len(c) > 1]


def test_allocation(graph, tests):
    """Allocate test sources and support files; Fixtures are copied resources in Package.swift."""
    files = {str(path.relative_to(tests)) for path in tests.rglob("*.swift")
             if path.relative_to(tests).parts[0] != "Fixtures"}
    allocations = graph.get("tests", {})
    targets = Rules(graph).layer
    problems = [f"unallocated test: {name}" for name in sorted(files - allocations.keys())]
    problems += [f"test allocation has no source: {name}"
                 for name in sorted(allocations.keys() - files)]
    for name, target in sorted(allocations.items()):
        if not isinstance(target, str) or not target.endswith("Tests") or target[:-5] not in targets:
            problems.append(f"invalid test target: {name} -> {target}")
    return problems


def plan(graph, sources, tests=None):
    rules = Rules(graph)
    removed = set(graph.get("removed", []))
    cuts = {tuple(cut.split("->")) for cut in graph.get("cuts", [])}
    directories = [d for d in sorted(sources.iterdir()) if d.is_dir()] if sources.is_dir() else []
    all_chunks = []
    for directory in directories:
        for path in sorted(directory.rglob("*.swift")):
            all_chunks.extend(chunks(path, directory.name))
    if not all_chunks:
        return [f"no Swift sources under {sources}"]
    known = set(rules.layer) | removed
    for directory in sorted({c["directory"] for c in all_chunks} - known - {graph["residual"]}):
        return [f"unranked target directory: {directory}"]
    targets = [allocate(c, graph) for c in all_chunks]
    problems = [f'unallocated: {c["directory"]}/{c["file"]}:{c["name"]}' for c, t in zip(all_chunks, targets) if t is None]
    for chunk, target in zip(all_chunks, targets):
        if target and chunk["directory"] == target and target not in rules.macos_only:
            for name in sorted(macos_imports(chunk["source"], graph)):
                problems.append(f'macOS import in neutral target: {target}/{chunk["file"]} imports {name}')
    # Executable targets cannot be imported, so their declarations never own a reference.
    executables = set(graph.get("executables", []))
    types, functions = collections.defaultdict(set), collections.defaultdict(set)
    nested = collections.defaultdict(set)
    for chunk, target in zip(all_chunks, targets):
        if target is None:
            continue
        if chunk["kind"] in ("decl", "ext"):
            members = collections.defaultdict(set)
            member_names(chunk["text"], chunk.get("path", chunk["name"]), members)
            for path, names in members.items():
                nested[(target, path)].update(names)
        if target in executables:
            continue
        if chunk["kind"] == "decl":
            types[chunk["name"]].add(target)
        elif chunk["kind"] == "free" and FUNC.match(chunk["text"].lstrip()) and not PRIVATE.match(chunk["text"].lstrip()):
            functions[chunk["name"]].add(target)
    modules = set(rules.layer) | {graph["residual"]}
    edges, evidence = collections.defaultdict(set), collections.defaultdict(list)
    for chunk, source in zip(all_chunks, targets):
        if source is None or source in removed:
            continue
        # Member types and functions of this declaration or the type an extension extends
        # resolve locally; other unqualified or module-qualified names resolve to owners.
        local = nested.get((source, chunk.get("path", chunk["name"])), set())
        references = set()
        for match in IDENTIFIER.finditer(chunk["text"]):
            name, start = match.group(0), match.start()
            if name not in types or name in local or source in types[name]:
                continue
            if start > 0 and chunk["text"][start - 1] == ".":
                qualifier = re.search(r"([A-Za-z_]\w*)\s*\.$", chunk["text"][max(0, start - 80):start])
                if not qualifier or qualifier.group(1) not in modules:
                    continue
            references.add(name)
        if chunk["kind"] == "ext" and chunk["name"] in types:
            references.add(chunk["name"])
        references |= {n for n in free_references(chunk["text"], functions.keys() - local) if source not in functions[n]}
        for name in references:
            if (chunk["name"], name) in cuts:
                continue
            for target in (types.get(name, set()) | functions.get(name, set())) - {source} - removed:
                edges[source].add(target)
                if len(evidence[(source, target)]) < 5:
                    evidence[(source, target)].append(f'{chunk["file"]}:{chunk["name"]} -> {name}')
    for source in sorted(edges):
        for target in sorted(edges[source]):
            for problem in rules.violations(source, target):
                problems.append(problem + ": " + "; ".join(evidence[(source, target)]))
    for component in strongly_connected(edges):
        problems.append("cycle: " + " <-> ".join(component))
    problems.extend(test_allocation(graph, tests if tests is not None else sources.parent / "Tests/ComputerMCPTests"))
    return list(dict.fromkeys(problems))


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
    parser.add_argument("mode", nargs="?", choices=["plan", "package"], default="plan")
    parser.add_argument("--graph", default=ROOT / "Scripts/module-graph.json")
    parser.add_argument("--sources", default=ROOT / "Sources")
    parser.add_argument("--tests", default=ROOT / "Tests/ComputerMCPTests")
    parser.add_argument("--package-json")
    args = parser.parse_args()
    graph = json.loads(pathlib.Path(args.graph).read_text())
    problems = plan(graph, pathlib.Path(args.sources), pathlib.Path(args.tests)) if args.mode == "plan" else package(graph, args.package_json)
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        print(f"Module graph check failed: {len(problems)} problem(s).", file=sys.stderr)
        return 1
    print(f"Module graph check passed ({args.mode}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
