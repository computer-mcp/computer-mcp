import ComputerMCPPermissions

/// A tool's declaration, before argument and canonical-path resolution. It is
/// catalog metadata; the gateway's profile evaluator still controls live admission.
/// Providers must declare every access independently of MCP effect annotations.
/// Project access, path operations and execution provenance are conjunctive.
package struct ToolRequirement: Codable, Equatable, Sendable {
  package enum Access: String, Codable, Sendable {
    case none, read, projectWrite, sourceProjectWrite
  }

  /// Argument selectors use dots for members and [] for all array elements.
  /// A missing optional path is either absent (inline data) or the project root.
  package struct Path: Codable, Equatable, Sendable {
    package enum Source: Codable, Equatable, Sendable {
      case argument(selector: String)
      case project
    }
    package enum RelativeBase: Codable, Equatable, Sendable {
      case project
      case deliveryScope(argument: String)
      case linkParent(argument: String)
    }
    package let source: Source
    package let relativeBase: RelativeBase
    package let operation: PathOperation
    package let defaultToProject: Bool

    package init(
      _ argument: String, _ operation: PathOperation, defaultToProject: Bool = false,
      relativeBase: RelativeBase = .project
    ) {
      self.source = .argument(selector: argument)
      self.relativeBase = relativeBase
      self.operation = operation
      self.defaultToProject = defaultToProject
    }

    private init(operation: PathOperation) {
      source = .project
      relativeBase = .project
      self.operation = operation
      defaultToProject = false
    }

    package static func project(_ operation: PathOperation) -> Self {
      Self(operation: operation)
    }
  }

  package enum Privacy: String, Codable, Sendable {
    case screen, desktopControl, localNetwork, machineInformation, unifiedLogs, skills

    var permission: Permission {
      switch self {
      case .screen: .screen
      case .desktopControl: .desktopControl
      case .localNetwork: .localNetwork
      case .machineInformation: .machineInformation
      case .unifiedLogs: .unifiedLogs
      case .skills: .skills
      }
    }
  }

  package enum Execution: Codable, Equatable, Sendable {
    case none, start, list
    case read(argument: String)
    case input(argument: String)
    case cancel(argument: String)
  }

  package enum Object: Codable, Equatable, Sendable {
    case argument(name: String)
    case registered(id: String)
    case catalog
    /// Resolve the named skill in its optional root before selecting plugin provenance.
    case skill(name: String, root: String)
  }

  package enum Target: Codable, Equatable, Sendable {
    case none
    case mcp(server: Object, access: PermissionValue)
    /// Target requirements must be resolved and checked just as a direct call.
    case forwarded(tool: String, arguments: String, server: String?)
  }

  /// Host registration provenance is resolved independently of tool-supplied input.
  package enum Contribution: Codable, Equatable, Sendable {
    case cli(registration: Object)
    case skills(selection: Object)
    case mcp(server: Object)
  }

  package let access: Access
  package var permissions: [PermissionRequirement]
  /// The permission needed when the call explicitly names a project.
  package let namedProjectAccess: PermissionValue?
  package let requiresFullAccess: Bool
  package let paths: [Path]
  package let execution: Execution
  package let target: Target
  package let networkURL: String?
  package let contribution: Contribution?

  package init(
    access: Access, permissions: [PermissionRequirement] = [],
    namedProjectAccess: PermissionValue? = nil, requiresFullAccess: Bool = false,
    paths: [Path] = [], execution: Execution = .none, target: Target = .none,
    networkURL: String? = nil, contribution: Contribution? = nil
  ) {
    self.access = access
    self.permissions = permissions
    self.namedProjectAccess = namedProjectAccess
    self.requiresFullAccess = requiresFullAccess
    self.paths = paths
    self.execution = execution
    self.target = target
    self.networkURL = networkURL
    self.contribution = contribution
  }

  package static let none = Self(access: .none)
  package static let fullAccess = Self(access: .none, requiresFullAccess: true)

  package static func privacy(_ permission: Privacy) -> Self {
    Self(access: .none, permissions: [try! PermissionRequirement(permission.permission, .access)])
  }

  package func requiringPlugin(_ id: String) throws -> Self {
    var result = self
    let permission = try PermissionRequirement(.plugin(id), .use)
    if !result.permissions.contains(permission) { result.permissions.append(permission) }
    return result
  }

  /// Downstream effect classification is supplied by the host registration and
  /// discovery policy. A remote execution needs Full access; a host action also
  /// declares its project access, regardless of the publisher's annotations.
  package static func downstream(
    serverID: String, readOnly: Bool, remoteExecution: Bool, hostAction: MCPHostServiceAction?
  ) -> Self {
    Self(
      access: hostAction == .projectProvision || hostAction == .projectRemoval
        ? .sourceProjectWrite : .none,
      namedProjectAccess: readOnly ? .read : .write,
      requiresFullAccess: remoteExecution,
      target: .mcp(server: .registered(id: serverID), access: readOnly ? .read : .all),
      contribution: .mcp(server: .registered(id: serverID)))
  }
}

/// Complete host-resolved inputs and route evidence for admission. Holding this
/// value does not grant access; a ledger authorization must still be obtained.
package struct ResolvedToolInvocation: Sendable {
  package let descriptor: CapabilityDescriptor
  package let identity: InvocationIdentity
  package let requirements: InvocationRequirements
  package let pluginOrigins: Set<PluginIdentity>

  package init(
    descriptor: CapabilityDescriptor, identity: InvocationIdentity,
    requirements: InvocationRequirements, pluginOrigins: Set<PluginIdentity>
  ) {
    self.descriptor = descriptor
    self.identity = identity
    self.requirements = requirements
    self.pluginOrigins = pluginOrigins
  }
}
