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

## Candidate and publication contract

1. Commit and merge the candidate's source and version declarations to trusted
   `master`. Complete source, dependency, lifecycle and cross-component checks.
2. Dispatch the canonical candidate workflow from that exact master commit.
   The no-secret job validates inputs before the protected `production` job
   receives signing/notarization credentials. PR and arbitrary branch outputs
   cannot enter this protected job.
3. Download its immutable Actions artifact, verifying the run source, workflow,
   GitHub archive digest, candidate manifest and every extracted output.
4. Install and accept that exact signed/notarized App. Check native permissions,
   navigation, workspace operations, isolated cold/concurrent MCP requests,
   source-unavailable operation and packaged plugin integration. Source tests
   and development builds do not substitute for these artifact-bound checks.
5. Only then create the signed formal tag on the same commit. Assemble records
   around the existing accepted binaries, upload them, verify remote bytes,
   publish and verify unauthenticated public downloads. Publication never rebuilds
   or re-signs the accepted App or DMG.
6. Import the official delivery record into the website and verify its deployed
   record and download links. Deliver changed dependencies/plugins in dependency
   order after the complete candidate combination has passed integration.

Human authorization for signing, publication and production replacement remains
required by its owning boundary. TCC is a native human action. Scripts report
these as `waiting_for_human` with the concrete action; they do not infer approval
from elapsed time. Normal stages, deadlines, result evaluation and bounded
network retries are scripted. A model does not judge whether a release passed.
The fixed Codex fixture exercises the real executable against a loopback model
and explicitly does not claim real-model/authentication coverage.

## Checkpoints, invalidation and failure

A stage receipt binds source commit and tree contents, toolchain/environment,
check definition, target configuration, dependency checkpoints, output inventory,
log digest and elapsed time. Local receipts are authenticated by an owner-only
key outside the run directory. Imported CI evidence must come from a successful
canonical master push, match GitHub's immutable artifact digest and every input.
Missing, edited, unsigned or mismatched local receipts cannot authorize reuse.

Only matching successful results are reused. A changed stage or dependency
invalidates that stage and its downstream evidence; a failed independent stage
does not erase other successes. Source or toolchain changes invalidate all
checks bound to those inputs. Installed App and plugin bytes are checked again
before publication. A digest is evidence identity, not proof of test quality or
permission to execute untrusted code.

States are `passed`, `failed`, `waiting_for_human` and `invalidated`. Failures and
interrupted attempts retain their logs and outputs. `resume` verifies them before
continuing. A partial draft upload resumes only missing assets and compares all
existing bytes; it never overwrites a release asset. Product checks are not
automatically rerun until they happen to pass.

## Retention and handoff

`cleanup` previews deletion by default. It removes only the run's unchanged,
authenticated, inactive temporary outputs; candidate, installation and delivery
evidence is retained. Unrecognized files and active process references block
deletion. Old Git worktrees require unique-content and behavior reconciliation,
then normal Git worktree removal. Credentials, live data, unrelated work and
the necessary rollback version are preserved.

Committed documents and scripts carry these rules to subsequent work. Private
machine paths, thread identifiers, recovery copies and per-run progress belong
in local execution records, not in this specification. A closeout is complete
only after changes are delivered, required evidence exists and owned temporary
work is accounted for; an archived conversation is not release evidence.
