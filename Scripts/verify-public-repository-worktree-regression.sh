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

for private_directory in .agent .codex .computer-mcp .local; do
  /bin/mkdir -p "$WORKTREE/$private_directory"
  /usr/sbin/mkfile -n 11m "$WORKTREE/$private_directory/fixture.bin"
done
"$WORKTREE/Scripts/verify-public-repository.sh" >/dev/null \
  || fail "untracked private runtime artifacts were treated as public source."

git -C "$WORKTREE" add -f .agent/fixture.bin
if "$WORKTREE/Scripts/verify-public-repository.sh" \
  >"$TEMP_DIR/stdout" 2>"$TEMP_DIR/stderr"
then
  fail "tracked private metadata was accepted."
fi
/usr/bin/grep -Fq 'private agent metadata is tracked' "$TEMP_DIR/stderr" \
  || fail "tracked private metadata did not produce the expected diagnosis."
git -C "$WORKTREE" update-index --force-remove .agent/fixture.bin

/usr/sbin/mkfile -n 11m "$WORKTREE/public-fixture.bin"
if "$WORKTREE/Scripts/verify-public-repository.sh" \
  >"$TEMP_DIR/stdout" 2>"$TEMP_DIR/stderr"
then
  fail "an oversized public source file was accepted."
fi
/usr/bin/grep -Fq 'source file exceeds 10 MiB' "$TEMP_DIR/stderr" \
  || fail "the oversized public file did not produce the expected diagnosis."
/bin/rm -- "$WORKTREE/public-fixture.bin"

/usr/bin/printf '/Users/%s/credential\n' 'xudongxu' >"$WORKTREE/leak.txt"
if "$WORKTREE/Scripts/verify-public-repository.sh" \
  >"$TEMP_DIR/stdout" 2>"$TEMP_DIR/stderr"
then
  fail "a real personal absolute path outside the Git control file was accepted."
fi
/usr/bin/grep -Fq 'personal absolute macOS paths' "$TEMP_DIR/stderr" \
  || fail "the real path leak did not produce the expected diagnosis."

echo "Public repository Git-worktree regression passed."
