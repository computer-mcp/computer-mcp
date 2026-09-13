#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/computer-mcp-draft-boundary.XXXXXX")
trap '/bin/rm -rf -- "$TEMP_DIR"' EXIT

mkdir -p "$TEMP_DIR/Scripts" "$TEMP_DIR/.github/workflows"
for name in verify-artifact-provenance-boundary.sh package-dmg.sh assemble-release-assets.sh; do
  cp "$ROOT_DIR/Scripts/$name" "$TEMP_DIR/Scripts/$name"
done
workflow="$TEMP_DIR/.github/workflows/release-gate.yml"
cp "$ROOT_DIR/.github/workflows/release-gate.yml" "$workflow"
zsh "$TEMP_DIR/Scripts/verify-artifact-provenance-boundary.sh"

for publication in 'gh release edit "$GITHUB_REF_NAME" --draft=false' 'draft: false'; do
  cp "$ROOT_DIR/.github/workflows/release-gate.yml" "$workflow"
  printf '\n          %s\n' "$publication" >>"$workflow"
  if zsh "$TEMP_DIR/Scripts/verify-artifact-provenance-boundary.sh" \
    >"$TEMP_DIR/output" 2>&1; then
    echo "Draft boundary regression failed: automatic publication was accepted." >&2
    exit 1
  fi
  /usr/bin/grep -Fq \
    'Release preparation must stop at a draft for local installation acceptance.' \
    "$TEMP_DIR/output"
done

echo "Draft boundary regression passed."
