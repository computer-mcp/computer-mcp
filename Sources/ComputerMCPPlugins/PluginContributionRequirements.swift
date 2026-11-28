import ComputerMCPCore
import ComputerMCPPermissions

/// Immutable reviewed inputs supplied by the host, never by a running provider.
package struct PluginContributionRequirements: Codable, Equatable, Sendable {
  package let sourceDigest: String
  package let componentID: String
  package let declarations: PluginPermissionDeclarations

  package init(
    sourceDigest: String, declarations: PluginPermissionDeclarations, componentID: String
  ) throws {
    guard sourceDigest.count == 64, !componentID.isEmpty else {
      throw PluginManifestError.invalid("A reviewed contribution requires a package identity.")
    }
    self.sourceDigest = sourceDigest
    self.componentID = componentID
    self.declarations = declarations
  }

  package var declarationDigest: String { try! declarations.digest() }
  package var contribution: PluginPermissionDeclarations.Contribution? {
    declarations.mcp[componentID]
  }
  package var approvalDigest: String { sourceDigest + ":" + declarationDigest }

  package func requirements(for tool: String) -> PluginToolRequirements? {
    contribution?.toolRequirements[tool] ?? contribution?.requirements
  }

  package func applying(to minimum: ToolRequirement, tool: String) -> ToolRequirement {
    guard let declared = requirements(for: tool) else { return minimum }
    return minimum.adding(access: declared.access, permissions: declared.callerPermissions)
  }
}

extension PluginToolRequirements {
  package var access: ToolRequirement.Access {
    switch project {
    case .none: .none
    case .read: .read
    case .write: .projectWrite
    }
  }

  package var callerPermissions: [PermissionRequirement] {
    permissions.map { value in
      let permission: Permission
      switch value {
      case .screen: permission = .screen
      case .desktopControl: permission = .desktopControl
      case .localNetwork: permission = .localNetwork
      case .machine: permission = .machineInformation
      case .unifiedLogs: permission = .unifiedLogs
      case .skills: permission = .skills
      }
      return try! PermissionRequirement(permission, .access)
    }
      + filesAndFolders.map { category in
        let folder: FolderCategory
        switch category {
        case .desktop: folder = .desktop
        case .documents: folder = .documents
        case .downloads: folder = .downloads
        case .iCloudDrive: folder = .iCloudDrive
        case .networkVolumes: folder = .networkVolumes
        case .removableVolumes: folder = .removableVolumes
        }
        return try! PermissionRequirement(.filesAndFolders(folder), .read)
      }
  }
}

extension PluginContributionOrigin {
  /// Catalogs and invocation routing use the same reviewed caller conditions.
  package func applyingRequirements(to descriptor: CapabilityDescriptor) throws
    -> CapabilityDescriptor
  {
    guard let reference = descriptor.mcpReference, let reviewed = reviewedRequirements else {
      return descriptor
    }
    guard reviewed.componentID == componentID else {
      throw PluginManifestError.invalid(
        "The reviewed contribution identity does not match its registration.")
    }
    var descriptor = descriptor
    descriptor.requirement = reviewed.applying(to: descriptor.requirement, tool: reference.toolName)
    if let requirement = reviewed.requirements(for: reference.toolName),
      requirement.project != .none
    {
      descriptor.projectRequirement = .required
    }
    return descriptor
  }
}
