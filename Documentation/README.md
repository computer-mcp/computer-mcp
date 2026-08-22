# Documentation

This tree holds repository-level documentation. Target-level API documentation
lives with the Swift target in `Sources/ComputerMCP/ComputerMCP.docc/`.

## Reading Map

- [Architecture](Architecture/README.md): current package, runtime,
  permission, and documentation architecture.
- [Reference](Reference/README.md): CLI, MCP protocol, tool schemas,
  permissions, and troubleshooting.
- [Decisions](Decisions/README.md): accepted decision records.
- [Proposals](Proposals/README.md): active design-in-progress, when present.
- [Archive](Archive/README.md): retired documentation retained for history.

## Placement Rules

- Current truth belongs in `Documentation/Architecture/`.
- Exhaustive user or operator reference belongs in `Documentation/Reference/`.
- Adopted rationale belongs in `Documentation/Decisions/`.
- Active alternatives belong in `Documentation/Proposals/`.
- Retired non-current material belongs in `Documentation/Archive/`.
- GitHub templates and CODEOWNERS belong in `.github/`.

Normative documents describe the current product contract. Versioned release
records, accepted decision records, migrations, and archived documents own
history when that history remains relevant to their role.
