# Codex Configuration and State Migration

`computer-mcp config migrate-codex` reads an explicit TOML file and emits a JSON
report for moving its embedded Codex settings to the independent `codex`
plugin. It does not contact the App, alter configuration, copy a database,
install dependencies, start Codex, or interrupt a thread.

```sh
computer-mcp config migrate-codex \
  --config /absolute/config/computer-mcp.toml \
  --adapter-config /absolute/config/codex.json \
  --state-directory /absolute/state/codex
```

The source must be a regular UTF-8 file of at most 1 MiB. A bare executable name retains
host-environment lookup. Resolve a relative executable containing `/` to its
actual absolute path before exporting; its meaning depends on the old host's
launch directory. Export neither searches for nor substitutes another vendor
executable. Destinations must be absolute and configuration must not overlap
the adapter database path.

## Report Ownership

| Field | Use |
| --- | --- |
| `sourceSHA256` | Identity of the exact source bytes reviewed; not an activation receipt |
| `configurationDirectory` | Base directory for the exported host manifest |
| `hostTOML` | Host manifest with the migrated `[codex]` section omitted; workspace, profiles, registrations and other host settings retained |
| `adapterConfiguration` | Codex execution settings, including enabled paths, timeouts, sandbox and approval policy |
| `adapterConfigurationPath` | Destination for the adapter JSON, also used in plugin launch arguments |
| `stateDirectory` | Adapter-owned directory containing `codex.sqlite` |
| `pluginID` | `codex` |
| `pluginSettings` | Host-owned settings to review and pass to `plugins configure` |

The plugin settings preserve native `codex.*` names and select the embedded
provider's finite tool surface for the configured App Server and Exec paths.
The historical `mcp_enabled` input is omitted from adapter settings and grants;
an enabled source must select App Server or Exec before export. Risk classification comes from that migration contract, not a plugin's
annotations. New plugin tools are not implicitly selected. Profile capability
and registration grants keep their existing meaning; the exporter does not
add profile grants. In particular, an existing broad `mcp.tools.call` grant
continues to cover host-selected tools across registrations.

App Server integration receives the scoped host-service channel. The plugin
cannot approve host operation tickets or change its authenticated caller.
Execution settings supplied by the source belong to `adapterConfiguration`;
omitted native settings follow the user's Codex configuration. A source with no `[codex]` section
has no execution settings to migrate and is rejected.

If source profiles refer to other plugin registrations, pass each known ID
with `--known-plugin-mcp-server`. An existing Codex plugin identity requires
explicit reconciliation with its recorded settings; this command does not
overwrite it. The immutable plugin manifest is not copied into the host TOML.

## Controlled Application

1. Keep the source manifest and a verified rollback copy. Export and review the
   report. Preserve its base directory when importing `hostTOML`; do not treat
   a report generated from one directory as a relocated configuration.
2. Install or register the independent plugin using the normal plugin commands.
   New installations start disabled. Save `adapterConfiguration` to the stated
   path and `pluginSettings` to a separate JSON file. Use owner-only file access.
3. Arrange a separate control session. Finish or explicitly hand off active
   Codex work and stop the exact old owned writers. Do not replace the backend
   executing the migration. A configuration preview cannot prove writer exit.
4. Take an offline snapshot of the stopped host database. The adapter's
   `migrate-state --source-snapshot ... --destination .../codex.sqlite` previews
   the seven domain tables. Review the plan and use its `--expected-plan-digest`
   with `--apply`. Host workspace/profile/grant/audit/credential stores stay
   with the host. Never copy an actively written database as a cutover shortcut.
5. Preview and import `hostTOML` through the App-owned `config import` operation,
   using its current digest for application. Apply the reviewed plugin settings
   through `plugins configure codex --settings-file ... --expected-revision ...`.
   Read `plugins show codex` for the current revision before each change.
6. Verify the selected plugin, exposed tools, existing thread and Goal state,
   approval boundaries, continuation, release and restart behavior in the
   replacement session. A successful export or seven-table copy does not prove
   this full handoff.

These are separate owner-controlled operations, not one cross-store atomic
transaction. If interrupted, inspect current configuration, plugin settings
and migration receipts before retrying. Do not enable both execution owners.
Before the new adapter writes state, rollback requires the previous host build
and saved manifest after stopping the plugin; the plugin-based host cannot
execute an embedded-Codex configuration. After new writes, the old snapshot is
stale: retain both stores and reconcile the authoritative state before any
reverse handoff. Replaying the original snapshot is not a rollback strategy.

See [Plugin Packages](PluginPackages.md), [Configuration](Config.md), and the
independent plugin's state migration reference for its import conflict rules.
