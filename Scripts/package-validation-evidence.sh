#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
SOURCE_DIR=""
OUTPUT_PATH=""

usage() {
  cat <<'EOF'
Usage: Scripts/package-validation-evidence.sh --source <directory> --output <archive.tar.gz>

The source directory must be outside the repository and contain:
  production-readiness-report.json
  evidence-bundles/*.json
  verification-records/journey.local.json
  verification-records/journey.chatgpt.json
  verification-records/journey.cloudflare.json
  verification-records/platform.apple_silicon_native.json
  verification-records/platform.rosetta_x86_64.json
EOF
}

fail() {
  echo "error: $1" >&2
  exit 1
}

while (( $# > 0 )); do
  case "$1" in
    --source)
      (( $# >= 2 )) || fail "--source requires a value."
      SOURCE_DIR=$2
      shift 2
      ;;
    --output)
      (( $# >= 2 )) || fail "--output requires a value."
      OUTPUT_PATH=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -n "$SOURCE_DIR" && -n "$OUTPUT_PATH" ]] || {
  usage >&2
  exit 1
}
SOURCE_DIR=${SOURCE_DIR:A}
OUTPUT_PATH=${OUTPUT_PATH:A}
CHECKSUM_PATH="$OUTPUT_PATH.sha256"
ROOT_DIR=${ROOT_DIR:A}

[[ -d "$SOURCE_DIR" ]] || fail "source directory does not exist."
[[ "$SOURCE_DIR" != "$ROOT_DIR" && "$SOURCE_DIR" != "$ROOT_DIR"/* ]] \
  || fail "private evidence must remain outside the repository."
[[ "$OUTPUT_PATH" != "$ROOT_DIR" && "$OUTPUT_PATH" != "$ROOT_DIR"/* ]] \
  || fail "private evidence archive must remain outside the repository."
[[ "$OUTPUT_PATH" != "$SOURCE_DIR" && "$OUTPUT_PATH" != "$SOURCE_DIR"/* ]] \
  || fail "output archive cannot be inside its source directory."
[[ "$OUTPUT_PATH" == *.tar.gz ]] || fail "output must end in .tar.gz."
[[ ! -e "$OUTPUT_PATH" && ! -e "$CHECKSUM_PATH" ]] \
  || fail "output archive or checksum already exists."
/bin/mkdir -p "${OUTPUT_PATH:h}"

READINESS_REPORT="$SOURCE_DIR/production-readiness-report.json"
BUNDLE_DIR="$SOURCE_DIR/evidence-bundles"
RECORD_DIR="$SOURCE_DIR/verification-records"
[[ -s "$READINESS_REPORT" ]] || fail "missing production-readiness-report.json."
[[ -d "$BUNDLE_DIR" ]] || fail "missing evidence-bundles directory."
[[ -d "$RECORD_DIR" ]] || fail "missing verification-records directory."

unexpected_node=$(/usr/bin/find "$SOURCE_DIR" \
  ! -type f ! -type d -print -quit)
[[ -z "$unexpected_node" ]] || fail "symlink or special file is not allowed: $unexpected_node"
empty_file=$(/usr/bin/find "$SOURCE_DIR" -type f -size 0 -print -quit)
[[ -z "$empty_file" ]] || fail "empty evidence file is not allowed: $empty_file"
credential_file=$(/usr/bin/find "$SOURCE_DIR" -type f \( \
  -name '*.pem' -o -name '*.p12' -o -name '*.key' -o \
  -name '*.token' -o -name '*.token-file' -o -name '.env' -o -name '.env.*' \
  \) -print -quit)
[[ -z "$credential_file" ]] || fail "credential-like file is not allowed: $credential_file"

scan_files_only() {
  local description=$1
  local pattern=$2
  local matches
  matches=$(rg -l --hidden --text "$pattern" "$SOURCE_DIR" || true)
  if [[ -n "$matches" ]]; then
    print -l -- ${(f)matches} >&2
    fail "$description"
  fi
}

scan_files_only "personal absolute paths must be redacted." '/Users/[^/]+'
scan_files_only "credential-like content must be redacted." \
  '(sk-(proj-|svcacct-)?[[:alnum:]_-]{20,}|gh[pousr]_[[:alnum:]]{30,}|github_pat_[[:alnum:]_]{40,}|AKIA[0-9A-Z]{16}|xox[baprs]-[[:alnum:]-]{20,}|eyJ[[:alnum:]_-]{100,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----)'

VALIDATION_BIN_DIR=$(/usr/bin/swift build \
  --package-path "$ROOT_DIR/Tools/Validation" \
  --show-bin-path)
VALIDATION_CLI="$VALIDATION_BIN_DIR/computer-mcp-validate"
[[ -x "$VALIDATION_CLI" ]] || fail "Validation CLI is unavailable."
"$VALIDATION_CLI" report verify --report "$READINESS_REPORT" >/dev/null

bundle_files=("$BUNDLE_DIR"/*.json(N))
(( ${#bundle_files[@]} > 0 )) || fail "no Evidence Bundle JSON files were found."
for bundle in $bundle_files; do
  "$VALIDATION_CLI" evidence verify --evidence-bundle "$bundle" >/dev/null
done

required_record_ids=(
  journey.local
  journey.chatgpt
  journey.cloudflare
  platform.apple_silicon_native
  platform.rosetta_x86_64
)
record_files=("$RECORD_DIR"/*.json(N))
(( ${#record_files[@]} == ${#required_record_ids[@]} )) \
  || fail "verification-records must contain exactly five JSON files."
for record_id in $required_record_ids; do
  record="$RECORD_DIR/$record_id.json"
  [[ -s "$record" ]] || fail "missing verification record: $record_id.json"
  "$VALIDATION_CLI" report verification-record verify --record "$record" >/dev/null
  [[ $(/usr/bin/jq -r '.id' "$record") == "$record_id" ]] \
    || fail "verification record filename and id differ: $record_id"
done

candidate_count=$(
  for record_id in $required_record_ids; do
    /usr/bin/jq -cS '.candidate' "$RECORD_DIR/$record_id.json"
  done | /usr/bin/sort -u | /usr/bin/wc -l | /usr/bin/awk '{print $1}'
)
[[ "$candidate_count" == "1" ]] \
  || fail "verification records are bound to different release candidates."

report_evidence_ids=$(
  /usr/bin/jq -r '.test_cases[].evidence_ids[]' "$READINESS_REPORT" \
    | /usr/bin/sort -u
)
bundle_evidence_ids=$(
  for bundle in $bundle_files; do
    /usr/bin/jq -r '.id' "$bundle"
  done | /usr/bin/sort -u
)
[[ "$report_evidence_ids" == "$bundle_evidence_ids" ]] \
  || fail "readiness report and packaged Evidence Bundle IDs differ."

COPYFILE_DISABLE=1 /usr/bin/tar \
  -czf "$OUTPUT_PATH" \
  --format pax \
  --no-mac-metadata \
  --no-xattrs \
  --no-acls \
  --no-fflags \
  --uid 0 \
  --gid 0 \
  --uname root \
  --gname wheel \
  -C "$SOURCE_DIR" \
  .

archive_digest=$(/usr/bin/shasum -a 256 "$OUTPUT_PATH" | /usr/bin/awk '{print $1}')
/usr/bin/printf '%s  %s\n' "$archive_digest" "${OUTPUT_PATH:t}" >"$CHECKSUM_PATH"
(
  cd "${OUTPUT_PATH:h}"
  /usr/bin/shasum -a 256 -c "${CHECKSUM_PATH:t}"
)

echo "Private redacted evidence archive created: $OUTPUT_PATH"
echo "Evidence Bundle count: ${#bundle_files[@]}"
echo "Archive SHA256: $archive_digest"
