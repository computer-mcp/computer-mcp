# Local system-service fixture

`SystemServiceProbe.m` is an explicit local acceptance test for inherited macOS
privacy permissions and Seatbelt's two independent service switches. Run from
the package root in a graphical login session:

```sh
COMPUTER_MCP_LOCAL_SERVICE_TESTS=1 /usr/bin/swift test --filter SeatbeltSystemServiceTests
```

On its first run, the test builds and signs
`.agent/execution-environment/service-fixture/ComputerMCPTestHost.app`, with bundle ID
`local.computer-mcp.test-host` and the name Computer MCP Test Host.
Launch Services starts this app as its own privacy-responsible process. Every probe verifies that it inherits that
same responsibility. The app requires existing Screen Recording, Accessibility
and Automation authorization; the test never requests authorization or changes
TCC settings. Missing authorization fails the explicit local test rather than
passing an isolation check without a working positive control.

After building the fixture, the user may explicitly request its permissions:

```sh
open -n -W .agent/execution-environment/service-fixture/ComputerMCPTestHost.app --args request-permissions
```

This separate mode can display macOS consent dialogs or open privacy settings;
the user chooses whether to grant access. The test never invokes this mode.
Grant access to this fixture app, then rerun the test command above. Subsequent
runs reuse the app without compiling or signing when the source, compiler/SDK,
build options, signing identity, relevant build environment, Info.plist and
entitlements match the saved fingerprint. Reuse also requires unchanged executable bytes,
matching Info.plist and successful strict signature verification. The cache is
created automatically; a clean checkout does not require any `.agent` files.

Set `COMPUTER_MCP_TEST_SIGNING_IDENTITY` to a local certificate signing identity
to keep macOS privacy grants across rebuilds: the designated requirement names
that identity. Without this variable the fixture uses ad-hoc signing, whose
privacy grants bind to one build. The signing identity is part of the build
fingerprint; changing it rebuilds and signs the app.

Changed inputs or an altered app trigger a rebuild with an explicit message
that its privacy permissions may need authorization again. `build.json` stores
the input and signed-executable fingerprints alongside the app.

The fixture owns the only window, Accessibility elements and Apple event target
it tests. It captures that window through ScreenCaptureKit, the exported
`CGWindowListCreateImage` symbol when present, and `screencapture -l`. The first
two captures stay in memory; the CLI capture is written to the fixture's private
temporary directory, checked and removed. The AX probe reads only the fixture
window's synthetic title. The Apple event asks the fixture to return a synthetic
token. It does not interact with the user's apps or content.

Each service has an unsandboxed positive control followed by all four combinations
of Screen capture and Accessibility. Apple events must fail in every sandboxed
combination. Deny-default blocks both `appleevent-send` and the
`com.apple.coreservices.appleevents` lookup. Even a profile allowance cannot
satisfy macOS's target-scoped sender entitlement requirement; arbitrary sandboxed
programs lack that entitlement (`errAEPrivilegeError`, -10004).

All probes have a deadline. `results.json` and `probe.log` under the fixture directory retain numeric outcomes and diagnostic errors. Exit
77 means the permission preflight is unavailable (or the legacy CoreGraphics
symbol is absent); exit 78 means the probe did not inherit the fixture's privacy
responsibility. A failed preflight leaves its dependent matrix untested.

The default test run skips this graphical, permission-dependent suite. The
separate `SeatbeltBoundaryTests.serviceRulesAreEnforcedIndependently` suite runs
all four combinations using `sandbox_check` without TCC grants. Those policy
checks supplement, and cannot replace, the local service acceptance test.
