import AppKit
import ComputerMCPDarwinTestSupport
import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPTestSupport
import ComputerMCPTunnels
import Foundation
import SwiftUI
import Testing

@testable import ComputerMCPApp
@testable import ComputerMCPConfiguration
@testable import ComputerMCPControlPlane
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlatform
@testable import ComputerMCPPlatformDarwin
@testable import ComputerMCPPlugins

@MainActor
@Suite(.serialized) struct H14PrivacyJourneyTests {
  @Test func everyPermissionObjectRoundTripsThroughBothPerspectives() async throws {
    let fixture = try await makeInventory()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = fixture.model
    let principals = [fixture.client, fixture.package, fixture.server]
    let packageScreen = try row(
      ObjectKey(.screen), principal: fixture.package, in: model, perspective: .category)
    #expect(!packageScreen.isStored && packageScreen.effectiveValue == .ask)
    let reviewed = model.snapshot
    try await set(packageScreen, .granted(.allow), in: model)
    await model.set(packageScreen, to: .denied, reviewed: reviewed)
    #expect(model.failure != nil)
    #expect(
      try row(ObjectKey(.screen), principal: fixture.package, in: model, perspective: .principal)
        .effectiveValue == .granted(.allow))
    model.failure = nil

    for principal in principals {
      let rows = fixture.objects
      let principalRows = model.grants(for: principal)
      #expect(Set(principalRows.map { ObjectKey($0.permission, $0.object?.id) }) == Set(rows))
      let ownerID = principal.sharedProfileID?.rawValue ?? principal.id
      for object in rows {
        let category = try row(object, principal: principal, in: model, perspective: .category)
        #expect(
          category == (try row(object, principal: principal, in: model, perspective: .principal)))
        let source = model.sourceGrant(for: category)
        if principal.sharedProfileID != nil || object.id == fixture.worktreeID {
          let owner = try #require(source)
          #expect(owner.principalID == ownerID)
          #expect(owner.object?.id == (object.id == fixture.worktreeID ? "project" : object.id))
          #expect(!model.canEdit(category))
          #expect(model.canEdit(owner))
        } else {
          #expect(source == nil)
          #expect(model.canEdit(category))
        }
        #expect(category.availableLevels == object.kind.grantedValues)
      }

      // Explicit siblings make a wildcard edit exercise fallback separately from the overrides.
      for object in rows where object.id != "*" && object.id != fixture.worktreeID {
        let current = try row(object, principal: principal, in: model, perspective: .principal)
        try await set(current, .granted(try #require(object.kind.grantedValues.first)), in: model)
      }
      for object in rows where object.id != fixture.worktreeID {
        let before = model.snapshot.grants
        let siblingRows = before.filter { grant in
          let key = ObjectKey(grant.permission, grant.object?.id)
          if grant.principalID == principal.id || grant.principalID == ownerID {
            if key == object
              || (object == ObjectKey(.projects, "project")
                && key == ObjectKey(.projects, fixture.worktreeID))
            {
              return false
            }
          }
          return true
        }
        let category = try row(object, principal: principal, in: model, perspective: .category)
        for level in object.kind.grantedValues {
          try await set(category, .granted(level), in: model)
          #expect(
            try row(object, principal: principal, in: model, perspective: .principal).effectiveValue
              == .granted(level))
          expectUnchanged(siblingRows, in: model)
        }
        let detail = try row(object, principal: principal, in: model, perspective: .principal)
        try await set(detail, .ask, in: model)
        #expect(
          try row(object, principal: principal, in: model, perspective: .category).effectiveValue
            == .ask)
        expectUnchanged(siblingRows, in: model)
        try await set(detail, .denied, in: model)
        #expect(
          try row(object, principal: principal, in: model, perspective: .category).effectiveValue
            == .denied)
        expectUnchanged(siblingRows, in: model)
        let highest = try #require(object.kind.grantedValues.last)
        try await set(detail, .granted(highest), in: model)
        #expect(
          try row(object, principal: principal, in: model, perspective: .category).effectiveValue
            == .granted(highest))
        try await set(category, .denied, in: model)
        #expect(
          try row(object, principal: principal, in: model, perspective: .principal).effectiveValue
            == .denied)
        expectUnchanged(siblingRows, in: model)
        if object == ObjectKey(.projects, "project") {
          for perspective in Perspective.allCases {
            let child = try row(
              ObjectKey(.projects, fixture.worktreeID), principal: principal, in: model,
              perspective: perspective)
            #expect(child.effectiveValue == .denied && !child.isStored)
          }
        }
        // Keep the concrete row active while testing later siblings.
        if object.id != "*" { try await set(detail, .granted(highest), in: model) }
      }
      try await verifyInheritedAndNetworkRows(principal: principal, fixture: fixture)
    }

    try await verifyExecutionAndDeclarationBounds(fixture)
  }

  @Test func liveViewsRenderBothPerspectivesAndReflectScopedEdits() async throws {
    let fixture = try await makeInventory()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = fixture.model
    _ = NSApplication.shared
    let frame = NSRect(x: 0, y: 0, width: 820, height: 1080)
    let host = NSHostingView(
      rootView: PrivacySecurityView(model: model)
        .environment(\.locale, Locale(identifier: "en"))
        .transaction { $0.disablesAnimations = true }
        .background(Color(nsColor: .controlBackgroundColor)))
    host.sizingOptions = []
    host.frame = frame
    host.appearance = NSAppearance(named: .aqua)
    let content = NSView(frame: frame)
    content.addSubview(host)
    let window = NSWindow(
      contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = content
    defer { window.close() }

    func capture(_ path: [PrivacyRoute], name: String) async throws -> Data {
      model.path = path
      // Let SwiftUI process its navigation binding and commit the destination.
      try await Task.sleep(for: .milliseconds(250))
      host.layoutSubtreeIfNeeded()
      window.display()
      return try captureAppView(host, size: frame.size, name: "privacy-live-" + name)
    }

    var renders: Set<Data> = [try await capture([], name: "home")]
    for kind in PrivacyPermissionKind.allCases {
      let image = try await capture([.permission(kind)], name: "category-" + kind.rawValue)
      #expect(
        renders.insert(image).inserted, "Expected a distinct rendered destination for \(kind)")
    }
    for principal in try [
      fixture.client, fixture.package, fixture.server,
      #require(model.principal("plugin/bounded-package")),
      #require(model.principal("server/other-local")),
    ] {
      let image = try await capture(
        [.principal(principal.id)],
        name: "principal-" + principal.id.replacingOccurrences(of: "/", with: "-"))
      #expect(
        renders.insert(image).inserted,
        "Expected a distinct rendered destination for \(principal.id)")
    }

    let project = ObjectKey(.projects, fixture.worktreeID)
    let category = try row(project, principal: fixture.client, in: model, perspective: .category)
    let owner = try #require(model.sourceGrant(for: category))
    let source = PrivacyRoute.grantSource(
      principalID: owner.principalID, permission: owner.permission, objectID: owner.object?.id)
    let categoryPath: [PrivacyRoute] = [.permission(.projects), source]
    let principalPath: [PrivacyRoute] = [.principal(fixture.client.id), source]
    let unset = try await capture(categoryPath, name: "worktree-source-unset")
    #expect(renders.insert(unset).inserted)
    try await set(category, .granted(.readWrite), in: model)
    let allowed = try await capture(categoryPath, name: "worktree-source-granted")
    #expect(allowed != unset)
    let detail = try row(project, principal: fixture.client, in: model, perspective: .principal)
    #expect(model.sourceGrant(for: detail)?.id == owner.id)
    let allowedFromPrincipal = try await capture(principalPath, name: "principal-source-granted")
    #expect(allowedFromPrincipal == allowed)
    try await set(detail, .denied, in: model)
    #expect(
      try await capture(principalPath, name: "principal-source-revoked") != allowedFromPrincipal)
    #expect(
      try row(project, principal: fixture.client, in: model, perspective: .category).effectiveValue
        == .denied)

    let screen = ObjectKey(.screen)
    for principal in [fixture.package, fixture.server] {
      let name = principal.id.replacingOccurrences(of: "/", with: "-")
      let categoryPath: [PrivacyRoute] = [.permission(.screen)]
      let principalPath: [PrivacyRoute] = [.principal(principal.id)]
      let beforeGrant = try await capture(categoryPath, name: name + "-screen-ask")
      try await set(
        row(screen, principal: principal, in: model, perspective: .category), .granted(.allow),
        in: model)
      #expect(try await capture(categoryPath, name: name + "-screen-allowed") != beforeGrant)
      let beforeRevocation = try await capture(principalPath, name: name + "-screen-active")
      try await set(
        row(screen, principal: principal, in: model, perspective: .principal), .denied, in: model)
      #expect(try await capture(principalPath, name: name + "-screen-revoked") != beforeRevocation)
    }
  }

  private func verifyInheritedAndNetworkRows(
    principal: PrivacyPrincipal, fixture: Inventory
  ) async throws {
    let model = fixture.model
    for kind in [PrivacyPermissionKind.projects, .plugins, .mcpServers] {
      let concrete = try #require(
        fixture.objects.first { $0.kind == kind && $0.id != "*" && $0.id != fixture.worktreeID })
      let wildcard = ObjectKey(kind, "*")
      let allowed = PrivacyGrantValue.granted(try #require(kind.grantedValues.last))
      try await set(
        row(wildcard, principal: principal, in: model, perspective: .category), allowed, in: model)
      let detail = try row(concrete, principal: principal, in: model, perspective: .principal)
      await model.set(model.sourceGrant(for: detail) ?? detail, choice: .inherited)
      try requireSuccess(model)
      for perspective in Perspective.allCases {
        let inherited = try row(concrete, principal: principal, in: model, perspective: perspective)
        #expect(inherited.choice == .inherited && inherited.effectiveValue == allowed)
      }
      let siblings = fixture.objects.filter {
        $0.kind == kind && $0.id != "*" && $0 != concrete && $0.id != fixture.worktreeID
      }
      try await set(
        row(wildcard, principal: principal, in: model, perspective: .principal), .denied, in: model)
      #expect(
        try row(concrete, principal: principal, in: model, perspective: .category).effectiveValue
          == .denied)
      for sibling in siblings {
        #expect(
          try row(sibling, principal: principal, in: model, perspective: .category).effectiveValue
            == allowed)
      }
      try await set(detail, allowed, in: model)
    }

    let fallback = ObjectKey(.projects, "*")
    let source = ObjectKey(.projects, "project")
    let sibling = ObjectKey(.projects, "other-project")
    let worktree = ObjectKey(.projects, fixture.worktreeID)
    let siblingBefore = try row(sibling, principal: principal, in: model, perspective: .category)
    for perspective in Perspective.allCases {
      let inherited = try row(worktree, principal: principal, in: model, perspective: perspective)
      let allowed = PrivacyGrantValue.granted(.readWrite)
      for value in [PrivacyGrantValue.denied, allowed] {
        try await set(inherited, value, in: model)
        for side in Perspective.allCases {
          let derived = try row(worktree, principal: principal, in: model, perspective: side)
          #expect(derived.effectiveValue == value && !derived.isStored)
          #expect(
            try row(source, principal: principal, in: model, perspective: side).value == value)
        }
        expectUnchanged([siblingBefore], in: model)
      }
    }
    for (object, value, perspective) in [
      (fallback, PrivacyNetworkAccess.trusted, Perspective.category),
      (sibling, .full, .principal),
      (worktree, .custom(hosts: ["h14.invalid"], includesTrusted: false), .category),
      (source, .none, .principal),
    ] {
      let displayed = try row(object, principal: principal, in: model, perspective: perspective)
      let target = model.sourceGrant(for: displayed) ?? displayed
      try #require(
        await model.setNetwork(target, to: value),
        Comment(rawValue: model.failure ?? "Network edit failed"))
      for side in Perspective.allCases {
        let saved = try row(object, principal: principal, in: model, perspective: side)
        #expect(saved.network == value)
        let effective: PrivacyNetworkAccess =
          value == .trusted
          ? .custom(hosts: saved.trustedHosts.sorted(), includesTrusted: false) : value
        #expect(saved.effectiveNetwork == effective)
      }
    }
    for perspective in Perspective.allCases {
      #expect(
        try row(worktree, principal: principal, in: model, perspective: perspective)
          .effectiveNetwork == PrivacyNetworkAccess.none)
      #expect(
        try row(sibling, principal: principal, in: model, perspective: perspective).effectiveNetwork
          == .full)
      let defaultNetwork = try row(
        fallback, principal: principal, in: model, perspective: perspective)
      #expect(defaultNetwork.network == .trusted)
      #expect(
        defaultNetwork.effectiveNetwork
          == .custom(hosts: defaultNetwork.trustedHosts.sorted(), includesTrusted: false))
    }
  }

  private func verifyExecutionAndDeclarationBounds(_ fixture: Inventory) async throws {
    let model = fixture.model
    let bounded = try #require(model.principal("plugin/bounded-package"))
    let boundedProject = try row(
      ObjectKey(.projects, "project"), principal: bounded, in: model, perspective: .category)
    let boundedDetail = try row(
      ObjectKey(.projects, "project"), principal: bounded, in: model, perspective: .principal)
    #expect(boundedProject == boundedDetail)
    #expect(boundedProject.availableLevels == [.read] && model.canEdit(boundedProject))
    await model.set(boundedProject, to: .granted(.readWrite))
    #expect(model.failure != nil)
    model.failure = nil
    #expect(
      try row(
        ObjectKey(.projects, "project"), principal: bounded, in: model, perspective: .principal
      ).value == .ask)
    let undeclared = try row(
      ObjectKey(.filesAndFolders, FolderCategory.documents.rawValue), principal: bounded, in: model,
      perspective: .principal)
    #expect(undeclared.availableLevels.isEmpty && undeclared.effectiveValue == .denied)
    #expect(bounded.effectiveExecution == .fullAccessAllowed)
    await model.setExecution(bounded, .sandbox)
    #expect(model.failure != nil)
    model.failure = nil
    #expect(model.principal(bounded.id)?.effectiveExecution == .fullAccessAllowed)

    let profile = try #require(model.principal(GatewayProfileID.chatGPTOperate.rawValue))
    let serverProject = try row(
      ObjectKey(.projects, "project"), principal: fixture.server, in: model, perspective: .principal
    )
    #expect(await model.setNetwork(serverProject, to: .full))
    for principal in [profile, fixture.server] {
      for mode in [PrivacyPrincipal.Execution.fullAccessAllowed, .sandbox] {
        await model.setExecution(principal, mode)
        try requireSuccess(model)
        #expect(model.principal(principal.id)?.execution == mode)
        if principal.id == profile.id {
          #expect(model.principal(fixture.client.id)?.execution == mode)
          #expect(model.principal(fixture.client.id)?.effectiveExecution == .sandbox)
        } else {
          #expect(model.principal(principal.id)?.effectiveExecution == mode)
        }
        #expect(model.principal(fixture.package.id)?.effectiveExecution == .sandbox)
        #expect(model.principal(bounded.id)?.effectiveExecution == .fullAccessAllowed)
      }
    }
    #expect(
      try row(
        ObjectKey(.projects, "project"), principal: fixture.server, in: model,
        perspective: .category
      ).network == PrivacyNetworkAccess.none)
    for (editor, value, savedState) in [
      (boundedDetail, PrivacyGrantValue.denied, ComputerMCPPermissions.PermissionState.denied),
      (boundedProject, .granted(.read), .granted(.read)),
    ] {
      let previous = try #require(model.snapshot.reviewedProviders[bounded.id]?.approval)
      try await set(editor, value, in: model)
      let review = try #require(model.snapshot.reviewedProviders[bounded.id])
      let saved = try #require(review.approval)
      #expect(saved.permissions.state(for: .project("project")) == savedState)
      #expect(saved.fullAccessConsent == previous.fullAccessConsent)
      #expect(model.principal(bounded.id)?.effectiveExecution == nil)
      for perspective in Perspective.allCases {
        let projected = try row(
          ObjectKey(.projects, "project"), principal: bounded, in: model,
          perspective: perspective)
        #expect(projected.value == value && projected.effectiveValue == nil)
      }
      try await fixture.service.approveProvider(
        review, permissions: saved.permissions, execution: .fullAccessAllowed,
        sandboxSettings: .init())
      await model.refresh()
      try requireSuccess(model)
      #expect(model.principal(bounded.id)?.effectiveExecution == .fullAccessAllowed)
      #expect(
        model.snapshot.reviewedProviders[bounded.id]?.approval?.fullAccessConsent
          != previous.fullAccessConsent)
      for perspective in Perspective.allCases {
        #expect(
          try row(
            ObjectKey(.projects, "project"), principal: bounded, in: model,
            perspective: perspective
          ).effectiveValue == value)
      }
    }
    await model.revokeAll(bounded)
    try requireSuccess(model)
    #expect(model.principal(bounded.id)?.effectiveExecution == nil)
    #expect(model.principal(fixture.package.id)?.effectiveExecution == .sandbox)
    for perspective in Perspective.allCases {
      let revoked = try row(
        ObjectKey(.projects, "project"), principal: bounded, in: model, perspective: perspective)
      #expect(revoked.value == .granted(.read) && revoked.effectiveValue == nil)
      #expect(!model.canEdit(revoked))
    }
  }

  private enum Perspective: CaseIterable { case category, principal }

  private struct ObjectKey: Hashable {
    let kind: PrivacyPermissionKind
    let id: String?
    init(_ kind: PrivacyPermissionKind, _ id: String? = nil) {
      self.kind = kind
      self.id = id
    }
  }

  private func row(
    _ key: ObjectKey, principal: PrivacyPrincipal, in model: PrivacySecurityModel,
    perspective: Perspective
  ) throws -> PrivacyGrant {
    let rows =
      switch perspective {
      case .category: model.grants(for: key.kind, includingUnset: true)
      case .principal: model.grants(for: principal)
      }
    return try #require(
      rows.first {
        $0.principalID == principal.id && $0.permission == key.kind && $0.object?.id == key.id
      }, "\(principal.id)/\(key.kind.rawValue)/\(key.id ?? "") via \(perspective)")
  }

  private func set(_ row: PrivacyGrant, _ grant: PrivacyGrantValue, in model: PrivacySecurityModel)
    async throws
  {
    let edit = model.sourceGrant(for: row) ?? row
    await model.set(edit, to: grant)
    try requireSuccess(model)
    #expect(
      model.grant(
        principalID: edit.principalID, permission: edit.permission, objectID: edit.object?.id)?
        .value == grant, "\(edit.id)")
  }

  private func requireSuccess(_ model: PrivacySecurityModel) throws {
    try #require(model.failure == nil, Comment(rawValue: model.failure ?? ""))
  }

  private func expectUnchanged(_ before: [PrivacyGrant], in model: PrivacySecurityModel) {
    let current = Dictionary(uniqueKeysWithValues: model.snapshot.grants.map { ($0.id, $0) })
    let changed = before.filter { prior in
      guard let row = current[prior.id] else { return true }
      return row.value != prior.value || row.effectiveValue != prior.effectiveValue
        || row.isStored != prior.isStored || row.network != prior.network
        || row.effectiveNetwork != prior.effectiveNetwork
        || row.isNetworkStored != prior.isNetworkStored
    }.map(\.id)
    #expect(changed.isEmpty, "Unaffected rows changed: \(changed)")
  }

  private struct Inventory {
    let root: URL
    let model: PrivacySecurityModel
    let service: LivePrivacySecurityService
    let client: PrivacyPrincipal
    let package: PrivacyPrincipal
    let server: PrivacyPrincipal
    let worktreeID: String

    var objects: [ObjectKey] {
      PrivacyPermissionKind.allCases.filter { $0 != .fullAccess }.flatMap { kind in
        switch kind {
        case .projects: ["*", "project", "other-project", worktreeID].map { ObjectKey(kind, $0) }
        case .plugins: ["*", "h14-package", "bounded-package"].map { ObjectKey(kind, $0) }
        case .mcpServers: ["*", "h14-local", "other-local"].map { ObjectKey(kind, $0) }
        case .filesAndFolders: FolderCategory.allCases.map { ObjectKey(kind, $0.rawValue) }
        default: [ObjectKey(kind)]
        }
      }
    }
  }

  private func makeInventory() async throws -> Inventory {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    do {
      let (app, host, authority) = try makeApp(root: root)
      var configuration = try await host.activeConfiguration()
      configuration.builtin.enabled = ["git.worktree_add"]
      configuration.mcp.servers = ["h14-local", "other-local"].map {
        .init(id: $0, transport: .stdio, command: "/usr/bin/true")
      }
      _ = try await host.activateManifest(
        configuration.exportedTOML(), expectedDigest: host.configurationDigest())
      let sibling = root.appendingPathComponent("other-project")
      try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
      try await host.database.saveProject(
        .init(id: "other-project", displayName: "Other Project", rootPath: sibling.path))
      let profileID = GatewayProfileID.chatGPTOperate
      let worktreeID = try await makeWorktree(
        app: app, host: host, project: root.appendingPathComponent("project"), profileID: profileID)

      let package = try writePackage(root: root, id: "h14-package", bounded: false)
      let otherPackage = try writePackage(root: root, id: "bounded-package", bounded: true)
      let firstRegistration = try await app.changePlugins(
        .registerDevelopment(package), expectedRevision: 0)
      let registered = try await app.changePlugins(
        .registerDevelopment(otherPackage), expectedRevision: firstRegistration.state.revision)
      let service = LivePrivacySecurityService(controlPlane: app)
      let model = PrivacySecurityModel(service: service)
      await model.refresh()
      let unavailable = try #require(
        model.grant(principalID: "plugin/h14-package", permission: .screen, objectID: nil))
      #expect(unavailable.effectiveValue == nil && !model.canEdit(unavailable))
      for (id, mode) in [
        ("plugin/h14-package", PrivacyPrincipal.Execution.sandbox),
        ("plugin/bounded-package", .fullAccessAllowed), ("server/h14-local", .sandbox),
        ("server/other-local", .sandbox),
      ] {
        try await service.approveProvider(
          try #require(model.snapshot.reviewedProviders[id]), permissions: .init(), execution: mode,
          sandboxSettings: .init())
        await model.refresh()
        try requireSuccess(model)
        #expect(model.principal(id)?.providerAvailability == .active)
      }
      #expect(try await app.fetchPlugins().state.revision > registered.state.revision)
      let subject = try GatewayPermissionSubject(
        context: .init(
          caller: .secureTunnel, profileID: profileID, trustedPrincipalID: "h14-client"))
      let requirements = InvocationRequirements(actions: [
        .init(requirement: try .init(.screen, .access))
      ])
      guard
        case .requests = try authority.admit(
          subject: subject, tool: "screen.capture", projectID: nil, argumentsDigest: "h14-screen",
          requirements: requirements)
      else { throw H14CoverageError.expectedRequest }
      await model.refresh()
      let request = try #require(model.snapshot.requests.first { $0.tool == "screen.capture" })
      let client = request.principal
      #expect(client.sharedProfileID == profileID)
      #expect(request.sharedProfileName == model.principal(profileID.rawValue)?.name)
      return try Inventory(
        root: root, model: model, service: service, client: client,
        package: #require(model.principal("plugin/h14-package")),
        server: #require(model.principal("server/h14-local")), worktreeID: worktreeID)
    } catch {
      try? FileManager.default.removeItem(at: root)
      throw error
    }
  }

  private enum H14CoverageError: Error { case expectedRequest }

  private func writePackage(root: URL, id: String, bounded: Bool) throws -> URL {
    let package = root.appendingPathComponent(id)
    let skill = package.appendingPathComponent("skills/guide")
    try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
    try "---\nname: guide\ndescription: A local guide\n---\nRead only.".write(
      to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    let permissions =
      bounded
      ? [("project", "read")]
      : [
        ("project", "write"), ("screen", "allow"), ("desktop-control", "allow"),
        ("local-network", "allow"), ("plugin", "use"), ("mcp-server", "all"),
        ("machine", "allow"), ("unified-logs", "allow"), ("skills", "allow"),
      ]
    let declarations =
      permissions.map { id, access in
        "[[permissions]]\nid = '\(id)'\naccess = '\(access)'\npurpose = 'Cover the registered permission'"
      }
      + (bounded
        ? []
        : [
          PluginFolderCategory.desktop, .documents, .downloads, .iCloudDrive, .networkVolumes,
          .removableVolumes,
        ].map { folder in
          "[[permissions]]\nid = 'files-and-folders'\ncategory = '\(folder.rawValue)'\naccess = 'read'\npurpose = 'Cover the folder category'"
        })
    let manifest = """
      id = '\(id)'
      name = '\(id)'
      version = '1.0.0'
      plugin_api = 1
      \(declarations.joined(separator: "\n"))
      [sandbox]
      \(bounded ? "full_access = true" : "network = 'full'")
      purpose = 'Exercise the reviewed execution mode'
      [[skills]]
      id = 'guide'
      path = 'skills'
      """
    try manifest.write(
      to: package.appendingPathComponent(PluginManifest.filename), atomically: true, encoding: .utf8
    )
    return package
  }

  private func makeWorktree(
    app: LiveAppControlPlane, host: AppControlPlaneService, project: URL,
    profileID: GatewayProfileID
  ) async throws -> String {
    try "fixture".write(
      to: project.appendingPathComponent("value.txt"), atomically: true, encoding: .utf8)
    for arguments in [
      ["init", "--quiet"], ["add", "value.txt"],
      [
        "-c", "user.name=H14", "-c", "user.email=h14@example.invalid", "commit", "--quiet", "-m",
        "fixture",
      ],
    ] {
      let git = Process()
      git.executableURL = URL(fileURLWithPath: host.platform.gitExecutable)
      git.currentDirectoryURL = project
      git.environment = [
        "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
      ]
      git.arguments = arguments
      try git.run()
      git.waitUntilExit()
      try #require(git.terminationStatus == 0)
    }
    let opened = try await app.fetchProfilePermissionOptions(id: profileID)
    var grant = opened.grant
    try grant.permissions.set(.granted(.write), for: .project("project"))
    try await app.saveProfilePermissions(grant, reviewed: opened)
    let runtime = try await host.makeGatewaySessionRuntime(
      caller: .secureTunnel, profileID: profileID, trustedPrincipalID: "h14-client"
    ).gateway
    let result: JSONValue
    do {
      result = try await runtime.callToolForMCPAsync(
        name: "git.worktree_add",
        arguments: .object(["project_id": .string("project"), "name": .string("journey")]),
        context: .empty)
    } catch {
      await runtime.shutdown()
      throw error
    }
    await runtime.shutdown()
    try #require(result.objectValue?["isError"] != .bool(true), "\(result)")
    let id = try #require(
      result.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?["project_id"]?
        .stringValue)
    let current = try await app.fetchProfilePermissionOptions(id: profileID)
    var restored = current.grant
    restored.permissions = opened.grant.permissions
    try await app.saveProfilePermissions(restored, reviewed: current)
    return id
  }

  private func makeApp(root: URL) throws -> (
    LiveAppControlPlane, AppControlPlaneService, GatewayPermissionService
  ) {
    let directories = AppControlPlaneServiceDirectories(
      applicationSupport: root.appendingPathComponent("Support"),
      logs: root.appendingPathComponent("Logs"))
    try directories.prepare()

    let database = try GatewayDatabase(path: directories.database.path)
    _ = database.permissionStore(counter: TestAuthorizationEpochCounter())
    try database.bootstrapPermissionProfiles(
      GatewayProfileID.builtIns.map { GatewayConfiguration().profileGrant(for: $0) },
      declarations: [])
    let launcher = testExecutionLauncher()
    var platform = MacOSPlatform.services(launcher: launcher)
    platform.permissionPolicyReader = TestManagedPolicyReader()
    let permissionService = try database.permissionRuntime(platform: platform).service
    let owner = try GatewayPermissionOwner(
      context: .init(
        caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "h14-test-owner"),
      validate: {})
    let manifestStore = try AtomicManifestStore(
      manifestURL: directories.manifest, database: database,
      loader: GatewayManifestConfigurationLoader(
        database: database, applications: platform.applications))
    _ = try manifestStore.activate(manifest: DefaultGatewayConfiguration.manifest)
    let secrets = try KeychainSecretStore(
      service: "h14-package-fixture", accessGroup: "TESTTEAMID.com.showxu.computer-mcp.tests",
      adapter: MemoryKeychainAdapter())
    let host = AppControlPlaneService(
      directories: directories, database: database,
      permissionControl: PermissionControlService(service: permissionService, owner: { owner }),
      manifestStore: manifestStore, defaultManifest: DefaultGatewayConfiguration.manifest,
      secretStore: secrets,
      openAITunnelSupervisor: OpenAITunnelSupervisor(
        launcher: launcher, secretStore: secrets,
        executableSearchDirectories: platform.executableSearchDirectories,
        proxyResolver: FixedOpenAITunnelHTTPProxyResolver()),
      launchAtLoginController: H14NoLaunchAtLogin(),
      computerUsePermissionReader: FixedComputerUsePermissionReader(), platform: platform,
      bundledPlugins: .init(packages: [], issues: []))
    let app = LiveAppControlPlane(
      controlPlane: host,
      gatewayService: AppGatewayService.live(controlPlane: host, directories: directories),
      fileLogger: try AppFileLogger(directory: directories.logs))

    let project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
    try database.saveProject(.init(id: "project", displayName: "Project", rootPath: project.path))
    return (app, host, permissionService)
  }
}

private struct H14NoLaunchAtLogin: LaunchAtLoginControlling {
  func state() -> LaunchAtLoginState { .unavailable }
  func setEnabled(_ enabled: Bool) throws {}
}
