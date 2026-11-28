import Foundation

/// Saved standing authority displayed for local owner confirmation after recovery.
/// This snapshot never carries active requests, consents, permits or executions.
package struct SuspendedPermissionAuthority: Equatable, Sendable, Codable {
  package let permissions: [Principal: Permissions]
  package let ownerPolicies: [Principal: PolicyAvailability]
  package let sandboxSettings: ProjectSandboxSettings
}

/// The runtime must stop every execution belonging to another epoch, including
/// processes absent from a restored database, before acknowledging this handoff.
/// Known IDs supplement that epoch-wide sweep; they do not limit it.
package struct AuthorizationEpochRecovery: Sendable, Codable, Equatable {
  package let epochID: UUID
  package let executionsToTerminate: Set<UUID>
}
