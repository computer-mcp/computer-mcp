import AppKit
import ComputerMCPControlPlane
import ComputerMCPCore
import ComputerMCPGateway
import ComputerMCPPermissions
import ComputerMCPPlugins
import Foundation

/// Presents the gateway's permission store in Privacy & Security and writes the owner's
/// changes back through the revision-checked control plane.
@MainActor
final class LivePrivacySecurityService: PrivacySecurityService {
  private let controlPlane: any AppControlPlane
  private var systemPermissions: [PrivacySystemPermission.Kind: PermissionSummary] = [:]
  var requestPermission: ((PermissionSummary) -> Void)?

  init(controlPlane: any AppControlPlane) {
    self.controlPlane = controlPlane
  }

  func ownerPolicyEditorService() async throws -> OwnerPolicyEditorService {
    try await controlPlane.ownerPolicyEditorService()
  }

  func privacySnapshot() async throws -> PrivacySnapshot {
    let inventory = try await controlPlane.fetchPrivacyPermissionInventory()
    let view = inventory.permissions
    let names = inventory.names
    let system = (try? await controlPlane.fetchPermissions()) ?? []
    systemPermissions = Dictionary(
      uniqueKeysWithValues: system.compactMap { summary in
        Self.systemPermission(summary).map { ($0.kind, summary) }
      })
    let paths = Dictionary(
      uniqueKeysWithValues:
        inventory.projects.map { ($0.id, $0.rootPath) })
    let profiles = Dictionary(uniqueKeysWithValues: view.profiles.map { ($0.id, $0) })
    let clients = view.profiles.map { profile in
      var principal = Self.principal(profile)
      principal.fullAccessLimitSources = Self.fullAccessSources(
        view.profileLimits[profile.id] ?? [])
      principal.clientAvailability =
        view.suspended || view.unconfirmedProfileIDs.contains(profile.id)
        ? .restoreReview : .available
      return principal
    }
    let verified = view.subjects.map { subject in
      let identity = Self.invocationPrincipal(subject.principal, names: names)
      let profile = profiles[subject.profileID]
      return PrivacyPrincipal(
        id: identity.id, name: identity.name,
        kind: .client(connection: Self.connectionName(subject.caller)),
        execution: profile?.fullAccess == true ? .fullAccessAllowed : .sandbox,
        fullAccessLimitSources: Self.fullAccessSources([subject.limits]),
        clientAvailability: subject.availability, sharedProfileID: subject.profileID,
        effectiveExecution: subject.effectiveMode.map {
          $0 == .sandbox ? .sandbox : .fullAccessAllowed
        })
    }
    let providers = inventory.providers.map { Self.principal($0, names: names) }
    let principals = clients + verified + providers
    let profileGrants = zip(clients, view.profiles).flatMap { principal, profile in
      Self.grants(
        profile, names: names, paths: paths, limits: view.profileLimits[profile.id] ?? [],
        trustedHosts: view.trustedHosts, sourceProjects: view.sourceProjects,
        isAvailable: principal.clientAvailability == .available)
    }
    let subjectGrants = zip(verified, view.subjects).flatMap { principal, subject in
      guard let profile = profiles[subject.profileID] else { return [PrivacyGrant]() }
      return Self.grants(
        profile, names: names, paths: paths, limits: [subject.limits],
        trustedHosts: view.trustedHosts, sourceProjects: view.sourceProjects,
        isAvailable: subject.availability == .available, principalID: principal.id)
    }
    let providerGrants = zip(providers, inventory.providers).flatMap { principal, provider in
      Self.grants(
        provider, principalID: principal.id, names: names, paths: paths,
        trustedHosts: view.trustedHosts, sourceProjects: view.sourceProjects)
    }
    return PrivacySnapshot(
      revision: view.revision,
      epoch: view.epoch, reviewedProfiles: view.profiles,
      reviewedProviders: Dictionary(
        uniqueKeysWithValues: zip(providers.map(\.id), inventory.providers)),
      clientSubjects: Dictionary(uniqueKeysWithValues: zip(verified.map(\.id), view.subjects)),
      sourceProjects: view.sourceProjects,
      requests: view.requests.compactMap {
        Self.request(
          $0, principals: principals, names: names, paths: paths, subjects: view.subjects)
      },
      principals: principals,
      grants: profileGrants + subjectGrants + providerGrants,
      managedSources: view.sources.map(Self.source),
      systemPermissions: system.compactMap(Self.systemPermission),
      suspendedForReview: view.suspended || !view.unconfirmedProfileIDs.isEmpty)
  }

  func answer(request id: String, with answer: PrivacyRequestAnswer, reviewed: PrivacySnapshot)
    async throws
  {
    guard let uuid = UUID(uuidString: id) else { return }
    let answer: PermissionAnswer? =
      switch answer {
      case .onlyThisTime: .onlyThisTime
      case .always: .always
      case .dontAllow: nil
      }
    do {
      try await controlPlane.answerPermissionRequest(
        id: uuid, answer: answer, expectedRevision: reviewed.revision)
    } catch GatewayPermissionError.revisionConflict { throw Self.changedPermissions() }
  }

  func setGrant(_ grant: PrivacyGrant, reviewed: PrivacySnapshot) async throws {
    let projectID = grant.permission == .projects ? grant.object?.id : nil
    try Self.requireEditableProject(projectID, reviewed: reviewed)
    guard let permission = Self.permission(grant) else { return }
    func apply(_ permissions: inout Permissions) throws {
      if grant.choice == .inherited {
        permissions.removeEntry(for: permission)
      } else {
        try permissions.set(Self.state(grant.value), for: permission)
      }
    }
    if let provider = reviewed.reviewedProviders[grant.principalID] {
      try await editProvider(provider) { permissions, _ in try apply(&permissions) }
    } else {
      try await edit(grant.principalID, projectID: projectID, reviewed: reviewed) {
        try apply(&$0.permissions)
      }
    }
  }

  func revokeAll(principalID: String, reviewed: PrivacySnapshot) async throws {
    if let provider = reviewed.reviewedProviders[principalID] {
      do {
        try await controlPlane.revokeProviderPermissions(reviewed: provider)
      } catch GatewayPermissionError.revisionConflict { throw Self.changedPermissions() }
      return
    }
    try await edit(principalID, reviewed: reviewed) { profile in
      profile.permissions = Permissions()
      profile.projectNetworks = profile.projectNetworks.mapValues { _ in .none }
      profile.fullAccess = false
    }
  }

  func setExecution(
    principalID: String, to execution: PrivacyPrincipal.Execution, reviewed: PrivacySnapshot
  ) async throws {
    if let provider = reviewed.reviewedProviders[principalID] {
      guard provider.availability == .active, let approval = provider.approval else {
        throw Self.changedPermissions()
      }
      try await approveProvider(
        provider, permissions: approval.permissions, execution: execution,
        sandboxSettings: approval.sandboxSettings ?? .init())
      return
    }
    try await edit(principalID, reviewed: reviewed) { profile in
      profile.fullAccess = execution != .sandbox
    }
  }

  func confirmRestoredPermissions(reviewed: PrivacySnapshot) async throws {
    guard let epoch = reviewed.epoch else { throw Self.changedPermissions() }
    do {
      try await controlPlane.confirmPermissionAuthority(
        epoch: epoch, expectedRevision: reviewed.revision, profiles: reviewed.reviewedProfiles)
    } catch GatewayPermissionError.revisionConflict { throw Self.changedPermissions() }
  }

  func openSystemSettings(for permission: PrivacySystemPermission.Kind) {
    guard let summary = systemPermissions[permission] else { return }
    requestPermission?(summary)
  }

  func setNetwork(
    _ grant: PrivacyGrant, to network: PrivacyNetworkAccess, reviewed: PrivacySnapshot
  ) async throws {
    guard grant.permission == .projects, let projectID = grant.object?.id else { return }
    try Self.requireEditableProject(projectID, reviewed: reviewed)
    let access = try network.validated().permissionAccess
    if let provider = reviewed.reviewedProviders[grant.principalID] {
      try await editProvider(provider) { _, settings in
        if projectID == "*" {
          settings.defaults.network = access
        } else {
          settings.projects[projectID, default: .init()].network =
            access
        }
      }
    } else {
      try await edit(grant.principalID, projectID: projectID, reviewed: reviewed) { profile in
        profile.projectNetworks[projectID] = access
      }
    }
  }

  func approveProvider(
    _ provider: ProviderPermissionOptions, permissions: Permissions,
    execution: PrivacyPrincipal.Execution, sandboxSettings: ProviderSandboxSettings
  ) async throws {
    do {
      try await controlPlane.saveProviderPermissions(
        reviewed: provider, permissions: permissions, fullAccess: execution == .fullAccessAllowed,
        sandboxSettings: sandboxSettings, editingApproval: false)
    } catch GatewayPermissionError.revisionConflict { throw Self.changedPermissions() }
  }

  private func editProvider(
    _ provider: ProviderPermissionOptions,
    change: (inout Permissions, inout ProviderSandboxSettings) throws -> Void
  ) async throws {
    guard provider.availability == .active, let approval = provider.approval else {
      throw Self.changedPermissions()
    }
    var permissions = approval.permissions
    var settings = approval.sandboxSettings ?? .init()
    try change(&permissions, &settings)
    do {
      try await controlPlane.saveProviderPermissions(
        reviewed: provider, permissions: permissions, fullAccess: approval.fullAccessConsent != nil,
        sandboxSettings: settings, editingApproval: true)
    } catch GatewayPermissionError.revisionConflict { throw Self.changedPermissions() }
  }

  private static func requireEditableProject(_ id: String?, reviewed: PrivacySnapshot) throws {
    guard let id, let source = reviewed.sourceProjects[id], source != id else { return }
    throw AppControlPlaneError.unavailable(
      "Edit permissions on the source project to change access for its worktrees.")
  }

  /// Saves one profile against the choices it was read with, so a concurrent change fails
  /// instead of being overwritten.
  private func edit(
    _ principalID: String, projectID: String? = nil, reviewed: PrivacySnapshot,
    _ change: (inout ProfileGrant) throws -> Void
  )
    async throws
  {
    if reviewed.principals.contains(where: { $0.id == principalID && $0.sharedProfileID != nil }) {
      throw AppControlPlaneError.unavailable(
        "Edit the shared client profile to change its permissions.")
    }
    guard let id = GatewayProfileID(rawValue: principalID) else { throw Self.changedPermissions() }
    let options = try await controlPlane.fetchProfilePermissionOptions(id: id)
    guard options.permissionRevision == reviewed.revision,
      options.permissionEpoch == reviewed.epoch,
      options.grant.authorizationRevision == reviewed.profileRevisions[principalID],
      projectID.map({ options.sourceProjects[$0] == reviewed.sourceProjects[$0] }) ?? true
    else { throw Self.changedPermissions() }
    var profile = options.grant
    try change(&profile)
    do {
      try await controlPlane.saveProfilePermissions(profile, reviewed: options)
    } catch GatewayPermissionError.revisionConflict { throw Self.changedPermissions() }
  }

  private static func principal(_ profile: ProfileGrant) -> PrivacyPrincipal {
    let connection =
      if profile.allowedCallers.contains(.secureTunnel) {
        "Secure Tunnel"
      } else if profile.allowedCallers.contains(.cloudflareTunnel) {
        "Cloudflare Tunnel"
      } else {
        "This Mac"
      }
    return PrivacyPrincipal(
      id: profile.id.rawValue, name: AppLocalization.string(profile.id.displayName),
      kind: .client(connection: connection),
      execution: profile.fullAccess ? .fullAccessAllowed : .sandbox)
  }

  static func principal(_ provider: ProviderPermissionOptions, names: PermissionObjectNames)
    -> PrivacyPrincipal
  {
    var principal = invocationPrincipal(.plugin(provider.identity), names: names)
    if case .package = provider.identity {
      principal = PrivacyPrincipal(
        id: principal.id, name: provider.name, kind: .plugin(version: provider.version ?? ""),
        execution: .sandbox)
    }
    principal.execution =
      provider.approval?.fullAccessConsent == nil ? .sandbox : .fullAccessAllowed
    principal.effectiveExecution = provider.effectiveMode.map {
      $0 == .sandbox ? .sandbox : .fullAccessAllowed
    }
    principal.providerAvailability = provider.availability
    principal.fullAccessLimitSources = fullAccessSources([provider.limits])
    return principal
  }

  static func changedPermissions() -> AppControlPlaneError {
    .unavailable("The permissions changed while you were editing. Review them and try again.")
  }

  static func grants(
    _ profile: ProfileGrant, names: PermissionObjectNames,
    paths: [String: String] = [:], limits: [ManagedLimits] = [], trustedHosts: Set<String> = [],
    sourceProjects: [String: String] = [:], isAvailable: Bool = true, principalID: String? = nil
  ) -> [PrivacyGrant] {
    grants(
      principalID: principalID ?? profile.id.rawValue, saved: profile.permissions,
      network: profile.projectNetworks, names: names, paths: paths, limits: limits,
      trustedHosts: trustedHosts, sourceProjects: sourceProjects, isAvailable: isAvailable)
  }

  static func grants(
    _ provider: ProviderPermissionOptions, principalID: String, names: PermissionObjectNames,
    paths: [String: String], trustedHosts: Set<String>, sourceProjects: [String: String] = [:]
  ) -> [PrivacyGrant] {
    let settings = provider.approval?.sandboxSettings
    var networks = settings?.projects.compactMapValues(\.network) ?? [:]
    networks["*"] = settings?.defaults.network
    return grants(
      principalID: principalID, saved: provider.approval?.permissions ?? .init(),
      network: networks, names: names, paths: paths, limits: [provider.limits],
      trustedHosts: trustedHosts, sourceProjects: sourceProjects,
      isAvailable: provider.effectiveMode != nil, declarations: provider.declarations
    ).map { grant in
      var grant = grant
      if grant.permission == .projects {
        if provider.effectiveMode == .sandbox, grant.object?.isRegistered == true,
          let settings, let id = grant.sourceProjectID
        {
          let selected = settings.settings(sourceProjectID: id)
          grant.effectiveNetwork = network(
            selected.effectiveNetwork(limits: provider.limits, trustedHosts: trustedHosts))
        } else {
          grant.effectiveNetwork = nil
        }
      }
      return grant
    }
  }

  private static func grants(
    principalID: String, saved: Permissions, network networks: [String: NetworkAccess],
    names: PermissionObjectNames, paths: [String: String], limits: [ManagedLimits],
    trustedHosts: Set<String>, sourceProjects: [String: String], isAvailable: Bool,
    declarations: PluginPermissionDeclarations? = nil
  ) -> [PrivacyGrant] {
    var permissions = Set(saved.entries.keys)
    permissions.formUnion([
      .screen, .desktopControl, .localNetwork, .machineInformation, .unifiedLogs, .skills,
    ])
    permissions.formUnion(FolderCategory.allCases.map(Permission.filesAndFolders))
    permissions.formUnion(
      (Array(names.projects.keys) + Array(networks.keys) + ["*"]).map(
        Permission.project))
    permissions.formUnion((Array(names.plugins.keys) + ["*"]).map(Permission.plugin))
    permissions.formUnion((Array(names.mcpServers.keys) + ["*"]).map(Permission.mcpServer))
    return permissions.compactMap { listedPermission in
      guard let (kind, original) = classify(listedPermission, names: names) else { return nil }
      let sourceProjectID: String?
      let permission: Permission
      if case .project(let id) = listedPermission {
        let source = sourceProjects[id] ?? id
        sourceProjectID = source
        permission = .project(source)
      } else {
        sourceProjectID = nil
        permission = listedPermission
      }
      let object = original.map { object in
        PrivacyObject(
          id: object.id, name: object.name,
          detail: kind == .projects ? paths[object.id] : object.detail,
          isRegistered: kind != .projects || object.id == "*" || names.projects[object.id] != nil)
      }
      var grant = PrivacyGrant(
        principalID: principalID, permission: kind,
        object: object, value: value(saved.state(for: permission)),
        sourceProjectID: sourceProjectID, isStored: saved.entries[permission] != nil)
      if grant.inheritsProjectAuthority {
        grant.inheritedValue = grant.value
        grant.isStored = false
      } else if [.projects, .plugins, .mcpServers].contains(kind), object?.id != "*" {
        var inherited = saved
        inherited.removeEntry(for: permission)
        grant.inheritedValue = value(inherited.state(for: permission))
      }
      grant.trustedHosts = trustedHosts
      let canonical = object?.detail.flatMap { try? CanonicalPath($0) }
      @MainActor func permitted(
        _ level: PrivacyGrantValue.Level, by ceiling: ManagedLimits, editingFallback: Bool
      ) -> Bool {
        guard case .granted(let value) = state(.granted(level)) else { return false }
        if object?.id == "*" {
          if editingFallback {
            var proposed = saved
            try? proposed.set(.granted(value), for: permission)
            return ceiling.restrictingSources(forFallback: permission, in: proposed).isEmpty
          }
          return ceiling.restrictingSources(forDefault: permission, value: value).isEmpty
        }
        guard let requirement = try? PermissionRequirement(permission, value) else { return false }
        return ceiling.restrictingSources(for: requirement).isEmpty
          && (canonical.map { ceiling.denying($0).isEmpty } ?? true)
      }
      let declaredLevels = kind.grantedValues.filter { level in
        guard let declarations, permission != .machineInformation, permission != .skills
        else { return true }
        guard case .granted(let value) = state(.granted(level)) else { return false }
        return declarations.permissions.contains {
          $0.matches(permission)
            && ComputerMCPPermissions.PermissionState.granted($0.value).allows(value)
        }
      }
      grant.allowedLevels = declaredLevels.filter { level in
        limits.allSatisfy { permitted(level, by: $0, editingFallback: true) }
      }
      if isAvailable, object?.isRegistered != false {
        let levels = declaredLevels.filter { level in
          limits.allSatisfy { permitted(level, by: $0, editingFallback: false) }
        }
        switch grant.value {
        case .ask:
          grant.effectiveValue = levels.isEmpty ? .denied : .ask
        case .denied:
          grant.effectiveValue = .denied
        case .granted(let maximum):
          let requested = state(.granted(maximum))
          grant.effectiveValue =
            levels.last { level in
              guard case .granted(let value) = state(.granted(level)) else { return false }
              return requested.allows(value)
            }.map(PrivacyGrantValue.granted) ?? (levels.isEmpty ? .denied : .ask)
        }
      }
      for limit in limits {
        for (source, availability) in limit.sources.sorted(by: { $0.key.rawValue < $1.key.rawValue }
        ) {
          let name = sourceName(source)
          let sourceLimits = ManagedLimits(sources: [source: availability])
          let levels = kind.grantedValues.filter {
            permitted($0, by: sourceLimits, editingFallback: true)
          }
          if case .unreadable = availability {
            grant.limitNotices.append(.init(source: name, effect: .unreadable))
          } else if levels != kind.grantedValues {
            grant.limitNotices.append(.init(source: name, effect: .permission(levels.last)))
          }
          guard case .project = permission else { continue }
          let cap: PrivacyNetworkAccess
          switch availability {
          case .absent: continue
          case .unreadable:
            cap = .none
            grant.networkLimitNotices.append(.init(source: name, effect: .unreadable))
          case .available(let policy):
            cap = network(policy.network.configuration)
            if cap != .full {
              grant.networkLimitNotices.append(.init(source: name, effect: .network(cap)))
            }
          }
          if cap != .full { grant.networkLimits.append(cap) }
        }
      }
      grant.limitNotices = Array(Set(grant.limitNotices)).sorted { $0.source < $1.source }
      grant.networkLimitNotices = Array(Set(grant.networkLimitNotices)).sorted {
        $0.source < $1.source
      }
      if case .project(let id) = permission {
        let selected = networks[id] ?? networks["*"] ?? .none
        grant.network = Self.network(selected.configuration)
        grant.isNetworkStored = !grant.inheritsProjectAuthority && networks[id] != nil
        if isAvailable, object?.isRegistered != false {
          let effective = limits.reduce(selected) { value, limit in
            Self.network(limit.network(applying: value, trustedHosts: trustedHosts))
              .permissionAccess
          }
          grant.effectiveNetwork = Self.network(effective.configuration)
        }
      }
      return grant
    }.sorted { order($0) < order($1) }
  }

  /// Wildcard rows first, folder categories in Finder's order, other objects by name.
  private static func order(_ grant: PrivacyGrant) -> (String, Int, Int, String) {
    let id = grant.object?.id ?? ""
    let category = FolderCategory.allCases.firstIndex { $0.rawValue == id } ?? 0
    return (grant.permission.rawValue, id == "*" ? 0 : 1, category, grant.object?.name ?? "")
  }

  static func fullAccessSources(_ limits: [ManagedLimits]) -> [String] {
    let sources = limits.reduce(into: Set<PolicySource>()) { sources, limit in
      for (source, availability) in limit.sources {
        switch availability {
        case .unreadable: sources.insert(source)
        case .available(let policy) where !policy.allowsFullAccess: sources.insert(source)
        default: break
        }
      }
    }
    return sourceNames(sources)
  }

  private static func sourceNames(_ sources: Set<PolicySource>) -> [String] {
    sources.map(sourceName).sorted()
  }

  private static func sourceName(_ source: PolicySource) -> String {
    switch source {
    case .owner: "Owner Policy"
    case .machine: "Machine Policy"
    case .managedPreferences: "Configuration Profile"
    case .connection: "Connection"
    }
  }

  static func request(
    _ item: GatewayPermissionRequestView, principals: [PrivacyPrincipal],
    names: PermissionObjectNames, paths: [String: String] = [:],
    subjects: [GatewayPermissionSubjectView] = []
  ) -> PrivacyRequest? {
    let request = item.request
    guard request.status == .pending else { return nil }
    let fallback = invocationPrincipal(request.invocation.principal, names: names)
    var principal =
      principals.first { $0.id == (item.profileID?.rawValue ?? fallback.id) } ?? fallback
    if let verified = principals.first(where: { $0.id == fallback.id }) {
      principal = verified
    } else if case .client = request.invocation.principal,
      let subject = subjects.first(where: { $0.principal == request.invocation.principal })
    {
      principal = PrivacyPrincipal(
        id: principal.id, name: principal.name,
        kind: .client(connection: connectionName(subject.caller)), execution: principal.execution)
    }
    switch request.content {
    case .permission(let content):
      guard let (kind, classifiedObject) = classify(content.requirement.permission, names: names)
      else {
        return nil
      }
      var object = classifiedObject
      if let current = object {
        let path: String?
        if case .path(let location) = content.scope {
          path = location.string
        } else {
          path = kind == .projects ? paths[current.id] : current.detail
        }
        object = PrivacyObject(id: current.id, name: current.name, detail: path)
      }
      return PrivacyRequest(
        id: request.id.uuidString, principal: principal, permission: kind, object: object,
        level: level(content.requirement.value), purpose: content.pluginPurpose,
        tool: request.invocation.tool, expires: request.expiresAt)
    case .network(let content):
      return PrivacyRequest(
        id: request.id.uuidString, principal: principal, permission: .projects,
        object: PrivacyObject(
          id: content.projectID, name: project(content.projectID, names: names).name,
          detail: paths[content.projectID]), level: .read, host: content.host,
        purpose: content.pluginPurpose, tool: request.invocation.tool,
        expires: request.expiresAt)
    case .projectRegistration(let content):
      let root = item.registrationGrantRoot ?? content.path
      return PrivacyRequest(
        id: request.id.uuidString, principal: principal, permission: .projects,
        object: PrivacyObject(
          id: content.projectID,
          name: item.registrationGrantName ?? URL(fileURLWithPath: root.string).lastPathComponent,
          detail: root.string),
        level: level(content.access),
        registration: item.registrationGrantRoot == nil ? .newProject : .existingProject,
        purpose: nil, tool: request.invocation.tool, expires: request.expiresAt)
    }
  }

  static func invocationPrincipal(_ principal: Principal, names: PermissionObjectNames)
    -> PrivacyPrincipal
  {
    switch principal {
    case .client(let id):
      PrivacyPrincipal(
        id: "client/" + id, name: clientAccessIdentity(id),
        kind: .client(connection: "Connection"), execution: .sandbox)
    case .plugin(.package(let id)):
      PrivacyPrincipal(
        id: "plugin/" + id, name: names.plugins[id] ?? id,
        kind: .plugin(version: ""), execution: .sandbox)
    case .plugin(.localServer(let id)):
      PrivacyPrincipal(
        id: "server/" + id, name: names.mcpServers[id] ?? id,
        kind: .localServer, execution: .sandbox)
    }
  }

  static func connectionName(_ caller: GatewayCallerKind) -> String {
    switch caller {
    case .secureTunnel: "Secure Tunnel"
    case .cloudflareTunnel: "Cloudflare Tunnel"
    case .localApp, .localCLI, .localMCP: "This Mac"
    }
  }

  private static func source(_ source: GatewayManagedPolicyView) -> PrivacyManagedSource {
    let name =
      switch source.source {
      case .owner: "Owner Policy"
      case .machine: "Machine Policy"
      case .managedPreferences: "Configuration Profile"
      case .connection: "Connection"
      }
    return PrivacyManagedSource(
      id: [
        source.source.rawValue, source.location, source.profileID?.rawValue,
        source.provider.map { invocationPrincipal(.plugin($0), names: .init()).id },
      ]
      .compactMap { $0 }.joined(separator: "/"),
      name: name, location: source.location, state: source.failure == nil ? .active : .unreadable,
      profileID: source.profileID, provider: source.provider, revision: source.revision)
  }

  private static func systemPermission(_ summary: PermissionSummary) -> PrivacySystemPermission? {
    let kind: PrivacySystemPermission.Kind
    switch summary.id {
    case "screen-recording": kind = .screenRecording
    case "accessibility": kind = .accessibility
    default: return nil
    }
    let state: PrivacySystemPermission.State =
      switch summary.state {
      case .granted: .allowed
      case .notDetermined: .notDetermined
      case .denied, .notGranted, .unavailable: .notAllowed
      }
    return PrivacySystemPermission(kind: kind, state: state)
  }

  private static func classify(_ permission: Permission, names: PermissionObjectNames)
    -> (PrivacyPermissionKind, PrivacyObject?)?
  {
    switch permission {
    case .project(let id): (.projects, project(id, names: names))
    case .filesAndFolders(let category):
      (
        .filesAndFolders,
        PrivacyObject(
          id: category.rawValue, name: category.title, detail: category.directory?.path)
      )
    case .plugin(let id):
      (.plugins, PrivacyObject(id: id, name: object(id, names.plugins, "All Plugins"), detail: nil))
    case .mcpServer(let id):
      (
        .mcpServers,
        PrivacyObject(id: id, name: object(id, names.mcpServers, "All MCP Servers"), detail: nil)
      )
    case .screen: (.screen, nil)
    case .desktopControl: (.desktopControl, nil)
    case .localNetwork: (.localNetwork, nil)
    case .machineInformation: (.machineInformation, nil)
    case .unifiedLogs: (.unifiedLogs, nil)
    case .skills: (.skills, nil)
    }
  }

  private static func project(_ id: String, names: PermissionObjectNames) -> PrivacyObject {
    PrivacyObject(id: id, name: object(id, names.projects, "All Projects"), detail: nil)
  }

  private static func object(_ id: String, _ names: [String: String], _ all: String) -> String {
    id == "*" ? all : names[id] ?? id
  }

  private static func permission(_ grant: PrivacyGrant) -> Permission? {
    let id = grant.object?.id ?? ""
    switch grant.permission {
    case .projects: return .project(id)
    case .filesAndFolders: return FolderCategory(rawValue: id).map(Permission.filesAndFolders)
    case .plugins: return .plugin(id)
    case .mcpServers: return .mcpServer(id)
    case .screen: return .screen
    case .desktopControl: return .desktopControl
    case .localNetwork: return .localNetwork
    case .machineInformation: return .machineInformation
    case .unifiedLogs: return .unifiedLogs
    case .skills: return .skills
    case .fullAccess: return nil
    }
  }

  private static func value(_ state: ComputerMCPPermissions.PermissionState) -> PrivacyGrantValue {
    switch state {
    case .notGranted: .ask
    case .denied: .denied
    case .granted(let value): .granted(level(value))
    }
  }

  private static func state(_ value: PrivacyGrantValue) -> ComputerMCPPermissions.PermissionState {
    switch value {
    case .ask: .notGranted
    case .denied: .denied
    case .granted(let level):
      switch level {
      case .allow: .granted(.access)
      case .read: .granted(.read)
      case .readWrite: .granted(.write)
      case .use: .granted(.use)
      case .all: .granted(.all)
      }
    }
  }

  private static func level(_ value: PermissionValue) -> PrivacyGrantValue.Level {
    switch value {
    case .read: .read
    case .write: .readWrite
    case .use: .use
    case .all: .all
    case .access: .allow
    }
  }

  private static func network(_ configuration: NetworkAccess.Configuration) -> PrivacyNetworkAccess
  {
    switch configuration {
    case .none: .none
    case .trusted: .trusted
    case .full: .full
    case .custom(let hosts, let includesTrusted):
      .custom(hosts: hosts.sorted(), includesTrusted: includesTrusted)
    }
  }
}

extension FolderCategory {
  fileprivate var directory: URL? {
    let directory: FileManager.SearchPathDirectory
    switch self {
    case .desktop: directory = .desktopDirectory
    case .documents: directory = .documentDirectory
    case .downloads: directory = .downloadsDirectory
    case .iCloudDrive, .networkVolumes, .removableVolumes: return nil
    }
    return FileManager.default.urls(for: directory, in: .userDomainMask).first?
      .resolvingSymlinksInPath()
  }

  fileprivate var title: String {
    switch self {
    case .desktop: "Desktop"
    case .documents: "Documents"
    case .downloads: "Downloads"
    case .iCloudDrive: "iCloud Drive"
    case .networkVolumes: "Network Volumes"
    case .removableVolumes: "Removable Volumes"
    }
  }
}
