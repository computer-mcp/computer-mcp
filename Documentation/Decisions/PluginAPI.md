# Plugin API Version

## Status

Accepted.

## Context

A plugin manifest states which host releases it supports with
`compatibility.minimum_host` and `compatibility.maximum_host`. The host rejects
unknown manifest fields, so a package that uses a newer field also has to raise
`minimum_host` to the first host release that understands it, and an older host
reports the package as malformed (`Unknown fields`) instead of as needing an
update. Host release numbers therefore carry two meanings: product changes and
changes to the contract between the host and its plugins. When the host refuses
a package, its messages ("incompatible with this host") do not say whether the
host or the plugin should be updated.

No plugin or host release has been published, and the official catalog is
empty, so the contract can be fixed without a migration.

## Decision

### `plugin_api`

Every manifest declares a required top-level integer `plugin_api`, starting at
`1`. A plugin API version defines the complete manifest schema and the runtime
contract: contribution kinds and their fields, how executables are launched,
the environment and arguments the host passes, and the checks it performs.
API `1` is the current manifest schema and runtime contract.

The host declares the plugin API versions it supports as one closed range in
`ComputerMCPPlugins`, currently `1...1`, and reports it in `computer-mcp
build-info` as `plugin_api` with `minimum` and `maximum`.

- Any change to the manifest schema (a field added, removed or reinterpreted)
  or to the runtime contract defines a new plugin API version. A manifest uses
  only the fields its declared version defines.
- A host may support several consecutive versions and decodes each manifest by
  its declared version. Removing support for the oldest version is a breaking
  host change.
- `minimum_host` and `maximum_host` remain for constraints within one API
  version, such as a host fix a plugin depends on. They are no longer how a
  package signals use of new manifest fields.

### Reading a manifest

The host first reads only `id`, `version` and `plugin_api`, ignoring other
fields, then decodes the full manifest strictly by its declared API version. A
`plugin_api` that is missing or not a positive integer makes the manifest
malformed (`invalid_manifest`, naming the field). A well-formed value outside
the supported range is refused before full decoding, so a newer manifest is
reported as needing a newer host rather than as malformed.

### Refusals

Compatibility evaluation produces at most one refusal and applies the checks in
this order, reporting the first that fails:

| Order | Reason | When | Message tells the user to |
| --- | --- | --- | --- |
| 1 | `host_update_required` | `plugin_api` is above the supported range | update Computer MCP |
| 1 | `plugin_update_required` | `plugin_api` is below the supported range | update the plugin |
| 2 | `platform_unsupported` | the platform or architecture is not declared, or no declared artifact targets this Mac | use a package built for this Mac |
| 3 | `host_update_required` | the host is below `minimum_host` | update Computer MCP |
| 3 | `plugin_update_required` | the host is at or above `maximum_host` | update the plugin |

Platform comes before the host range because updating either side does not help
on an unsupported Mac.

A refusal is a structured value, not a message: the plugin's ID and version,
the reason, what the plugin declared (its `plugin_api`, platforms and
architectures, or host range) and what the host supports (its plugin API range,
platform and architecture, or version). Every boundary carries it unchanged
instead of converting it to a generic error:

- archive loading, preparation and installation, including bundled collection
  in `computer-mcp _bundle-plugins`;
- GitHub release manifest loading and catalog selection;
- the resolver and plugin store issues, and the doctor;
- control-plane and CLI responses, audit records and the App.

Error codes are `plugin.host_update_required`, `plugin.plugin_update_required`
and `plugin.platform_unsupported`, replacing the generic incompatibility codes
and messages. Tests cover each reason, the order, and each boundary.

### Catalog

The official catalog moves to schema 3, which adds `plugin_api` to each
release's `compatibility` object. The website generator requires `plugin_api`
in the tagged manifest and accepts only manifests of plugin API versions it
knows, and the committed catalog seed becomes a valid schema 3 snapshot. The
host reads only schema 3 and filters releases with the same evaluation; an
explicitly selected release that fails it reports its refusal.

### Bundled plugins

Bundled archives are rebuilt reproducibly in their plugin repositories from
accepted commits whose manifests declare `plugin_api`, and
`Resources/PluginArchives/index.json` is updated with their digests. Bundled
preparation applies the same evaluation, so an archive outside the supported
range fails the App build. Before the first release, an archive may be adopted
from an accepted commit before that plugin version is published; a host release
requires the plugin release with the same archive digest to be public first.

## Consequences

- Plugin authors read one number to know whether a host can load their package,
  and refused packages tell users which side to update.
- Adding a manifest field is a plugin API change, even when optional, because
  hosts reject unknown fields.
- Catalog schemas 1 and 2 are no longer read; nothing was published with them.

## Alternatives Considered

- Keeping `minimum_host` as the only signal: couples plugin compatibility to
  host release numbers and keeps "malformed" as the answer for newer manifests.
- Making `plugin_api` optional with a default: a missing value would have to
  mean a schema that no longer exists separately from API `1`.
- Accepting unknown fields: would let a plugin rely on behavior an older host
  silently ignores.
