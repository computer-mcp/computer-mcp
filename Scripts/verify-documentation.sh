#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
TEMP_PARENT=${TMPDIR:-/tmp}
TEMP_PARENT=${TEMP_PARENT%/}
TEMP_ROOT=$(mktemp -d "$TEMP_PARENT/computer-mcp-docc.XXXXXX")
ALL_SYMBOLS="$TEMP_ROOT/all-symbols"
MODULE_SYMBOLS="$TEMP_ROOT/module-symbols"
ARCHIVE_PATH="$TEMP_ROOT/ComputerMCP.doccarchive"
BUILD_LOG="$TEMP_ROOT/swift-build.log"
DOC_VERSION=$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleShortVersionString' \
  "$ROOT_DIR/Resources/ComputerMCPApp/Info.plist")

cleanup() {
  case "$TEMP_ROOT" in
    "$TEMP_PARENT"/computer-mcp-docc.*)
      /bin/rm -rf -- "$TEMP_ROOT"
      ;;
  esac
}
trap cleanup EXIT

fail() {
  echo "Documentation verification failed: $1" >&2
  exit 1
}

/bin/mkdir -p "$ALL_SYMBOLS" "$MODULE_SYMBOLS"

if ! /usr/bin/swift build \
  --package-path "$ROOT_DIR" \
  --build-system native \
  --target ComputerMCP \
  -Xswiftc -emit-symbol-graph \
  -Xswiftc -emit-symbol-graph-dir \
  -Xswiftc "$ALL_SYMBOLS" \
  -Xswiftc -symbol-graph-minimum-access-level \
  -Xswiftc internal >"$BUILD_LOG" 2>&1
then
  /usr/bin/tail -n 200 "$BUILD_LOG" >&2
  fail "SwiftPM could not emit the ComputerMCP symbol graph."
fi

while IFS= read -r -d '' graph; do
  /bin/cp "$graph" "$MODULE_SYMBOLS/"
done < <(/usr/bin/find "$ALL_SYMBOLS" -type f -name 'ComputerMCP*.symbols.json' -print0)

[[ -f "$MODULE_SYMBOLS/ComputerMCP.symbols.json" ]] \
  || fail "ComputerMCP.symbols.json was not emitted."

xcrun docc convert \
  "$ROOT_DIR/Sources/ComputerMCP/ComputerMCP.docc" \
  --additional-symbol-graph-dir "$MODULE_SYMBOLS" \
  --fallback-display-name "ComputerMCP" \
  --fallback-bundle-identifier "com.showxu.computer-mcp.documentation" \
  --fallback-bundle-version "$DOC_VERSION" \
  --output-path "$ARCHIVE_PATH" \
  --warnings-as-errors

[[ -f "$ARCHIVE_PATH/data/documentation/computermcp.json" ]] \
  || fail "DocC did not produce the ComputerMCP root page."

echo "ComputerMCP DocC warning gate passed."
