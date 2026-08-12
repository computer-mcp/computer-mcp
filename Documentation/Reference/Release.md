# Release Reference

Computer MCP is distributed outside the Mac App Store as a notarized Universal
2 DMG. A signed `vMAJOR.MINOR.PATCH` tag in the canonical GitHub repository is
the only supported source of an official release. Local builds are for
development, validation, and release rehearsal only.

## Release trust boundary

The release workflow is `.github/workflows/release-gate.yml` and has two jobs:

1. `verify` runs without Apple or publication secrets. It verifies the signed
   annotated tag restored from the canonical remote after checkout, confirms
   that its commit is reachable from `origin/master`,
   checks version and changelog alignment, rejects unfinished legal records or
   malformed release templates, and runs the complete build, test,
   documentation, metadata, and development-distribution gates.
2. `release` starts only after `verify` passes and GitHub authorizes the
   protected `production` Environment. It imports signing assets into a
   temporary runner Keychain, builds fresh arm64 and x86_64 slices, signs the
   App with Developer ID, notarizes and staples the App and DMG, runs Gatekeeper
   validation, captures both notarization receipts, renders artifact-bound
   release records, assembles checksummed assets, and creates a draft GitHub
   Release.

Publishing the draft is a GitHub-side operator action after the notarized DMG
has passed final installation and ChatGPT acceptance. A tag never causes a
local machine to package or upload an official artifact.

## One-time GitHub configuration

Create a GitHub Environment named `production`. Restrict its deployment branch
and tag policy to the canonical repository, add a required reviewer, and do not
allow untrusted branches to access it. The workflow grants `contents: write`
only to the release job; all preceding jobs retain read-only repository access.

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

## Runner credential lifecycle

The release job:

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

## Preparing a release

Before tagging:

1. update `ComputerMCPCLI.version`, `ComputerMCPCLI.build`,
   `CFBundleShortVersionString`, and `CFBundleVersion` together;
2. move all entries out of `CHANGELOG.md` `Unreleased` into a dated version
   section;
3. finalize the static content in
   `Documentation/Reference/ReleaseNotes-<version>.md` and
   `ProductionReadinessReport-<version>.md` while preserving the exact
   machine render tokens required by `verify-release-readiness.sh`;
4. obtain the publisher's explicit approval for `LICENSE`, `EULA.md`, and
   `PRIVACY.md`, record the approved file digests, and remove only the
   corresponding draft markers; any additional external legal review follows
   the publisher's release policy and is not a technical release gate;
5. merge the release commit to `master` and wait for normal CI to pass;
6. create an SSH-signed annotated tag from that exact commit and push only the
   tag.

Example after the repository version has been changed to `1.0.2`:

```sh
git switch master
git pull --ff-only origin master
git tag -s -a v1.0.2 -m "Computer MCP 1.0.2"
git verify-tag v1.0.2
git push origin v1.0.2
```

The tag is rejected unless it:

- has the exact `vMAJOR.MINOR.PATCH` form;
- is an annotated tag with a valid signature listed in
  `.github/signing-allowed-signers`;
- points to the checked-out commit;
- matches the App and CLI version;
- is reachable from `origin/master`;
- has a dated changelog section while `Unreleased` is empty.

## CI release sequence

`Scripts/release-ci.sh` is the CI-only orchestrator. It fails immediately when
run outside GitHub Actions, from a non-tag ref, in a fork, or with a personal
`notarytool` Keychain profile. In the protected release job it runs:

```text
verify-release-ref.sh
verify-release-readiness.sh
build-app.sh
package-dmg.sh
verify-distribution.sh
assemble-release-assets.sh
gh release create --draft
```

`build-app.sh` resolves the locked SwiftPM graph, compiles optimized arm64 and
x86_64 slices from scratch, combines them into a Universal 2 App, generates
version-derived notices/SBOM/dependency metadata, validates the provisioning
profile and private Keychain group, and signs the embedded CLI and App with
Hardened Runtime and a secure timestamp.

`package-dmg.sh` submits a ZIP of the signed App to Apple's notary service,
requires an `Accepted` JSON receipt, staples and validates the App ticket,
creates `Computer-MCP-<version>-universal.dmg`, submits the DMG, staples and
validates the DMG ticket, stores its accepted JSON receipt, then writes
`SHA256SUMS`.

`verify-distribution.sh` mounts the DMG read-only and verifies the checksum,
volume identity, Universal 2 slices, versions, source commit, embedded CLI
digest, Developer ID chain, timestamp, entitlements, provisioning profile,
stapled tickets, and Gatekeeper assessments. The mounted App must be byte-for-
byte identical to the current signed App for all identity-bearing files.

`assemble-release-assets.sh` binds the signed tag, commit, Team ID,
architectures, embedded CLI and DMG digests, notarization submission IDs, and
GitHub Actions run URL into the release-note and readiness templates. It then
copies the dependency manifest, CycloneDX SBOM, third-party notices, rendered
records, and notarization receipts beside the DMG and rewrites `SHA256SUMS`
over the complete upload set.
An independently generated summary-only Evidence Manifest can be required with
`INCLUDE_EVIDENCE_MANIFEST=1`; private raw evidence is never uploaded.

## Draft acceptance and publication

Download every file from the draft Release and verify:

```sh
shasum -a 256 -c SHA256SUMS
spctl --assess --type open --context context:primary-signature --verbose=2 \
  Computer-MCP-1.0.2-universal.dmg
xcrun stapler validate Computer-MCP-1.0.2-universal.dmg
```

Then install the App from the DMG and run the local, ChatGPT, permission,
Keychain, launch-at-login, and lifecycle acceptance checks against that exact
artifact. Publishing the existing draft is the operator attestation that all
23 checks passed. Do not rebuild or replace individual assets after acceptance.

## Supported local scope

Local commands exercise build and package structure without producing an
official release:

```sh
Scripts/build-app.sh
Scripts/package-dmg.sh
Scripts/verify-distribution.sh
Scripts/verify-cli-interface.sh
```

When exactly one Apple Development identity and compatible profile are
installed, `build-app.sh` uses them for stable production-Bundle testing. This
preserves the production Team ID, Bundle ID, Data Protection Keychain access
group, and TCC identity while remaining an unnotarized development artifact.

Use a separate local runtime namespace when testing migration or first-launch
behavior:

```sh
APP_ENVIRONMENT=development Scripts/build-app.sh
```

For isolated bundle/DMG structure checks without runtime Keychain access:

```sh
ADHOC_SIGNING=1 Scripts/build-app.sh
Scripts/package-dmg.sh
Scripts/verify-distribution.sh
```

Local `RELEASE_MODE=1`, local notarization, and local GitHub Release upload are
not supported release paths. Both `build-app.sh` and `package-dmg.sh` reject
official release mode outside a GitHub tag job, and CI notarization accepts only
the protected Team API key workflow.

## Failure handling

- A failed `verify` job never receives Apple or publication credentials.
- A failed `release` job runs credential cleanup and creates no GitHub Release
  unless every prior command has completed.
- A rejected notarization stops before DMG publication; inspect the submission
  log using the same Team API key outside workflow logs.
- An existing Release for the tag causes the workflow to stop instead of
  overwriting assets.
- A failed immutable tag remains an audit record. After correcting a workflow
  or source defect, increment the patch version and create a new signed tag;
  never move, replace, or force-push the failed tag.
- A transient runner or external-service failure may be retried for the same
  immutable tag only when the source and workflow need no correction and no
  draft already exists.
- If a draft exists, inspect and resolve it explicitly; the workflow will not
  mutate it on a retry.

GitHub CI uses the `macos-26` hosted image and selects Xcode 26.4 explicitly so
the root and Validation Swift 6.2 package manifests use one known toolchain.
