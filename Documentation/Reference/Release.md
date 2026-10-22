# Release Reference

Release status: implemented by the
[release workflow](../../.github/workflows/release-gate.yml). Computer MCP is
distributed outside the Mac App Store as a notarized Universal 2 DMG.
[Versioning](../../VERSIONING.md) adopts the organization's version rules and
records the host's additions. This reference owns version sources, release
procedure and checks. `Scripts/release-checks.json` defines executable checks;
`Scripts/release.py` runs those same checks locally and in CI.

## Components and Version Sources

| Shipped component | Version meaning | Version source | Mirrors and derived fields | Update and read-only check |
| --- | --- | --- | --- | --- |
| Computer MCP App and embedded CLI | Product version and positive 32-bit integer build | Root `Version.json` | `Resources/ComputerMCPApp/Info.plist`: `CFBundleShortVersionString` and `CFBundleVersion`; generated `Sources/ComputerMCPCore/ComputerMCPCLI.swift`: version, build and runtime display | `Scripts/version.py update` regenerates mirrors; `Scripts/version.py check` verifies them |

Related component identities retain their own authorities:

| Component | Authoritative source | Derived or observed identity |
| --- | --- | --- |
| Project plugins | Each plugin's `computer-mcp-plugin.toml` | Runtime constants, where present, are generated from that manifest; archives retain the exact declaration |
| Bundled plugin archives | The plugin repository's accepted commit, built reproducibly there | `Resources/PluginArchives/index.json` pins each archive by SHA-256; bundling checks the plugin API, platform and artifact, and host range for every requested App architecture |
| Swift dependencies, including independent SDKs | Their public release tags, with this repository's requirements and locks described below | Dependency manifest and SBOM describe the actual packaged closure |
| Vendor protocol declarations | The importing component's schema provenance | Installed vendor executable version is recorded separately during integration checks |
| Product website | The accepted product release's published `release.json` asset | Website `public/release.json` is imported and checked; its private npm package version is independent |

## Compatibility Surface

Consumers depend on the App and embedded CLI, CLI commands, options, output and
exit codes, MCP transport and tool contracts, plugin manifests and host checks,
TOML configuration, serialized values, evidence formats and documented file
locations. The relevant contracts are indexed in the
[Reference](README.md), including [CLI](CLI.md), [MCP Protocol](MCPProtocol.md),
[Config](Config.md), [Plugin Packages](PluginPackages.md) and
[Validation](Validation.md).

`Package.swift` declares the Swift tools and deployment-target floors and the
two macOS executable products. Linux builds and tests the platform-neutral
targets. [Package](../Architecture/Package.md) describes that package surface.
Compatibility decisions rely on review and regression evidence; numeric version
checks do not infer API compatibility.

The host supports one closed range of plugin API versions, currently `1...1`,
reported by `computer-mcp build-info` as `plugin_api`. The organization's
[plugin version rules](https://github.com/computer-mcp/.github/blob/master/VERSIONING.md#plugin-versions-and-compatibility)
define the API and host ranges; the [Plugin API decision](../Decisions/PluginAPI.md)
and [Plugin Packages](PluginPackages.md) own decoding, evaluation order and
refusals.

## Dependencies and Verified Combinations

`Package.swift` owns compatibility requirements, and `Package.resolved` records
selected versions and revisions. [Package](../Architecture/Package.md#dependencies)
records the host's complete direct baseline under the organization rules linked
from [Versioning](../../VERSIONING.md). Both the host and `Tools/Validation`
commit `Package.resolved`; CI checks for lockfile drift.

The host uses the organization's MCP Swift SDK fork. `Tools/Validation` uses the
unmodified upstream SDK as an independent client for gateway interoperability
checks; its [README](../../Tools/Validation/README.md) owns that exception and its
`Package.swift` owns the exact pin. Root package tests and the separate Validation
package checks exercise their respective locked dependency closures.

`Scripts/version.py check --dependencies` checks root requirements and locks,
and compares every resolved public dependency tag with its locked commit.
Bare and `v`-prefixed tags, and SwiftPM's normalization of a two-component tag to
a three-component version, are accepted only when they identify the same locked
commit. The command does not check the separate Validation package's pins.

Protocol baselines and actual runtime versions need not be numerically equal;
integration evidence identifies the combination actually exercised. An upstream
release triggers downstream changes, rebuilding or revalidation when its effect
on that component warrants them. Dependency locks and public tags supply the SDK
identity; there is no separate SDK version ledger.

## Derived Metadata and Drift Checks

An installed App, old worktree or convenient binary is not a source for the next
product version. Missing authority or inconsistent derived fields fail the
check. Packaged runtime and build identity must match `Version.json`.

```sh
python3 Scripts/version.py update --version X.Y.Z --build N --kind KIND --reason REASON
python3 Scripts/version.py generate
python3 Scripts/version.py check
```

`update` changes the authority and regenerates App/CLI fields. Its required
`--kind` is `fix`, `feature`, `breaking` or `candidate`; the output records the
component, previous and current metadata, kind and rationale. `generate`
refreshes derived fields. `check` is read-only.

CI checks generated values, release/tag alignment and advancement against an
ancestor commit's authority. `check --base COMMIT` checks current metadata and
reports why comparison was skipped when HEAD has no parent, the base is
unavailable or the base is not an ancestor of HEAD. `check --tag TAG` checks the
declared version and candidate source commit. `check --app APP_PATH` and
`check --cli CLI_PATH` inspect actual packaged versions.

## Candidate, Acceptance and Publication

### Cloud pipeline

`.github/workflows/release-gate.yml` performs source verification, Universal 2
construction, Developer ID signing, notarization, signed-tag creation, asset
upload and public-release verification in GitHub Actions. The no-secret job is
read-only. The `production` job has repository content-write and Actions-read
permissions, and runs only an explicitly requested canonical `master` commit.
Its Environment authorization permits the complete release operation.

Candidate identity is the protected Actions run and attempt, bound to source
and artifact hashes. `Scripts/candidate.py` preserves the built artifact and
authenticates GitHub artifact retrieval. `Scripts/publish-release.py` assembles
and publishes the unchanged candidate. Cloud publication requires no pre-existing
local `.agent` state or installed App.

### One-time GitHub configuration

Keep the `production` Environment restricted to canonical `master` with a
required reviewer. PR and arbitrary-branch jobs must not receive its secrets.

Environment variables:

| Variable | Purpose |
| --- | --- |
| `APPLE_TEAM_ID` | Apple Developer Team ID |
| `DEVELOPER_ID_SIGNING_IDENTITY` | Exact `Developer ID Application: ...` identity |
| `RELEASE_TAG_SIGNING_IDENTITY` | Dedicated cloud Git tag signer's email identity |

Environment secrets:

| Secret | Purpose |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Password-protected Developer ID certificate/private key, Base64 encoded |
| `DEVELOPER_ID_P12_PASSWORD` | PKCS#12 export password |
| `DEVELOPER_ID_PROFILE_BASE64` | Developer ID profile authorizing production identity and Keychain group |
| `ASC_API_KEY_P8_BASE64` | App Store Connect Team API private key, Base64 encoded |
| `ASC_API_KEY_ID` | Team API key identifier |
| `ASC_API_ISSUER_ID` | Team API issuer UUID |
| `RELEASE_TAG_SIGNING_KEY` | Dedicated SSH private key for cloud annotated tags |

The tag signer's public key and identity are committed to
`.github/signing-allowed-signers`. Its private key belongs only in protected
secret storage; never copy the operator's personal signing key into Actions.
To rotate the cloud key, review the new public trust entry before activating the
new secret. Retain public keys needed to verify historical tags.

The notarization API key must be a Team key; an Individual key cannot
authenticate `notarytool`. Use the least App Store Connect role that supports
notarization. Team keys apply across the team's apps. Base64 is an encoding;
Environment Secret protection supplies confidentiality.

#### Credential ownership

| Credential or approval | Purpose and storage |
| --- | --- |
| Mac login password / Touch ID | Local administrator and Keychain authorization; remains on the Mac |
| Apple Account password and two-factor authentication | Human developer-portal access; never a workflow secret |
| Operator SSH signing key | Sign source changes; remains in the operator's SSH agent/Keychain |
| Dedicated release SSH key | Sign cloud annotated tags; protected `production` secret and ephemeral owner-only runner file |
| Developer ID certificate and profile | Sign and authorize the production App; protected secrets and recoverable secure originals |
| App Store Connect Team API key | Submit notarization; protected secret and secure original `.p8` recovery copy |
| GitHub Environment approval | Authorize one trusted cloud release run |
| Runner Keychain password | Generated randomly in the job and destroyed with its temporary Keychain |
| GitHub `GITHUB_TOKEN` | Scoped repository release and artifact operations; automatically issued to the job |

Apple App-Specific Passwords are not used. App runtime tunnel credentials belong
to Computer MCP's Data Protection Keychain and never enter the release pipeline.
Never commit private keys, certificates, profiles, passwords or environment
dumps. GitHub does not reveal a saved secret; keep necessary original Apple
credentials in recovery-capable secret storage.

### Preparing and publishing a version

1. Prepare the version and changelog under [Versioning](../../VERSIONING.md),
   using the update command above. Shared release-note and readiness templates
   render from the dated changelog section and immutable candidate identity.
   Existing legal approvals remain valid; changed legal text requires its own
   approval and updated digests.
2. Commit and merge the product source, version authority and changelog to
   canonical `master`. Complete the shared source, dependency and distribution
   checks in GitHub CI.
3. Dispatch the release workflow with a fresh correlation identity:

```sh
gh workflow run release-gate.yml --ref master \
  --field request_id=RELEASE_REQUEST_ID --field operation=publish
```

Approve the resulting `production` Environment request. The protected job builds
Universal 2 binaries, imports ephemeral Developer ID assets, signs and notarizes
the App and DMG, verifies the exact distribution and preserves the candidate
artifact with its inventory and digest. It creates the signed formal tag on the
candidate commit using the dedicated cloud release identity. Publication assembles
release records around the unchanged notarized DMG, preserves the complete
assembly before uploads, compares existing draft assets, uploads missing assets
and verifies authenticated and unauthenticated public downloads.

The completed GitHub Release contains the notarized DMG, notes, readiness record,
dependency manifest, SBOM, notices, notarization receipts, provenance, checksums
and website delivery record.

The shared command also dispatches the same cloud pipeline, waits for its result
and downloads its authenticated candidate for optional local installation:

```sh
python3 Scripts/release.py publish --run RELEASE_RUN_ID
python3 Scripts/release.py resume --run RELEASE_RUN_ID --profile publish
```

An Environment wait exits 75 with the exact Actions URL. Resume the same request
after approval; an interrupted local wait does not justify another dispatch.
Local commands upload no release assets and perform no official construction,
signing or notarization.

### Website synchronization

The website's existing Pages workflow reconciles the latest public stable
release on its hourly schedule, source pushes and manual dispatch. The importer
verifies the official tag, source commit and metadata asset digest. The website
automation App creates a signed proposal and auto-merges it after required CI,
then Pages builds and deploys current canonical master. It preserves the
published site if import, checks, merge or deployment fails.

No per-release local metadata import or website upload is required. Website
runtime and App versioning remain independent. Manual import remains available
in that repository through `npm run release:update -- vX.Y.Z`.

### Local installation and diagnostics

A user's Mac downloads the official DMG and replaces the App while preserving
needed rollback, user data and plugin installation identities. The candidate
installer can install a downloaded, authenticated candidate:

```sh
python3 Scripts/install-candidate.py --run RELEASE_RUN_ID --approve-cutover
```

It validates exact bytes and signature/staples, stops the prior App normally,
preserves it, replaces the App, verifies its startup identity and rolls back on
failure. Installation does not run the installed diagnostic suite automatically.

Optional candidate-bound native diagnostics remain available:

```sh
python3 Scripts/release.py run --run RELEASE_RUN_ID --profile acceptance
```

They check native permissions, navigation, workspace operations and installed
plugin package identity, compatibility, dependencies and files on that Mac.
Package checks preserve host settings and do not claim vendor runtime or
end-to-end acceptance; those belong to each plugin. Cloud release reports do
not claim these results.

TCC decisions remain native human actions; elapsed time never counts as
authorization.

## Evidence Reuse and Invalidation

Local shared-check receipts bind source, dependencies, configuration, check
definitions, toolchain, environment, outputs and logs and remain authenticated by
their owner-only key. `--reuse-ci` imports successful canonical master source CI
receipts with the exact source and verified immutable artifact digests. Missing,
untrusted or mismatched receipts cannot authorize reuse. Only matching successful
results are reused; a failed independent check does not erase another check's
valid evidence. Changed inputs invalidate affected checks and their downstream
results. Failed results, timings and attempt logs remain available for diagnosis.

Installed diagnostics use separate candidate-bound receipts. A committed
checker correction within `CANDIDATE_CHECK_FILES` in `Scripts/release.py` may be
rebound to an existing candidate through
`resume --run RELEASE_RUN_ID --reuse-candidate --profile acceptance` after the
exact permitted source difference is reviewed. The affected checks run again;
this operation neither dispatches another build nor changes the candidate or
formal tag identity. Product, dependency, packaging or signing changes require a
new candidate and affected acceptance. Source tests do not establish installed
acceptance.

### Publication recovery

`Scripts/restore-cloud-release.py` recovers the immutable candidate and complete
publication assembly before a retry. Both artifacts must come from the official
master dispatch workflow at the same source commit. A candidate is recoverable
after its protected build and preservation steps succeeded. Archive digests,
manifest identity and every extracted output are checked before reuse.
Publication recovery also binds the candidate identity, signed tag object and
complete asset inventory.

Use **Re-run failed jobs** for a failed workflow. The protected job restores its
prior signed candidate and assembly and resumes publication. It does not build
or re-sign that candidate. To recover a previous dispatch at the same source:

```sh
gh workflow run release-gate.yml --ref master \
  --field request_id=RELEASE_REQUEST_ID --field operation=publish \
  --field resume_run_id=FAILED_RUN_ID
```

Missing or mismatched recovery evidence stops the operation for investigation.
An authentication or network error does not prove that a tag, draft or asset is
absent. Publication transport failures resume the accepted binaries. Partial
draft uploads compare all existing bytes and upload missing assets; publication
refuses to overwrite public assets.

### Public-release verification

Public-release verification uses protected master to check the already published
declared version and signing key. It does not build another App or change public
assets:

```sh
gh workflow run release-gate.yml --ref master \
  --field request_id=RELEASE_REQUEST_ID --field operation=verify-public
```

This verifies public asset digests, checksums, notarization receipts, native
signatures/staples, packaged build identity and the dedicated tag signing key.
Its temporary signing-check tag stays on the runner.

## Entry Points and Artifact Retention

| Operation | Existing command or procedure | Required access |
| --- | --- | --- |
| Version update and check | `python3 Scripts/version.py update`, `generate` and `check`, with arguments above | Local repository; `check --dependencies` also reads public dependency tags |
| Shared source and CI checks | `python3 Scripts/release.py run --run CHECK_RUN_ID --profile ci` | Local toolchain and public dependency tags |
| Candidate construction and publication | Cloud dispatch or `python3 Scripts/release.py publish --run RELEASE_RUN_ID`, as above | Canonical master, GitHub Actions and protected `production` approval |
| Status and local interrupted wait | `python3 Scripts/release.py status --run RELEASE_RUN_ID --profile publish` and `resume --run RELEASE_RUN_ID --profile publish` | Local run receipts; GitHub Actions for cloud progress |
| Cloud recovery and public verification | Workflow dispatches above with `resume_run_id` or `operation=verify-public` | Canonical master and protected `production` approval |
| Local installation and diagnostics | `install-candidate.py --approve-cutover` and the `acceptance` profile, as above | Exact authenticated candidate, local replacement authorization and native permissions |
| Cleanup | `python3 Scripts/release.py cleanup --run CHECK_RUN_ID`; add `--apply` after reviewing the preview | Run ownership and authenticated inactive outputs |

`Scripts/release-checks.json` defines shared CI/source checks and optional
candidate/installed-diagnostic entrypoints. Ordinary CI's `ci` profile covers
dependency identity, formatting, script/workflow boundaries, Swift and Validation
tests, interfaces, documentation and development distribution. Local development
packaging uses `ADHOC_SIGNING=1`; it cannot supply an official release.

`cleanup` previews deletion by default. It removes the run's unchanged,
authenticated, inactive temporary outputs; candidate and installation evidence
is retained. Unrecognized files and active process references block deletion.
Old Git worktrees require unique-content and behavior reconciliation, then normal
Git worktree removal. Credentials, live data, unrelated work and the necessary
rollback version are preserved. Never copy a full checkout or `.git` into
release outputs.

Once the signed tag, required public assets and digests, notarization and release
record are verified, the official publication is the durable release record.
Completed local release copies, logs and duplicate binaries need no separate
archive; failed attempts, unique evidence and the rollback version stay until
resolved.

Committed documents and scripts carry current release facts and procedures.
Private machine paths, thread identifiers, recovery copies and per-run progress
belong in local execution records. Closeout requires delivered changes, verified
release evidence and accounting for owned temporary work; an archived
conversation is not release evidence.
