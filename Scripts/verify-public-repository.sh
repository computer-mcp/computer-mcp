#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
cd "$ROOT_DIR"

RG=(rg -n --hidden \
  --glob '!.git/**' \
  --glob '!.build/**' \
  --glob '!**/.build/**' \
  --glob '!dist/**' \
  --glob '!.agent/**' \
  --glob '!.codex/**' \
  --glob '!.computer-mcp/**' \
  --glob '!.local/**' \
  --glob '!Scripts/verify-public-repository.sh')

PUBLIC_PATHS=(.)

private_agent_files=(${(f)$(git ls-files '.agent/**' '.codex/**' '.refs.yaml')})
if (( ${#private_agent_files[@]} > 0 )); then
  print -l -- $private_agent_files >&2
  echo "Public repository verification failed: private agent metadata is tracked." >&2
  exit 1
fi

fail_if_match() {
  local description=$1
  local pattern=$2
  local matches
  matches=$("${RG[@]}" -l "$pattern" $PUBLIC_PATHS || true)
  if [[ -n "$matches" ]]; then
    print -l -- ${(f)matches} >&2
    echo "Public repository verification failed: $description" >&2
    exit 1
  fi
}

fail_if_match "personal absolute macOS paths" '/Users/xudongxu/'
fail_if_match "known secret formats" \
  '(sk-(proj-|svcacct-)?[[:alnum:]_-]{20,}|gh[pousr]_[[:alnum:]]{30,}|github_pat_[[:alnum:]_]{40,}|AKIA[0-9A-Z]{16}|xox[baprs]-[[:alnum:]-]{20,}|eyJ[[:alnum:]_-]{100,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----)'

if rg -n 'XCTest|import XCTest' Tests Tools/Validation/Tests; then
  echo "Public repository verification failed: XCTest remains in test targets." >&2
  exit 1
fi

credential_files=(${(f)$(find . \
  -path './.git' -prune -o \
  -path '*/.build' -prune -o \
  -path './dist' -prune -o \
  -path './.agent' -prune -o \
  -path './.codex' -prune -o \
  -path './.computer-mcp' -prune -o \
  -path './.local' -prune -o \
  -type f \( -name '*.pem' -o -name '*.p12' -o -name '*.key' -o \
    -name '*.p8' -o -name '*.provisionprofile' -o -name '*.mobileprovision' -o \
    -name '*.token' -o -name '*.token-file' -o -name '.env' -o -name '.env.*' \) \
  -print)})
if (( ${#credential_files[@]} > 0 )); then
  print -l -- $credential_files >&2
  echo "Public repository verification failed: credential-like files are present." >&2
  exit 1
fi

large_files=(${(f)$(find . \
  -path './.git' -prune -o \
  -path '*/.build' -prune -o \
  -path './dist' -prune -o \
  -type f -size +10M -print)})
if (( ${#large_files[@]} > 0 )); then
  print -l -- $large_files >&2
  echo "Public repository verification failed: source file exceeds 10 MiB." >&2
  exit 1
fi

generated=(${(f)$(find Tests Tools/Validation/Tests \
  -type f \( -name '*.log' -o -name '*.pid' -o -name '*.campaign.json' -o \
    -name '*.evidence.json' -o -name '*.doccarchive' \) -print)})
if (( ${#generated[@]} > 0 )); then
  print -l -- $generated >&2
  echo "Public repository verification failed: generated evidence is inside tests." >&2
  exit 1
fi

echo "Public repository verification passed."
