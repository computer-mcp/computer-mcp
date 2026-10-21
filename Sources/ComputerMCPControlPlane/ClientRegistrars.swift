import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPProcess
import Foundation

struct CodexClientRegistrar {
  func read(_ plan: RegistrationPlanContents, using service: ClientRegistrationService)
    -> RegistrationObservation
  {
    guard let executable = plan.clientExecutable else {
      return .init(state: .unavailable, entry: nil)
    }
    do {
      let result = try service.run(
        executable, ["mcp", "get", plan.serverName, "--json"], plan.environment)
      guard result.exitCode != nil else {
        return .init(state: .unreadable, entry: nil, uncertain: true)
      }
      guard !result.timedOut, !result.stdoutTruncated, !result.stderrTruncated else {
        return .init(state: .unreadable, entry: nil)
      }
      if result.exitCode == 1, result.stderr.contains("No MCP server named") {
        return .init(state: .notRegistered, entry: nil)
      }
      guard result.exitCode == 0,
        let entry = try? JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8)),
        entry.objectValue?["transport"]?.objectValue != nil
      else { return .init(state: .unreadable, entry: nil) }
      return service.observation(entry, for: plan)
    } catch { return .init(state: .unreadable, entry: nil) }
  }

  func actions(_ plan: RegistrationPlanContents) -> [ClientRegistrationAction] {
    guard let executable = plan.clientExecutable else { return [] }
    let arguments =
      plan.operation == .remove
      ? ["mcp", "remove", plan.serverName]
      : ["mcp", "add", plan.serverName, "--", plan.server.executable] + plan.server.arguments
    return [
      .init(
        step: plan.operation.rawValue, command: .init(executable: executable, arguments: arguments),
        file: nil, before: nil, after: nil)
    ]
  }
}

struct ClaudeCodeClientRegistrar {
  func read(_ plan: RegistrationPlanContents, using service: ClientRegistrationService)
    -> RegistrationObservation
  {
    do {
      return service.observation(
        try RegistrationJSONFile.read(plan.location.configurationFile).entry(
          named: plan.serverName), for: plan)
    } catch { return .init(state: .unreadable, entry: nil) }
  }

  func actions(_ plan: RegistrationPlanContents) -> [ClientRegistrationAction] {
    guard let executable = plan.clientExecutable else { return [] }
    var actions: [ClientRegistrationAction] = []
    if plan.operation == .remove || plan.observation.state == .different {
      actions.append(
        .init(
          step: "remove",
          command: .init(
            executable: executable,
            arguments: ["mcp", "remove", "--scope", "user", plan.serverName]), file: nil,
          before: nil, after: nil))
    }
    if plan.operation == .register {
      actions.append(
        .init(
          step: "add",
          command: .init(
            executable: executable,
            arguments: [
              "mcp", "add", "--scope", "user", plan.serverName, "--", plan.server.executable,
            ] + plan.server.arguments), file: nil, before: nil, after: nil))
    }
    return actions
  }

  func canRestore(_ entry: JSONValue?) -> Bool {
    guard let object = entry?.objectValue else { return false }
    let type = object["type"]?.stringValue ?? (object["command"] != nil ? "stdio" : "")
    switch type {
    case "stdio":
      return Set(object.keys).isSubset(of: ["type", "command", "args", "env"])
        && object["command"]?.stringValue != nil
        && (object["args"] == nil
          || object["args"]?.arrayValue?.allSatisfy { $0.stringValue != nil } == true)
        && stringMap(object["env"])
    case "http", "sse":
      return Set(object.keys).isSubset(of: ["type", "url", "headers"])
        && object["url"]?.stringValue != nil && stringMap(object["headers"])
    default: return false
    }
  }

  private func stringMap(_ value: JSONValue?) -> Bool {
    value == nil || value?.objectValue?.values.allSatisfy { $0.stringValue != nil } == true
  }

  func apply(_ plan: RegistrationPlanContents, using service: ClientRegistrationService)
    -> ClientRegistrationResult
  {
    var steps: [ClientRegistrationStep] = []
    for action in plan.actions {
      let step = service.execute(action, plan: plan)
      steps.append(step)
      if step.outcome == .uncertain {
        return service.result(
          .uncertain, plan: plan, steps: steps, observation: plan.observation, error: .uncertain)
      }
      if step.outcome != .succeeded { return reconcile(plan, using: service, steps: steps) }
    }
    let final = read(plan, using: service)
    return service.result(
      service.goalReached(plan, final) ? .succeeded : .failed, plan: plan, steps: steps,
      observation: final, error: service.goalReached(plan, final) ? nil : .processFailed)
  }

  private func reconcile(
    _ plan: RegistrationPlanContents, using service: ClientRegistrationService,
    steps: [ClientRegistrationStep]
  ) -> ClientRegistrationResult {
    var steps = steps
    var final = read(plan, using: service)
    if service.goalReached(plan, final) {
      return service.result(.succeeded, plan: plan, steps: steps, observation: final)
    }
    if plan.operation == .register, plan.observation.state == .different,
      final.state == .notRegistered, let old = plan.observation.entry,
      let executable = plan.clientExecutable
    {
      // A separate read gates recovery: another writer's entry must never be removed.
      final = read(plan, using: service)
      if final.state == .notRegistered {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(old), let payload = String(data: data, encoding: .utf8) {
          let step = service.executePrivate(
            step: "restore", executable: executable,
            arguments: ["mcp", "add-json", "--scope", "user", plan.serverName, payload], plan: plan)
          steps.append(step)
          if step.outcome == .uncertain {
            return service.result(
              .uncertain, plan: plan, steps: steps, observation: final, error: .uncertain)
          }
          final = read(plan, using: service)
        }
      }
    }
    let succeeded = service.goalReached(plan, final)
    return service.result(
      succeeded ? .succeeded : .failed, plan: plan, steps: steps, observation: final,
      error: succeeded ? nil : .processFailed)
  }
}

/// The host supplies application presence, running-state observation and the configuration path.
package struct ClaudeDesktopRegistration: Sendable {
  package let configurationFile: URL
  package let isInstalled: @Sendable () -> Bool
  package let isRunning: @Sendable () -> Bool

  package init(
    configurationFile: URL, isInstalled: @escaping @Sendable () -> Bool,
    isRunning: @escaping @Sendable () -> Bool
  ) {
    self.configurationFile = configurationFile
    self.isInstalled = isInstalled
    self.isRunning = isRunning
  }
}

struct ClaudeDesktopClientRegistrar {
  func read(_ plan: RegistrationPlanContents, using service: ClientRegistrationService)
    -> RegistrationObservation
  {
    do {
      return service.observation(
        try RegistrationJSONFile.read(plan.location.configurationFile).entry(
          named: plan.serverName), for: plan)
    } catch { return .init(state: .unreadable, entry: nil) }
  }

  func actions(_ plan: RegistrationPlanContents) -> [ClientRegistrationAction] {
    [
      .init(
        step: plan.operation.rawValue, command: nil, file: plan.location.configurationFile,
        before: plan.observation.entry.map { .init($0, client: .claudeDesktop) },
        after: plan.operation == .register ? plan.server : nil)
    ]
  }
}
