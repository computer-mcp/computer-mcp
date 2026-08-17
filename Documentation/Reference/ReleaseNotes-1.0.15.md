# Computer MCP 1.0.15 Release Notes

Status: CI-rendered notarized draft. The GitHub Release must remain a draft
until the publisher completes the 23/23 acceptance checklist against the exact
checksummed artifact recorded below.

## Highlights

- Recursive read-only workspace scans preserve the final symlink as metadata
  instead of resolving it to the target. A dangling symlink can be listed or
  reported without aborting `file.list`, `file.tree`, `file.find`,
  `file.search`, `workspace.todos`, or `workspace.env_files`.
- Recursive content tools never follow symlinks. Links to content outside the
  registered workspace are skipped without reading the target, while explicit
  path operations and operation tickets continue to enforce canonical
  workspace containment.
- Directory enumeration now reconstructs child URLs from lexical names, and
  symlink results retain their original workspace-relative path instead of the
  target path.
- The notarized 1.0.14 draft remains unpublished because exact-artifact
  acceptance found the dangling-symlink scan regression after its real ChatGPT
  Full Shell and escaping-symlink denial checks had passed. Users never
  received that candidate; 1.0.15 repeats signing, notarization, installation,
  and external acceptance from the corrected source.
- Exact-artifact acceptance repeats all 287 advertised tool calls, schema-2
  evidence correlation, real ChatGPT Full Shell, and the complete 23-case
  checklist after a normal Finder launch.
- Official artifacts remain Universal 2, Developer ID signed, notarized,
  stapled, Gatekeeper assessed, checksummed, and produced only by the protected
  GitHub Actions signed-tag workflow.

## Install

1. Download `Computer-MCP-1.0.15-universal.dmg` and `SHA256SUMS` from the same
   GitHub Release.
2. Verify the SHA-256 digest.
3. Open the DMG and drag `Computer MCP.app` to `/Applications`.
4. Cold-start the App from Finder and grant only the macOS permissions needed
   by the capabilities you enable.
5. Use **Install Command Line Tool** if you want the App-owned CLI link at
   `~/.local/bin/computer-mcp`.

The release does not bundle Codex, OpenAI `tunnel-client`, `cloudflared`, or
provider credentials. OpenAI and Cloudflare runtime credentials are supplied
by each user and stored in that user's App-owned Data Protection Keychain.

## Security defaults

- `shell.run`, generic CLI execution, process spawning, workspace writes, and
  Full Shell remain disabled until both local policy and the selected profile
  explicitly grant them.
- Remote profiles never inherit `local-admin` authority.
- Configuration export contains no provider secret, token, credential,
  Keychain value, or resolved proxy value.
- Screen Recording and Accessibility are local macOS TCC grants for the signed
  App identity; another app's grant does not transfer to Computer MCP.
- Runtime credentials are not release inputs and are never embedded in the
  App, DMG, examples, logs, configuration exports, or GitHub Release.

## Legal and privacy

Computer MCP is proprietary source-visible software, not an open-source Swift
package. Installation and non-commercial use are governed by `LICENSE` and
`EULA.md`. Third-party licenses are reproduced in the App and DMG. Local data
and remote transmission boundaries are described in `PRIVACY.md`.

## Final release record

- Release date: __RELEASE_DATE__
- Candidate commit: `__RELEASE_COMMIT__`
- Signed tag: `__RELEASE_TAG__`
- Signed tag object: `__RELEASE_TAG_OBJECT__`
- Apple Team ID: `__APPLE_TEAM_ID__`
- Architectures: `__APP_ARCHITECTURES__`
- App notarization submission: `__APP_NOTARY_SUBMISSION_ID__`
- DMG notarization submission: `__DMG_NOTARY_SUBMISSION_ID__`
- DMG SHA-256: `__DMG_SHA256__`
- Embedded CLI SHA-256: `__EMBEDDED_CLI_SHA256__`
- GitHub Actions run: __GITHUB_RUN_URL__
- Apple Silicon native installation and lifecycle: required before publishing
  the draft
- x86_64 compatibility under Rosetta 2: required before publishing the draft
- Final acceptance: the publisher must record 23/23 before publishing the
  draft

The GitHub Release upload set contains the notarized DMG, `SHA256SUMS`,
CycloneDX SBOM, dependency manifest, third-party notices, these rendered
release notes, the rendered production-readiness report, and both notarization
receipts. Private raw acceptance evidence is retained separately and is never
uploaded automatically.
