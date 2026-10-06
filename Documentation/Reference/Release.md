# Release Reference

Computer MCP is distributed outside the Mac App Store as a notarized Universal
2 DMG. [Versioning and Release](../Architecture/VersioningAndRelease.md) owns
version meaning and artifact identity. This reference owns commands and protected
publisher configuration.

## Cloud pipeline

`.github/workflows/release-gate.yml` performs source verification, Universal 2
construction, Developer ID signing, notarization, signed-tag creation, asset
upload and public-release verification in GitHub Actions. The no-secret job is
read-only. The `production` job has repository content-write and Actions-read
permissions, and runs only an explicitly requested canonical `master` commit.
Its Environment authorization permits the complete release operation. Publication
requires matching successful canonical source checks. Public-release verification
uses protected master to check the existing distribution and signing key.

`Scripts/candidate.py` preserves the built artifact and authenticates GitHub
artifact retrieval. `Scripts/publish-release.py` assembles and publishes the
unchanged candidate. `Scripts/restore-cloud-release.py` recovers immutable
candidate and publication artifacts before a retry. Cloud publication requires
no pre-existing local `.agent` state or installed App.

## One-time GitHub configuration

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

### Credential ownership

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

## Preparing and publishing a version

1. Use `Scripts/version.py update --version X.Y.Z --build N --kind fix --reason …`
   for a compatible fix, or the corresponding version kind. `Version.json` owns
   the product version; generated App and CLI fields are not independent inputs.
2. Finalize the dated changelog section. Shared release-note and readiness
   templates render from that section and the immutable candidate identity.
   Existing legal approvals remain valid; changed legal text requires its own
   approval and updated digests.
3. Merge the verified source to canonical `master` and allow master CI to finish.
4. Dispatch the release workflow with a fresh correlation identity:

```sh
gh workflow run release-gate.yml --ref master \
  --field request_id=RELEASE_REQUEST_ID --field operation=publish
```

Approve the resulting `production` Environment request. All remaining package
and publication steps run in that workflow. Its completed GitHub Release contains
the notarized DMG, notes, readiness record, dependency manifest, SBOM, notices,
notarization receipts, provenance, checksums and website delivery record.

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

## Publication recovery

A complete publication assembly is preserved as an immutable Actions artifact
before its first release-asset upload. Draft uploads compare existing bytes and
upload only missing assets. An authentication or network error does not prove
that a tag, draft or asset is absent.

Use **Re-run failed jobs** for a failed workflow. The protected job restores its
prior signed candidate and assembly and resumes publication. It does not build
or re-sign that candidate. To recover a previous dispatch at the same source:

```sh
gh workflow run release-gate.yml --ref master \
  --field request_id=RELEASE_REQUEST_ID --field operation=publish \
  --field resume_run_id=FAILED_RUN_ID
```

Missing or altered immutable artifacts stop recovery. Inspect that failure
before choosing a new candidate. Published assets and tags cannot be replaced;
a post-publication product defect requires its appropriate next version.

To validate automation against the already published declared version without
building or publishing an App:

```sh
gh workflow run release-gate.yml --ref master \
  --field request_id=RELEASE_REQUEST_ID --field operation=verify-public
```

This verifies public asset digests, checksums, notarization receipts, native
signatures/staples, packaged build identity and the dedicated tag signing key.
Its temporary signing-check tag stays on the runner.

## Website synchronization

The website's existing Pages workflow reconciles the latest public stable
release on its hourly schedule, source pushes and manual dispatch. The importer
verifies the official tag, source commit and metadata asset digest. The website
automation App creates a signed proposal and auto-merges it after required CI,
then Pages builds and deploys current canonical master. It preserves the
published site if import, checks, merge or deployment fails.

No per-release local metadata import or website upload is required. Website
runtime and App versioning remain independent. Manual import remains available
in that repository through `npm run release:update -- vX.Y.Z`.

## Local installation and diagnostics

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
plugin fixtures on that Mac. Cloud release reports do not claim these results.
A checker-only correction can use `resume --reuse-candidate --profile acceptance`
after its exact permitted source difference is reviewed. TCC decisions remain
native human actions; elapsed time never counts as authorization.

## Shared checks and cleanup

`Scripts/release-checks.json` defines the shared CI/source checks and optional
candidate/installed-diagnostic entrypoints. Ordinary CI runs the same definition:

```sh
python3 Scripts/release.py run --run CHECK_RUN_ID --profile ci
```

It covers dependency identity, formatting, script/workflow boundaries, Swift and
Validation tests, interfaces, documentation and development distribution.
`--reuse-ci` accepts only matching successful canonical master receipts;
untrusted, missing or mismatched receipts cannot authorize candidate reuse.

Local development packaging uses `ADHOC_SIGNING=1`; it cannot supply an official
release. Native shared-check cleanup previews unchanged inactive outputs before
removal. Once the official tag, public assets, digests and records are verified,
completed local duplicates need no archive. Preserve failures, unique source
recovery, credentials, user data and necessary App rollback. Never copy a full
checkout or `.git` into release outputs.
