# Documentation

This tree holds repository-level documentation. Target-level API documentation
lives with the Swift target in `Sources/ComputerMCPGateway/ComputerMCPGateway.docc/`.

## Reading Map

- [Architecture](Architecture/README.md): current package, runtime,
  permission, and documentation architecture.
- [Reference](Reference/README.md): CLI, MCP protocol, tool schemas,
  permissions, releases, and troubleshooting.
- [Release](Reference/Release.md): version sources, compatibility, candidate
  acceptance, publication, evidence reuse, and artifact retention.
- [Decisions](Decisions/README.md): accepted decision records.
- [Proposals](Proposals/README.md): active design-in-progress, when present.

## Placement Rules

- Current architecture truth belongs in `Documentation/Architecture/`.
- Exhaustive user or operator reference belongs in `Documentation/Reference/`.
- Version rules belong in [Versioning](../VERSIONING.md), which adopts the
  organization rules and states the host's additions.
- Adopted rationale belongs in `Documentation/Decisions/`.
- Active alternatives belong in `Documentation/Proposals/`.
- Repository collaboration configuration and CODEOWNERS belong in `.github/`;
  issue and pull request templates come from the organization `.github`
  repository.

Normative documents describe the current product contract. The changelog,
GitHub Releases, accepted decision records and migrations own history when that
history remains relevant to their role. Retired material is removed after its
current facts move to their owners; Git history retains it.
