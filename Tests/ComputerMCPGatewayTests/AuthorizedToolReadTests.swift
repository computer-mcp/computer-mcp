import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPToolKit
import ComputerMCPToolsProject
import ComputerMCPToolsSkills
import ComputerMCPToolsStructured
import Foundation
import Testing

@testable import ComputerMCPGateway

@Suite struct AuthorizedToolReadTests {
  @Test(arguments: ["json.read", "project.instructions", "skills.read_file"])
  func injectedCheckersReachTheReader(tool: String) throws {
    let fixture = try ToolReadFixture(tool: tool)
    try fixture.check(.opening, prechecks: tool.hasPrefix("skills.") ? 0 : 3, injected: true)
  }

  @Test(
    arguments: [
      "json.read", "jsonl.read", "toml.read", "yaml.read", "xml.read", "plist.read", "csv.read",
      "markdown.links", "markdown.tables", "markdown.section", "markdown.frontmatter",
      "markdown.link_check",
    ], ReadAttack.allCases)
  func structuredReadsRecheckAtUse(tool: String, attack: ReadAttack) throws {
    let fixture = try ToolReadFixture(tool: tool)
    try fixture.check(attack, prechecks: 3)
  }

  @Test(
    arguments: [
      "project.instructions", "project.todos", "project.env_files", "project.outline",
      "project.commands",
    ], ReadAttack.allCases)
  func projectReadsRecheckAtUse(tool: String, attack: ReadAttack) throws {
    let fixture = try ToolReadFixture(tool: tool)
    try fixture.check(attack, prechecks: 3)
  }

  @Test(
    arguments: [
      "skills.read", "skills.read_file", "skills.read_package", "skills.outline",
      "skills.link_check",
    ], [ReadAttack.opening, .revocation])
  func skillReadsRecheckAtUse(tool: String, attack: ReadAttack) throws {
    let fixture = try ToolReadFixture(tool: tool)
    let prechecks = ["skills.read", "skills.read_package"].contains(tool) ? 1 : 0
    try fixture.check(attack, prechecks: prechecks)
  }
}

enum ReadAttack: CaseIterable, Sendable {
  case afterPrecheck, opening, revocation

  func checkNumber(prechecks: Int) -> Int {
    switch self {
    case .afterPrecheck: prechecks
    case .opening: prechecks + 1
    case .revocation: prechecks + 3
    }
  }
}

private final class ToolReadFixture {
  let paths: DurablePathFixture
  let target: URL
  let deniedDirectory: URL
  let authorization: GatewayPathAccess
  let configuration: GatewayConfiguration
  let invocation: ToolInvocation

  init(tool: String) throws {
    paths = try DurablePathFixture()
    let skill = tool.hasPrefix("skills.")
    let parent = paths.project.appendingPathComponent(skill ? "skills/sample/content" : "content")
    let fileName: String
    switch tool {
    case "project.instructions": fileName = "AGENTS.md"
    case "project.commands": fileName = "package.json"
    case "project.env_files": fileName = ".env"
    case "project.outline", "project.todos": fileName = "sample.swift"
    case "skills.read": fileName = "SKILL.md"
    default:
      fileName =
        "sample."
        + (tool.hasPrefix("markdown.") || skill ? "md" : tool.components(separatedBy: ".")[0])
    }
    target = (tool == "skills.read" ? parent.deletingLastPathComponent() : parent)
      .appendingPathComponent(fileName)
    deniedDirectory = paths.root.appendingPathComponent("host/denied")
    for directory in [parent, deniedDirectory] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    if skill {
      try Self.content(tool: "skills.read", marker: "publicReadCanary").write(
        to: parent.deletingLastPathComponent().appendingPathComponent("SKILL.md"),
        atomically: true, encoding: .utf8)
    }
    try Self.content(tool: tool, marker: "publicReadCanary").write(
      to: target, atomically: true, encoding: .utf8)
    try Self.content(tool: tool, marker: "privateReadCanary").write(
      to: deniedDirectory.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
    let id = try paths.authorize(paths.project, operation: .read, once: false)
    authorization = GatewayPathAccess(store: paths.store, authorizationID: id)
    configuration = GatewayConfiguration(
      builtin: BuiltinConfig(enabled: [tool]),
      skills: SkillsConfig(
        enabled: skill,
        roots: [
          SkillRootConfig(id: "local", path: paths.project.appendingPathComponent("skills").path)
        ]),
      projectDirectory: paths.project)
    var arguments: [String: JSONValue] = [
      "path": .string(tool == "project.instructions" ? "content" : "content/" + fileName),
      "heading": .string("Heading"),
    ]
    if skill {
      arguments["name"] = .string("sample")
      if tool == "skills.read_package" { arguments["path"] = .string("content") }
    }
    invocation = .init(name: tool, arguments: .object(arguments), context: .empty)
  }

  private func provider(access: (any HostPathAccessChecking)? = nil) -> any GatewayToolProvider {
    let environment = ToolEnvironment(configuration: configuration, pathAccess: access)
    if invocation.name.hasPrefix("skills.") { return SkillsToolProvider(environment: environment) }
    if invocation.name.hasPrefix("project.") {
      return ProjectToolProvider(environment: environment)
    }
    return StructuredToolProvider(environment: environment)
  }

  func check(_ attack: ReadAttack, prechecks: Int, injected: Bool = false) throws {
    let baseline = try HostPathAccess.$current.withValue(authorization) {
      try provider().callTool(invocation)
    }
    #expect(try text(baseline).contains("publicReadCanary"))
    let parent = target.deletingLastPathComponent()
    let backup = parent.deletingLastPathComponent().appendingPathComponent("original-content")
    let access = ReadMutationAccess(
      base: authorization, target: target, trigger: attack.checkNumber(prechecks: prechecks)
    ) { [store = paths.store, principal = paths.principal, deniedDirectory] in
      if attack == .revocation {
        try store.transactionWithDatabase { _, ledger in
          _ = try ledger.revoke(
            principal: principal, permission: .project("project"), expectedRevision: ledger.revision
          )
        }
      } else {
        // Swapping the parent preserves the leaf's regular-file metadata from preflight.
        try FileManager.default.moveItem(at: parent, to: backup)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: deniedDirectory)
      }
    }
    do {
      let result = try HostPathAccess.$current.withValue(injected ? nil : access) {
        try provider(access: injected ? access : nil).callTool(invocation)
      }
      #expect(try !text(result).contains("privateReadCanary"))
      if attack == .revocation { #expect(try !text(result).contains("publicReadCanary")) }
    } catch {
      // Some inventory tools return per-file errors; others fail the entire call.
    }
    #expect(access.mutated)
    #expect(access.denied)
  }

  private func text(_ value: JSONValue) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
  }

  private static func content(tool: String, marker: String) -> String {
    switch tool {
    case "json.read", "jsonl.read": return "{\"value\":\"\(marker)\"}\n"
    case "toml.read": return "value = \"\(marker)\"\n"
    case "yaml.read": return "value: \(marker)\n"
    case "xml.read": return "<root>\(marker)</root>"
    case "plist.read":
      return
        "<plist version=\"1.0\"><dict><key>value</key><string>\(marker)</string></dict></plist>"
    case "csv.read": return "value\n\(marker)\n"
    case "project.commands": return "{\"scripts\":{\"\(marker)\":\"echo hello\"}}"
    case "project.env_files": return "\(marker)=hello\n"
    case "project.outline": return "struct \(marker) {}\n"
    case "project.todos": return "// TODO: \(marker)\n"
    default:
      return
        "---\nname: sample\ndescription: \(marker)\n---\n# Heading\n\n\(marker) [\(marker)](#heading)\n\n| Value | Kind |\n| --- | --- |\n| \(marker) | text |\n\n## \(marker)\n"
    }
  }
}

/// Injects a policy or filesystem change immediately after a successful check.
private final class ReadMutationAccess: HostPathAccessChecking, @unchecked Sendable {
  private let base: any HostPathAccessChecking
  private let target: URL
  private let trigger: Int
  private let action: @Sendable () throws -> Void
  private let lock = NSLock()
  private var count = 0
  private var didMutate = false
  private var didDeny = false
  var mutated: Bool { lock.withLock { didMutate } }
  var denied: Bool { lock.withLock { didDeny } }

  init(
    base: any HostPathAccessChecking, target: URL, trigger: Int,
    action: @escaping @Sendable () throws -> Void
  ) {
    self.base = base
    self.target = target.standardizedFileURL
    self.trigger = trigger
    self.action = action
  }

  func check(_ path: URL, operation: HostPathOperation) throws {
    do { try base.check(path, operation: operation) } catch {
      lock.withLock { didDeny = true }
      throw error
    }
    let mutate = lock.withLock {
      guard operation == .read, path.standardizedFileURL == target else { return false }
      count += 1
      return count == trigger
    }
    if mutate {
      try action()
      lock.withLock { didMutate = true }
    }
  }
}
