import ComputerMCPControlPlane
import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlugins

@Suite(.timeLimit(.minutes(1)))
struct GatewaySkillLibraryAdmissionTests {
  @Test func declaredGlobalLibraryWorksWithoutAccessToTheSelectedProject() async throws {
    let fixture = try SkillLibraryAdmissionFixture()
    try await fixture.run { fixture in
      let list = try result(await fixture.call("skills.list", ["root_id": .string("library")]))
      #expect(list["skills"]?.arrayValue?.map { $0.objectValue?["name"] } == [.string("guide")])
      let read = try result(await fixture.call("skills.read", fixture.read))
      #expect(read["content"]?.stringValue?.contains("Declared library guidance.") == true)
      let reportedPath = try #require(read["path"]?.stringValue)
      #expect(
        try ProjectPathResolver.resolve(
          reportedPath, relativeTo: URL(fileURLWithPath: "/")) == fixture.skill)
      #expect(try fixture.requestCount() == 0)
      let profile = try #require(fixture.database.profiles().first { $0.id == .chatGPTOperate })
      #expect(profile.permissions.state(for: .skills) == .granted(.access))
      #expect(profile.permissions.state(for: .project("selected")) == .notGranted)
      #expect(!profile.fullAccess)
    }
  }

  @Test func aLibraryInsideTheSelectedProjectStillRequestsProjectRead() async throws {
    let fixture = try SkillLibraryAdmissionFixture(insideProject: true)
    try await fixture.run { fixture in
      let metadata = try failure(await fixture.call("skills.read", fixture.read))
      #expect(metadata["code"] == .string("permission.required"))
      let requests = try #require(metadata["requests"]?.arrayValue)
      #expect(requests.count == 1)
      #expect(requests.first?.objectValue?["permission"] == .string("project"))
      #expect(requests.first?.objectValue?["object"] == .string("selected"))
      #expect(requests.first?.objectValue?["value"] == .string("read"))
      #expect(try fixture.requestCount() == 1)
    }
  }

  @Test(arguments: [false, true])
  func hostDataAndExplicitProjectDenialDoNotBecomeRequests(hostData: Bool) async throws {
    let fixture = try SkillLibraryAdmissionFixture(
      insideProject: true, hostData: hostData, projectDenied: !hostData)
    try await fixture.run { fixture in
      let metadata = try failure(await fixture.call("skills.read", fixture.read))
      #expect(metadata["code"] == .string("permission.denied"))
      #expect(metadata["request_ids"] == nil)
      #expect(try fixture.requestCount() == 0)
    }
  }

  @Test func callerSuppliedRootAndPurposeCannotImportLibraryAuthority() async throws {
    let fixture = try SkillLibraryAdmissionFixture()
    try await fixture.run { fixture in
      let generic = try failure(
        await fixture.call(
          "file.read",
          [
            "path": .string(fixture.skill.path), "root_id": .string("library"),
            "purpose": .string("skill-library"), "library_root": .string(fixture.library.path),
          ]))
      #expect(generic["code"] == .string("permission.denied"))
      #expect(generic["request_ids"] == nil)
      for arguments in [
        ["root_id": JSONValue.string(fixture.undeclared.path), "name": .string("private")],
        [
          "root_id": .string("library"), "name": .string("guide"),
          "path": .string(fixture.privateSkill.path),
        ],
      ] {
        let tool = arguments["path"] == nil ? "skills.read" : "skills.read_file"
        let denied = try await fixture.call(tool, arguments)
        _ = try failure(denied)
        #expect(!String(describing: denied).contains("Undeclared private guidance."))
      }
      #expect(try fixture.requestCount() == 0)
    }
  }

  @Test func aggregateLibraryProofSurvivesAnExactOneTimeSkillsRetry() async throws {
    let fixture = try SkillLibraryAdmissionFixture(aggregate: true, skillsGranted: false)
    try await fixture.run { fixture in
      let pending = try failure(await fixture.call("skills.list", [:]))
      #expect(pending["code"] == .string("permission.required"))
      let ids = try #require(pending["request_ids"]?.arrayValue)
      #expect(ids.count == 1)
      let owner = try GatewayPermissionOwner(
        context: .init(
          caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "skill-owner"),
        validate: {})
      let control = PermissionControlService(
        service: fixture.gateway.permissionRuntime.service, owner: { owner })
      for value in ids {
        let id = try #require(value.stringValue.flatMap(UUID.init(uuidString:)))
        _ = try control.answerRequest(
          id, answer: .onlyThisTime, expectedRevision: control.view().revision)
      }
      let report = try result(
        await fixture.call("skills.list", ["_permission_request_ids": .array(ids)]))
      #expect(
        Set(report["skills"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue } ?? [])
          == ["guide", "plugin-guide"])
      let subsequent = try failure(await fixture.call("skills.list", [:]))
      #expect(subsequent["code"] == .string("permission.required"))
    }
  }

  @Test func aggregateCallsIsolateDeniedPluginsAndProtectedArchiveRoots() async throws {
    let fixture = try SkillLibraryAdmissionFixture(aggregate: true)
    try await fixture.run { fixture in
      for (tool, arguments, field) in [
        ("skills.list", [:], "skills"),
        ("skills.search", ["query": JSONValue.string("guide")], "matches"),
      ] {
        let report = try result(await fixture.call(tool, arguments))
        #expect(
          Set(report[field]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue } ?? [])
            == ["guide", "plugin-guide"])
        try fixture.gateway.permissionRuntime.store.readWithDatabase { _, ledger in
          let authorization = try #require(
            ledger.authorizations.values.first {
              $0.invocation.tool == tool
            })
          #expect(
            Set(authorization.requirements.paths.map { $0.path.string })
              == [fixture.library.path, fixture.root.appendingPathComponent("plugin-library").path])
          #expect(authorization.requirements.paths.allSatisfy { $0.purpose != nil })
          #expect(
            authorization.requirements.actions.contains {
              $0.requirement.permission == .plugin("allowed-plugin")
            })
          #expect(
            !authorization.requirements.actions.contains {
              $0.requirement.permission == .plugin("denied-plugin")
                || $0.requirement.permission == .plugin("archive-plugin")
            })
        }
      }
      let roots = try result(await fixture.call("skills.roots", [:]))
      #expect(
        Set(roots["roots"]?.arrayValue?.compactMap { $0.objectValue?["id"]?.stringValue } ?? [])
          == ["library", "plugin-library"])
      let read = try result(await fixture.call("skills.read", ["name": .string("guide")]))
      #expect(read["content"]?.stringValue?.contains("Declared library guidance.") == true)
      let described = try result(
        await fixture.call("skills.describe", ["name": .string("plugin-guide")]))
      #expect(described["name"] == .string("plugin-guide"))
      for root in ["denied-library", "archive-library"] {
        let error = try failure(await fixture.call("skills.list", ["root_id": .string(root)]))
        #expect(error["code"] == .string("permission.denied"))
      }
      #expect(try fixture.requestCount() == 0)
    }
  }

  private func result(_ report: JSONValue) throws -> [String: JSONValue] {
    try #require(report.objectValue?["isError"] != .bool(true), "\(report)")
    return try #require(
      report.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue)
  }

  private func failure(_ report: JSONValue) throws -> [String: JSONValue] {
    try #require(report.objectValue?["isError"] == .bool(true), "\(report)")
    return try #require(
      report.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue)
  }
}

private struct SkillLibraryAdmissionFixture {
  let root: URL
  let library: URL
  let skill: URL
  let undeclared: URL
  let privateSkill: URL
  let database: GatewayDatabase
  let gateway: GatewayRuntime
  var read: [String: JSONValue] { ["root_id": .string("library"), "name": .string("guide")] }

  init(
    insideProject: Bool = false, hostData: Bool = false, projectDenied: Bool = false,
    aggregate: Bool = false, skillsGranted: Bool = true
  ) throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cm-skill-admission-\(UUID())")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    root = try ProjectPathResolver.canonicalProject(temporary)
    let selected = root.appendingPathComponent("selected")
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
    library = (insideProject ? selected : root).appendingPathComponent("library")
    skill = try Self.writeSkill("guide", body: "Declared library guidance.", in: library)
    undeclared = root.appendingPathComponent("undeclared")
    privateSkill = try Self.writeSkill(
      "private", body: "Undeclared private guidance.", in: undeclared)
    database = try GatewayDatabase(inMemory: ())
    var permissions = fixturePermissions(skillsGranted ? [.skills: .granted(.access)] : [:])
    if projectDenied { try permissions.set(.denied, for: .project("selected")) }
    var plugins: [ResolvedPlugin] = []
    let directories = AppControlPlaneServiceDirectories(
      applicationSupport: root.appendingPathComponent("host-support"),
      logs: root.appendingPathComponent("host-logs"))
    if aggregate {
      for (id, rootID, location, name, state) in [
        (
          "allowed-plugin", "plugin-library", root.appendingPathComponent("plugin-library"),
          "plugin-guide", PermissionState.granted(.use)
        ),
        (
          "denied-plugin", "denied-library", root.appendingPathComponent("denied-library"),
          "denied-guide", .denied
        ),
        (
          "archive-plugin", "archive-library",
          directories.plugins.appendingPathComponent("installation/package/skills"),
          "archive-guide", .granted(.use)
        ),
      ] {
        _ = try Self.writeSkill(name, body: "Plugin guidance.", in: location)
        try permissions.set(state, for: .plugin(id))
        plugins.append(
          .init(
            id: id, mcpServers: [], cliCommands: [],
            skillRoots: [.init(id: rootID, path: location.path)],
            origins: [
              .init(kind: .skills, id: rootID): .init(
                pluginID: id, componentID: "guidance", version: try PluginVersion("1.0.0"),
                source: .init(kind: .development, root: location))
            ],
            diagnostics: []))
      }
    }
    let grant = ProfileGrant(
      id: .chatGPTOperate, permissions: permissions, allowedCallers: [.localMCP])
    try database.saveProfile(grant)
    let project = ComputerMCPCore.RegisteredProject(
      id: "selected", displayName: "Selected", rootPath: selected.path)
    try database.saveProject(project)
    var platform = fixtureHostedPlatform()
    platform.permissionPolicyReader = TestManagedPolicyReader()
    if hostData { platform.hostDataPaths.insert(library) }
    if aggregate { platform.hostDataPaths.formUnion(directories.hostDataPaths) }
    gateway = try GatewayRuntime(
      configuration: .init(
        runtime: .init(caller: .localMCP, profileID: grant.id), profiles: [.init(grant: grant)],
        builtin: .init(enabled: ["file.read"]),
        skills: .init(enabled: true, roots: [.init(id: "library", path: library.path)]),
        projectDirectory: selected),
      context: .init(
        caller: .localMCP, profileID: grant.id, projectID: project.id,
        trustedPrincipalID: "skill-library-client"),
      database: database, registeredProjects: [project], platform: platform, plugins: plugins,
      bundledPlugins: .init(packages: [], issues: []))
  }

  private static func writeSkill(_ name: String, body: String, in library: URL) throws -> URL {
    let directory = library.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("SKILL.md")
    try "---\nname: \(name)\ndescription: Fixture skill.\n---\n\(body)\n".write(
      to: file, atomically: true, encoding: .utf8)
    return try ProjectPathResolver.resolve(file.path, relativeTo: URL(fileURLWithPath: "/"))
  }

  func call(_ tool: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
    try await gateway.callToolForMCPAsync(
      name: tool, arguments: .object(arguments), context: .empty)
  }

  func requestCount() throws -> Int {
    try gateway.permissionRuntime.store.readWithDatabase { _, ledger in ledger.requests.count }
  }

  func run(_ operation: (Self) async throws -> Void) async throws {
    do {
      try await operation(self)
      await gateway.shutdown()
      try FileManager.default.removeItem(at: root)
    } catch {
      await gateway.shutdown()
      try? FileManager.default.removeItem(at: root)
      throw error
    }
  }
}
