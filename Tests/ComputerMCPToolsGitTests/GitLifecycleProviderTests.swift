import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPToolsGit

struct GitLifecycleProviderTests {
  @Test func capabilityControlsCatalogAndDispatch() throws {
    let configuration = GatewayConfiguration.fixture(
      builtin: .init(enabled: Array(GitToolProvider.lifecycleTools)))
    let unavailable = GitToolProvider(environment: .init(configuration: configuration))
    #expect(try unavailable.definitions().isEmpty)
    #expect(throws: (any Error).self) {
      try unavailable.callTool(
        .init(name: "git.worktree_list", arguments: .object([:]), context: .empty))
    }
    let recorder = GitLifecycleRecorder()
    let provider = GitToolProvider(
      environment: .init(configuration: configuration, worktrees: recorder))
    #expect(Set(try provider.definitions().map(\.tool.name)) == GitToolProvider.lifecycleTools)
    #expect(!Set(try provider.definitions().map(\.tool.name)).contains("git.worktrees"))
    let definitions = try provider.definitions()
    let add = try #require(definitions.first { $0.tool.name == "git.worktree_add" })
    #expect(add.tool.inputSchema.objectValue?["required"] == .array([.string("name")]))
    #expect(
      add.tool.inputSchema.objectValue?["properties"]?.objectValue?["name"]?.objectValue?[
        "maxLength"] == .number(48))
    for definition in definitions {
      #expect(definition.capability.hostOperation == .worktreeLifecycle)
      #expect(!definition.capability.requirement.requiresFullAccess)
    }
  }

  @Test func parsedInputsReachLifecycleServiceWithoutAConfiguredExecutable() throws {
    let recorder = GitLifecycleRecorder()
    let provider = GitToolProvider(
      environment: .init(
        configuration: .fixture(
          builtin: .init(enabled: Array(GitToolProvider.lifecycleTools))), worktrees: recorder))
    let calls: [(String, [String: JSONValue])] = [
      ("git.worktree_add", ["name": .string("topic")]),
      ("git.worktree_list", [:]), ("git.worktree_remove", [:]),
      ("git.merge", ["branch": .string("worktree/topic")]),
      ("git.branch_delete", ["name": .string("worktree/topic")]),
      (
        "git.branch_delete",
        [
          "name": .string("worktree/topic"), "dry_run": .bool(false),
          "confirm_delete": .bool(true), "force": .bool(true),
        ]
      ),
    ]
    for (name, arguments) in calls {
      _ = try provider.callTool(.init(name: name, arguments: .object(arguments), context: .empty))
    }
    let operations = recorder.operations
    #expect(operations.count == 6)
    guard case .add("topic", nil, nil) = operations[0],
      case .remove(false) = operations[2],
      case .deleteBranch("worktree/topic", false, true, false) = operations[4],
      case .deleteBranch("worktree/topic", true, false, true) = operations[5]
    else {
      Issue.record("Lifecycle defaults changed")
      return
    }
    #expect(throws: (any Error).self) {
      try provider.callTool(
        .init(
          name: "git.branch_delete",
          arguments: .object(["name": .string("topic"), "dry_run": .bool(false)]), context: .empty))
    }
    #expect(recorder.operations.count == 6)
  }
}

final class GitLifecycleRecorder: GitWorktreeServing, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [GitWorktreeOperation] = []
  var operations: [GitWorktreeOperation] { lock.withLock { values } }
  func call(_ operation: GitWorktreeOperation) throws -> JSONValue {
    lock.withLock { values.append(operation) }
    return .object(["terminationWarnings": .array([])])
  }
}
