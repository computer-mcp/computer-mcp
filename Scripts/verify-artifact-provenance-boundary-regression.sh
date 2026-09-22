#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/computer-mcp-candidate-boundary.XXXXXX")
trap '/bin/rm -rf -- "$TEMP_DIR"' EXIT

mkdir -p "$TEMP_DIR/Scripts" "$TEMP_DIR/.github/workflows"
for name in verify-artifact-provenance-boundary.sh package-dmg.sh assemble-release-assets.sh; do
  cp "$ROOT_DIR/Scripts/$name" "$TEMP_DIR/Scripts/$name"
done
workflow="$TEMP_DIR/.github/workflows/release-gate.yml"
cp "$ROOT_DIR/.github/workflows/release-gate.yml" "$workflow"
zsh "$TEMP_DIR/Scripts/verify-artifact-provenance-boundary.sh"

for publication in 'gh release create "$GITHUB_REF_NAME" --draft' 'gh release edit "$GITHUB_REF_NAME" --draft=false' 'git tag v1.0.0' 'draft: false'; do
  cp "$ROOT_DIR/.github/workflows/release-gate.yml" "$workflow"
  printf '\n          %s\n' "$publication" >>"$workflow"
  if zsh "$TEMP_DIR/Scripts/verify-artifact-provenance-boundary.sh" \
    >"$TEMP_DIR/output" 2>&1; then
    echo "Candidate boundary regression failed: premature tag/publication was accepted." >&2
    exit 1
  fi
  /usr/bin/grep -Fq \
    'Candidate construction must stop at an immutable artifact before installed acceptance and tagging.' \
    "$TEMP_DIR/output"
done

echo "Candidate boundary regression passed."
