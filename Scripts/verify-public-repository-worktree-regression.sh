#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/computer-mcp-public-worktree.XXXXXX")
WORKTREE="$TEMP_DIR/repository"

cleanup() {
  if [[ -e "$WORKTREE/.git" ]]; then
    git -C "$ROOT_DIR" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
  fi
  /bin/rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "Public repository worktree regression failed: $1" >&2
  exit 1
}

git -C "$ROOT_DIR" worktree add --detach "$WORKTREE" HEAD >/dev/null
[[ -f "$WORKTREE/.git" ]] || fail "the fixture is not a Git worktree."
/bin/cp "$ROOT_DIR/Scripts/verify-public-repository.sh" \
  "$WORKTREE/Scripts/verify-public-repository.sh"

"$WORKTREE/Scripts/verify-public-repository.sh" >/dev/null \
  || fail "a clean Git worktree was rejected because of its control file."

/usr/bin/printf '/Users/%s/credential\n' 'xudongxu' >"$WORKTREE/leak.txt"
if "$WORKTREE/Scripts/verify-public-repository.sh" \
  >"$TEMP_DIR/stdout" 2>"$TEMP_DIR/stderr"
then
  fail "a real personal absolute path outside the Git control file was accepted."
fi
/usr/bin/grep -Fq 'personal absolute macOS paths' "$TEMP_DIR/stderr" \
  || fail "the real path leak did not produce the expected diagnosis."

echo "Public repository Git-worktree regression passed."
