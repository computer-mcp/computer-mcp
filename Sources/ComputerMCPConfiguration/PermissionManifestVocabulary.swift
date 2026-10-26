import ComputerMCPPermissions

/// Shared spelling for profile grants and administrator ceilings.
enum PermissionManifestVocabulary {
  static let privacy: [String: Permission] = [
    "screen": .screen, "desktop-control": .desktopControl, "local-network": .localNetwork,
    "machine": .machineInformation, "unified-logs": .unifiedLogs, "skills": .skills,
  ]
  static let folders: [String: FolderCategory] = [
    "desktop": .desktop, "documents": .documents, "downloads": .downloads,
    "icloud-drive": .iCloudDrive, "network-volumes": .networkVolumes,
    "removable-volumes": .removableVolumes,
  ]
  static func validateObject(_ id: String) throws {
    guard !id.isEmpty, id.utf8.count <= 256,
      !id.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
      id == "*" || !id.contains("*")
    else {
      throw ConfigurationError.invalid("Permission object must be an identifier or *.")
    }
  }
}
