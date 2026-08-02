# Documentation

## Scope / Purpose

This document states the current documentation architecture for the repository.

## Context / Boundaries

The repository separates public guide content, architecture truth, reference
material, decision history, and API documentation.

## Constraints

- Root `README.md` remains the public landing guide.
- `Documentation/Architecture/` owns current architecture truth.
- `Documentation/Reference/` owns exhaustive operational details.
- `Documentation/Decisions/` owns accepted rationale.
- `Sources/ComputerMCP/ComputerMCP.docc/` owns target-level API documentation.

## Current Structure

| Location | Role |
| --- | --- |
| `README.md` | Public guide and entry index |
| `AGENTS.md` | Agent route and operational guardrails |
| `Documentation/README.md` | Repository documentation reading index |
| `Documentation/Architecture/` | Current architecture truth |
| `Documentation/Reference/` | CLI, protocol, tools, permissions, troubleshooting |
| `Documentation/Decisions/` | Accepted decisions |
| `Documentation/Proposals/` | Active design-in-progress |
| `Documentation/Archive/` | Retired non-current material |
| `.github/` | GitHub collaboration configuration |

## Key Principles

- Do not make README files carry route instructions.
- Do not make decision records the only source of current truth.
- Do not move target API docs into repository-level `Documentation/`.
- Do not check in generated DocC archives.

## Cross-cutting Concerns

When behavior changes, update the public guide, relevant architecture truth,
reference material, tests, and DocC as appropriate.

## Planning

Task plans are working-session state and are not repository documentation.

## Related Decisions

- [Target-level DocC](../Decisions/TargetLevelDocC.md)
