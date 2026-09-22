#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
fail() { echo "Candidate source verification failed: $1" >&2; exit 1; }

[[ ${GITHUB_ACTIONS:-false} == true ]] || fail "Protected candidates require GitHub Actions."
[[ ${GITHUB_REPOSITORY:-} == computer-mcp/computer-mcp ]] || fail "Untrusted repository."
[[ ${GITHUB_EVENT_NAME:-} == workflow_dispatch ]] || fail "Candidates require an explicit dispatch."
[[ ${GITHUB_REF:-} == refs/heads/master && ${GITHUB_REF_TYPE:-} == branch ]] \
  || fail "Candidates must use the trusted master workflow and source."
[[ ${GITHUB_SHA:-} == $(git -C "$ROOT_DIR" rev-parse HEAD) ]] \
  || fail "Candidate source differs from the workflow commit."
git -C "$ROOT_DIR" merge-base --is-ancestor HEAD refs/remotes/origin/master \
  || fail "Candidate commit is not on origin/master."
[[ -z $(git -C "$ROOT_DIR" status --porcelain) ]] || fail "Candidate source is dirty."
python3 "$ROOT_DIR/Scripts/version.py" check
version=$(python3 "$ROOT_DIR/Scripts/version.py" show --field version)
if git -C "$ROOT_DIR" show-ref --verify --quiet "refs/tags/v$version"; then
  fail "v$version already exists; accepted releases cannot be rebuilt."
fi
[[ ${GITHUB_RUN_ID:-} =~ '^[0-9]+$' && ${GITHUB_RUN_ATTEMPT:-} =~ '^[0-9]+$' ]] \
  || fail "Missing immutable Actions candidate identity."
echo "Trusted candidate: $GITHUB_SHA / $GITHUB_RUN_ID.$GITHUB_RUN_ATTEMPT / v$version"
