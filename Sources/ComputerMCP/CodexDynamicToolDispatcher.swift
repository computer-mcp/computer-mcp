import Foundation

final class CodexDynamicToolDispatcher: @unchecked Sendable {
  private weak var runtime: GatewayRuntime?
  private let lock = NSLock()

  func attach(_ runtime: GatewayRuntime) {
    lock.withLock {
      self.runtime = runtime
    }
  }

  func descriptor(
    named name: String,
    arguments: JSONValue,
    requestID: String,
    workspaceID: String?
  ) throws -> CapabilityDescriptor {
    guard !name.hasPrefix("codex.") else {
      throw GatewayToolError.disabled(
        "codex.app.dynamic_tool_recursive: Codex provider tools cannot call themselves."
      )
    }
    guard let runtime = lock.withLock({ runtime }) else {
      throw GatewayToolError.disabled(
        "codex.app.dynamic_tool_unavailable: The owning gateway runtime is unavailable."
      )
    }
    return try runtime.preflightCodexTool(
      name: name,
      arguments: arguments,
      requestID: requestID,
      workspaceID: workspaceID
    )
  }

  func execute(
    name: String,
    arguments: JSONValue,
    requestID: String,
    workspaceID: String?
  ) async throws -> JSONValue {
    guard !name.hasPrefix("codex.") else {
      throw GatewayToolError.disabled(
        "codex.app.dynamic_tool_recursive: Codex provider tools cannot call themselves."
      )
    }
    guard let runtime = lock.withLock({ runtime }) else {
      throw GatewayToolError.disabled(
        "codex.app.dynamic_tool_unavailable: The owning gateway runtime is unavailable."
      )
    }
    return try await runtime.callToolFromCodex(
      name: name,
      arguments: arguments,
      requestID: requestID,
      workspaceID: workspaceID
    )
  }
}
