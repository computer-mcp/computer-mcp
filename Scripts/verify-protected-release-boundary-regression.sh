#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/computer-mcp-protected-release-test.XXXXXX")

cleanup() {
  /bin/rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

for forbidden_command in 'rg --version' 'brew install ripgrep'; do
  fixture="$TEMP_DIR/forbidden-tool.sh"
  /usr/bin/printf '%s\n' '#!/bin/zsh' "$forbidden_command" >"$fixture"

  if PROTECTED_RELEASE_TEST_ADDITIONAL_PATHS="$fixture" \
    "$ROOT_DIR/Scripts/verify-protected-release-boundary.sh" \
    >"$TEMP_DIR/stdout" 2>"$TEMP_DIR/stderr"
  then
    echo \
      "Protected release boundary regression failed: $forbidden_command was accepted." \
      >&2
    exit 1
  fi
  /usr/bin/grep -Fq \
    'Protected release execution must not depend on Homebrew or ripgrep.' \
    "$TEMP_DIR/stderr"
done

echo "Protected release boundary regression passed."
