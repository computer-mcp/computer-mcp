#!/bin/zsh
set -euo pipefail

RIPGREP_EXECUTABLE=${RIPGREP_EXECUTABLE:-rg}
if ! command -v "$RIPGREP_EXECUTABLE" >/dev/null 2>&1; then
  echo "Verification failed: ripgrep is unavailable. Set RIPGREP_EXECUTABLE to an existing installation." >&2
  exit 127
fi
"$RIPGREP_EXECUTABLE" --version >/dev/null

# A failed inspection is not the same as a successful search with no matches.
rg() {
  local result=0
  command "$RIPGREP_EXECUTABLE" "$@" || result=$?
  if (( result > 1 )); then
    echo "Verification failed: ripgrep could not complete the inspection (exit $result)." >&2
    exit "$result"
  fi
  return "$result"
}

ROOT_DIR=${0:A:h:h}
cd "$ROOT_DIR"

PACKAGE=$(/usr/bin/swift package dump-package)
PRODUCTS=$(jq -c '[.products[].name] | sort' <<<"$PACKAGE")
if [[ "$PRODUCTS" != '["ComputerMCPApp","computer-mcp"]' ]]; then
  echo "Package boundary gate failed: only the App and CLI executable products are allowed." >&2
  exit 1
fi

LIBRARIES=(${(f)"$(jq -r '.targets[] | select(.type == "regular") | .path // "Sources/\(.name)"' <<<"$PACKAGE")"})
if rg -n '^\s*public\b' "${LIBRARIES[@]}" --glob '*.swift'; then
  echo "Package boundary gate failed: internal target declarations must not be public." >&2
  exit 1
fi

# Neutral targets build on Linux: no unconditional macOS framework imports (a conditional
# import selects a platform, as in the module graph check) and no macOS paths. A test
# target is neutral when the target it tests is.
NEUTRAL=(${(f)"$(jq -r --argjson graph "$(<Scripts/module-graph.json)" '
  ($graph.macos_only) as $macos
  | .targets[]
  | select(.type == "regular" or .type == "test")
  | select((.name | IN($macos[])) or (.type == "test" and (.name | rtrimstr("Tests") | IN($macos[]))) | not)
  | .path // (if .type == "test" then "Tests/\(.name)" else "Sources/\(.name)" end)
' <<<"$PACKAGE")"})
if ! python3 - "${NEUTRAL[@]}" <<'PY'
import importlib.util, json, pathlib, sys
spec = importlib.util.spec_from_file_location("graph", "Scripts/verify-module-graph.py")
graph = importlib.util.module_from_spec(spec)
spec.loader.exec_module(graph)
macos = set(json.loads(pathlib.Path("Scripts/module-graph.json").read_text())["macos_imports"])
found = False
for root in sys.argv[1:]:
    for path in sorted(pathlib.Path(root).rglob("*.swift")):
        for name in sorted(graph.unconditional_imports(path.read_text()) & macos):
            print(f"{path}: imports {name}")
            found = True
sys.exit(1 if found else 0)
PY
then
  echo "Package boundary gate failed: neutral targets must not import macOS frameworks." >&2
  exit 1
fi
if rg -n '"/(usr/s?bin|System|Applications)/' "${NEUTRAL[@]}" --glob '*.swift'; then
  echo "Package boundary gate failed: neutral targets must not reference macOS system paths." >&2
  exit 1
fi

if rg -n '^(@testable )?import ComputerMCP$' Tools/Validation; then
  echo "Package boundary gate failed: Validation imports the production implementation module." >&2
  exit 1
fi

if rg -n '\.package\(\s*path:\s*"\.\./\.\."' Tools/Validation/Package.swift; then
  echo "Package boundary gate failed: Validation still depends on the root package by path." >&2
  exit 1
fi

if rg -n 'swift-codex|CodexAppServer(Client|Protocol|Runtime)|CodexExec|CodexMCP' Package.swift; then
  echo "Package boundary gate failed: domain execution dependencies belong to independent plugins." >&2
  exit 1
fi

echo "App/CLI package boundary gate passed."
