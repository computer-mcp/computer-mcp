# Changelog

All notable user-visible changes to Computer MCP are documented here.

## Unreleased

## 1.0.8 — 2026-08-14

- Refresh the App-managed OpenAI `tunnel-client` profile with the current
  embedded CLI, gateway socket, gateway profile, and Tunnel identity before
  every start. This automatically migrates an existing connection when the App
  is updated or moved, then runs doctor before launching the tunnel process.
- Add fail-closed regressions for the required `init --force`, doctor, and run
  ordering and for a profile-refresh failure that must prevent process launch.
  The immutable `v1.0.7` attempt completed Developer ID signing, App and DMG
  notarization, Gatekeeper, checksums, credential cleanup, draft creation, exact
  DMG installation, and installed-CLI binary verification successfully. Exact
  ChatGPT acceptance then found that the existing Tunnel Client YAML still
  launched a bridge from the old development App path; its draft remains
  unpublished and no public GitHub Release was created.

## 1.0.7 — 2026-08-14

- Update a user-owned `~/.local/bin/computer-mcp` symlink from an older
  Computer MCP App bundle to the newly installed App automatically. Regular
  files, non-App targets, and links not owned by the user remain protected.
- Add a regression that performs the exact old-App-to-new-App CLI link
  migration required by the installation acceptance Test Case. The immutable
  `v1.0.6` attempt completed Developer ID signing, App and DMG notarization,
  Gatekeeper, checksums, credential cleanup, and draft creation successfully.
  Exact installation acceptance then found the old valid App-owned CLI link
  was classified as installed but refused migration; its draft remains
  unpublished and no public GitHub Release was created.

## 1.0.6 — 2026-08-14

- Copy accepted App and DMG notarization receipts into the root release-asset
  directory before generating `SHA256SUMS`, so every checksummed basename is
  also an uploadable root-level file.
- Add fail-closed, regression-tested asset-layout and checksum assembly gates
  that reject nested, external, missing, duplicate, symlinked, or misplaced
  release inputs before production credentials are available. The immutable
  `v1.0.5` attempt successfully Developer ID signed, notarized, stapled, and
  passed Gatekeeper for both the App and DMG, then stopped while assembling
  checksums because the two accepted receipt files had not been copied out of
  `ReleaseMetadata`. Credential cleanup succeeded and no GitHub Release was
  created.

## 1.0.5 — 2026-08-14

- Developer ID sign the final DMG container with a secure timestamp before
  submitting it to Apple, then independently verify its signature, Team ID,
  notarization ticket, Gatekeeper result, and checksum.
- Add no-secret signature-record and packaging-order regressions that reject a
  missing Developer ID authority, Team ID, timestamp, container signature, or
  a DMG signed only after notarization. The immutable `v1.0.4` attempt
  successfully signed and notarized the App, notarized and stapled the DMG,
  and passed mounted-App Gatekeeper assessment. It then stopped because the
  unsigned DMG container produced `source=no usable signature`; credential
  cleanup succeeded and no GitHub Release was created.

## 1.0.4 — 2026-08-13

- Parse Apple notarization responses through a dedicated fail-closed verifier
  that avoids zsh special parameters and validates the accepted status and UUID
  submission ID before stapling.
- Exercise accepted, rejected, missing, malformed, and invalid-ID notarization
  records before production credentials become available. The immutable
  `v1.0.3` attempt successfully built and Developer ID signed the Universal 2
  App, then stopped after the App notarization command returned because the
  packaging script declared zsh's read-only `status` parameter. Its ephemeral
  credentials were removed and it produced no GitHub Release or distributable
  artifact.

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
