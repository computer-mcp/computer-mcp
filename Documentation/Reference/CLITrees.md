# CLI Trees

A CLI tree describes an executable's machine-readable interface. Direct CLI
registrations and Plugin CLI contributions use the same loader, schema generator,
argument encoder, process ownership, and Gateway authorization path. A tree is
publisher input; it cannot grant permissions or install its external executable.

## Registration

For a direct registration, add a tree source and explicitly disable arbitrary
arguments:

```toml
[[cli.commands]]
id = "printf-strings"
executable = "/usr/bin/printf"
allow_any_args = false
tree = { kind = "file", path = "/absolute/path/to/printf-cli-tree.json" }
```

The runnable example is `Examples/printf-cli-tree.json`. It exposes literal
string printing and declares partial coverage; it is not a complete printf
interface. Existing registrations without a tree retain their raw CLI contract.

| Source | Fields | Behavior |
| --- | --- | --- |
| `file` | `path` | Read a bounded regular JSON file. Direct relative paths use the CLI cwd; Plugin paths are package-relative. |
| `introspection` | `args` | Run the registered executable with the exact declared argv and validate its JSON tree. |
| `helper` | `helper`, `args` | Run the resolved exporter and validate its JSON tree. Direct helpers use absolute executable paths; Plugin helpers use package/dependency references. |

Exporters run in the CLI's cwd/environment with closed stdin, a 5-second execution
budget and a 4 MiB stdout bound. Enabling an exporter authorizes running that
package code for discovery; it does not grant projected tool calls to a profile.
Exporters must return this contract. Native introspection using another format
needs a verified package exporter; human-readable help is not parsed as a tree.
The package manager does not run exporters while reading a manifest or installing
an archive.

## Document

The root has `format_version: 1`, `source`, `executable_version`, `coverage`,
`omissions`, and `commands`. The format number identifies serialization
compatibility. Source/version strings describe the publisher's interface baseline,
not an independently probed installed binary version.

The optional root `executable_checks` array declares compatibility assertions
that run before each authorized projected call. Omission or an empty array means
no compatibility assertion is declared; a present field must be an array.
Each check contains fixed `args` and exactly one of `stdout` (exact UTF-8 bytes,
including any newline) or `stdout_sha256` (64 lowercase hexadecimal digits).
For example, a publisher can require `{"args":["--version"],"stdout":"6.3.1\n"}`.
There may be at most four checks. Each has 1–128 NUL-free arguments, at most
64 KiB including argument terminators, and at most 64 KiB expected text.

`coverage` is `complete` or `partial`. Partial coverage requires a nonempty
`omissions` list; complete coverage requires an empty list. Coverage is a
publisher declaration, not proof of an upstream CLI's full surface.

Each command has a unique `id` and `path`, a `description`, `executable`,
`parameters`, `argv`, and `stdout`. An empty path denotes the root. Nested paths
must have parent nodes. A group uses `executable: false` with empty parameters
and argv; it does not become an MCP tool. IDs use 1–64 ASCII letters, digits,
underscores, or hyphens. Documents are limited to 4 MiB and 4096 nodes; each node
has at most 256 parameters and 1024 mapping tokens.

Optional command fields are `stdin`, `output_schema`, `help_argv`,
`dry_run_parameter`, and `risk_hint`. Help argv documents an actual supported help
entry. Dry-run references an actual Boolean flag parameter; it neither inserts a
made-up flag nor lowers execution risk. Risk hints are not authorization.

## Parameters and Mapping

A parameter defines `name`, `schema`, and optional `description`, `required`,
`default`, `secret`, `conflicts`, and `requires`. Omitted booleans default to
false, and omitted relationship arrays to empty. Relationships are between
explicitly supplied parameter names, including supplied false/null values.
Required input and an omitted-input default cannot coexist.
`workspace_id` is reserved for Gateway routing; map a CLI's similarly named
option through a different parameter name.

`default` documents what the CLI does when the parameter is omitted. It is not
inserted into argv/stdin. Explicit null, empty string, false, empty array, and
absence remain distinct inputs. A one-way Boolean flag rejects explicit false;
use its declared inverse flag or omit the parameter. Secret inputs are marked
`writeOnly` in the tool schema and cannot publish defaults.
One-way flag schemas advertise `const: true`; their omitted false default remains
in the descriptor rather than an invalid schema default.

`argv` is the entire ordered mapping, including command words and constants.
The metadata `path` is not automatically prepended. Each parameter maps exactly
once, either to argv or stdin.

| Token | Fields | Encoding |
| --- | --- | --- |
| `literal` | `value` | One exact string, including a declared `--` separator. |
| `positional` | `parameter` | One scalar or each array element, in order. |
| `option` | `parameter`, `flag`, `style` | `separate`: flag followed by values; `repeated`: flag before each value; `equals`: one `--flag=value` per value. |
| `flag` | `parameter`, `flag`, optional `inverse` | True emits `flag`; false emits `inverse`. |

No shell interpolation, string joining, or help-text guessing occurs. Empty
strings, Unicode, quotes, whitespace, and shell metacharacters are literal argv
values. Leading-hyphen positional values require a declared `--`; leading-hyphen
option values require `equals`. Flags/options cannot follow the separator. A
variadic positional must be last; omitting an earlier positional cannot shift a
later one. Arrays emit no tokens when empty. NUL is rejected in argv.

`stdin` names one parameter and an `encoding`: `utf8`, strict `base64`, or
deterministic `json`. String/binary stdin may contain NUL. Input is closed after
delivery. Encoded invocations are bounded to 16384 arguments, 1 MiB argv bytes,
and 4 MiB stdin.

The schema subset supports string/integer/number/boolean/null/array/object types,
`description`, `enum`, `const`, string `minLength`/`maxLength`, numeric
`minimum`/`maximum`, array `items`/`minItems`/`maxItems`, and object
`properties`/`required`/Boolean `additionalProperties`. Nested schemas have a
16-level bound. Unsupported assertions fail validation, rather than being
advertised and ignored. Required inputs, relationships, and secret metadata
are generated from the same descriptors used during execution.

## Execution and Refresh

Projected tools have stable names derived from the registration identity and
command ID, with readable titles and source/path/coverage metadata. Obtain names
from `tools/list`; do not construct them manually. Calls require the host's Full
Shell permission and a workspace, just like `cli.exec`. A self-reported read-only
hint cannot expose a command to an observe profile. `cli.exec` and
`process.spawn` cannot bypass a declared tree. For file-backed trees, `cli.help`
returns declared metadata without executing help argv; executable exporters are
not run through that read-only capability.

The executable and interpreters are resolved in the actual cwd/environment.
The host supplies the base environment; registration `env` values override it.
Status checks, tree exporters and projected calls use that same merged environment.
Relative executable paths and relative PATH entries use the configured CLI cwd
(the selected workspace when no cwd override is supplied), not the App's directory.
When executable checks are declared, their interpreter chain must be fully
resolvable. Each check executes the resolved program with its fixed argv and
closed stdin in that same cwd/environment. A zero exit, complete captured stdout
matching the assertion, and successful stream capture are required. Both streams
are bounded to 4 MiB. Checks run within the authorized call's process ownership
and concurrency slot; they are vendor/package code, not inherently read-only.
They do not run during file-backed listing/help, installation, or static doctor.
Probe argv/output are not included in tool results or failure diagnostics.

All checks together have an execution budget of the smaller of five seconds and
the registration timeout. The target command then receives its own registration
timeout. Process startup and termination cleanup can add latency to these budgets.
Cancellation or a failed check prevents the target command. No successful check
is cached across invocations, so environment, cwd and installed-version changes
are checked again. Before checks and after each successful check, the host compares
resolved paths and executable/interpreter file identity, size, timestamps and
permissions. An observed change prevents the target call. This is not atomic
kernel pinning, a dynamic-library snapshot, publisher authentication or a sandbox.
After an incompatible update, bind a compatible executable or update the verified
tree and refresh the catalog; the host does not update vendor dependencies.

Tool metadata includes `cli.executable_check_count` and `cli.compatibility`:
`required_before_call` means declared checks will run, not that they have passed;
`not_declared` means no runtime assertion is configured.

Execution uses the shared managed process implementation with process-group
cancellation, bounded output, and per-call ownership. The timeout uses the
registration override or host default (1 ms–1 hour). Results include exit code,
signal, timeout/cancellation status, and per-stream encoding/truncation. Invocation
argv and stdin are not copied into result metadata. Gateway audit stores digests,
not input or output bodies. CLI stdout/stderr remain real vendor output and may
themselves contain sensitive information.

`stdout` is `text`, `binary`, or `json`. Binary bytes use explicit base64; invalid
UTF-8 text also uses base64. JSON is decoded only after successful execution and
complete capture, then checked against `output_schema` when supplied. Invalid,
truncated, or schema-invalid JSON returns a tool error with the captured output.
Non-JSON output does not acquire an invented data schema. The known execution
envelope is the MCP structured result; JSON data appears under `result.data`.

The router reloads trees during explicit catalog refresh and at a 30-second
interval. A complete validated generation replaces definitions and call routes
atomically. Invalid refreshes retain the last validated generation and report a
refresh error. Visible schema/catalog changes use the existing upstream change
notification path. A publisher's executable-version string does not establish
that the executable file has stayed compatible with the tree.

## Native Interface Integration Check

`NativeCLITreeIntegrationTests` is an explicit local check for the independent
Swift Format plugin and a user-supplied Swift Format 6.3.1 executable. It is not
enabled in ordinary tests because those external checkouts/toolchains are not
package dependencies. Set both paths to run it:

```sh
COMPUTER_MCP_FORMATTER_PLUGIN=/absolute/path/to/swift-format-plugin \
COMPUTER_MCP_FORMATTER_EXECUTABLE=/absolute/path/to/swift-format \
  swift test --filter NativeCLITreeIntegrationTests
```

The test checks the real version, loads the independent package, compares the
five projected tools with direct registration, formats and lints explicit stdin,
checks raw-call and observe-profile rejection, and verifies that package and
executable bytes are unchanged. It uses a private temporary workspace and
in-memory Gateway state; it does not connect to the App or production sockets.
The generated tree retains explicit partial coverage and its publisher baseline.
Its version and native-interface checks execute inside the same generic call
path as direct registration; an incompatible assertion is also tested to reject
an otherwise valid invocation.
