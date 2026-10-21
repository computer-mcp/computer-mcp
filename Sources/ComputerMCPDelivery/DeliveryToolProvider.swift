import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPToolKit
import Foundation

package final class DeliveryToolProvider: GatewayToolProvider, Sendable {
  package let id = "delivery"
  package let namespaces = ["delivery"]
  private let environment: ToolEnvironment
  private let io: DeliveryIO
  private let recoveryCancellation = DeliveryCancellation()
  private let recoveryTask: Task<Void, Never>?
  private static let execution = BlockingOperationExecutor(
    label: "computer-mcp.delivery", serial: false)

  package convenience init(environment: ToolEnvironment) {
    self.init(environment: environment, io: .init(), startsRecovery: true)
  }

  internal init(environment: ToolEnvironment, io: DeliveryIO, startsRecovery: Bool = true) {
    self.environment = environment
    self.io = io
    let cancellation = recoveryCancellation
    recoveryTask =
      startsRecovery && !environment.configuration.delivery.scopes.isEmpty
      ? Task {
        try? await Self.execution.perform {
          for scope in environment.configuration.delivery.scopes {
            if cancellation.isCancelled { return }
            do {
              let repository = try DeliveryRepository(
                scope: scope,
                workspace: environment.configuration.workspaceDirectory,
                git: DeliveryGit(environment: environment), io: io, cancellation: cancellation)
              try repository.withLock { try repository.recover() }
            } catch { continue }
          }
        }
      } : nil
  }

  package func definitions() -> [ToolDefinition] {
    Self.toolDefinitions(toolMeta: environment.workspaceScope.toolMeta).filter {
      environment.configuration.builtin.enabled.contains($0.tool.name)
    }
  }

  package func shutdown() async {
    recoveryCancellation.cancel()
    recoveryTask?.cancel()
    await recoveryTask?.value
  }

  package func callTool(_ invocation: ToolInvocation) throws -> JSONValue {
    try call(invocation, cancellation: .init())
  }

  package func callToolAsync(_ invocation: ToolInvocation) async throws -> JSONValue {
    try Task.checkCancellation()
    let cancellation = DeliveryCancellation()
    return try await withTaskCancellationHandler {
      try await Self.execution.perform { try self.call(invocation, cancellation: cancellation) }
    } onCancel: {
      cancellation.cancel()
    }
  }

  private func call(_ invocation: ToolInvocation, cancellation: DeliveryCancellation) throws
    -> JSONValue
  {
    guard ["delivery.scopes.list", "delivery.apply"].contains(invocation.name) else {
      throw GatewayToolError.unknownTool(invocation.name)
    }
    guard environment.configuration.builtin.enabled.contains(invocation.name) else {
      throw GatewayToolError.disabled("\(invocation.name) is disabled by configuration.")
    }
    if invocation.name == "delivery.scopes.list" {
      let scopes: [JSONValue] = environment.configuration.delivery.scopes.map { scope in
        .object([
          "id": .string(scope.id), "repository": .string(scope.repository),
          "paths": .array(scope.paths.map(JSONValue.string)),
          "default_branch": .string(scope.defaultBranch),
          "worktree_root": .string(scope.worktreeRoot),
          "sparse": .bool(scope.sparse), "mode": .string(scope.mode.rawValue),
        ])
      }
      return try textResult(.object(["scopes": .array(scopes)]))
    }
    do {
      let request = try DeliveryRequest(arguments: invocation.arguments)
      guard
        let scope = environment.configuration.delivery.scopes.first(where: {
          $0.id == request.scope
        })
      else {
        throw DeliveryFailure(
          reason: .scopeUnknown, detail: "Unknown delivery scope: \(request.scope)")
      }
      let repository = try DeliveryRepository(
        scope: scope, workspace: environment.configuration.workspaceDirectory,
        git: DeliveryGit(environment: environment), io: io, cancellation: cancellation)
      let (result, failure) = try repository.apply(request)
      return try result.envelope(failure: failure)
    } catch {
      let failure =
        (error as? DeliveryFailure)
        ?? DeliveryFailure(
          reason: .gitFailed, detail: boundedDeliveryText(error.localizedDescription))
      return try DeliveryResult(state: .aborted, reason: failure.reason).envelope(failure: failure)
    }
  }
}
