# Computer MCP 1.0.29 Release Notes

Status: protected-CI release template. The workflow publishes only the exact
candidate that passes signed-tag, signing, notarization, staple, Gatekeeper,
checksum, provenance, and byte-identity gates.

## Highlights

- The App, owner-only control Socket, and CLI now share
  `AppControlPlaneOperations`. Gateway-aware workspace, profile, configuration,
  provider, and tunnel mutations therefore use one implementation, including
  restart and rollback behavior.
- `computer-mcp app capabilities` exposes the local owner-control contract as
  structured data. The CLI now covers App lifecycle, configuration history and
  rollback, profile activation, provider diagnostics, permission status, audit
  reads, and OpenAI and Cloudflare tunnel administration.
- Tunnel credentials are accepted only through standard input and remain in the
  App-owned Data Protection Keychain. They are not accepted as command-line
  arguments and are not returned in structured output.
- Computer Use refuses Accessibility actions that target the Computer MCP host
  process. Accessibility execution runs on the main actor, closing the
  menu-bar self-press crash path seen in 1.0.28.
- Workspace registration and other owner administration remain local-only.
  Remote MCP callers receive a stable instruction to use the owner CLI; the
  Computer MCP executable is not registered into its own remotely callable
  `cli.exec` surface.

## Validation

- 923 automated tests passed in CI-equivalent serial mode: 827 core/CLI tests,
  25 App tests, and 71 Validation tests.
- The executable-derived CLI contract, 22 Validation Test Cases, examples,
  localization, DocC warnings-as-errors, release metadata, signing/notarization
  boundary regressions, and public-repository gates passed.
- Independent arm64 and x86_64 optimized builds produced a provenance-bound
  development Universal 2 App and DMG, which passed mounted distribution
  verification without installing or launching the candidate.
- The installed 1.0.28 (29) App remained running under its original process for
  the entire build and validation sequence.

## Install

1. Download `Computer-MCP-1.0.29-universal.dmg` and `SHA256SUMS` from this
   GitHub Release.
2. Verify the checksums, open the DMG, and drag `Computer MCP.app` to
   `/Applications`.
3. Quit 1.0.28 only when you are ready to replace it, then launch 1.0.29. The
   release build and validation process never modifies the running 1.0.28 App.

The release does not bundle Codex, OpenAI `tunnel-client`, `cloudflared`, or
provider credentials.

## Security and compatibility

- The local control Socket remains owner-only. Its write operations are not
  exported as remote MCP tools.
- `shell.run`, Full Shell, generic CLI execution, operation tickets, and
  destructive tools retain their independent policy and approval boundaries.
- Existing schema-1 configuration, production Bundle ID, Team ID, Keychain
  group, TCC identity, runtime namespace, profiles, workspaces, tunnel
  credentials, and audit history remain compatible.
- v1.0.28 and all earlier tags and release records remain immutable.

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

The GitHub Release contains the notarized DMG, complete `SHA256SUMS`, CycloneDX
SBOM, dependency manifest, third-party notices, rendered release notes and
readiness report, and both accepted notarization receipts.
