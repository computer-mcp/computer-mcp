# Versioning and Release

This document owns version meaning, release identity and acceptance policy.
[Release Reference](../Reference/Release.md) owns operator commands and protected
publisher configuration. `Scripts/release-checks.json` owns executable checks;
`Scripts/release.py` runs those same checks locally and in CI.

## Components and authority

| Component | Authoritative source | Derived or observed identity |
| --- | --- | --- |
| Computer MCP App and CLI | Root `Version.json`: product version and integer build | App Info.plist and CLI constants are generated; packaged runtime and build identity must match |
| Project plugins | Each plugin's `computer-mcp-plugin.toml` | Runtime constants, where present, are generated from that manifest; archives retain the exact declaration |
| Swift dependencies, including independent SDKs | Their public release tags; this repository's `Package.swift` compatibility requirements and `Package.resolved` revisions | Dependency manifest and SBOM describe the actual packaged closure |
| Vendor protocol declarations | The importing component's schema provenance | Installed vendor executable version is recorded separately during integration checks |
| Product website | The accepted product release's published `release.json` asset | Website `public/release.json` is imported and checked; its private npm package version is independent |

An installed App, old worktree or convenient binary is never a source for the
next product version. A missing authority or inconsistent derived field fails
the check. There is no second SDK version ledger. Protocol baseline and actual
runtime version need not be numerically equal; executable behavior is verified
for the combination actually used.

## Upgrade decisions

- Compatible behavior fixes increment the patch number.
- Compatible new public capabilities increment the minor number.
- Incompatible public interface changes increment the major number.
- Each plugin and SDK has its own release sequence. For components in `0.x`,
  patches remain compatible; new capabilities or incompatible changes increment
  the minor number and describe their compatibility impact.
- Documentation, CI and cleanup changes alone do not force a product release.
- An upstream release requires downstream change, rebuilding or revalidation
  only when its effect on that downstream component warrants it.

Every version update records component, change kind and rationale in the change
review and changelog. Numeric checks enforce declared rules; they do not infer
API compatibility. Review and regression evidence support that decision.

## Updates and drift checks

`Scripts/version.py update --version … --build … --kind … --reason …` changes
the authority and regenerates App/CLI fields. `generate` refreshes derived fields.
`check` is read-only. CI checks generated values, release/tag alignment and the
declared upgrade against the previous committed authority. `check --dependencies`
also compares every resolved public dependency tag with its locked commit and
declared requirement; equivalent tag spellings are accepted only for the same
commit. `check --app …` and `--cli …` inspect actual packaged versions.

Build numbers increase when an App candidate is revised. Candidate identity is
the protected Actions run and attempt, bound to source and artifact hashes.
An unsuccessful candidate does not consume a new formal patch version. After a
formal tag or artifact is published it is immutable: any subsequent product fix
requires its appropriate new version.

## Cloud release contract

1. Commit and merge the product source, version authority and dated changelog to
   canonical `master`. Complete the shared source, dependency and distribution
   checks in GitHub CI.
2. Dispatch `.github/workflows/release-gate.yml` once. The no-secret verification
   job authenticates the source and reuses only matching successful master CI.
   The protected `production` authorization covers construction and publication.
3. The protected job builds Universal 2 binaries, imports ephemeral Developer ID
   assets, signs and notarizes the App and DMG, verifies the exact distribution
   and preserves an immutable candidate artifact with its inventory and digest.
4. It creates the signed formal tag on that candidate commit using the dedicated
   cloud release identity. Publication assembles release records around the
   unchanged notarized DMG, preserves the complete assembly before uploads,
   compares existing draft assets, uploads missing assets and verifies both
   authenticated and unauthenticated public downloads.
5. The website's Pages workflow automatically imports the latest official public
   `release.json`, submits a signed automation proposal, waits for its required
   CI checks and deploys the merged generation. The existing hourly schedule,
   source pushes and manual dispatches run reconciliation.
6. A user's Mac downloads and installs the public distribution. Production
   replacement remains separately authorized and preserves a rollback App.
   Native TCC decisions and optional installed diagnostics belong to that Mac;
   they are not prerequisites for cloud publication and the cloud readiness
   record does not claim results for them.

Formal tags and public release assets are immutable. Product fixes require their
appropriate next version; CI or documentation changes alone do not consume an
App version. `verify-public` checks the already published declared version and
cloud tag signing without building another App or changing public assets.

## Checkpoints and recovery

Local shared-check receipts bind source, configuration, check definitions,
outputs and logs and remain authenticated by their owner-only key. Imported
source CI receipts require exact canonical source and immutable artifact digests.
Only matching successful results are reused; a failed independent check does
not erase another check's valid evidence.

Cloud release recovery uses GitHub's immutable candidate and publication
artifacts. Both must come from the official master dispatch workflow at the
same source commit. A candidate is recoverable only after its protected build
and preservation steps succeeded. Archive digests, manifest identity and every
extracted output are checked before reuse. Publication recovery also binds the
candidate identity, signed tag object and complete asset inventory.

Rerunning a failed release job restores its earlier candidate instead of
rebuilding. `resume_run_id` selects a prior dispatch at the same commit. Missing
or mismatched recovery evidence stops the operation for investigation. Product,
packaging or signing changes require a new candidate; a publication transport
failure does not justify replacing accepted binaries or incrementing a version.
Partial draft uploads resume missing assets and compare all existing bytes.
Public assets are never overwritten.

Installed diagnostics use their separate candidate-bound receipts. A committed
checker correction may be rebound to an existing candidate through the
explicitly enumerated checker-only boundary. That operation neither dispatches
another build nor changes the candidate or formal tag identity.

## Retention and handoff

`cleanup` previews deletion by default. It removes only the run's unchanged,
authenticated, inactive temporary outputs; candidate and installation
evidence is retained. Unrecognized files and active process references block
deletion. Old Git worktrees require unique-content and behavior reconciliation,
then normal Git worktree removal. Credentials, live data, unrelated work and
the necessary rollback version are preserved.

Once a release is complete and its signed tag, required public assets and
digests, notarization and release record are verified, the official publication
is the durable release record. Completed local release copies, logs and
duplicate binaries then need no separate archive; failed attempts, unique
evidence and the rollback version stay until resolved.

Committed documents and scripts carry these rules to subsequent work. Private
machine paths, thread identifiers, recovery copies and per-run progress belong
in local execution records, not in this specification. A closeout is complete
only after changes are delivered, required evidence exists and owned temporary
work is accounted for; an archived conversation is not release evidence.
