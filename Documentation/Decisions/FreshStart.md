# Fresh Start at 0.1.0

## Status

Accepted.

## Decision

The Computer MCP organization restarted at a 0.1.0 baseline:

- Each organization repository except the MCP Swift SDK fork began a new history
  from one signed root commit containing its then-current tree. The fork keeps
  its upstream ancestry.
- Every earlier GitHub release and tag was deleted. Releases and tags created
  from the new history are immutable under the organization's maintenance rules.
- Every component versions from 0.1.0. The App's integer build number continues
  to increase. A component publishes 1.0.0 once its public interface is stable.
- Version-advancement checks compare against a base commit only when it is an
  ancestor of the checked commit, so a root commit validates on its own.
- The App database starts from a new initial schema. Installations created
  before the fresh start move their workspaces, profiles, registrations, plugin
  selections and tunnel configuration through a one-time export and import;
  audit history, approvals, operation tickets and execution receipts are not
  carried over. Keychain items keep their service and account identities.

## Rationale

There were no external users. The earlier history was dense with superseded
iterations and process records; its durable rationale already lived in the
architecture documents and these decision records. Restarting before the module
restructuring keeps the restructuring itself in the new history, and a single
0.1.0 baseline removes accumulated version numbers that no longer described
compatibility.

## Consequences

- References to commits of the earlier history, such as pinned reusable
  workflows, were repinned to the new root commits.
- Plugin manifests declare `minimum_host = "0.1.0"`; the bundled Computer Use
  archive was rebuilt for that bound.
- The schema migrations and the embedded Codex configuration import that served
  pre-fresh-start installations are retired once existing installations have
  completed the one-time import.
