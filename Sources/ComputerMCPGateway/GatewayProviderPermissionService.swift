import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPPlugins
import Foundation
import GRDB

extension GatewayPermissionService {
  package func approveProvider(
    _ review: GatewayProviderReview, permissions: Permissions, fullAccess: Bool,
    sandboxSettings: ProviderSandboxSettings = .init(),
    userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
    owner: GatewayPermissionOwner, expectedProviderRevision: Int64?, expectedRevision: UInt64,
    expectedEpoch: UUID, editingApproval: Bool = false, reviewedLimits: ManagedLimits? = nil,
    now: Date = Date()
  ) throws -> GatewayProviderApproval {
    try transactionWithPolicy { database, ledger, policies in
      let approval = try Self.applyProviderApproval(
        review, permissions: permissions, fullAccess: fullAccess, sandboxSettings: sandboxSettings,
        userHome: userHome, owner: owner, expectedProviderRevision: expectedProviderRevision,
        expectedRevision: expectedRevision, expectedEpoch: expectedEpoch,
        editingApproval: editingApproval, reviewedLimits: reviewedLimits,
        database: database, ledger: &ledger, policies: policies, now: now)
      if !editingApproval, case .package(let id) = review.identity {
        var state = review.configuration.plugins
        guard state.revision < Int64.max else { throw PermissionMigrationError.revisionExhausted }
        state.settings[id, default: .init()].enabled = true
        state.revision += 1
        try GatewayDatabase.writePluginSnapshot(state, database: database)
      }
      return approval
    }
  }

  static func applyProviderApproval(
    _ review: GatewayProviderReview, permissions: Permissions, fullAccess: Bool,
    sandboxSettings: ProviderSandboxSettings,
    userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
    owner: GatewayPermissionOwner, expectedProviderRevision: Int64?, expectedRevision: UInt64,
    expectedEpoch: UUID, editingApproval: Bool = false, reviewedLimits: ManagedLimits? = nil,
    database: Database, ledger: inout PermissionLedger,
    policies: GatewayPermissionPolicySnapshot, now: Date
  ) throws -> GatewayProviderApproval {
    try owner.authorize()
    try Self.requireRevision(expectedRevision, database: database)
    guard ledger.suspendedAuthority == nil && ledger.pendingEpochRecovery == nil,
      ledger.authorizationEpochID == expectedEpoch,
      try GatewayDatabase.configurationState(in: database) == review.configuration
    else { throw GatewayPermissionError.revisionConflict }
    var record =
      try ProviderAuthorityRecord.load(review.identity, in: database)
      ?? ProviderAuthorityRecord(identity: review.identity, payload: Data())
    _ = try record.identity
    let previous = record.payload.isEmpty ? nil : try Self.providerApproval(record)
    guard previous?.revision == expectedProviderRevision else {
      throw GatewayPermissionError.revisionConflict
    }
    if editingApproval {
      guard let previous, previous.enabled, previous.epoch == expectedEpoch,
        previous.sourceDigest == review.sourceDigest,
        fullAccess == (previous.fullAccessConsent != nil)
      else { throw GatewayPermissionError.revisionConflict }
    }
    if let declarations = review.declarations {
      try GatewayProviderApproval.validate(permissions, declarations: declarations)
      try GatewayProviderReadExceptions.validate(
        declarations, settings: sandboxSettings, userHome: userHome)
      guard fullAccess == (declarations.sandbox?.fullAccess == true) else {
        throw GatewayPermissionError.invalidBinding
      }
    }
    let derivedIDs = Set(review.configuration.derivedProjects.map(\.projectID))
    for (permission, state) in permissions.entries {
      if case .project(let id) = permission, derivedIDs.contains(id) {
        guard previous?.permissions.entries[permission] == state else {
          throw PermissionModelError.invalidObject
        }
        continue
      }
      guard case .granted = state else { continue }
      let known: Bool
      switch permission {
      case .project(let id):
        known = id == "*" || review.configuration.projects.contains { $0.id == id }
      case .plugin(let id): known = id == "*" || review.pluginIDs.contains(id)
      case .mcpServer(let id): known = id == "*" || review.serverIDs.contains(id)
      default: known = true
      }
      guard known else { throw PermissionModelError.invalidObject }
    }
    let limits = policies.providerLimits(
      review.identity, epoch: expectedEpoch,
      previous: ledger.environment.limits[.plugin(review.identity)])
    guard reviewedLimits.map({ $0 == limits }) ?? true else {
      throw GatewayPermissionError.revisionConflict
    }
    try Self.validateProviderEdit(
      permissions, fullAccess: fullAccess, limits: limits,
      previous: editingApproval ? previous : nil)
    guard (previous?.revision ?? 0) < Int64.max else {
      throw PermissionMigrationError.revisionExhausted
    }
    let trustedHosts = Set(ledger.environment.trustedHosts.map(\.host))
    let currentSettings = ledger.sandboxSettings.providers[review.identity]
    var selectedSettings =
      !editingApproval && previous != nil && currentSettings == nil
      ? sandboxSettings.rebindingReviewedChoices() : sandboxSettings
    let ceiling = review.declarations.map { $0.sandbox?.network?.value ?? .none }
    selectedSettings.defaults.networkCeiling = ceiling.map {
      (currentSettings?.defaults.networkCeiling ?? .none).updating(to: $0)
    }
    if let currentSettings {
      selectedSettings.defaults.network = currentSettings.defaults.network.updating(
        to: selectedSettings.defaults.network)
      for (id, var override) in selectedSettings.projects {
        if let network = override.network {
          override.network = (currentSettings.projects[id]?.network ?? .none).updating(to: network)
          selectedSettings.projects[id] = override
        }
      }
    }
    for projectID in [nil] + selectedSettings.projects.keys.sorted().map(Optional.some) {
      let settings = selectedSettings.settings(sourceProjectID: projectID)
      if editingApproval,
        settings == previous?.sandboxSettings?.settings(sourceProjectID: projectID)
      {
        continue
      }
      if fullAccess {
        guard settings.network.configuration == .none, settings.readExceptions.isEmpty else {
          throw GatewayPermissionError.invalidBinding
        }
      }
      if let ceiling, !settings.network.fits(within: ceiling, trustedHosts: trustedHosts) {
        throw GatewayPermissionError.invalidBinding
      }
      for source in limits.sources.values {
        switch source {
        case .absent: break
        case .unreadable: throw GatewayPermissionError.managedLimit
        case .available(let policy):
          guard settings.network.fits(within: policy.network, trustedHosts: trustedHosts) else {
            throw GatewayPermissionError.managedLimit
          }
        }
      }
      try GatewayProviderReadExceptions.verify(settings.readExceptions, userHome: userHome)
      for exception in settings.readExceptions {
        if let declarations = review.declarations {
          guard
            declarations.sandbox?.readExceptions?.contains(where: {
              $0.path == exception.declaredPath && $0.purpose == exception.purpose
            }) == true
          else { throw GatewayPermissionError.invalidBinding }
        }
        guard
          ledger.canApproveReadException(
            at: exception.path, for: review.identity, settings: settings, limits: limits)
        else {
          throw GatewayPermissionError.invalidBinding
        }
      }
    }
    let principal = Principal.plugin(review.identity)
    let current = ledger.permissions(for: principal)
    var selection = current
    for permission in current.entries.keys where permissions.entries[permission] == nil {
      selection.removeEntry(for: permission)
    }
    for (permission, state) in permissions.entries where current.entries[permission] != state {
      try selection.set(state, for: permission)
    }
    if selection != current {
      _ = try ledger.setPermissions(selection, for: principal, expectedRevision: ledger.revision)
    }
    if selectedSettings != currentSettings {
      _ = try ledger.setProviderSandboxSettings(
        selectedSettings, for: review.identity, expectedRevision: ledger.revision)
    }
    let consent: ModeConsent? =
      if editingApproval { previous?.fullAccessConsent } else if fullAccess {
        ledger.consent(for: principal, mode: .fullAccess(.standing))
      } else { nil }
    let approval = GatewayProviderApproval(
      identity: review.identity, revision: (previous?.revision ?? 0) + 1, epoch: expectedEpoch,
      enabled: true, sourceDigest: review.sourceDigest, declarations: review.declarations,
      declarationDigest: try review.declarations?.digest(),
      permissions: ledger.permissions(for: principal),
      fullAccessConsent: consent,
      sandboxSettings: ledger.sandboxSettings.providers[review.identity], update: .unchanged)
    try approval.validate()
    record.payload = try Self.encodeProviderApproval(approval)
    try record.save(database)
    try Self.synchronizeProvider(approval, ledger: &ledger, limits: limits)
    try Self.advanceControlRevision(database)
    try GatewayPermissionAudit.record(
      "approve_provider", capabilityID: "permissions.provider", owner: owner,
      database: database, ledger: ledger, profileIDs: [],
      permissions: Set(permissions.entries.keys), provider: approval.identity,
      expectedRevision: expectedRevision, now: now)
    return approval
  }

  package func revokeProvider(
    _ identity: PluginIdentity, owner: GatewayPermissionOwner,
    expectedProviderRevision: Int64, expectedRevision: UInt64, expectedEpoch: UUID? = nil,
    expectedSourceDigest: String? = nil, now: Date = Date()
  ) throws -> RevocationResult {
    try transactionWithPolicy { database, ledger, _ in
      try owner.authorize()
      try Self.requireRevision(expectedRevision, database: database)
      guard var record = try ProviderAuthorityRecord.load(identity, in: database) else {
        throw GatewayPermissionError.invalidBinding
      }
      var approval = try Self.providerApproval(record)
      guard approval.revision == expectedProviderRevision, approval.revision < Int64.max,
        expectedEpoch.map({ $0 == ledger.authorizationEpochID }) ?? true,
        expectedSourceDigest.map({ $0 == approval.sourceDigest }) ?? true
      else {
        throw GatewayPermissionError.revisionConflict
      }
      approval.enabled = false
      approval.revision += 1
      approval.fullAccessConsent = nil
      record.payload = try Self.encodeProviderApproval(approval)
      try record.save(database)
      try Self.retireProvider(.plugin(identity), ledger: &ledger)
      try Self.advanceControlRevision(database)
      try GatewayPermissionAudit.record(
        "revoke_provider", capabilityID: "permissions.provider", owner: owner,
        database: database, ledger: ledger, profileIDs: [], provider: identity,
        expectedRevision: expectedRevision,
        now: now)
      return ledger.pendingRevocations
    }
  }

  package func setOwnerPolicy(
    _ document: Data?, provider: PluginIdentity, owner: GatewayPermissionOwner,
    expectedRevision: UInt64, expectedEpoch: UUID? = nil, now: Date = Date()
  ) throws -> RevocationResult {
    let resolved = try document.map { try GatewayResolvedPolicy(bytes: $0, reader: policyReader) }
    return try transactionWithPolicy { database, ledger, policies in
      try owner.authorize()
      try Self.requireRevision(expectedRevision, database: database)
      guard expectedEpoch.map({ $0 == ledger.authorizationEpochID }) ?? true else {
        throw GatewayPermissionError.revisionConflict
      }
      guard ledger.suspendedAuthority == nil && ledger.pendingEpochRecovery == nil,
        let epoch = ledger.authorizationEpochID,
        var record = try ProviderAuthorityRecord.load(provider, in: database)
      else { throw PermissionModelError.authoritySuspended }
      record.ownerPolicy = document
      record.policyEpoch = epoch.uuidString
      try record.save(database)
      _ = try refresh(
        database, ledger: &ledger,
        snapshot: policies.settingProvider(record, document: resolved), now: now)
      try Self.advanceControlRevision(database)
      try GatewayPermissionAudit.record(
        document == nil ? "clear_provider_policy" : "set_provider_policy",
        capabilityID: "permissions.owner_policy", owner: owner, database: database,
        ledger: ledger, profileIDs: [], provider: provider, expectedRevision: expectedRevision,
        now: now)
      return ledger.pendingRevocations
    }
  }

  private static func encodeProviderApproval(_ approval: GatewayProviderApproval) throws -> Data {
    try approval.validate()
    let data = try JSONEncoder().encode(approval)
    guard data.count <= 4_194_304 else { throw PermissionPersistenceError.invalidCurrentState }
    return data
  }

  static func providerApproval(_ record: ProviderAuthorityRecord) throws -> GatewayProviderApproval
  {
    guard record.payload.count <= 4_194_304 else {
      throw PermissionPersistenceError.invalidCurrentState
    }
    let value = try JSONDecoder().decode(GatewayProviderApproval.self, from: record.payload)
    guard value.identity == (try record.identity) else {
      throw PermissionPersistenceError.invalidCurrentState
    }
    try value.validate()
    return value
  }

  static func answerProviderRequest(
    _ request: PermissionRequest, answer: PermissionAnswer, owner: GatewayPermissionOwner,
    database: Database, ledger: inout PermissionLedger, expectedRevision: UInt64, now: Date
  ) throws -> Result<RevocationResult, any Error> {
    guard case .plugin(let identity) = request.invocation.principal,
      var record = try ProviderAuthorityRecord.load(identity, in: database)
    else { return .failure(GatewayPermissionError.invalidBinding) }
    var approval = try providerApproval(record)
    guard approval.enabled, approval.epoch == ledger.authorizationEpochID,
      approval.sandboxSettings != nil
    else { return .failure(GatewayPermissionError.invalidBinding) }
    if case .permission(let content) = request.content, let declarations = approval.declarations,
      !declarations.permissions.contains(where: {
        $0.matches(content.requirement.permission)
          && PermissionState.granted($0.value).allows(content.requirement.value)
      }), content.requirement.permission != .machineInformation,
      content.requirement.permission != .skills
    {
      return .failure(GatewayPermissionError.invalidBinding)
    }
    guard !isManagedLimited(request, ledger: ledger) else {
      return .failure(GatewayPermissionError.managedLimit)
    }
    do { _ = try ledger.answer(request.id, with: answer, now: now) } catch {
      return .failure(error)
    }
    if case .always = answer {
      guard approval.revision < Int64.max else { throw PermissionMigrationError.revisionExhausted }
      approval.permissions = ledger.permissions(for: approval.principal)
      approval.sandboxSettings = ledger.sandboxSettings.providers[identity]
      approval.revision += 1
      approval.fullAccessConsent = nil
      record.payload = try Self.encodeProviderApproval(approval)
      try record.save(database)
    }
    try advanceControlRevision(database)
    try GatewayPermissionAudit.record(
      "answer_provider_request", capabilityID: "permissions.answer", owner: owner,
      database: database, ledger: ledger, profileIDs: [], request: request,
      provider: identity, expectedRevision: expectedRevision, now: now)
    return .success(ledger.pendingRevocations)
  }

  private static func retireProvider(_ principal: Principal, ledger: inout PermissionLedger) throws
  {
    let hasTransientAuthority =
      ledger.environment.modes[principal] != nil
      || ledger.authorizations.values.contains {
        $0.invocation.principal == principal && (try? ledger.invocationAccess($0.id)) != nil
      }
      || ledger.requests.values.contains {
        $0.invocation.principal == principal && $0.status != .revoked
      }
    if ledger.permissions(for: principal).entries != [:] {
      _ = try ledger.setPermissions(
        Permissions(), for: principal, expectedRevision: ledger.revision)
    }
    if case .plugin(let identity) = principal, ledger.sandboxSettings.providers[identity] != nil {
      _ = try ledger.setProviderSandboxSettings(
        nil, for: identity, expectedRevision: ledger.revision)
    }
    var environment = ledger.environment
    environment.modes[principal] = nil
    if case .plugin(let identity) = principal { environment.providerRequirements?[identity] = nil }
    if environment != ledger.environment {
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    }
    if hasTransientAuthority {
      _ = try ledger.retirePrincipal(principal, expectedRevision: ledger.revision)
    }
  }

  static func synchronizeProvider(
    _ approval: GatewayProviderApproval, ledger: inout PermissionLedger, limits: ManagedLimits
  ) throws {
    guard ledger.suspendedAuthority == nil && ledger.pendingEpochRecovery == nil else { return }
    guard approval.enabled, approval.epoch == ledger.authorizationEpochID else {
      try Self.retireProvider(approval.principal, ledger: &ledger)
      return
    }
    if ledger.permissions(for: approval.principal).entries != approval.permissions.entries {
      _ = try ledger.setPermissions(
        approval.permissions, for: approval.principal, expectedRevision: ledger.revision)
    }
    if ledger.sandboxSettings.providers[approval.identity] != approval.sandboxSettings {
      _ = try ledger.setProviderSandboxSettings(
        approval.sandboxSettings, for: approval.identity, expectedRevision: ledger.revision)
    }
    var environment = ledger.environment
    environment.limits[approval.principal] = limits
    if environment.providerRequirements?[approval.identity]?.digest != approval.requirementDigest {
      if environment.providerRequirements == nil { environment.providerRequirements = [:] }
      environment.providerRequirements?[approval.identity] = ProviderRequirementBinding(
        digest: approval.requirementDigest)
    }
    environment.modes[approval.principal] = approval.fullAccessConsent.flatMap {
      ledger.isConsentValid($0, for: approval.principal) ? $0 : nil
    }
    if environment != ledger.environment {
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    }
  }

  static func validateProviderEdit(
    _ permissions: Permissions, fullAccess: Bool, limits: ManagedLimits,
    previous: GatewayProviderApproval? = nil
  ) throws {
    for (permission, state) in permissions.entries {
      guard case .granted(let value) = state else { continue }
      if let previous, previous.permissions.entries[permission]?.allows(value) == true { continue }
      switch permission {
      case .project(let id), .plugin(let id), .mcpServer(let id):
        guard !id.isEmpty, id.utf8.count <= 256,
          !id.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
          id == "*" || !id.contains("*")
        else { throw PermissionModelError.invalidObject }
        if id == "*" {
          guard limits.restrictingSources(forFallback: permission, in: permissions).isEmpty else {
            throw GatewayPermissionError.managedLimit
          }
          continue
        }
      default: break
      }
      guard limits.restrictingSources(for: try .init(permission, value)).isEmpty else {
        throw GatewayPermissionError.managedLimit
      }
    }
    if let previous {
      for permission in previous.permissions.entries.keys
      where permissions.entries[permission] == nil {
        if case .granted(let value) = permissions.state(for: permission),
          !previous.permissions.state(for: permission).allows(value),
          !limits.restrictingSources(for: try .init(permission, value)).isEmpty
        {
          throw GatewayPermissionError.managedLimit
        }
      }
    }
    if fullAccess && previous == nil {
      for source in limits.sources.values {
        switch source {
        case .absent: continue
        case .available(let policy) where policy.allowsFullAccess: continue
        default: throw GatewayPermissionError.managedLimit
        }
      }
    }
  }

  /// Called in the same transaction that publishes the newly selected installation.
  static func reconcileProviderSources(
    database: Database, ledger: inout PermissionLedger, previous: PluginStoreSnapshot
  ) throws {
    let state = try GatewayDatabase.configurationState(in: database).plugins
    for var record in try ProviderAuthorityRecord.fetchAll(database) {
      var approval = try providerApproval(record)
      guard case .package(let id) = approval.identity else { continue }
      if previous.settings[id] != state.settings[id]
        || previous.selectedInstallations[id] != state.selectedInstallations[id]
      {
        _ = try ledger.retireProviderExecutions(
          approval.identity, expectedRevision: ledger.revision)
      }
      if state.settings[id]?.enabled != true
        || (state.selectedInstallations[id] == nil && previous.selectedInstallations[id] != nil)
      {
        if approval.enabled {
          guard approval.revision < Int64.max else {
            throw PermissionMigrationError.revisionExhausted
          }
          approval.enabled = false
          approval.revision += 1
          approval.fullAccessConsent = nil
          record.payload = try Self.encodeProviderApproval(approval)
          try record.save(database)
        }
        try Self.retireProvider(approval.principal, ledger: &ledger)
      }
      guard let selected = state.selectedInstallations[id],
        let installation = state.installations.first(where: { $0.id == selected })
      else { continue }
      if approval.sourceDigest == installation.manifestDigest {
        if approval.pendingSourceDigest != nil {
          guard approval.revision < Int64.max else {
            throw PermissionMigrationError.revisionExhausted
          }
          approval.revision += 1
          approval.pendingSourceDigest = nil
          approval.pendingDeclarations = nil
          approval.update = .unchanged
          record.payload = try Self.encodeProviderApproval(approval)
          try record.save(database)
        }
        continue
      }
      guard approval.pendingSourceDigest != installation.manifestDigest else { continue }
      guard let proposed = installation.declarations, let prior = approval.declarations else {
        if approval.enabled {
          guard approval.revision < Int64.max else {
            throw PermissionMigrationError.revisionExhausted
          }
          approval.revision += 1
        }
        approval.enabled = false
        approval.fullAccessConsent = nil
        record.payload = try Self.encodeProviderApproval(approval)
        try record.save(database)
        try Self.retireProvider(approval.principal, ledger: &ledger)
        continue
      }
      try GatewayProviderReadExceptions.validate(proposed, settings: approval.sandboxSettings)
      let change = try proposed.update(
        from: prior,
        conservativeEquivalent: .conservativeEquivalent(
          permissions: ledger.permissions(for: approval.principal),
          limits: ledger.environment.limits[approval.principal] ?? .init()))
      let consentWasValid =
        approval.fullAccessConsent.map {
          ledger.isConsentValid($0, for: approval.principal)
        } ?? false
      guard approval.revision < Int64.max else { throw PermissionMigrationError.revisionExhausted }
      approval.revision += 1
      approval.update = change
      if change == .widening {
        approval.pendingSourceDigest = installation.manifestDigest
        approval.pendingDeclarations = proposed
      } else {
        try approval.narrow(to: proposed)
        approval.sourceDigest = installation.manifestDigest
        approval.pendingSourceDigest = nil
        approval.pendingDeclarations = nil
      }
      if ledger.suspendedAuthority == nil && ledger.pendingEpochRecovery == nil, approval.enabled,
        approval.epoch == ledger.authorizationEpochID
      {
        if ledger.permissions(for: approval.principal).entries != approval.permissions.entries {
          _ = try ledger.setPermissions(
            approval.permissions, for: approval.principal, expectedRevision: ledger.revision)
        }
        approval.permissions = ledger.permissions(for: approval.principal)
        if change != .widening, let consent = approval.fullAccessConsent,
          !ledger.isConsentValid(consent, for: approval.principal)
        {
          // Existing local consent covers a strict attenuation, never an expansion.
          approval.fullAccessConsent =
            consentWasValid
            ? ledger.consent(for: approval.principal, mode: .fullAccess(.standing)) : nil
        }
        try synchronizeProvider(
          approval, ledger: &ledger,
          limits: ledger.environment.limits[approval.principal] ?? .init())
        approval.sandboxSettings = ledger.sandboxSettings.providers[approval.identity]
      }
      record.payload = try Self.encodeProviderApproval(approval)
      try record.save(database)
    }
  }

  static func reconcileLocalProviderSources(
    _ servers: [MCPServerConfig], database: Database, ledger: inout PermissionLedger
  ) throws {
    for var record in try ProviderAuthorityRecord.fetchAll(database) {
      var approval = try providerApproval(record)
      guard case .localServer(let id) = approval.identity, approval.enabled else { continue }
      if let server = servers.first(where: { $0.id == id }), server.enabled,
        server.transport == .stdio,
        try GatewayProviderReview.digest(server) == approval.sourceDigest
      {
        continue
      }
      guard approval.revision < Int64.max else { throw PermissionMigrationError.revisionExhausted }
      approval.enabled = false
      approval.revision += 1
      approval.fullAccessConsent = nil
      record.payload = try encodeProviderApproval(approval)
      try record.save(database)
      try retireProvider(approval.principal, ledger: &ledger)
    }
  }
}
