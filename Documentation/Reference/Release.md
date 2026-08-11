# Release Reference

Computer MCP is distributed as a manually updated, notarized DMG containing
`Computer MCP.app`. This release does not use Sparkle or the App Store.

## Prerequisites

- macOS 14 or newer
- Xcode command-line tools with Swift 6.2 or newer
- Developer ID Application signing identity
- a macOS provisioning profile that authorizes the production App ID, signing
  certificate, and private Keychain access group
- Apple notarization credentials stored as a `notarytool` Keychain profile

Store notarization credentials once:

```sh
xcrun notarytool store-credentials computer-mcp-notary \
  --apple-id <apple-id> \
  --team-id <team-id> \
  --password <app-specific-password>
```

Do not place credentials in the repository or shell history.

## Development Artifact

```sh
Scripts/build-app.sh
Scripts/package-dmg.sh
Scripts/verify-distribution.sh
Scripts/verify-cli-interface.sh
```

When exactly one valid Apple Development identity is installed,
`build-app.sh` selects it automatically and embeds the single compatible
provisioning profile. This authorizes the production App ID and private Data
Protection Keychain group. Apple Development and Developer ID builds with the
same Team ID and production Bundle ID share that group even though their
certificates differ; they do not use legacy per-binary Keychain ACL prompts.
If more than one identity or compatible profile is installed, select both
inputs explicitly:

```sh
SIGNING_IDENTITY="Apple Development: Example (TEAMID)" \
PROVISIONING_PROFILE=/absolute/path/to/profile.provisionprofile \
Scripts/build-app.sh
```

The normal local command intentionally builds the production environment so
it exercises the same Bundle ID, Application Support directory, Keychain
service, and access group as Release. To run a completely separate local
environment, opt in explicitly:

```sh
APP_ENVIRONMENT=development Scripts/build-app.sh
```

That creates `dist/Computer MCP Development.app` with Bundle ID
`com.showxu.computer-mcp.development` and separate runtime state and secrets.

CI or isolated packaging tests can explicitly request ad-hoc signing:

```sh
ADHOC_SIGNING=1 Scripts/build-app.sh
```

An ad-hoc artifact has no provisioned Team/private access group. Its App
control plane intentionally fails closed before reading secrets; it is useful
only for build, bundle, and DMG structure validation. It is not a local runtime
substitute and has no legacy Keychain fallback.

## Release Artifact

```sh
export SIGNING_IDENTITY="Developer ID Application: Example (TEAMID)"
export EXPECTED_TEAM_ID="TEAMID"
export NOTARY_KEYCHAIN_PROFILE="computer-mcp-notary"
export PROVISIONING_PROFILE="/absolute/path/to/developer-id.provisionprofile"
export RELEASE_MODE=1

Scripts/build-app.sh
Scripts/package-dmg.sh
Scripts/verify-distribution.sh
```

`build-app.sh`:

1. resolves the locked dependency graph once;
2. builds optimized `ComputerMCPApp` and `computer-mcp` independently for
   `arm64` and `x86_64` with Xcode's Swift and `--build-system native`;
3. combines the two architecture slices into `dist/Computer MCP.app`;
4. signs the embedded CLI;
5. rejects expired or ambiguous provisioning profiles and verifies that the
   selected profile authorizes the signing certificate, production App ID,
   Team ID, and exact private Keychain access group;
6. embeds the profile and signs the App with its exact application identifier
   and Keychain group;
7. writes the source commit, Team ID, architectures, and signed embedded CLI
   SHA-256 into the signed bundle;
8. verifies both slices, the deep signature, environment, and signed
   entitlements.

`package-dmg.sh`:

1. submits the signed App with `notarytool --wait`, staples it, and validates
   the App ticket;
2. creates an APFS `dist/Computer-MCP-1.0.0-universal.dmg` with `diskutil image`
   and includes the App, source-visible
   terms, EULA, privacy policy, deterministic notices, dependency manifest,
   and CycloneDX SBOM;
3. submits the DMG with `notarytool --wait`;
4. staples and validates the DMG ticket;
5. writes `dist/SHA256SUMS` only after stapling.

`verify-distribution.sh` mounts the DMG read-only, verifies both executables,
Info.plist, code signatures, CLI/App version equality, embedded CLI SHA256, and
Gatekeeper assessment. A provisioned artifact must contain an unexpired profile
that authorizes its Team, App ID, and single private Keychain group; an ad-hoc
artifact must not contain a profile. The verifier also compares the mounted
App's Info.plist, signed executables, provisioning profile, and code-signature
resources byte-for-byte with the current `dist/Computer MCP.app`, so an older
DMG cannot pass after the App is rebuilt.

After final 23/23 acceptance, use the independent Validation CLI's
`report release-manifest` command to create the public, summary-only
`Computer-MCP-1.0.0-EvidenceManifest.json`. It fails closed unless the readiness
report is ready, every referenced Evidence Bundle verifies against the same
App/CLI digests, and the local, ChatGPT, Cloudflare, Apple Silicon, and Rosetta
verification records are all supplied. Raw evidence and credentials remain in
the private checksummed archive.

```sh
/usr/bin/swift run --package-path Tools/Validation --build-system native \
  computer-mcp-validate report release-manifest \
  --app-bundle "dist/Computer MCP.app" \
  --dmg dist/Computer-MCP-1.0.0-universal.dmg \
  --readiness-report <external-readiness-report.json> \
  --evidence-archive <private-evidence-archive.tar.gz> \
  --evidence-bundle <validation-evidence-bundle.json> \
  --verification-record journey.local=<redacted-local-record.json> \
  --verification-record journey.chatgpt=<redacted-chatgpt-record.json> \
  --verification-record journey.cloudflare=<redacted-cloudflare-record.json> \
  --verification-record \
    platform.apple_silicon_native=<redacted-apple-silicon-record.json> \
  --verification-record \
    platform.rosetta_x86_64=<redacted-rosetta-record.json> \
  --tag v1.0.0 \
  --output dist/Computer-MCP-1.0.0-EvidenceManifest.json
```

Repeat `--evidence-bundle` for every bundle consumed by the ready report. The
generator compares that exact set with the report and rejects development or
mixed-artifact evidence.

Before generating the public manifest, seal the external redacted evidence
directory with `Scripts/package-validation-evidence.sh`. The packager validates
all canonical records and writes the private archive's `.sha256` receipt; it
will not accept a source or destination inside the repository.

After creating and verifying the signed annotated Tag, assemble the exact
GitHub Release upload set:

```sh
EXPECTED_TEAM_ID=<team-id> Scripts/assemble-release-assets.sh
```

The assembler reruns the notarized distribution gate, verifies the signed Tag
and Evidence Manifest, rejects draft legal text and pending release records,
copies the SBOM, dependency manifest, notices, release notes, and readiness
report beside the DMG, and rewrites `SHA256SUMS` to cover all seven public
assets. It never copies the private raw evidence archive into `dist`.

## Distribution Validation

Before publishing:

```sh
codesign -d --verbose=4 "dist/Computer MCP.app"
codesign -d --entitlements :- "dist/Computer MCP.app"
codesign --verify --deep --strict --verbose=2 "dist/Computer MCP.app"
spctl --assess --type execute --verbose=2 "dist/Computer MCP.app"
xcrun stapler validate "dist/Computer-MCP-1.0.0-universal.dmg"
```

Then:

1. mount the DMG;
2. copy the App to `/Applications`;
3. cold-start it from Finder;
4. confirm App-owned workspaces render;
5. add a temporary workspace;
6. install the CLI link and verify `app status` and `workspace list` use the
   same App state;
7. quit from the menu bar;
8. confirm the private socket and owned Tunnel process stop;
9. reopen and verify persisted state and launch-at-login status.

## Versioning

Keep these aligned:

- `ComputerMCPCLI.version`
- `ComputerMCPCLI.build`
- `CFBundleShortVersionString`
- `CFBundleVersion`
- release notes and artifact name

`computer-mcp --version` prints both values as `<version> (<build>)`. The App
assembly script fails before compiling if either source value differs from the
matching `Info.plist` value, and distribution verification compares the same
pair against the embedded CLI.

The embedded CLI hash stored in `ComputerMCPEmbeddedCLIHash` must match the
signed resource exactly.

Provider versions are discovered at runtime and are not the App version.

## External Prerequisites

The release does not bundle:

- OpenAI `tunnel-client`;
- Codex;
- `apple-cli-mcp`;
- browser providers.

GitHub publication requires `swift-codex` to remain the exact public remote
dependency `0.1.1`. `Scripts/verify-swift-codex-release-gate.sh` blocks CI if
the package regresses to a local path, branch, revision, or different version.

GitHub CI uses the `macos-26` hosted image so its default Xcode supplies the
Swift 6.2-or-newer toolchain required by both package manifests.

The App must remain useful without them and show deterministic Doctor guidance.
Notarization cannot be claimed when signing identity or Apple credentials are
unavailable; in that case label the artifact as a development DMG.
