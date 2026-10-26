import ComputerMCPCore
import ComputerMCPPermissions
import Foundation
import Testing

@testable import ComputerMCPConfiguration

@Suite struct ManagedPolicyDocumentTests {
  @Test func allLimitKindsDecodeWithConcreteOverridesAndRemoteFullAccess() throws {
    let document = try ManagedPolicyDocument.decode(
      Data(
        """
        full_access = true
        remote_full_access = false
        network = { level = "custom", hosts = ["*.example.com"], include_trusted = false }
        denied_read_locations = ["/fixture/private"]
        [permissions]
        screen = "deny"
        [projects]
        "*" = "read"
        source = "write"
        [files_and_folders]
        downloads = "read"
        [plugins]
        "*" = "deny"
        package = "use"
        [mcp_servers]
        "*" = "read"
        [execution]
        time_ms = 1000
        output_bytes = 2000
        memory_bytes = 3000
        retention_seconds = 4
        retained_output_bytes = 5000
        """.utf8))
    let local = document.resolved(for: .localCLI)
    let remote = document.resolved(for: .secureTunnel)
    #expect(local.allowsFullAccess && !remote.allowsFullAccess)
    #expect(local.permissionCeilings.state(for: .project("source")) == .granted(.write))
    #expect(local.permissionCeilings.state(for: .project("future")) == .granted(.read))
    #expect(local.permissionCeilings.state(for: .plugin("package")) == .granted(.use))
    #expect(local.permissionCeilings.state(for: .plugin("future")) == .denied)
    #expect(local.permissionCeilings.state(for: .screen) == .denied)
    #expect(local.deniedReadLocations == [try CanonicalPath("/fixture/private")])
    #expect(local.network.allows("api.example.com", trustedHosts: []))
    #expect(!local.network.allows("other.test", trustedHosts: ["other.test"]))
    #expect(local.executionLimits.timeMilliseconds == 1000)
    #expect(local.executionLimits.outputBytes == 2000)
    #expect(local.executionLimits.memoryBytes == 3000)
    #expect(local.executionLimits.retentionSeconds == 4)
    #expect(local.executionLimits.retainedOutputBytes == 5000)
  }

  @Test(arguments: [
    "unknown = false", "[permissions]\nscreen = 'access'", "[permissions]\nscreen = 'read'",
    "[projects]\np = 'all'", "[plugins]\np = 'write'", "[files_and_folders]\ndownloads = 'write'",
    "[mcp_servers]\np = 'use'", "network = 'custom'", "denied_read_locations = ['relative/path']",
    "[execution]\ntime_ms = 0", "[execution]\noutput_bytes = -1", "[execution]\nextra = 1",
  ])
  func malformedOrUnknownLimitsFailClosed(text: String) {
    #expect(throws: (any Error).self) { try ManagedPolicyDocument.decode(Data(text.utf8)) }
  }

  @Test func emptyPolicyAddsNoCeilings() throws {
    let policy = try ManagedPolicyDocument.decode(Data()).resolved(for: .secureTunnel)
    #expect(policy.permissionCeilings.entries.isEmpty)
    #expect(policy.allowsFullAccess)
    #expect(policy.network == .full)
    #expect(policy.deniedReadLocations.isEmpty)
    #expect(policy.executionLimits == .none)
  }
}
