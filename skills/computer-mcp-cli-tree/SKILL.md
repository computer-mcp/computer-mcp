---
name: computer-mcp-cli-tree
description: Author, review, or update canonical Computer MCP CLI Tree JSON from a vendor executable's verified version, help, machine introspection, and official documentation. Use for CLI contribution coverage, argv/stdin mapping, compatibility assertions, and interface drift. Do not use for ordinary CLI operation, MCP-native adapters, manifest grants, or runtime help parsing.
---

# Computer MCP CLI Tree

Use the host's canonical JSON ABI and validator. The host owns schema validation,
argument encoding, process management and authorization; the tree describes a
verified interface. A Swift authoring DSL is unnecessary.

## Establish the source

1. Read the target repository instructions and existing tree, generator and
   package manifest. Locate the Computer MCP checkout and its
   `Documentation/Reference/CLITrees.md`; this is the normative ABI reference.
   Use its `Examples/printf-cli-tree.json` for a small partial example.
2. Identify the exact executable and version. Prefer official machine-readable
   introspection when available. Otherwise inspect the real version/help entry
   points and current official documentation. Keep source commands, versions,
   dates and hashes in the task's local evidence; cite official documentation
   where it settles behavior. Do not infer an option from another CLI.
3. Review discovery commands before running them. Help and version are still
   executable code. Use a disposable working directory for checks, avoid login,
   model prompts and writes unrelated to authoring. Do not import credentials
   into fixtures or change production registration while investigating drift.
4. Build a coverage inventory: command path, source evidence, input shape,
   output encoding, execution effects, supported or omitted. Use `partial` with
   concrete omissions whenever any relevant surface is unverified. `complete`
   requires evidence for the full claimed interface, including parent nodes.

## Produce the tree

Preserve stable command IDs when meaning is unchanged. For each supported node:

- Map every parameter exactly once through the complete ordered `argv` or
  `stdin`. A command's `path` does not prepend its command words.
- Distinguish omission, false, null, empty strings and arrays. Defaults document
  native behavior; they are not emitted. Verify inverse Boolean flags, option
  styles, positional ordering and literal `--` behavior from native evidence.
- Declare types and supported constraints. Preserve exact signed integers.
  Do not invent output JSON schemas or dry-run flags.
- Keep secrets out of defaults, examples, probe receipts and output assertions.
- Add exact `executable_checks` for the verified version and, when available,
  stable machine interface output. Preserve exact newlines for text or use the
  SHA-256 of exact bytes. Do not hash volatile or user-specific output.
- Keep package-specific generators in the package that owns them. A generator
  translates a verified machine format into canonical JSON; the host does not
  parse human help during ordinary execution.

## Validate and investigate drift

Find a built host CLI with `computer-mcp cli-tree --help`. When working on the
host source, use `swift build` and its `.build/debug/computer-mcp` candidate.
Do not replace the running production App to acquire this command.

```sh
computer-mcp cli-tree validate /absolute/path/cli-tree.json --expected-version VERSION
computer-mcp cli-tree check /absolute/path/cli-tree.json --executable /absolute/path/vendor --working-directory /disposable/directory
```

`validate` is static and returns versioned JSON diagnostics; `check` explicitly
executes declared assertions. Read `valid`, diagnostic codes and JSON Pointer
paths. Fix the reported invalid node and validate again. A warning that checks
are undeclared does not establish compatibility. A version string alone proves
nothing about the selected binary.

When a check fails, preserve the old source and receipt, inspect the actual
interface difference, then update only verified mappings and assertions.
Do not change the expected output merely to make the check green. Keep unknown
surfaces omitted until supported by evidence. Revalidate the original and
candidate fixtures, test representative encoded argv/stdin and native output in
isolated state, and run the owning package's tests. Prove that changed flags,
defaults and bounds fail safely. Do not use a model fixture as authenticated
vendor execution evidence.

## Deliver

Return the canonical JSON change, source/version evidence, coverage and concrete
omissions, stable IDs affected, validation/check results and relevant native
cases. Distinguish static validity, executable compatibility and tested command
semantics. Leave installation and permission changes to the explicitly requested
host/plugin workflow. Use [review cases](references/review-cases.md) when testing
this authoring workflow.
