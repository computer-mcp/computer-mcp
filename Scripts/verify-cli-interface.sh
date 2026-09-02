#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
SWIFT_EXECUTABLE=${SWIFT_EXECUTABLE:-/usr/bin/swift}

ROOT_BIN_DIR=$("$SWIFT_EXECUTABLE" build \
  --package-path "$ROOT_DIR" \
  --show-bin-path)
VALIDATION_BIN_DIR=$("$SWIFT_EXECUTABLE" build \
  --package-path "$ROOT_DIR/Tools/Validation" \
  --show-bin-path)

ROOT_CLI="$ROOT_BIN_DIR/computer-mcp"
VALIDATION_CLI="$VALIDATION_BIN_DIR/computer-mcp-validate"
CLI_REFERENCE="$ROOT_DIR/Documentation/Reference/CLI.md"

if [[ ! -x "$ROOT_CLI" || ! -x "$VALIDATION_CLI" ]]; then
  echo "CLI interface verification failed: expected executables are unavailable." >&2
  exit 1
fi

APP_VERSION=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleShortVersionString" \
  "$ROOT_DIR/Resources/ComputerMCPApp/Info.plist")
APP_BUILD=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleVersion" \
  "$ROOT_DIR/Resources/ComputerMCPApp/Info.plist")
if [[ "$("$ROOT_CLI" --version)" != "$APP_VERSION ($APP_BUILD)" ]]; then
  echo "CLI interface verification failed: release metadata does not match Info.plist." >&2
  exit 1
fi

verify_help() {
  local executable=$1
  shift
  "$executable" "$@" --help >/dev/null
}

verify_help "$ROOT_CLI"
verify_help "$ROOT_CLI" app
verify_help "$ROOT_CLI" config
verify_help "$ROOT_CLI" workspace
verify_help "$ROOT_CLI" profile
verify_help "$ROOT_CLI" tunnel
verify_help "$ROOT_CLI" tunnel openai
verify_help "$ROOT_CLI" tunnel cloudflare
verify_help "$ROOT_CLI" codex
verify_help "$ROOT_CLI" codex elevation
verify_help "$ROOT_CLI" tools
verify_help "$ROOT_CLI" audit
verify_help "$ROOT_CLI" providers
verify_help "$ROOT_CLI" install
verify_help "$ROOT_CLI" uninstall
verify_help "$ROOT_CLI" serve
public_leaf_commands=(
  "app status"
  "doctor"
  "build-info"
  "config path"
  "config show"
  "config defaults"
  "config validate"
  "config export"
  "config import"
  "workspace list"
  "workspace add"
  "workspace remove"
  "workspace enable"
  "workspace deduplicate"
  "profile list"
  "profile show"
  "profile grant"
  "profile shell"
  "tunnel openai list"
  "tunnel openai doctor"
  "tunnel openai start"
  "tunnel openai stop"
  "tunnel openai logs"
  "tunnel cloudflare list"
  "tunnel cloudflare doctor"
  "tunnel cloudflare start"
  "tunnel cloudflare stop"
  "tunnel cloudflare logs"
  "codex diagnose-thread"
  "codex diagnostics"
  "codex release-thread"
  "codex recent-thread"
  "codex elevation list"
  "codex elevation read"
  "codex elevation approve"
  "codex elevation deny"
  "codex elevation revoke"
  "codex elevation effective"
  "tools list"
  "tools inspect"
  "tools call"
  "tools inventory"
  "audit export"
  "providers discover"
  "install cli"
  "uninstall cli"
  "install codex"
  "serve stdio"
  "serve http"
  "bridge"
)
actual_command_lines=()
for command_path in $public_leaf_commands; do
  usage_line=$("$ROOT_CLI" ${=command_path} --help \
    | /usr/bin/awk '/^USAGE: / { sub(/^USAGE: /, ""); print; exit }')
  [[ -n "$usage_line" ]] || {
    echo "CLI interface verification failed: missing usage for '$command_path'." >&2
    exit 1
  }
  actual_command_lines+=("$usage_line")
done
actual_command_surface=$(printf '%s\n' "${actual_command_lines[@]}")
actual_command_surface=${actual_command_surface%$'\n'}
documented_command_surface=$(/usr/bin/awk '
  $0 == "## Command surface" { found_surface = 1; next }
  found_surface && $0 == "```text" { in_surface = 1; next }
  in_surface && $0 == "```" { exit }
  in_surface && length($0) > 0 { print }
' "$CLI_REFERENCE")
if [[ "$documented_command_surface" != "$actual_command_surface" ]]; then
  echo "CLI interface verification failed: CLI.md command surface differs from executable USAGE output." >&2
  /usr/bin/diff -u \
    <(printf '%s\n' "$actual_command_surface") \
    <(printf '%s\n' "$documented_command_surface") >&2 || true
  exit 1
fi

verify_help "$VALIDATION_CLI"
verify_help "$VALIDATION_CLI" test-case
verify_help "$VALIDATION_CLI" test-case list
verify_help "$VALIDATION_CLI" test-case validate
verify_help "$VALIDATION_CLI" runbook
verify_help "$VALIDATION_CLI" runbook generate
verify_help "$VALIDATION_CLI" inventory
verify_help "$VALIDATION_CLI" inventory generate
verify_help "$VALIDATION_CLI" fixture
verify_help "$VALIDATION_CLI" fixture workspace generate
verify_help "$VALIDATION_CLI" fixture manifest generate
verify_help "$VALIDATION_CLI" fixture mcp serve
verify_help "$VALIDATION_CLI" probe
verify_help "$VALIDATION_CLI" probe app catalog
verify_help "$VALIDATION_CLI" probe app call
verify_help "$VALIDATION_CLI" probe app full-catalog
verify_help "$VALIDATION_CLI" probe provider discover
verify_help "$VALIDATION_CLI" probe http call
verify_help "$VALIDATION_CLI" probe downstream verify
verify_help "$VALIDATION_CLI" probe gateway verify
verify_help "$VALIDATION_CLI" probe codex verify
verify_help "$VALIDATION_CLI" evidence
verify_help "$VALIDATION_CLI" evidence correlate
verify_help "$VALIDATION_CLI" evidence verify
verify_help "$VALIDATION_CLI" report
verify_help "$VALIDATION_CLI" report generate
verify_help "$VALIDATION_CLI" report verify
verify_help "$VALIDATION_CLI" report verification-record
verify_help "$VALIDATION_CLI" report verification-record generate
verify_help "$VALIDATION_CLI" report verification-record verify
verify_help "$VALIDATION_CLI" report release-manifest
verify_help "$VALIDATION_CLI" report verify-release-manifest

OUTSIDE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/computer-mcp-cli.XXXXXX")
FIXTURE_MANIFEST="$OUTSIDE_DIR/validation-fixture.toml"
FIXTURE_MARKER="$OUTSIDE_DIR/provider-starts.log"
DOCTOR_JSON="$OUTSIDE_DIR/doctor.json"
CODEX_APP_PLAN="$OUTSIDE_DIR/codex-app-plan.json"
trap 'rm -f "$FIXTURE_MANIFEST" "$FIXTURE_MARKER" "$DOCTOR_JSON" "$CODEX_APP_PLAN"; rmdir "$OUTSIDE_DIR" 2>/dev/null || true' EXIT
(
  cd "$OUTSIDE_DIR"
  verify_help "$ROOT_CLI"
  verify_help "$VALIDATION_CLI"
)

"$VALIDATION_CLI" fixture manifest generate \
  --output "$FIXTURE_MANIFEST" \
  --fixture-executable "$VALIDATION_CLI" \
  --start-marker "$FIXTURE_MARKER" >/dev/null
rg -U 'args = \[\n[[:space:]]+"fixture",\n[[:space:]]+"mcp",\n[[:space:]]+"serve",' \
  "$FIXTURE_MANIFEST" >/dev/null
rg '^exposure = "reexport"$' "$FIXTURE_MANIFEST" >/dev/null
rg '^prefix = "fixture_stdio"$' "$FIXTURE_MANIFEST" >/dev/null
if rg 'downstream-fixture' "$FIXTURE_MANIFEST" >/dev/null; then
  echo "CLI interface verification failed: generated manifest contains an obsolete command." >&2
  exit 1
fi

doctor_exit=0
"$ROOT_CLI" doctor --journey local --json >"$DOCTOR_JSON" || doctor_exit=$?
if [[ "$doctor_exit" != "0" && "$doctor_exit" != "1" ]]; then
  echo "CLI interface verification failed: doctor returned $doctor_exit." >&2
  exit 1
fi
/usr/bin/plutil -convert xml1 -o /dev/null "$DOCTOR_JSON"
[[ $(/usr/bin/plutil -extract schema_version raw -o - "$DOCTOR_JSON") == "1" ]] \
  || { echo "CLI interface verification failed: doctor schema changed." >&2; exit 1; }
rg '"generated_at"[[:space:]]*:[[:space:]]*"[0-9]{4}-' "$DOCTOR_JSON" >/dev/null
if rg -i 'bearer [a-z0-9._-]{12}|api[_ -]?key[[:space:]]*[:=][[:space:]]*[^" ]+' \
  "$DOCTOR_JSON" >/dev/null
then
  echo "CLI interface verification failed: doctor output may contain a secret." >&2
  exit 1
fi

"$ROOT_CLI" install codex \
  --app \
  --codex-cli /bin/echo \
  --server-executable "$ROOT_CLI" \
  --dry-run >"$CODEX_APP_PLAN"
rg '"bridge"' "$CODEX_APP_PLAN" >/dev/null
rg '"local-mcp"' "$CODEX_APP_PLAN" >/dev/null
if rg '"--config"' "$CODEX_APP_PLAN" >/dev/null; then
  echo "CLI interface verification failed: App Codex plan contains --config." >&2
  exit 1
fi
if "$ROOT_CLI" install codex \
  --app \
  --config "$FIXTURE_MANIFEST" \
  --codex-cli /bin/echo \
  --server-executable "$ROOT_CLI" \
  --dry-run >/dev/null 2>&1
then
  echo "CLI interface verification failed: --app and --config were accepted together." >&2
  exit 1
fi

echo "CLI interface verification passed."
