import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPToolKit
import ComputerMCPWorktrees
import Foundation
import GRDB

/// Reservations contain filesystem identity, but no bookmark or access grant.
private struct GatewayProjectReservation: Codable {
  let projectID: String
  let path: CanonicalPath
  let identity: ProjectRootIdentity
  let createdAt: Date
}

private struct GatewayProjectRegistrationInspection {
  let request: PermissionRequest
  let profile: ProfileGrant
  let projects: [ComputerMCPCore.RegisteredProject]
  let catalog: [ComputerMCPPermissions.RegisteredProject]
  let identities: [String: ProjectRootIdentity]
  let roots: [String: URL]
  let nesting: [TrackedProjectNesting]
}

extension GatewayPermissionService {
  package func requestProject(
    subject: GatewayPermissionSubject, path: String, access: PermissionValue,
    argumentsDigest: String, retryIDs: Set<UUID> = [], now: Date = Date()
  ) throws -> ProjectRegistrationDecision {
    guard path.hasPrefix("/"), path.utf8.count <= 16_384, !path.contains("\0") else {
      throw GatewayToolError.invalidArguments("path must name an absolute existing folder.")
    }
    let root = try ProjectPathResolver.resolve(path, relativeTo: URL(fileURLWithPath: "/"))
    let canonical = try CanonicalPath(root.path)
    let identity = try ProjectRootIdentity(root)
    return try transactionWithPolicy { database, ledger, policies in
      _ = try Self.bind(subject, database: database)
      _ = try refresh(database, ledger: &ledger, snapshot: policies, now: now)
      let profile = try Self.profile(
        subject.profileID, database: database, epoch: ledger.authorizationEpochID)
      guard profile.allowedCallers.contains(subject.caller) else {
        throw GatewayPermissionError.invalidBinding
      }
      try Self.synchronize(
        profile, principal: subject.principal, requestedProject: nil, ledger: &ledger)
      let invocation = InvocationIdentity(
        principal: subject.principal, tool: "project.request", projectID: nil,
        argumentsDigest: argumentsDigest)
      if !retryIDs.isEmpty {
        guard retryIDs.count == 1, let id = retryIDs.first,
          let request = ledger.requests[id], request.invocation == invocation,
          case .projectRegistration(let content) = request.content,
          content.principal == subject.principal, content.path == canonical,
          content.access == access
        else { throw PermissionModelError.retryMismatch }
        guard now < request.expiresAt else { throw PermissionModelError.expiredRequest }
        switch request.status {
        case .declined: return .denied(.permissionDenied(.project(content.projectID)))
        case .revoked: return .denied(.authorizationRevoked)
        case .pending, .registered:
          guard
            let stored = try RuntimeSettingRecord.fetchOne(
              database, key: Self.projectReservationKey(canonical))
          else {
            return .denied(.authorizationRevoked)
          }
          let reservation = try JSONDecoder().decode(
            GatewayProjectReservation.self, from: Data(stored.value.utf8))
          guard reservation.projectID == content.projectID, reservation.path == canonical,
            reservation.identity == identity
          else {
            return .denied(.authorizationRevoked)
          }
          if request.status == .pending { return .request(request) }
          guard case .registered(let sourceID) = request.status,
            sourceID == content.projectID,
            ledger.environment.paths?.projects.allLocations.contains(where: {
              $0.root == canonical && $0.projectID == sourceID
            }) == true,
            ledger.permissions(for: subject.principal).state(for: .project(sourceID)).allows(access)
          else { return .denied(.authorizationRevoked) }
          return try ledger.requestProjectRegistration(content, invocation: invocation, now: now)
        case .onlyThisTime, .always, .consumed:
          throw PermissionModelError.invalidRegistrationAnswer
        }
      }
      try database.execute(
        sql: "DELETE FROM runtimeSettings WHERE key LIKE 'project.request.%' AND updatedAt < ?",
        arguments: [now.addingTimeInterval(-86_400)])
      let key = Self.projectReservationKey(canonical)
      let stored = try RuntimeSettingRecord.fetchOne(database, key: key)
      let previous = try stored.map {
        try JSONDecoder().decode(GatewayProjectReservation.self, from: Data($0.value.utf8))
      }
      let existing = ledger.environment.paths?.projects.allLocations.first { $0.root == canonical }
      let reservation: GatewayProjectReservation
      let reusable =
        previous.map {
          $0.path == canonical && $0.identity == identity
            && (existing == nil || existing?.projectID == $0.projectID)
            && now < $0.createdAt.addingTimeInterval(86_400)
        } ?? false
      if let previous, reusable {
        reservation = GatewayProjectReservation(
          projectID: previous.projectID, path: previous.path, identity: previous.identity,
          createdAt: now)
      } else {
        if let previous {
          for request in ledger.requests.values {
            guard case .projectRegistration(let content) = request.content,
              content.projectID == previous.projectID, content.path == canonical,
              request.status == .pending
            else { continue }
            _ = try ledger.retireRequest(request.id, expectedRevision: ledger.revision)
          }
        }
        reservation = GatewayProjectReservation(
          projectID: existing?.projectID ?? UUID().uuidString, path: canonical, identity: identity,
          createdAt: now)
      }
      let decision = try ledger.requestProjectRegistration(
        ProjectRegistrationRequest(
          principal: subject.principal, projectID: reservation.projectID,
          path: canonical, access: access),
        invocation: invocation, now: now)
      if case .request = decision {
        if stored == nil {
          let count =
            try Int.fetchOne(
              database,
              sql: "SELECT COUNT(*) FROM runtimeSettings WHERE key LIKE 'project.request.%'") ?? 0
          guard count < 16_384 else {
            throw GatewayPermissionError.subjectCapacity
          }
        }
        try RuntimeSettingRecord(
          key: key, value: String(decoding: JSONEncoder().encode(reservation), as: UTF8.self),
          updatedAt: now
        ).save(database)
      }
      return decision
    }
  }

  /// Bookmark, registration, standing permission and catalog are committed together.
  /// The local owner reviews the reserved canonical path; one-time registration is invalid.
  @discardableResult
  package func answerProjectRequest(
    _ id: UUID, allow: Bool, owner: GatewayPermissionOwner,
    expectedRevision: UInt64, now: Date = Date()
  ) throws -> ComputerMCPCore.RegisteredProject? {
    let inspection =
      try allow
      ? inspectProjectRegistration(id, owner: owner, expectedRevision: expectedRevision, now: now)
      : nil
    return try transactionWithPolicy { database, ledger, policies in
      try owner.authorize()
      try Self.requireRevision(expectedRevision, database: database)
      _ = try refresh(database, ledger: &ledger, snapshot: policies, now: now)
      guard let request = ledger.requests[id],
        case .projectRegistration(let content) = request.content
      else {
        throw PermissionModelError.invalidRegistrationAnswer
      }
      let binding = try Self.binding(request.invocation.principal, database: database)
      var profile = try Self.profile(
        binding.profileID, database: database, epoch: ledger.authorizationEpochID)
      guard profile.allowedCallers.contains(binding.caller) else {
        throw GatewayPermissionError.invalidBinding
      }
      if !allow {
        _ = try ledger.answerProjectRegistration(id, registeredProject: nil, now: now)
        try Self.advanceControlRevision(database)
        try GatewayPermissionAudit.record(
          "dont_allow", capabilityID: "project.request", owner: owner,
          database: database, ledger: ledger, profileIDs: [profile.id], request: request,
          expectedRevision: expectedRevision, now: now)
        return nil
      }
      guard !Self.isManagedLimited(request, ledger: ledger) else {
        throw GatewayPermissionError.managedLimit
      }
      guard let inspection,
        request == inspection.request, profile == inspection.profile,
        try GatewayDatabase.projects(in: database) == inspection.projects,
        ledger.environment.paths?.registeredProjects == inspection.catalog
      else { throw GatewayPermissionError.revisionConflict }
      try Self.validateProjectIdentities(inspection)
      guard let bookmarks = projectBookmarks,
        let stored = try RuntimeSettingRecord.fetchOne(
          database, key: Self.projectReservationKey(content.path))
      else { throw PermissionModelError.invalidRegistrationAnswer }
      let reservation = try JSONDecoder().decode(
        GatewayProjectReservation.self, from: Data(stored.value.utf8))
      let root = URL(fileURLWithPath: content.path.string, isDirectory: true)
      guard reservation.projectID == content.projectID, reservation.path == content.path,
        try ProjectRootIdentity(root) == reservation.identity
      else { throw ProjectBookmarkError.rootChanged(projectID: content.projectID) }
      let existing = try GatewayDatabase.projects(in: database).first {
        try resolvedRegistrationRoot($0.rootPath).path
          == content.path.string
      }
      let sourceProject = ledger.environment.paths?.registeredProjects.first {
        $0.id == content.projectID
      }
      let derived = existing.flatMap { existing in
        ledger.environment.paths?.registeredProjects.first {
          $0.id == existing.id && $0.root == content.path && $0.sourceID != nil
            && ledger.environment.paths?.projects.sourceID(for: $0.id) == content.projectID
        }
      }
      guard existing == nil || existing?.id == content.projectID || derived != nil else {
        throw PermissionModelError.invalidRegistrationAnswer
      }
      var proposed = try existing ?? bookmarks.registerFolder(at: root, displayName: nil)
      proposed.id = existing?.id ?? content.projectID
      guard !proposed.bookmarkIsStale else {
        throw ProjectBookmarkError.rootChanged(projectID: content.projectID)
      }
      let resolved = try bookmarks.resolve(proposed)
      defer { resolved.close() }
      guard !resolved.project.bookmarkIsStale, !resolved.bookmarkWasRefreshed,
        try ProjectRootIdentity(resolved.rootURL) == resolved.rootIdentity,
        try ProjectRootIdentity(ProjectPathResolver.canonicalProject(resolved.rootURL))
          == reservation.identity,
        try ProjectRootIdentity(root) == reservation.identity
      else { throw ProjectBookmarkError.rootChanged(projectID: content.projectID) }
      proposed = resolved.project
      proposed.id = existing?.id ?? content.projectID
      let registered = try GatewayDatabase.registerProjectIdempotently(proposed, in: database)
      guard registered.project.id == proposed.id else {
        throw PermissionModelError.invalidRegistrationAnswer
      }
      let permissionProject: ComputerMCPPermissions.RegisteredProject
      if derived != nil {
        guard let sourceProject else { throw PermissionModelError.invalidProjectGraph }
        permissionProject = sourceProject
      } else {
        permissionProject = ComputerMCPPermissions.RegisteredProject(
          id: proposed.id, root: content.path)
      }
      _ = try ledger.answerProjectRegistration(id, registeredProject: permissionProject, now: now)
      try profile.permissions.set(
        ledger.permissions(for: content.principal).state(for: .project(content.projectID)),
        for: .project(content.projectID))
      try Self.advance(&profile)
      try Self.save(profile, database: database, epoch: ledger.authorizationEpochID)
      try Self.synchronizeBound(profile, database: database, ledger: &ledger)
      guard var paths = ledger.environment.paths else {
        throw PermissionModelError.invalidProjectGraph
      }
      var projects = paths.registeredProjects
      if !projects.contains(where: { $0.id == permissionProject.id }) {
        projects.append(permissionProject)
      }
      try paths.setProjects(projects)
      var permissions: [Principal: Permissions] = [:]
      for record in try ProfileRecord.fetchAll(database) {
        let storedProfile = try record.value()
        permissions[.client("profile:" + storedProfile.id.rawValue)] = storedProfile.permissions
      }
      try paths.projects.validate(
        nesting: inspection.nesting, permissions: permissions)
      var environment = ledger.environment
      environment.paths = paths
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
      guard try ProjectRootIdentity(root) == reservation.identity else {
        throw ProjectBookmarkError.rootChanged(projectID: content.projectID)
      }
      try Self.validateProjectIdentities(inspection)
      try Self.advanceControlRevision(database)
      try GatewayPermissionAudit.record(
        "allow", capabilityID: "project.request", owner: owner,
        database: database, ledger: ledger, profileIDs: [profile.id], request: request,
        expectedRevision: expectedRevision, now: now)
      return registered.project
    }
  }

  /// Git inspection runs before taking the writer. Every catalog, profile and physical
  /// root used by that inspection is rechecked before publishing its result.
  private func inspectProjectRegistration(
    _ id: UUID, owner: GatewayPermissionOwner, expectedRevision: UInt64, now: Date
  ) throws -> GatewayProjectRegistrationInspection {
    let snapshot = try store.readWithDatabase { database, ledger in
      try owner.authorize()
      try Self.requireRevision(expectedRevision, database: database)
      guard let request = ledger.requests[id],
        case .projectRegistration(let content) = request.content,
        let catalog = ledger.environment.paths?.registeredProjects,
        let stored = try RuntimeSettingRecord.fetchOne(
          database, key: Self.projectReservationKey(content.path))
      else { throw PermissionModelError.invalidRegistrationAnswer }
      guard request.status == .pending else { throw PermissionModelError.alreadyAnswered }
      guard now < request.expiresAt else { throw PermissionModelError.expiredRequest }
      let binding = try Self.binding(request.invocation.principal, database: database)
      let profile = try Self.profile(
        binding.profileID, database: database, epoch: ledger.authorizationEpochID)
      guard profile.allowedCallers.contains(binding.caller) else {
        throw GatewayPermissionError.invalidBinding
      }
      let reservation = try JSONDecoder().decode(
        GatewayProjectReservation.self, from: Data(stored.value.utf8))
      guard reservation.projectID == content.projectID, reservation.path == content.path else {
        throw PermissionModelError.invalidRegistrationAnswer
      }
      return (request, profile, try GatewayDatabase.projects(in: database), catalog, reservation)
    }
    guard case .projectRegistration(let content) = snapshot.0.content else {
      throw PermissionModelError.invalidRegistrationAnswer
    }
    let requestedRoot = URL(fileURLWithPath: content.path.string, isDirectory: true)
    guard try ProjectRootIdentity(requestedRoot) == snapshot.4.identity else {
      throw ProjectBookmarkError.rootChanged(projectID: content.projectID)
    }
    var proposed = snapshot.2
    if try !proposed.contains(where: {
      try resolvedRegistrationRoot($0.rootPath).path
        == content.path.string
    }) {
      proposed.append(
        ComputerMCPCore.RegisteredProject(
          id: content.projectID, displayName: requestedRoot.lastPathComponent,
          rootPath: content.path.string))
    }
    guard Set(proposed.map(\.id)).count == proposed.count else {
      throw PermissionModelError.invalidProjectGraph
    }
    let canonicalRoots = try Dictionary(
      uniqueKeysWithValues: proposed.map { ($0.id, try resolvedRegistrationRoot($0.rootPath)) })
    // Unavailable unrelated roots remain catalog entries. Only the requested grant and
    // roots participating in a nesting relationship need live filesystem identities.
    let involved = canonicalRoots.filter { id, root in
      id == content.projectID || root.path == content.path.string
        || canonicalRoots.contains { otherID, other in
          otherID != id
            && (ProjectPathResolver.contains(root, in: other)
              || ProjectPathResolver.contains(other, in: root))
        }
    }
    let roots = Dictionary(
      uniqueKeysWithValues: proposed.filter { involved[$0.id] != nil }.map {
        ($0.id, URL(fileURLWithPath: $0.rootPath))
      })
    let identities = try roots.mapValues {
      try ProjectRootIdentity(ProjectPathResolver.canonicalProject($0))
    }
    let inspection = GatewayProjectRegistrationInspection(
      request: snapshot.0, profile: snapshot.1, projects: snapshot.2, catalog: snapshot.3,
      identities: identities, roots: roots, nesting: try projectNesting(proposed))
    try Self.validateProjectIdentities(inspection)
    return inspection
  }

  private static func validateProjectIdentities(_ inspection: GatewayProjectRegistrationInspection)
    throws
  {
    for (id, root) in inspection.roots {
      guard
        try ProjectRootIdentity(ProjectPathResolver.canonicalProject(root))
          == inspection.identities[id]
      else {
        throw ProjectBookmarkError.rootChanged(projectID: id)
      }
    }
  }

  private static func projectReservationKey(_ path: CanonicalPath) -> String {
    "project.request." + MCPExecutionRecord.digest(.string(path.string))
  }
}

/// Git's index is queried as data using fixed arguments and disabled executable configuration.
package enum GatewayTrackedProjectNesting {
  package static func inspect(
    _ projects: [ComputerMCPCore.RegisteredProject], gitExecutable: String,
    runner: any CommandRunning
  ) throws -> [TrackedProjectNesting] {
    var result: [TrackedProjectNesting] = []
    let roots = try Dictionary(
      uniqueKeysWithValues: projects.map { ($0.id, try resolvedRegistrationRoot($0.rootPath)) })
    for outer in projects {
      let root = roots[outer.id]!
      let prefix = root.path == "/" ? "/" : root.path + "/"
      let nested = projects.filter {
        $0.id != outer.id && roots[$0.id]!.path.hasPrefix(prefix)
      }
      guard !nested.isEmpty, try hasGitAncestor(root) else { continue }
      let discovery = try runner.runIsolated(
        executable: gitExecutable,
        arguments: HostGitConfiguration.arguments + ["rev-parse", "--is-inside-work-tree"],
        workingDirectory: root, environment: HostGitConfiguration.environment(home: root),
        timeoutMilliseconds: 5_000, maxOutputBytes: 16_384)
      guard !discovery.timedOut, !discovery.stdoutTruncated, !discovery.stderrTruncated else {
        throw GatewayToolError.executionFailed("Cannot locate enclosing Git repository.")
      }
      guard discovery.exitCode == 0,
        discovery.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
      else {
        throw GatewayToolError.executionFailed("Cannot locate enclosing Git repository.")
      }
      for inner in nested {
        let path = roots[inner.id]!.path
        let relative = String(path.dropFirst(prefix.count))
        let command = try runner.runIsolated(
          executable: gitExecutable,
          arguments: HostGitConfiguration.arguments + [
            "ls-files", "-z", "--", ":(literal)" + relative,
          ],
          workingDirectory: root, environment: HostGitConfiguration.environment(home: root),
          timeoutMilliseconds: 5_000, maxOutputBytes: 1_048_576)
        guard command.exitCode == 0, !command.timedOut,
          !command.stdoutTruncated, !command.stderrTruncated
        else {
          throw GatewayToolError.executionFailed(
            "Cannot validate tracked nested project boundaries.")
        }
        if !command.stdout.isEmpty {
          result.append(TrackedProjectNesting(innerID: inner.id, outerID: outer.id))
        }
      }
    }
    return result
  }

  private static func hasGitAncestor(_ root: URL) throws -> Bool {
    var directory = root
    while true {
      do {
        _ = try FileManager.default.attributesOfItem(
          atPath: directory.appendingPathComponent(".git").path)
        return true
      } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      } catch {
        throw GatewayToolError.executionFailed("Cannot inspect enclosing Git repository.")
      }
      let parent = directory.deletingLastPathComponent()
      if parent.path == directory.path { return false }
      directory = parent
    }
  }
}

private func resolvedRegistrationRoot(_ path: String) throws -> URL {
  try ProjectPathResolver.resolve(path, relativeTo: URL(fileURLWithPath: "/"))
}
