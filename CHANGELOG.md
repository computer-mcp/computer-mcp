# Changelog

All notable user-visible changes to Computer MCP are documented here.

## Unreleased

## 1.0.3 — 2026-08-13

- Make the protected release job self-contained by limiting its formal
  build/sign/notarize path to macOS and Xcode tools instead of relying on a
  Homebrew tool installed in the preceding job.
- Add positive and negative release-boundary gates that reject Homebrew or
  ripgrep dependencies after production credentials become available. The
  immutable `v1.0.2` attempt stopped at the first production tooling preflight,
  before protected credentials were validated or used, and produced no GitHub
  Release or production artifact.

## 1.0.2 — 2026-08-12

- Make `git.branch` deterministic across Git configurations by explicitly
  disabling paging, color, and column output and requesting list semantics.
- Verify that the reusable `fixture-base` branch exists when generating the
  Validation Git fixture. The immutable `v1.0.1` attempt stopped in the
  no-secret Validation job and produced no GitHub Release or production
  artifact.

## 1.0.1 — 2026-08-12

- Preserve and verify the remote SSH-signed annotated tag object after GitHub
  Actions checkout before any protected production credential is available.
- Notarized Universal 2 DMG release candidate. The immutable
  `v1.0.0` attempt stopped in the no-secret verification job and produced no
  GitHub Release or production artifact.

## 1.0.0 — 2026-08-12 (unpublished candidate)

- Initial App/CLI release candidate for macOS 14+ as a Universal 2 DMG.
- Policy-enforced local and remote MCP gateway with explicit caller, profile,
  workspace, risk, TCC, and audit boundaries.
- Independent OpenAI Secure MCP Tunnel and Cloudflare remotely managed named
  tunnel lifecycles.
- Typed builtin, Skills, CLI, downstream MCP, process, Codex, and Computer Use
  capability families.
- App-owned configuration, GRDB state, Keychain secrets, security-scoped
  workspaces, Control Socket, embedded CLI, and launch-at-login lifecycle.
- Signed-tag releases capture accepted App and DMG notarization receipts and
  render artifact-bound records before creating the checksummed draft.
