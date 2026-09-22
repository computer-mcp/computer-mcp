# Release Reference

Computer MCP is distributed outside the Mac App Store as a notarized Universal
2 DMG. [Versioning and Release](../Architecture/VersioningAndRelease.md) owns
version meaning, compatibility and evidence policy. This reference owns commands
and protected publisher configuration.

## Release trust boundary

`.github/workflows/release-gate.yml` builds candidates on an explicitly requested
canonical `master` commit. Its no-secret `verify` job runs the shared source
checks, reusing only matching official successful master CI receipts. Its
`release` job starts after verification and protected `production` Environment
authorization. It signs and notarizes the App and DMG and uploads a checksummed,
immutable Actions artifact. It neither creates a formal tag nor publishes a
GitHub Release.

`Scripts/candidate.py` authenticates the run, workflow, repository, commit and
GitHub artifact digest before extracting the candidate. Installation acceptance
binds the exact packaged App and selected plugin bytes to fixed case results.
`Scripts/publish-release.py` requires authenticated matching checkpoints before
creating the signed tag and publishing those same binaries. Source changes,
rebuilding, re-signing or package changes invalidate the relevant evidence.

## One-time GitHub configuration

Create a GitHub Environment named `production`. Restrict its deployment branch
policy to the canonical repository, add a required reviewer, and do not
allow untrusted branches to access it. The candidate workflow has read-only repository access. Publication uses the
authorized operator’s Git signing identity and GitHub CLI credentials only after
installed acceptance has passed.

Set these Environment variables:

| Variable | Value |
| --- | --- |
| `APPLE_TEAM_ID` | Apple Developer Team ID, for example `A7JC3DY3PU` |
| `DEVELOPER_ID_SIGNING_IDENTITY` | Exact `Developer ID Application: ...` identity |

Set these Environment secrets:

| Secret | Purpose |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Developer ID certificate and private key exported as password-protected PKCS#12, then Base64 encoded |
| `DEVELOPER_ID_P12_PASSWORD` | Password protecting the PKCS#12 export |
| `DEVELOPER_ID_PROFILE_BASE64` | Developer ID provisioning profile authorizing the production App ID and private Keychain group |
| `ASC_API_KEY_P8_BASE64` | App Store Connect Team API private key, Base64 encoded |
| `ASC_API_KEY_ID` | Team API key identifier |
| `ASC_API_ISSUER_ID` | Team API issuer UUID |

The API key must be a Team key. An Individual API key cannot authenticate
`notarytool`. Assign the lowest App Store Connect role that satisfies the
notarization operation, retain the `.p8` only in protected secret storage, and
revoke it immediately if exposure is suspected. Team keys apply across the
team's apps and cannot be limited to only Computer MCP.

GitHub stores binary inputs as Base64 text. Base64 is an encoding, not an
additional encryption layer; the GitHub Environment Secret is the protection
boundary. Never commit `.p12`, `.p8`, provisioning profiles, passwords, decoded
secrets, or environment dumps.

### Credential map for release operators

The release flow intentionally separates human account access, Git signing,
Apple code signing, notarization, and App runtime credentials. They are not one
shared password and must not be reused across boundaries.

| Credential or approval | Purpose | Storage and operator responsibility |
| --- | --- | --- |
| Mac login password / Touch ID | Local administrator and Keychain authorization only | Remains on the Mac; never add it to GitHub or a release command |
| Apple Account password and two-factor authentication | Sign in to Apple Developer and App Store Connect | Human portal access only; never store it in GitHub Actions |
| SSH signing private key | Sign the release commit and annotated `v*` tag | Keep in the local SSH agent/Keychain and retain a secure recovery copy |
| Developer ID `.p12` and its export password | Import the certificate and private key used by `codesign` | Keep a recoverable encrypted backup; GitHub stores the encoded file and password as separate `production` Secrets |
| Developer ID provisioning profile | Authorize the production App ID, entitlements, and Keychain group | GitHub `production` Secret; no per-release input |
| App Store Connect Team API `.p8`, Key ID, and Issuer ID | Authenticate `notarytool` submissions | Preserve the one-time-download private key in secure backup and GitHub `production` Secrets; revoke and replace it if exposed |
| GitHub Environment approval | Permit this trusted-master candidate run to read protected Apple credentials | A per-run reviewer decision, not a password |
| Temporary runner Keychain password | Unlock only the ephemeral CI signing Keychain | Generated randomly inside the job and destroyed with the runner; nobody records or enters it |
| GitHub `GITHUB_TOKEN` | Read repository content and candidate artifacts | Issued automatically to the job with scoped permissions; no personal access token is required |

Apple App-Specific Passwords are not used by this repository and can be revoked
without affecting the Team API key workflow. Cloudflare tunnel tokens and
OpenAI tunnel keys are App runtime credentials in the production App's Data
Protection Keychain; they are never inputs to the release workflow.

An operator needs to understand these roles, but does not need to memorize
secret values or type a release password for each tag. The normal human actions
are to merge the verified candidate PR, approve the protected `production` job,
authorize production replacement and resolve native permission prompts. The
release scripts perform checks and publish accepted bytes using the authorized
operator identity. Store the original `.p12`, its export
password, and the original `.p8` in a recovery-capable secrets manager because
GitHub does not reveal Secret values after they are saved.

## Runner credential lifecycle

The release job:

0. verifies that the protected job and its complete script closure have no
   Homebrew or ripgrep dependency; GitHub jobs use isolated filesystems, so a
   tool installed by the preceding no-secret job is intentionally unavailable;
1. decodes the PKCS#12 file, provisioning profile, and Team API key below
   `RUNNER_TEMP` with owner-only permissions;
2. creates a random-password temporary Keychain;
3. imports the Developer ID identity and configures the code-sign partition
   list without printing credential values;
4. passes the profile path explicitly to `Scripts/build-app.sh`;
5. passes the Team API key tuple explicitly to `notarytool` through
   `Scripts/package-dmg.sh`;
6. deletes the temporary Keychain and decoded files in an `always()` cleanup
   step.

The GitHub-hosted runner is ephemeral. No Apple credential is embedded in the
App, DMG, release metadata, logs, or GitHub Release. App runtime secrets remain
in Computer MCP's separate Data Protection Keychain namespace.

## Preparing a candidate

1. Use `Scripts/version.py update --version X.Y.Z --build N --kind fix --reason …`
   for a compatible fix, or the corresponding `feature`, `breaking` or
   `candidate` kind. `Version.json` is authoritative; do not edit generated
   App/CLI values independently. The build increases for revised App candidates.
2. Finalize the dated changelog and versioned release-note/readiness templates.
   Preserve the exact render tokens checked by `verify-release-readiness.sh`.
   Existing publisher approval records for legal documents remain in force;
   changed legal text requires its owning approval and updated digests.
3. Validate and merge the source into official `master`. Resolve component
   compatibility and required plugin/SDK candidates before public delivery.
4. Run the shared pipeline. The run identifier names local checkpoints, not a
   product version:

```sh
python3 Scripts/version.py check --dependencies
python3 Scripts/release.py plan --run candidate --profile candidate
python3 Scripts/release.py run --run candidate --profile candidate
python3 Scripts/release.py status --run candidate --profile candidate
```

A protected Environment wait exits with code 75 and prints its exact Actions
URL. Approve that run through GitHub, then use:

```sh
python3 Scripts/release.py resume --run candidate --profile candidate
```

Do not dispatch again merely because the local command was interrupted. The
recorded request identity locates the existing run. A failed candidate retains
its evidence. After a source correction, merge the correction and use a new run
identifier/build as appropriate, keeping the intended formal product version.

## Shared checks and checkpoints

`Scripts/release-checks.json` defines `ci`, `source`, `boundaries`, `candidate`,
`acceptance` and `publish` profiles. Ordinary CI invokes the same entry point:

```sh
python3 Scripts/release.py run --run local --profile ci
python3 Scripts/release.py resume --run local --profile ci
python3 Scripts/release.py status --run local --profile ci
```

The CI profile checks dependencies, formatting/script boundaries, complete Swift
and Validation tests, CLI/examples/localization, documentation and development
packaging. The source profile omits development distribution. `--reuse-ci` may
import authenticated GitHub evidence from the matching successful master push;
missing or mismatched evidence runs locally. A failed master CI cannot be
bypassed by protected candidate construction.

Run state, logs, immutable attempt history and outputs stay below
`.agent/releases/<run>/`. The owner-only checkpoint key lives in the Git common
directory. Do not copy an arbitrary key/receipt pair into a trusted checkout.
The status report gives stage state and duration. Each command has a deadline;
failed cases are retained, not automatically retried until green. `resume`
revalidates every input and output before reusing a passed stage.

## Installation acceptance

Finish active production tasks and authorize the specific replacement before:

```sh
python3 Scripts/install-candidate.py --run candidate --approve-cutover
python3 Scripts/release.py run --run candidate --profile acceptance
```

The installer requires an authenticated candidate checkpoint, mounts its exact
DMG read-only, checks the App's files, signature and notarization, stages it,
requests normal App termination, preserves the previous App and installs the
candidate. It checks running version/build and rolls back the App if launch
fails. It never rewrites production data, plugin receipts or credentials. An
interrupted cutover retains its journal and all identifiable App copies for
inspection. Rollback of the executable does not imply rollback of a database
migration; release review must establish data compatibility before replacement.

The acceptance script checks actual installed identity, signature, notarization,
TCC, native navigation, workspace add/duplicate-add/remove, fixed cold concurrent
requests, cancellation/reconnection and source-unavailable operation. It also
runs the installed Codex adapter with the real vendor executable and an isolated
loopback model through the packaged gateway. That fixture exercises App Server,
Exec, permission inheritance and owned-process cleanup without production
credentials or a model judging results. The installed plugin must pass doctor
and runtime-version checks; its full file inventory is bound to the receipt.

TCC denial exits 75 with the exact System Settings action. Enable the permissions
for the production App and resume. `acceptance` never replaces a running App
implicitly. Install the accepted plugin candidate through the App's supported
plugin operations before combined acceptance; preserve prior installation IDs
for rollback and never repair an identity mismatch by changing its receipt.

## Publication

With all candidate and installed acceptance checkpoints valid:

```sh
python3 Scripts/release.py publish --run candidate
```

The publisher verifies installed App/plugin bytes and each evidence file again,
creates or verifies the signed `vMAJOR.MINOR.PATCH` tag on that candidate commit,
confirms trusted master ancestry and pushes only that tag. It assembles release
records around the existing DMG, never builds or re-signs the package, and saves
an immutable asset inventory. Assets are uploaded into a draft, downloaded and
compared before the draft becomes public. Unauthenticated public downloads must
also match. `release.json` is the product delivery record used by the website.

A partial draft upload resumes only missing assets. Existing bytes must match;
public assets and formal tags cannot be replaced. Authentication/network failure
is a failed operation, not evidence that no release exists. Resume the same run
to continue its verified assembly. Do not rebuild an accepted binary to retry
publication. A post-publication defect is handled in the next appropriate version.

After publication, use the website repository's `npm run release:update -- vX.Y.Z`,
commit and deliver its generated record, then `release:verify-public` and normal
website checks. Check the deployed record against the same public delivery.

## Supported local scope

Local builds and distribution checks are available independently:

```sh
Scripts/build-app.sh
Scripts/package-dmg.sh
Scripts/verify-distribution.sh
APP_ENVIRONMENT=development Scripts/build-app.sh
```

With exactly one compatible Apple Development identity/profile, `build-app.sh`
uses stable production-Bundle testing identity. The `development` environment
uses a separate runtime namespace. `ADHOC_SIGNING=1` supports isolated bundle/DMG
structure checks without runtime Keychain access. These unnotarized artifacts
cannot substitute for the protected signed candidate.

Local names include development/validation identity and cannot claim a formal
release. `RELEASE_MODE=1` is restricted to the canonical trusted-master candidate
workflow. Local official signing/notarization remains unsupported. GitHub CI
uses `macos-26` and explicitly selects Xcode 26.4.

## Cleanup and recovery

```sh
python3 Scripts/release.py cleanup --run local
python3 Scripts/release.py cleanup --run local --apply
```

Preview is the default. Cleanup checks ownership, unchanged authenticated files
and absence of running references before removing a stage's temporary work.
Candidate, acceptance, publication and previous-App recovery records are retained.
Modified or unique files cause retention. Inspect retained failed attempts before
any separate archival or deletion; never delete active process directories.

Notarization rejection, invalid signatures, incomplete checksums, failed
source/installed checks and unknown results stop publication. Inspect the saved
stage log and original failure, repair its cause, then resume valid checkpoints.
If an Apple submission succeeded before interruption, inspect that submission
rather than assuming it needs a new product version. Changed bytes always need
new signing/notarization and affected artifact acceptance. Credentials are cleaned
up even when the protected workflow fails.
