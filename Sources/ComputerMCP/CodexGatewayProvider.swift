import Foundation

struct CodexGatewayProvider: GatewayToolProvider, Sendable {
  let id = "codex"

  private let configuration: CodexConfig
  private let appServer: (any CodexAppServerRuntimeProtocol)?
  private let exec: (any CodexExecRuntimeProtocol)?
  private let mcp: (any CodexMCPRuntimeProtocol)?
  private let owner: CodexRuntimeOwner?
  private let database: GatewayDatabase?
  private let tools: [MCPTool]

  init(
    configuration: CodexConfig,
    appServer: (any CodexAppServerRuntimeProtocol)?,
    exec: (any CodexExecRuntimeProtocol)?,
    mcp: (any CodexMCPRuntimeProtocol)?,
    owner: CodexRuntimeOwner? = nil,
    database: GatewayDatabase? = nil
  ) {
    self.configuration = configuration
    self.appServer = appServer
    self.exec = exec
    self.mcp = mcp
    self.owner = owner
    self.database = database
    tools = Self.makeTools(
      appServerEnabled: appServer != nil,
      execEnabled: exec != nil,
      mcpEnabled: mcp != nil
    )
  }

  init(
    configuration: CodexConfig,
    workspaceURL: URL,
    owner: CodexRuntimeOwner? = nil,
    database: GatewayDatabase? = nil,
    dynamicToolDispatcher: CodexDynamicToolDispatcher? = nil,
    maxOutputBytes: Int = 1_048_576
  ) {
    self.init(
      configuration: configuration,
      appServer: configuration.appServerEnabled
        ? LiveCodexAppServerRuntime(
          configuration: configuration,
          workspaceURL: workspaceURL,
          owner: owner,
          database: database,
          dynamicToolDispatcher: dynamicToolDispatcher,
          maxOutputBytes: maxOutputBytes
        )
        : nil,
      exec: configuration.execEnabled
        ? LiveCodexExecRuntime(
          configuration: configuration,
          workspaceURL: workspaceURL,
          maxOutputBytes: maxOutputBytes
        )
        : nil,
      mcp: configuration.mcpEnabled
        ? LiveCodexMCPRuntime(
          configuration: configuration,
          workspaceURL: workspaceURL,
          maxOutputBytes: maxOutputBytes
        )
        : nil,
      owner: owner,
      database: database
    )
  }

  func listTools() throws -> [MCPTool] {
    tools
  }

  func capability(for tool: MCPTool) -> CapabilityDescriptor {
    let readOnly = Self.readOnlyToolNames.contains(tool.name)
    let risk: CapabilityRisk =
      tool.name == "codex.worktree.remove.perform"
      ? .destructive
      : (readOnly ? .readOnly : .workspaceWrite)
    return CapabilityDescriptor(
      id: tool.name,
      risk: risk,
      workspaceRequirement: .required,
      localOnly: false,
      usesNetwork: true
    )
  }

  func callTool(name: String, arguments: JSONValue?) throws -> JSONValue {
    throw GatewayToolError.executionFailed(
      "codex.async_required: Codex tools require the asynchronous MCP execution path."
    )
  }

  func callToolAsync(name: String, arguments: JSONValue?) async throws -> JSONValue {
    let object = arguments?.objectValue ?? [:]
    let result: JSONValue
    do {
      switch name {
      case "codex.app.status":
        result = try await tryAppServer().status()
      case "codex.diagnostics.snapshot":
        result = try await CodexOperationalDiagnostics.snapshot(
          database: database,
          owner: owner,
          limit: try Self.boundedInt("limit", in: object, default: 100, range: 1...1_000)
        )
      case "codex.app.runtimes.list":
        result = await CodexRuntimeDirectory.shared.statuses(workspaceID: owner?.workspaceID)
      case "codex.app.runtimes.history":
        let records =
          try database?.codexRuntimeLeases(limit: 1_000).filter {
            $0.owner?.workspaceID == owner?.workspaceID
          } ?? []
        result = .object(["runtimes": .array(records.map(\.json))])
      case "codex.app.runtimes.cleanup.preview":
        result = try CodexRuntimeMaintenance.preview(
          database: database,
          workspaceID: owner?.workspaceID
        )
      case "codex.app.runtimes.cleanup.perform":
        guard object["confirm_cleanup"]?.boolValue == true else {
          throw GatewayToolError.invalidArguments(
            "codex.app.runtime_cleanup_confirmation_required: Set confirm_cleanup=true after reviewing the cleanup preview."
          )
        }
        result = try await CodexRuntimeMaintenance.cleanup(
          database: database,
          workspaceID: owner?.workspaceID
        )
      case "codex.app.runtimes.inspect":
        let runtimeID = try Self.requiredString("runtime_id", in: object)
        guard
          let runtime = CodexRuntimeDirectory.shared.runtime(
            id: runtimeID,
            workspaceID: owner?.workspaceID
          )
        else {
          throw GatewayToolError.invalidArguments(
            "codex.app.runtime_unknown: Unknown Computer MCP runtime '\(runtimeID)'."
          )
        }
        result = await runtime.status()
      case "codex.app.runtimes.stop":
        let runtimeID = try Self.requiredString("runtime_id", in: object)
        guard
          let runtime = CodexRuntimeDirectory.shared.runtime(
            id: runtimeID,
            workspaceID: owner?.workspaceID
          )
        else {
          throw GatewayToolError.invalidArguments(
            "codex.app.runtime_unknown: Unknown Computer MCP runtime '\(runtimeID)'."
          )
        }
        await runtime.shutdown()
        result = await runtime.status()
      case "codex.app.methods.list":
        result = Self.appMethodsList()
      case "codex.app.methods.describe":
        result = try Self.appMethodDescription(
          method: Self.requiredString("method", in: object)
        )
      case "codex.app.methods.call":
        let method = try Self.requiredString("method", in: object)
        let params = object["params"]
        if method == "turn/start" {
          guard let threadID = params?.objectValue?["threadId"]?.stringValue else {
            throw GatewayToolError.invalidArguments(
              "codex.app.thread_id_required: turn/start requires a non-empty threadId."
            )
          }
          try CodexWorktreeLeaseManager.validate(
            database: database,
            workspaceID: owner?.workspaceID,
            leaseID: nil,
            threadID: threadID
          )
        }
        result = try await tryAppServer().call(
          method: method,
          params: params
        )
      case "codex.app.thread.start":
        result = try await tryAppServer().call(
          method: "thread/start",
          params: try Self.threadStartParams(in: object)
        )
      case "codex.app.thread.reclaim":
        result = try await tryAppServer().call(
          method: "thread/resume",
          params: try Self.threadResumeParams(in: object)
        )
      case "codex.app.thread.list":
        result = try await tryAppServer().call(
          method: "thread/list",
          params: try Self.threadListParams(in: object)
        )
      case "codex.app.thread.loaded.list":
        result = try await tryAppServer().call(
          method: "thread/loaded/list",
          params: try Self.threadLoadedListParams(in: object)
        )
      case "codex.app.thread.read":
        result = try await tryAppServer().call(
          method: "thread/read",
          params: try Self.threadReadParams(in: object)
        )
      case "codex.app.thread.fork":
        result = try await tryAppServer().call(
          method: "thread/fork",
          params: try Self.threadForkParams(in: object)
        )
      case "codex.app.thread.release":
        result = try await tryAppServer().call(
          method: "thread/unsubscribe",
          params: try Self.threadIDParams(in: object)
        )
      case "codex.app.handoff.diagnose":
        result = await CodexThreadHandoffDiagnostics.diagnose(
          threadID: try Self.requiredIdentifier("thread_id", in: object),
          observedError: try Self.optionalString("observed_error", in: object),
          workspaceID: owner?.workspaceID,
          database: database
        )
      case "codex.app.goal.get":
        result = try await tryAppServer().call(
          method: "thread/goal/get",
          params: try Self.threadIDParams(in: object)
        )
      case "codex.app.goal.set":
        result = try await tryAppServer().call(
          method: "thread/goal/set",
          params: try Self.goalSetParams(in: object)
        )
      case "codex.app.goal.clear":
        result = try await tryAppServer().call(
          method: "thread/goal/clear",
          params: try Self.threadIDParams(in: object)
        )
      case "codex.app.runtime.stop":
        let runtime = try tryAppServer()
        await runtime.shutdown()
        result = await runtime.status()
      case "codex.app.turn.start":
        result = try await tryAppServer().call(
          method: "turn/start",
          params: try turnStartParams(in: object)
        )
      case "codex.app.turn.steer":
        result = try await tryAppServer().call(
          method: "turn/steer",
          params: try Self.turnSteerParams(in: object)
        )
      case "codex.app.turn.interrupt":
        result = try await tryAppServer().call(
          method: "turn/interrupt",
          params: try Self.turnInterruptParams(in: object)
        )
      case "codex.app.review.start":
        result = try await tryAppServer().call(
          method: "review/start",
          params: try Self.reviewStartParams(in: object)
        )
      case "codex.app.models.list":
        result = try await tryAppServer().call(
          method: "model/list",
          params: try Self.modelListParams(in: object)
        )
      case "codex.app.skills.list":
        result = try await tryAppServer().call(
          method: "skills/list",
          params: try Self.skillsListParams(in: object)
        )
      case "codex.app.apps.list":
        result = try await tryAppServer().call(
          method: "app/list",
          params: try Self.appsListParams(in: object)
        )
      case "codex.app.events.read":
        result = try await tryAppServer().events(
          afterCursor: try Self.nonnegativeInt("after_cursor", in: object, default: 0),
          maxResults: try Self.boundedInt(
            "max_results",
            in: object,
            default: 100,
            range: 1...1_000
          )
        )
      case "codex.app.requests.list":
        result = try await tryAppServer().pendingRequests()
      case "codex.app.requests.respond":
        result = try await tryAppServer().respond(
          requestID: Self.requiredString("request_id", in: object),
          response: object["response"] ?? .object([:])
        )
      case "codex.app.approvals.list":
        result = try await tryAppServer().approvals(
          state: try Self.optionalString("state", in: object),
          limit: try Self.boundedInt("limit", in: object, default: 100, range: 1...1_000)
        )
      case "codex.app.approvals.read":
        result = try await tryAppServer().approval(
          id: Self.requiredIdentifier("approval_id", in: object)
        )
      case "codex.app.approvals.respond":
        result = try await tryAppServer().respondToApproval(
          id: Self.requiredIdentifier("approval_id", in: object),
          decision: Self.requiredString("decision", in: object)
        )

      case "codex.run.create":
        result = try CodexOrchestrationEngine.create(
          database: database,
          workspaceID: owner?.workspaceID,
          workspacePath: try selectedWorkspacePath(),
          parentRunID: try Self.optionalString("parent_run_id", in: object),
          threadID: try Self.optionalString("thread_id", in: object),
          officialGoalLinked: try Self.optionalBool("official_goal_linked", in: object) ?? false,
          objective: try Self.requiredString("objective", in: object),
          acceptedScope: try Self.requiredStringArray("accepted_scope", in: object),
          phase: try Self.optionalString("phase", in: object) ?? "delivery",
          acceptanceCriteria: try Self.requiredStringArray(
            "acceptance_criteria",
            in: object
          ),
          requiredEvidenceKinds: try Self.optionalStringArray(
            "required_evidence_kinds",
            in: object
          ) ?? ["build", "git_status", "test"],
          budget: CodexRunBudget(
            maxTurns: try Self.boundedInt(
              "max_turns", in: object, default: 100, range: 1...10_000
            ),
            maxDurationSeconds: try Self.boundedInt(
              "max_duration_seconds", in: object, default: 86_400, range: 60...2_592_000
            ),
            maxNoProgressSeconds: try Self.boundedInt(
              "max_no_progress_seconds", in: object, default: 900, range: 30...86_400
            ),
            maxRepeatedFailures: try Self.boundedInt(
              "max_repeated_failures", in: object, default: 3, range: 1...100
            )
          )
        ).json
      case "codex.run.list":
        result = .object([
          "runs": .array(
            try database?.codexOrchestrationRuns(
              workspaceID: owner?.workspaceID,
              limit: try Self.boundedInt("limit", in: object, default: 100, range: 1...1_000)
            ).map(\.json) ?? []
          )
        ])
      case "codex.run.read":
        result = try selectedRun(id: Self.requiredIdentifier("run_id", in: object)).json
      case "codex.run.record":
        result = try CodexOrchestrationEngine.record(
          database: database,
          workspaceID: owner?.workspaceID,
          runID: Self.requiredIdentifier("run_id", in: object),
          expectedRevision: try Self.requiredInt("expected_revision", in: object),
          event: try Self.runEvent(in: object)
        ).json
      case "codex.run.evaluate":
        result = try CodexOrchestrationEngine.evaluate(
          database: database,
          workspaceID: owner?.workspaceID,
          runID: Self.requiredIdentifier("run_id", in: object),
          expectedRevision: try Self.requiredInt("expected_revision", in: object)
        ).json
      case "codex.run.accept":
        result = try CodexOrchestrationEngine.accept(
          database: database,
          workspaceID: owner?.workspaceID,
          runID: Self.requiredIdentifier("run_id", in: object),
          expectedRevision: try Self.requiredInt("expected_revision", in: object),
          worktreeClean: try Self.requiredBool("worktree_clean", in: object)
        ).json
      case "codex.run.transition":
        result = try CodexOrchestrationEngine.transition(
          database: database,
          workspaceID: owner?.workspaceID,
          runID: Self.requiredIdentifier("run_id", in: object),
          expectedRevision: try Self.requiredInt("expected_revision", in: object),
          action: Self.requiredString("action", in: object),
          reason: try Self.optionalString("reason", in: object)
        ).json
      case "codex.run.reconcile":
        result = try CodexOrchestrationEngine.reconcileChild(
          database: database,
          workspaceID: owner?.workspaceID,
          parentRunID: Self.requiredString("parent_run_id", in: object),
          expectedRevision: try Self.requiredInt("expected_revision", in: object),
          childRunID: Self.requiredString("child_run_id", in: object),
          childEvidenceIDs: try Self.requiredStringArray("child_evidence_ids", in: object),
          criterionID: Self.requiredString("criterion_id", in: object),
          acceptCriterion: try Self.optionalBool("accept_criterion", in: object) ?? false
        ).json
      case "codex.worktree.leases.acquire":
        let modeRaw = try Self.optionalString("mode", in: object) ?? "exclusive"
        guard let mode = CodexWorktreeLeaseMode(rawValue: modeRaw) else {
          throw CodexWorktreeLeaseError.invalid("unsupported mode '\(modeRaw)'")
        }
        result = try CodexWorktreeLeaseManager.acquire(
          database: database,
          workspaceID: owner?.workspaceID,
          agentID: Self.requiredString("agent_id", in: object),
          threadID: try Self.optionalString("thread_id", in: object),
          runID: try Self.optionalString("run_id", in: object),
          parentLeaseID: try Self.optionalString("parent_lease_id", in: object),
          branch: try Self.optionalString("branch", in: object),
          mode: mode,
          ttlSeconds: try Self.boundedInt(
            "ttl_seconds", in: object, default: 900, range: 30...86_400
          ),
          liveRuntimeStatus: await CodexRuntimeDirectory.shared.statuses(
            workspaceID: owner?.workspaceID
          )
        ).json
      case "codex.worktree.leases.list":
        result = .object([
          "leases": .array(
            try database?.codexWorktreeLeases(
              workspaceID: owner?.workspaceID,
              limit: try Self.boundedInt("limit", in: object, default: 100, range: 1...1_000)
            ).map(\.json) ?? []
          )
        ])
      case "codex.worktree.leases.read":
        result = try selectedLease(id: Self.requiredIdentifier("lease_id", in: object)).json
      case "codex.worktree.leases.heartbeat":
        result = try CodexWorktreeLeaseManager.heartbeat(
          database: database,
          workspaceID: owner?.workspaceID,
          leaseID: Self.requiredIdentifier("lease_id", in: object),
          expectedRevision: try Self.requiredInt("expected_revision", in: object),
          ttlSeconds: try Self.boundedInt(
            "ttl_seconds", in: object, default: 900, range: 30...86_400
          )
        ).json
      case "codex.worktree.leases.release":
        result = try CodexWorktreeLeaseManager.release(
          database: database,
          workspaceID: owner?.workspaceID,
          leaseID: Self.requiredIdentifier("lease_id", in: object),
          expectedRevision: try Self.requiredInt("expected_revision", in: object),
          reason: Self.requiredString("reason", in: object)
        ).json
      case "codex.worktree.leases.cleanup.preview":
        result = try CodexWorktreeLeaseManager.cleanupExpired(
          database: database,
          workspaceID: owner?.workspaceID,
          perform: false
        )
      case "codex.worktree.leases.cleanup.perform":
        guard try Self.requiredBool("confirm_cleanup", in: object) else {
          throw CodexWorktreeLeaseError.invalid(
            "confirm_cleanup must be true after reviewing the preview"
          )
        }
        result = try CodexWorktreeLeaseManager.cleanupExpired(
          database: database,
          workspaceID: owner?.workspaceID,
          perform: true
        )
      case "codex.worktree.managed.list":
        result = .object([
          "worktrees": .array(
            try database?.codexManagedWorktrees(
              sourceWorkspaceID: owner?.workspaceID,
              limit: try Self.boundedInt("limit", in: object, default: 100, range: 1...1_000)
            ).map(\.json) ?? []
          )
        ])
      case "codex.worktree.managed.read":
        result = try selectedManagedWorktree(
          id: Self.requiredString("managed_worktree_id", in: object)
        ).json
      case "codex.worktree.provision.plan":
        result = try CodexManagedWorktreeManager.planProvision(
          database: database,
          sourceWorkspaceID: owner?.workspaceID,
          profileID: owner?.profileID,
          caller: owner?.caller,
          agentID: Self.requiredString("agent_id", in: object),
          threadID: try Self.optionalString("thread_id", in: object),
          runID: try Self.optionalString("run_id", in: object),
          parentLeaseID: Self.requiredString("parent_lease_id", in: object),
          branch: Self.requiredString("branch", in: object),
          startPoint: try Self.optionalString("start_point", in: object) ?? "HEAD",
          ttlSeconds: try Self.boundedInt(
            "ttl_seconds", in: object, default: 900, range: 30...86_400
          )
        ).json
      case "codex.worktree.provision.perform":
        result = try CodexManagedWorktreeManager.performProvision(
          database: database,
          sourceWorkspaceID: owner?.workspaceID,
          planID: Self.requiredString("plan_id", in: object),
          expectedRevision: try Self.requiredInt("expected_revision", in: object),
          confirmProvision: try Self.requiredBool("confirm_provision", in: object)
        ).json
      case "codex.worktree.remove.plan":
        let managed = try selectedManagedWorktree(
          id: Self.requiredString("managed_worktree_id", in: object)
        )
        result = try CodexManagedWorktreeManager.planRemoval(
          database: database,
          sourceWorkspaceID: owner?.workspaceID,
          managedWorktreeID: managed.id,
          liveRuntimeStatus: await CodexRuntimeDirectory.shared.statuses(
            workspaceID: managed.workspaceID
          )
        ).json
      case "codex.worktree.remove.perform":
        let managed = try selectedManagedWorktree(
          id: Self.requiredString("managed_worktree_id", in: object)
        )
        result = try CodexManagedWorktreeManager.performRemoval(
          database: database,
          sourceWorkspaceID: owner?.workspaceID,
          managedWorktreeID: managed.id,
          expectedRevision: try Self.requiredInt("expected_revision", in: object),
          confirmRemoval: try Self.requiredBool("confirm_remove", in: object),
          liveRuntimeStatus: await CodexRuntimeDirectory.shared.statuses(
            workspaceID: managed.workspaceID
          )
        ).json

      case "codex.exec.start":
        result = try await tryExec().start(
          prompt: Self.requiredString("prompt", in: object),
          model: Self.optionalString("model", in: object)
        )
      case "codex.exec.resume":
        result = try await tryExec().resume(
          upstreamSessionID: Self.requiredString("upstream_session_id", in: object),
          prompt: Self.optionalString("prompt", in: object)
        )
      case "codex.exec.list":
        result = try await tryExec().list()
      case "codex.exec.events":
        result = try await tryExec().events(
          sessionID: Self.requiredIdentifier("session_id", in: object),
          afterCursor: Self.nonnegativeInt("after_cursor", in: object, default: 0),
          maxResults: Self.boundedInt(
            "max_results",
            in: object,
            default: 100,
            range: 1...1_000
          )
        )
      case "codex.exec.result":
        result = try await tryExec().result(
          sessionID: Self.requiredIdentifier("session_id", in: object)
        )
      case "codex.exec.cancel":
        result = try await tryExec().cancel(
          sessionID: Self.requiredIdentifier("session_id", in: object)
        )

      case "codex.mcp.status":
        result = try await tryMCP().status()
      case "codex.mcp.tools.list":
        result = try await tryMCP().tools()
      case "codex.mcp.run":
        result = try await tryMCP().run(
          prompt: Self.requiredString("prompt", in: object),
          model: Self.optionalString("model", in: object)
        )
      case "codex.mcp.reply":
        result = try await tryMCP().reply(
          threadID: Self.requiredIdentifier("thread_id", in: object),
          prompt: Self.requiredString("prompt", in: object)
        )
      case "codex.mcp.calls.list":
        result = try await tryMCP().calls()
      case "codex.mcp.events":
        result = try await tryMCP().events(
          callID: Self.requiredIdentifier("call_id", in: object),
          afterCursor: Self.nonnegativeInt("after_cursor", in: object, default: 0),
          maxResults: Self.boundedInt(
            "max_results",
            in: object,
            default: 100,
            range: 1...1_000
          )
        )
      case "codex.mcp.result":
        result = try await tryMCP().result(
          callID: Self.requiredIdentifier("call_id", in: object)
        )
      case "codex.mcp.approvals.list":
        result = try await tryMCP().pendingApprovals(
          callID: Self.requiredIdentifier("call_id", in: object)
        )
      case "codex.mcp.approval.respond":
        result = try await tryMCP().respondToApproval(
          callID: Self.requiredIdentifier("call_id", in: object),
          approvalID: Self.requiredIdentifier("approval_id", in: object),
          decision: Self.requiredString("decision", in: object)
        )
      case "codex.mcp.cancel":
        result = try await tryMCP().cancel(
          callID: Self.requiredIdentifier("call_id", in: object)
        )
      default:
        throw GatewayToolError.unknownTool(name)
      }
    } catch let error as GatewayToolError {
      throw error
    } catch {
      throw GatewayToolError.executionFailed(
        CodexApprovalRedactor.redactString(error.localizedDescription)
      )
    }
    return try Self.resultEnvelope(result)
  }

  func shutdown() async {
    await appServer?.shutdown()
    await exec?.shutdown()
    await mcp?.shutdown()
  }

  private func tryAppServer() throws -> any CodexAppServerRuntimeProtocol {
    guard let appServer else {
      throw GatewayToolError.disabled(
        "codex.app.disabled: Codex App Server is disabled by local configuration."
      )
    }
    return appServer
  }

  private func selectedWorkspacePath() throws -> String {
    guard let workspaceID = owner?.workspaceID,
      let workspace = try database?.workspace(id: workspaceID)
    else {
      throw CodexOrchestrationError.invalid("the selected workspace is not registered")
    }
    return workspace.rootPath
  }

  private func selectedRun(id: String) throws -> CodexOrchestrationRun {
    guard let run = try database?.codexOrchestrationRun(id: id),
      run.workspaceID == owner?.workspaceID
    else {
      throw CodexOrchestrationError.unknown(id)
    }
    return run
  }

  private func selectedLease(id: String) throws -> CodexWorktreeLease {
    guard let lease = try database?.codexWorktreeLease(id: id),
      lease.workspaceID == owner?.workspaceID
    else {
      throw CodexWorktreeLeaseError.unknown(id)
    }
    return lease
  }

  private func selectedManagedWorktree(id: String) throws -> CodexManagedWorktree {
    guard let worktree = try database?.codexManagedWorktree(id: id),
      worktree.sourceWorkspaceID == owner?.workspaceID
    else {
      throw CodexManagedWorktreeError.unknown(id)
    }
    return worktree
  }

  private func tryExec() throws -> any CodexExecRuntimeProtocol {
    guard let exec else {
      throw GatewayToolError.disabled(
        "codex.exec.disabled: Codex Exec is disabled by local configuration."
      )
    }
    return exec
  }

  private func tryMCP() throws -> any CodexMCPRuntimeProtocol {
    guard let mcp else {
      throw GatewayToolError.disabled(
        "codex.mcp.disabled: Codex MCP is disabled by local configuration."
      )
    }
    return mcp
  }

  private static func appMethodsList() -> JSONValue {
    .object([
      "methods": .array(
        CodexAppServerMethodCatalog.methods.map { method in
          .object([
            "method": .string(method.method),
            "description": .string(method.description),
            "takes_params": .bool(method.takesParams),
            "risk": .string(method.risk.rawValue),
          ])
        }
      )
    ])
  }

  private static func appMethodDescription(method: String) throws -> JSONValue {
    guard let descriptor = CodexAppServerMethodCatalog.method(named: method) else {
      throw GatewayToolError.invalidArguments(
        "codex.app.method_not_allowed: App Server method '\(method)' is not in the reviewed allowlist."
      )
    }
    return .object([
      "method": .string(descriptor.method),
      "description": .string(descriptor.description),
      "takes_params": .bool(descriptor.takesParams),
      "risk": .string(descriptor.risk.rawValue),
      "call_context": .object([
        "tool": .string("codex.app.methods.call"),
        "method": .string(descriptor.method),
      ]),
    ])
  }

  private static func params(in object: [String: JSONValue]) throws -> JSONValue {
    guard let value = object["params"] else {
      return .object([:])
    }
    guard value.objectValue != nil else {
      throw GatewayToolError.invalidArguments(
        "codex.params_invalid: params must be a JSON object."
      )
    }
    return value
  }

  private static func threadStartParams(in object: [String: JSONValue]) throws -> JSONValue {
    try validateKeys(
      in: object,
      allowed: ["model", "ephemeral", "personality", "service_tier"]
    )
    var params: [String: JSONValue] = [:]
    try copyOptionalString("model", to: "model", from: object, into: &params)
    try copyOptionalBool("ephemeral", to: "ephemeral", from: object, into: &params)
    try copyOptionalString("personality", to: "personality", from: object, into: &params)
    try copyOptionalString("service_tier", to: "serviceTier", from: object, into: &params)
    return .object(params)
  }

  private static func threadListParams(in object: [String: JSONValue]) throws -> JSONValue {
    try validateKeys(
      in: object,
      allowed: [
        "archived", "cursor", "limit", "search_term", "sort_direction", "sort_key",
        "source_kinds",
      ]
    )
    var params: [String: JSONValue] = [:]
    try copyOptionalBool("archived", to: "archived", from: object, into: &params)
    try copyOptionalString("cursor", to: "cursor", from: object, into: &params)
    try copyOptionalInt("limit", to: "limit", from: object, range: 1...1_000, into: &params)
    try copyOptionalString("search_term", to: "searchTerm", from: object, into: &params)
    try copyOptionalString(
      "sort_direction",
      to: "sortDirection",
      from: object,
      into: &params
    )
    try copyOptionalString("sort_key", to: "sortKey", from: object, into: &params)
    try copyOptionalStringArray(
      "source_kinds",
      to: "sourceKinds",
      from: object,
      into: &params
    )
    return .object(params)
  }

  private static func threadResumeParams(in object: [String: JSONValue]) throws -> JSONValue {
    try validateKeys(
      in: object,
      allowed: ["thread_id", "model", "personality", "service_tier"]
    )
    var params: [String: JSONValue] = [
      "threadId": .string(try requiredIdentifier("thread_id", in: object))
    ]
    try copyOptionalString("model", to: "model", from: object, into: &params)
    try copyOptionalString("personality", to: "personality", from: object, into: &params)
    try copyOptionalString("service_tier", to: "serviceTier", from: object, into: &params)
    return .object(params)
  }

  private static func threadLoadedListParams(in object: [String: JSONValue]) throws -> JSONValue {
    try validateKeys(in: object, allowed: ["cursor", "limit"])
    var params: [String: JSONValue] = [:]
    try copyOptionalString("cursor", to: "cursor", from: object, into: &params)
    try copyOptionalInt("limit", to: "limit", from: object, range: 1...1_000, into: &params)
    return .object(params)
  }

  private static func threadIDParams(in object: [String: JSONValue]) throws -> JSONValue {
    try validateKeys(in: object, allowed: ["thread_id"])
    return .object(["threadId": .string(try requiredIdentifier("thread_id", in: object))])
  }

  private static func goalSetParams(in object: [String: JSONValue]) throws -> JSONValue {
    try validateKeys(
      in: object,
      allowed: ["thread_id", "objective", "status", "token_budget"]
    )
    var params: [String: JSONValue] = [
      "threadId": .string(try requiredIdentifier("thread_id", in: object))
    ]
    try copyOptionalString("objective", to: "objective", from: object, into: &params)
    if let status = try optionalString("status", in: object) {
      guard
        ["active", "paused", "blocked", "usageLimited", "budgetLimited", "complete"]
          .contains(status)
      else {
        throw GatewayToolError.invalidArguments(
          "codex.argument_invalid: 'status' is not an official Codex Goal status."
        )
      }
      params["status"] = .string(status)
    }
    try copyOptionalInt(
      "token_budget",
      to: "tokenBudget",
      from: object,
      range: 1...100_000_000,
      into: &params
    )
    return .object(params)
  }

  private static func threadReadParams(in object: [String: JSONValue]) throws -> JSONValue {
    try validateKeys(in: object, allowed: ["thread_id", "include_turns"])
    return .object([
      "threadId": .string(try requiredIdentifier("thread_id", in: object)),
      "includeTurns": .bool(try optionalBool("include_turns", in: object) ?? true),
    ])
  }

  private static func threadForkParams(in object: [String: JSONValue]) throws -> JSONValue {
    try validateKeys(
      in: object,
      allowed: ["thread_id", "model", "ephemeral", "service_tier"]
    )
    var params: [String: JSONValue] = [
      "threadId": .string(try requiredIdentifier("thread_id", in: object))
    ]
    try copyOptionalString("model", to: "model", from: object, into: &params)
    try copyOptionalBool("ephemeral", to: "ephemeral", from: object, into: &params)
    try copyOptionalString("service_tier", to: "serviceTier", from: object, into: &params)
    return .object(params)
  }

  private func turnStartParams(in object: [String: JSONValue]) throws -> JSONValue {
    try Self.validateKeys(
      in: object,
      allowed: [
        "thread_id", "prompt", "model", "effort", "personality", "service_tier", "summary",
        "output_schema", "worktree_lease_id",
      ]
    )
    let threadID = try Self.requiredIdentifier("thread_id", in: object)
    try CodexWorktreeLeaseManager.validate(
      database: database,
      workspaceID: owner?.workspaceID,
      leaseID: try Self.optionalString("worktree_lease_id", in: object),
      threadID: threadID
    )
    var params: [String: JSONValue] = [
      "threadId": .string(threadID),
      "input": .array([
        .object([
          "type": .string("text"),
          "text": .string(try Self.requiredString("prompt", in: object)),
        ])
      ]),
    ]
    try Self.copyOptionalString("model", to: "model", from: object, into: &params)
    try Self.copyOptionalString("effort", to: "effort", from: object, into: &params)
    try Self.copyOptionalString("personality", to: "personality", from: object, into: &params)
    try Self.copyOptionalString("service_tier", to: "serviceTier", from: object, into: &params)
    try Self.copyOptionalString("summary", to: "summary", from: object, into: &params)
    try Self.copyOptionalObject("output_schema", to: "outputSchema", from: object, into: &params)
    return .object(params)
  }

  private static func turnInterruptParams(in object: [String: JSONValue]) throws -> JSONValue {
    try validateKeys(in: object, allowed: ["thread_id", "turn_id"])
    return .object([
      "threadId": .string(try requiredIdentifier("thread_id", in: object)),
      "turnId": .string(try requiredIdentifier("turn_id", in: object)),
    ])
  }

  private static func turnSteerParams(in object: [String: JSONValue]) throws -> JSONValue {
    try validateKeys(
      in: object,
      allowed: ["thread_id", "expected_turn_id", "prompt", "client_user_message_id"]
    )
    var params: [String: JSONValue] = [
      "threadId": .string(try requiredIdentifier("thread_id", in: object)),
      "expectedTurnId": .string(try requiredIdentifier("expected_turn_id", in: object)),
      "input": .array([
        .object([
          "type": .string("text"),
          "text": .string(try requiredString("prompt", in: object)),
        ])
      ]),
    ]
    try copyOptionalString(
      "client_user_message_id",
      to: "clientUserMessageId",
      from: object,
      into: &params
    )
    return .object(params)
  }

  private static func reviewStartParams(in object: [String: JSONValue]) throws -> JSONValue {
    try validateKeys(in: object, allowed: ["thread_id", "target", "delivery"])
    guard let target = object["target"], target.objectValue != nil else {
      throw GatewayToolError.invalidArguments(
        "codex.argument_required: 'target' must be a JSON object."
      )
    }
    var params: [String: JSONValue] = [
      "threadId": .string(try requiredIdentifier("thread_id", in: object)),
      "target": target,
    ]
    if let delivery = try optionalString("delivery", in: object) {
      guard ["inline", "detached"].contains(delivery) else {
        throw GatewayToolError.invalidArguments(
          "codex.argument_invalid: 'delivery' must be 'inline' or 'detached'."
        )
      }
      params["delivery"] = .string(delivery)
    }
    return .object(params)
  }

  private static func runEvent(in object: [String: JSONValue]) throws -> CodexRunEvent {
    let rawKind = try requiredString("event", in: object)
    guard let kind = CodexRunEventKind(rawValue: rawKind) else {
      throw CodexOrchestrationError.invalid("unsupported event '\(rawKind)'")
    }
    return CodexRunEvent(
      kind: kind,
      summary: try requiredString("summary", in: object),
      phase: try optionalString("phase", in: object),
      nextAction: try optionalString("next_action", in: object),
      turnID: try optionalString("turn_id", in: object),
      approvalID: try optionalString("approval_id", in: object),
      commandID: try optionalString("command_id", in: object),
      criterionID: try optionalString("criterion_id", in: object),
      evidenceKind: try optionalString("evidence_kind", in: object),
      requestID: try optionalString("request_id", in: object),
      correlationID: try optionalString("correlation_id", in: object),
      artifact: try optionalString("artifact", in: object),
      repositoryDigest: try optionalString("repository_digest", in: object),
      failureFingerprint: try optionalString("failure_fingerprint", in: object),
      externalBlocker: try optionalBool("external_blocker", in: object) ?? false
    )
  }

  private static func modelListParams(in object: [String: JSONValue]) throws -> JSONValue {
    try validateKeys(in: object, allowed: ["cursor", "include_hidden", "limit"])
    var params: [String: JSONValue] = [:]
    try copyOptionalString("cursor", to: "cursor", from: object, into: &params)
    try copyOptionalBool("include_hidden", to: "includeHidden", from: object, into: &params)
    try copyOptionalInt("limit", to: "limit", from: object, range: 1...1_000, into: &params)
    return .object(params)
  }

  private static func skillsListParams(in object: [String: JSONValue]) throws -> JSONValue {
    try validateKeys(in: object, allowed: ["force_reload"])
    var params: [String: JSONValue] = [:]
    try copyOptionalBool("force_reload", to: "forceReload", from: object, into: &params)
    return .object(params)
  }

  private static func appsListParams(in object: [String: JSONValue]) throws -> JSONValue {
    try validateKeys(in: object, allowed: [])
    return .object([:])
  }

  private static func validateKeys(
    in object: [String: JSONValue],
    allowed: Set<String>
  ) throws {
    guard let key = object.keys.sorted().first(where: { !allowed.contains($0) }) else {
      return
    }
    throw GatewayToolError.invalidArguments(
      "codex.argument_unknown: '\(key)' is not accepted by this typed tool."
    )
  }

  private static func optionalBool(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> Bool? {
    guard let raw = object[key] else { return nil }
    guard let value = raw.boolValue else {
      throw GatewayToolError.invalidArguments(
        "codex.argument_invalid: '\(key)' must be a boolean."
      )
    }
    return value
  }

  private static func requiredBool(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> Bool {
    guard let value = try optionalBool(key, in: object) else {
      throw GatewayToolError.invalidArguments(
        "codex.argument_required: '\(key)' must be a boolean."
      )
    }
    return value
  }

  private static func requiredInt(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> Int {
    guard let value = object[key]?.intValue, value >= 0 else {
      throw GatewayToolError.invalidArguments(
        "codex.argument_required: '\(key)' must be a nonnegative integer."
      )
    }
    return value
  }

  private static func requiredStringArray(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> [String] {
    guard let values = try optionalStringArray(key, in: object), !values.isEmpty else {
      throw GatewayToolError.invalidArguments(
        "codex.argument_required: '\(key)' must be a non-empty string array."
      )
    }
    return values
  }

  private static func optionalStringArray(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> [String]? {
    guard let raw = object[key] else { return nil }
    guard let values = raw.arrayValue?.compactMap(\.stringValue),
      values.count == raw.arrayValue?.count,
      values.count <= 1_000,
      values.allSatisfy({
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && $0.utf8.count <= 16_384
      })
    else {
      throw GatewayToolError.invalidArguments(
        "codex.argument_invalid: '\(key)' must be an array of non-empty strings."
      )
    }
    return values
  }

  private static func copyOptionalString(
    _ key: String,
    to targetKey: String,
    from object: [String: JSONValue],
    into result: inout [String: JSONValue]
  ) throws {
    if let value = try optionalString(key, in: object) {
      result[targetKey] = .string(value)
    }
  }

  private static func copyOptionalBool(
    _ key: String,
    to targetKey: String,
    from object: [String: JSONValue],
    into result: inout [String: JSONValue]
  ) throws {
    if let value = try optionalBool(key, in: object) {
      result[targetKey] = .bool(value)
    }
  }

  private static func copyOptionalInt(
    _ key: String,
    to targetKey: String,
    from object: [String: JSONValue],
    range: ClosedRange<Int>,
    into result: inout [String: JSONValue]
  ) throws {
    guard let raw = object[key] else { return }
    guard let value = raw.intValue, range.contains(value) else {
      throw GatewayToolError.invalidArguments(
        "codex.argument_invalid: '\(key)' must be an integer between \(range.lowerBound) and \(range.upperBound)."
      )
    }
    result[targetKey] = .number(Double(value))
  }

  private static func copyOptionalObject(
    _ key: String,
    to targetKey: String,
    from object: [String: JSONValue],
    into result: inout [String: JSONValue]
  ) throws {
    guard let value = object[key] else { return }
    guard value.objectValue != nil else {
      throw GatewayToolError.invalidArguments(
        "codex.argument_invalid: '\(key)' must be a JSON object."
      )
    }
    result[targetKey] = value
  }

  private static func copyOptionalStringArray(
    _ key: String,
    to targetKey: String,
    from object: [String: JSONValue],
    into result: inout [String: JSONValue]
  ) throws {
    guard let raw = object[key] else { return }
    guard let values = raw.arrayValue,
      values.count <= 1_000,
      values.allSatisfy({ value in
        guard let string = value.stringValue else { return false }
        return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && string.utf8.count <= 16_384
      })
    else {
      throw GatewayToolError.invalidArguments(
        "codex.argument_invalid: '\(key)' must be an array of non-empty strings."
      )
    }
    result[targetKey] = .array(values)
  }

  private static func requiredString(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> String {
    guard let value = object[key]?.stringValue,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      value.utf8.count <= 1_048_576
    else {
      throw GatewayToolError.invalidArguments(
        "codex.argument_required: '\(key)' must be a non-empty string."
      )
    }
    return value
  }

  private static func requiredIdentifier(
    _ key: String,
    in object: [String: JSONValue],
    maximumBytes: Int = 1_024
  ) throws -> String {
    let value = try requiredString(key, in: object)
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.utf8.count <= maximumBytes,
      trimmed.rangeOfCharacter(from: .controlCharacters) == nil,
      CodexApprovalRedactor.redactString(trimmed, maximumCharacters: 8_192) == trimmed
    else {
      throw GatewayToolError.invalidArguments(
        "codex.argument_invalid: '\(key)' must be a bounded opaque identifier."
      )
    }
    return trimmed
  }

  private static func optionalString(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> String? {
    guard let raw = object[key] else { return nil }
    guard let value = raw.stringValue,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      value.utf8.count <= 1_048_576
    else {
      throw GatewayToolError.invalidArguments(
        "codex.argument_invalid: '\(key)' must be a non-empty string when provided."
      )
    }
    return value
  }

  private static func nonnegativeInt(
    _ key: String,
    in object: [String: JSONValue],
    default defaultValue: Int
  ) throws -> Int {
    let value = object[key]?.intValue ?? defaultValue
    guard value >= 0 else {
      throw GatewayToolError.invalidArguments(
        "codex.argument_invalid: '\(key)' must be nonnegative."
      )
    }
    return value
  }

  private static func boundedInt(
    _ key: String,
    in object: [String: JSONValue],
    default defaultValue: Int,
    range: ClosedRange<Int>
  ) throws -> Int {
    let value = object[key]?.intValue ?? defaultValue
    guard range.contains(value) else {
      throw GatewayToolError.invalidArguments(
        "codex.argument_invalid: '\(key)' must be between \(range.lowerBound) and \(range.upperBound)."
      )
    }
    return value
  }

  private static func resultEnvelope(_ value: JSONValue) throws -> JSONValue {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let text = String(decoding: try encoder.encode(value), as: UTF8.self)
    return .object([
      "content": .array([
        .object([
          "type": .string("text"),
          "text": .string(text),
        ])
      ]),
      "structuredContent": .object(["result": value]),
      "isError": .bool(false),
    ])
  }

  private static func makeTools(
    appServerEnabled: Bool,
    execEnabled: Bool,
    mcpEnabled: Bool
  ) -> [MCPTool] {
    var result: [MCPTool] = []
    if appServerEnabled {
      result.append(contentsOf: appServerTools)
    }
    if execEnabled {
      result.append(contentsOf: execTools)
    }
    if mcpEnabled {
      result.append(contentsOf: mcpTools)
    }
    return result
  }

  private static let readAnnotations = MCPToolAnnotations(
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    openWorldHint: false
  )

  private static let writeAnnotations = MCPToolAnnotations(
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: false,
    openWorldHint: true
  )

  private static let emptySchema = objectSchema()
  private static let cursorSchema = objectSchema(
    properties: [
      "after_cursor": integerSchema(minimum: 0),
      "max_results": integerSchema(minimum: 1, maximum: 1_000),
    ]
  )

  private static let appServerTools: [MCPTool] = [
    tool(
      "codex.diagnostics.snapshot",
      "Read one redacted, workspace-scoped operational snapshot that correlates Codex runtimes, process and connection ownership, approvals, acceptance runs, worktree leases, cleanup state, and recent tool or Git audit receipts.",
      objectSchema(properties: ["limit": integerSchema(minimum: 1, maximum: 1_000)])
    ),
    tool(
      "codex.app.status", "Read the persistent Codex App Server connection status.", emptySchema),
    tool(
      "codex.app.runtimes.list",
      "List active Computer MCP-owned Codex App Server runtimes for the selected workspace.",
      emptySchema
    ),
    tool(
      "codex.app.runtimes.history",
      "List persisted Computer MCP runtime ownership and shutdown receipts for the selected workspace.",
      emptySchema
    ),
    tool(
      "codex.app.runtimes.cleanup.preview",
      "Classify active runtimes, watchdog-pending processes, and stale runtime records without sending signals or changing state.",
      emptySchema
    ),
    tool(
      "codex.app.runtimes.cleanup.perform",
      "Clean reviewed stale Computer MCP runtime records only after their owned process and supervisor are gone. This never signals unrelated Codex processes.",
      objectSchema(
        properties: ["confirm_cleanup": booleanSchema()],
        required: ["confirm_cleanup"]
      ),
      write: true
    ),
    tool(
      "codex.app.runtimes.inspect",
      "Inspect one Computer MCP-owned runtime, including owner, connection generation, process group, known threads, and shutdown state.",
      objectSchema(properties: ["runtime_id": stringSchema()], required: ["runtime_id"])
    ),
    tool(
      "codex.app.runtimes.stop",
      "Stop and reap one specific Computer MCP-owned runtime. Other Codex applications and user-owned processes are never targeted.",
      objectSchema(properties: ["runtime_id": stringSchema()], required: ["runtime_id"]),
      write: true
    ),
    tool(
      "codex.app.methods.list",
      "List reviewed Codex App Server RPC methods. Authentication, configuration mutation, marketplace mutation, raw shell, filesystem bypass, and remote pairing methods are never included.",
      emptySchema
    ),
    tool(
      "codex.app.methods.describe",
      "Describe one reviewed Codex App Server RPC and the fixed follow-up call context.",
      objectSchema(properties: ["method": stringSchema()], required: ["method"])
    ),
    tool(
      "codex.app.methods.call",
      "Call one reviewed Codex App Server RPC. The gateway fixes cwd, sandbox, and approval policy and rejects instruction/config overrides. A leased turn must use codex.app.turn.start with its lease ID.",
      objectSchema(
        properties: [
          "method": stringSchema(),
          "params": .object([
            "type": .string("object"),
            "additionalProperties": .bool(true),
          ]),
        ],
        required: ["method"]
      ),
      write: true
    ),
    tool(
      "codex.app.thread.start", "Start a Codex thread in the bound workspace.",
      objectSchema(
        properties: [
          "model": stringSchema(),
          "ephemeral": booleanSchema(),
          "personality": stringSchema(),
          "service_tier": stringSchema(),
        ]
      ),
      write: true),
    tool(
      "codex.app.thread.list",
      "List Codex threads restricted to the bound workspace.",
      objectSchema(
        properties: [
          "archived": booleanSchema(),
          "cursor": stringSchema(),
          "limit": integerSchema(minimum: 1, maximum: 1_000),
          "search_term": stringSchema(),
          "sort_direction": stringSchema(),
          "sort_key": stringSchema(),
          "source_kinds": arraySchema(items: stringSchema()),
        ]
      )
    ),
    tool(
      "codex.app.thread.reclaim",
      "Explicitly resume a persisted thread under the current Computer MCP runtime after workspace validation. A writer conflict is reported without terminating external Codex applications.",
      objectSchema(
        properties: [
          "thread_id": stringSchema(),
          "model": stringSchema(),
          "personality": stringSchema(),
          "service_tier": stringSchema(),
        ],
        required: ["thread_id"]
      ),
      write: true
    ),
    tool(
      "codex.app.thread.loaded.list",
      "List thread IDs loaded by the current Computer MCP-owned App Server runtime.",
      objectSchema(
        properties: [
          "cursor": stringSchema(),
          "limit": integerSchema(minimum: 1, maximum: 1_000),
        ]
      )
    ),
    tool(
      "codex.app.thread.read", "Read one Codex thread after verifying its workspace.",
      objectSchema(
        properties: [
          "thread_id": stringSchema(),
          "include_turns": booleanSchema(),
        ],
        required: ["thread_id"]
      )
    ),
    tool(
      "codex.app.thread.fork", "Fork a Codex thread in the bound workspace.",
      objectSchema(
        properties: [
          "thread_id": stringSchema(),
          "model": stringSchema(),
          "ephemeral": booleanSchema(),
          "service_tier": stringSchema(),
        ],
        required: ["thread_id"]
      ),
      write: true),
    tool(
      "codex.app.thread.release",
      "Release this runtime's subscription to a verified workspace thread. The persisted thread remains available to official Codex clients.",
      objectSchema(properties: ["thread_id": stringSchema()], required: ["thread_id"]),
      write: true
    ),
    tool(
      "codex.app.handoff.diagnose",
      "Inspect thread ownership and handoff blockers using Computer MCP runtime, process, connection, and approval evidence.",
      objectSchema(
        properties: [
          "thread_id": stringSchema(),
          "observed_error": stringSchema(),
        ],
        required: ["thread_id"]
      )
    ),
    tool(
      "codex.app.goal.get",
      "Read the official persisted Codex Goal for a verified workspace thread.",
      objectSchema(properties: ["thread_id": stringSchema()], required: ["thread_id"])
    ),
    tool(
      "codex.app.goal.set",
      "Create or update the official persisted Codex Goal. A completed turn does not complete the Goal unless its status is explicitly accepted as complete.",
      objectSchema(
        properties: [
          "thread_id": stringSchema(),
          "objective": stringSchema(),
          "status": .object([
            "type": .string("string"),
            "enum": .array(
              ["active", "paused", "blocked", "usageLimited", "budgetLimited", "complete"]
                .map(JSONValue.string)
            ),
          ]),
          "token_budget": integerSchema(minimum: 1, maximum: 100_000_000),
        ],
        required: ["thread_id"]
      ),
      write: true
    ),
    tool(
      "codex.app.goal.clear",
      "Clear the official persisted Codex Goal for a verified workspace thread.",
      objectSchema(properties: ["thread_id": stringSchema()], required: ["thread_id"]),
      write: true
    ),
    tool(
      "codex.app.runtime.stop",
      "Release all thread subscriptions and stop the current Computer MCP-owned App Server runtime.",
      emptySchema,
      write: true
    ),
    tool(
      "codex.app.turn.start", "Start a Codex turn with gateway-owned sandbox and approval policy.",
      objectSchema(
        properties: [
          "thread_id": stringSchema(),
          "prompt": stringSchema(),
          "model": stringSchema(),
          "effort": stringSchema(),
          "personality": stringSchema(),
          "service_tier": stringSchema(),
          "summary": stringSchema(),
          "output_schema": freeObjectSchema(),
          "worktree_lease_id": stringSchema(),
        ],
        required: ["thread_id", "prompt"]
      ), write: true),
    tool(
      "codex.app.turn.steer",
      "Steer the currently active Codex turn. The expected turn ID prevents instructions from being applied to a newer turn.",
      objectSchema(
        properties: [
          "thread_id": stringSchema(),
          "expected_turn_id": stringSchema(),
          "prompt": stringSchema(),
          "client_user_message_id": stringSchema(),
        ],
        required: ["thread_id", "expected_turn_id", "prompt"]
      ),
      write: true
    ),
    tool(
      "codex.app.turn.interrupt", "Interrupt an active Codex turn.",
      objectSchema(
        properties: ["thread_id": stringSchema(), "turn_id": stringSchema()],
        required: ["thread_id", "turn_id"]
      ), write: true),
    tool(
      "codex.app.review.start", "Start a Codex review for a verified workspace thread.",
      objectSchema(
        properties: [
          "thread_id": stringSchema(),
          "target": freeObjectSchema(),
          "delivery": .object([
            "type": .string("string"),
            "enum": .array([.string("inline"), .string("detached")]),
          ]),
        ],
        required: ["thread_id", "target"]
      ), write: true),
    tool(
      "codex.app.models.list", "List models exposed by Codex App Server.",
      objectSchema(
        properties: [
          "cursor": stringSchema(),
          "include_hidden": booleanSchema(),
          "limit": integerSchema(minimum: 1, maximum: 1_000),
        ]
      )
    ),
    tool(
      "codex.app.skills.list", "List Skills for the bound workspace.",
      objectSchema(properties: ["force_reload": booleanSchema()])
    ),
    tool("codex.app.apps.list", "List apps exposed by Codex App Server.", emptySchema),
    tool(
      "codex.app.events.read", "Read App Server notifications by monotonic cursor.", cursorSchema),
    tool(
      "codex.app.requests.list",
      "List pending ordinary user-input and MCP elicitation requests. Native approval requests use codex.app.approvals.*, while credential refresh remains denied.",
      emptySchema),
    tool(
      "codex.app.requests.respond",
      "Respond to one pending ordinary user-input or MCP elicitation request. Native approval decisions use codex.app.approvals.respond; credential refresh cannot be approved.",
      objectSchema(
        properties: [
          "request_id": stringSchema(),
          "response": .object([:]),
        ],
        required: ["request_id", "response"]
      ),
      write: true
    ),
    tool(
      "codex.app.approvals.list",
      "List durable App Server approval records. Policy authorization and user consent remain separate decisions.",
      objectSchema(
        properties: [
          "state": .object([
            "type": .string("string"),
            "enum": .array(
              ["pending", "approved", "denied", "timed_out", "interrupted", "failed"]
                .map(JSONValue.string)
            ),
          ]),
          "limit": integerSchema(minimum: 1, maximum: 1_000),
        ]
      )
    ),
    tool(
      "codex.app.approvals.read",
      "Read one durable, redacted App Server approval record and its audit outcome.",
      objectSchema(
        properties: ["approval_id": stringSchema()],
        required: ["approval_id"]
      )
    ),
    tool(
      "codex.app.approvals.respond",
      "Approve once, approve for a bounded session scope when supported, or deny one live App Server request. Workspace and capability policy are revalidated before approval.",
      objectSchema(
        properties: [
          "approval_id": stringSchema(),
          "decision": .object([
            "type": .string("string"),
            "enum": .array(
              ["approve_once", "approve_session", "deny"].map(JSONValue.string)
            ),
          ]),
        ],
        required: ["approval_id", "decision"]
      ),
      write: true
    ),
    tool(
      "codex.run.create",
      "Create a persisted Computer MCP acceptance run. This may link to an official Goal thread, but its acceptance criteria and evidence remain explicitly Computer MCP-owned.",
      objectSchema(
        properties: [
          "objective": stringSchema(),
          "accepted_scope": arraySchema(items: stringSchema()),
          "acceptance_criteria": arraySchema(items: stringSchema()),
          "required_evidence_kinds": arraySchema(items: stringSchema()),
          "phase": stringSchema(),
          "parent_run_id": stringSchema(),
          "thread_id": stringSchema(),
          "official_goal_linked": booleanSchema(),
          "max_turns": integerSchema(minimum: 1, maximum: 10_000),
          "max_duration_seconds": integerSchema(minimum: 60, maximum: 2_592_000),
          "max_no_progress_seconds": integerSchema(minimum: 30, maximum: 86_400),
          "max_repeated_failures": integerSchema(minimum: 1, maximum: 100),
        ],
        required: ["objective", "accepted_scope", "acceptance_criteria"]
      ),
      write: true
    ),
    tool(
      "codex.run.list",
      "List persisted Computer MCP acceptance runs for the selected workspace.",
      objectSchema(properties: ["limit": integerSchema(minimum: 1, maximum: 1_000)])
    ),
    tool(
      "codex.run.read",
      "Read one Computer MCP acceptance run, including open criteria, evidence, budgets, blockers, and terminal reason.",
      objectSchema(properties: ["run_id": stringSchema()], required: ["run_id"])
    ),
    tool(
      "codex.run.record",
      "Record one revision-checked progress event and apply bounded stall, failure, approval, and turn-completion rules.",
      objectSchema(
        properties: [
          "run_id": stringSchema(),
          "expected_revision": integerSchema(minimum: 1),
          "event": .object([
            "type": .string("string"),
            "enum": .array(
              [
                "planning", "turn_started", "turn_completed", "repository_changed",
                "command_started", "command_progress", "command_completed", "failure",
                "acceptance_passed", "acceptance_failed", "approval_pending",
                "approval_resolved", "blocker",
              ].map(JSONValue.string)
            ),
          ]),
          "summary": stringSchema(),
          "phase": stringSchema(),
          "next_action": stringSchema(),
          "turn_id": stringSchema(),
          "approval_id": stringSchema(),
          "command_id": stringSchema(),
          "criterion_id": stringSchema(),
          "evidence_kind": stringSchema(),
          "request_id": stringSchema(),
          "correlation_id": stringSchema(),
          "artifact": stringSchema(),
          "repository_digest": stringSchema(),
          "failure_fingerprint": stringSchema(),
          "external_blocker": booleanSchema(),
        ],
        required: ["run_id", "expected_revision", "event", "summary"]
      ),
      write: true
    ),
    tool(
      "codex.run.evaluate",
      "Evaluate a run against time, turn, repeated-failure, and no-progress bounds without claiming completion.",
      objectSchema(
        properties: [
          "run_id": stringSchema(),
          "expected_revision": integerSchema(minimum: 1),
        ],
        required: ["run_id", "expected_revision"]
      ),
      write: true
    ),
    tool(
      "codex.run.accept",
      "Accept completion only when every criterion has evidence, required build/test/Git evidence is present, no turn or approval remains active, and the caller confirms a clean worktree.",
      objectSchema(
        properties: [
          "run_id": stringSchema(),
          "expected_revision": integerSchema(minimum: 1),
          "worktree_clean": booleanSchema(),
        ],
        required: ["run_id", "expected_revision", "worktree_clean"]
      ),
      write: true
    ),
    tool(
      "codex.run.transition",
      "Pause, resume, or cancel a Computer MCP acceptance run. This does not invent or change official Codex Goal statuses.",
      objectSchema(
        properties: [
          "run_id": stringSchema(),
          "expected_revision": integerSchema(minimum: 1),
          "action": .object([
            "type": .string("string"),
            "enum": .array(["pause", "resume", "cancel"].map(JSONValue.string)),
          ]),
          "reason": stringSchema(),
        ],
        required: ["run_id", "expected_revision", "action"]
      ),
      write: true
    ),
    tool(
      "codex.run.reconcile",
      "Explicitly import selected evidence from an accepted child run into one parent criterion. Unselected child output never overwrites the parent run.",
      objectSchema(
        properties: [
          "parent_run_id": stringSchema(),
          "expected_revision": integerSchema(minimum: 1),
          "child_run_id": stringSchema(),
          "child_evidence_ids": arraySchema(items: stringSchema()),
          "criterion_id": stringSchema(),
          "accept_criterion": booleanSchema(),
        ],
        required: [
          "parent_run_id", "expected_revision", "child_run_id", "child_evidence_ids",
          "criterion_id",
        ]
      ),
      write: true
    ),
    tool(
      "codex.worktree.leases.acquire",
      "Acquire exclusive mutation ownership for the selected registered worktree. Independent child tasks use a separately registered worktree and an isolated_worktree lease linked to its parent.",
      objectSchema(
        properties: [
          "agent_id": stringSchema(),
          "thread_id": stringSchema(),
          "run_id": stringSchema(),
          "parent_lease_id": stringSchema(),
          "branch": stringSchema(),
          "mode": .object([
            "type": .string("string"),
            "enum": .array(["exclusive", "isolated_worktree"].map(JSONValue.string)),
          ]),
          "ttl_seconds": integerSchema(minimum: 30, maximum: 86_400),
        ],
        required: ["agent_id"]
      ),
      write: true
    ),
    tool(
      "codex.worktree.leases.list",
      "List active and historical worktree mutation leases for the selected workspace.",
      objectSchema(properties: ["limit": integerSchema(minimum: 1, maximum: 1_000)])
    ),
    tool(
      "codex.worktree.leases.read",
      "Read one worktree mutation lease and its task lineage.",
      objectSchema(properties: ["lease_id": stringSchema()], required: ["lease_id"])
    ),
    tool(
      "codex.worktree.leases.heartbeat",
      "Renew one active revision-checked worktree lease for a bounded duration.",
      objectSchema(
        properties: [
          "lease_id": stringSchema(),
          "expected_revision": integerSchema(minimum: 1),
          "ttl_seconds": integerSchema(minimum: 30, maximum: 86_400),
        ],
        required: ["lease_id", "expected_revision"]
      ),
      write: true
    ),
    tool(
      "codex.worktree.leases.release",
      "Release one active revision-checked worktree lease without deleting files or worktrees.",
      objectSchema(
        properties: [
          "lease_id": stringSchema(),
          "expected_revision": integerSchema(minimum: 1),
          "reason": stringSchema(),
        ],
        required: ["lease_id", "expected_revision", "reason"]
      ),
      write: true
    ),
    tool(
      "codex.worktree.leases.cleanup.preview",
      "Preview expired worktree lease receipts. This does not change files, worktrees, branches, or processes.",
      emptySchema
    ),
    tool(
      "codex.worktree.leases.cleanup.perform",
      "Mark reviewed expired lease receipts as expired. Filesystem and Git cleanup remain separate governed operations.",
      objectSchema(
        properties: ["confirm_cleanup": booleanSchema()],
        required: ["confirm_cleanup"]
      ),
      write: true
    ),
    tool(
      "codex.worktree.managed.list",
      "List Computer MCP-owned worktree plans and lifecycle receipts rooted in the selected source workspace.",
      objectSchema(properties: ["limit": integerSchema(minimum: 1, maximum: 1_000)])
    ),
    tool(
      "codex.worktree.managed.read",
      "Read one Computer MCP-owned worktree plan or lifecycle receipt.",
      objectSchema(
        properties: ["managed_worktree_id": stringSchema()],
        required: ["managed_worktree_id"]
      )
    ),
    tool(
      "codex.worktree.provision.plan",
      "Persist and validate a five-minute plan for a new isolated Git worktree under the Computer MCP-managed root. This does not create a branch or directory.",
      objectSchema(
        properties: [
          "agent_id": stringSchema(),
          "thread_id": stringSchema(),
          "run_id": stringSchema(),
          "parent_lease_id": stringSchema(),
          "branch": stringSchema(),
          "start_point": stringSchema(),
          "ttl_seconds": integerSchema(minimum: 30, maximum: 86_400),
        ],
        required: ["agent_id", "parent_lease_id", "branch"]
      ),
      write: true
    ),
    tool(
      "codex.worktree.provision.perform",
      "Create exactly one reviewed managed worktree, register it as a child workspace, inherit the current profile's workspace grant, and acquire an isolated writer lease.",
      objectSchema(
        properties: [
          "plan_id": stringSchema(),
          "expected_revision": integerSchema(minimum: 1),
          "confirm_provision": booleanSchema(),
        ],
        required: ["plan_id", "expected_revision", "confirm_provision"]
      ),
      write: true
    ),
    tool(
      "codex.worktree.remove.plan",
      "Verify Computer MCP ownership, an inactive writer lease, no live runtime, exact Git linkage, and a clean worktree before persisting a five-minute removal plan.",
      objectSchema(
        properties: ["managed_worktree_id": stringSchema()],
        required: ["managed_worktree_id"]
      ),
      write: true
    ),
    tool(
      "codex.worktree.remove.perform",
      "Remove exactly the reviewed clean Computer MCP-owned worktree and its managed workspace registration. The local branch is preserved. This destructive operation also requires a gateway operation ticket.",
      objectSchema(
        properties: [
          "managed_worktree_id": stringSchema(),
          "expected_revision": integerSchema(minimum: 1),
          "confirm_remove": booleanSchema(),
        ],
        required: ["managed_worktree_id", "expected_revision", "confirm_remove"]
      ),
      write: true
    ),
  ]

  private static let execTools: [MCPTool] = [
    tool(
      "codex.exec.start",
      "Start an isolated `codex exec` JSONL session. cwd, sandbox, approval policy, writable roots, and config overrides are fixed locally.",
      objectSchema(
        properties: ["prompt": stringSchema(), "model": stringSchema()],
        required: ["prompt"]
      ),
      write: true
    ),
    tool(
      "codex.exec.resume",
      "Resume one upstream Codex Exec session under the same fixed workspace and policy.",
      objectSchema(
        properties: [
          "upstream_session_id": stringSchema(),
          "prompt": stringSchema(),
        ],
        required: ["upstream_session_id"]
      ),
      write: true
    ),
    tool("codex.exec.list", "List gateway-owned Codex Exec sessions.", emptySchema),
    tool(
      "codex.exec.events",
      "Read JSONL events for one Codex Exec session by monotonic cursor.",
      sessionCursorSchema(id: "session_id")
    ),
    tool(
      "codex.exec.result",
      "Read the terminal result for one completed Codex Exec session.",
      objectSchema(properties: ["session_id": stringSchema()], required: ["session_id"])
    ),
    tool(
      "codex.exec.cancel",
      "Cancel one running Codex Exec session.",
      objectSchema(properties: ["session_id": stringSchema()], required: ["session_id"]),
      write: true
    ),
  ]

  private static let mcpTools: [MCPTool] = [
    tool(
      "codex.mcp.status", "Read the persistent `codex mcp-server` connection status.", emptySchema),
    tool("codex.mcp.tools.list", "List tools reported by `codex mcp-server`.", emptySchema),
    tool(
      "codex.mcp.run",
      "Start the Codex MCP `codex` tool with gateway-owned cwd, sandbox, approval policy, and no instruction/config overrides.",
      objectSchema(
        properties: ["prompt": stringSchema(), "model": stringSchema()],
        required: ["prompt"]
      ),
      write: true
    ),
    tool(
      "codex.mcp.reply",
      "Reply to an existing Codex MCP thread.",
      objectSchema(
        properties: ["thread_id": stringSchema(), "prompt": stringSchema()],
        required: ["thread_id", "prompt"]
      ),
      write: true
    ),
    tool("codex.mcp.calls.list", "List gateway-owned Codex MCP calls.", emptySchema),
    tool(
      "codex.mcp.events",
      "Read server messages and approval events for one Codex MCP call by cursor.",
      sessionCursorSchema(id: "call_id")
    ),
    tool(
      "codex.mcp.result",
      "Read the current or terminal result for one Codex MCP call.",
      objectSchema(properties: ["call_id": stringSchema()], required: ["call_id"])
    ),
    tool(
      "codex.mcp.approvals.list",
      "List pending command or patch approvals for one Codex MCP call.",
      objectSchema(properties: ["call_id": stringSchema()], required: ["call_id"])
    ),
    tool(
      "codex.mcp.approval.respond",
      "Allow or deny one pending Codex MCP approval. Allow is accepted only when every cwd, grant root, and patch path stays within the bound workspace.",
      objectSchema(
        properties: [
          "call_id": stringSchema(),
          "approval_id": stringSchema(),
          "decision": .object([
            "type": .string("string"),
            "enum": .array([.string("allow"), .string("deny")]),
          ]),
        ],
        required: ["call_id", "approval_id", "decision"]
      ),
      write: true
    ),
    tool(
      "codex.mcp.cancel",
      "Request cancellation for one active Codex MCP call.",
      objectSchema(properties: ["call_id": stringSchema()], required: ["call_id"]),
      write: true
    ),
  ]

  private static let readOnlyToolNames = Set(
    (appServerTools + execTools + mcpTools)
      .filter { $0.annotations?.readOnlyHint == true }
      .map(\.name)
  )

  private static func tool(
    _ name: String,
    _ description: String,
    _ inputSchema: JSONValue,
    write: Bool = false
  ) -> MCPTool {
    MCPTool(
      name: name,
      description: description,
      inputSchema: inputSchema,
      outputSchema: MCPTool.resultEnvelopeSchema,
      annotations: write ? writeAnnotations : readAnnotations
    )
  }

  private static func objectSchema(
    properties: [String: JSONValue] = [:],
    required: [String] = []
  ) -> JSONValue {
    var schema: [String: JSONValue] = [
      "type": .string("object"),
      "properties": .object(properties),
      "additionalProperties": .bool(false),
    ]
    if !required.isEmpty {
      schema["required"] = .array(required.map(JSONValue.string))
    }
    return .object(schema)
  }

  private static func sessionCursorSchema(id: String) -> JSONValue {
    objectSchema(
      properties: [
        id: stringSchema(),
        "after_cursor": integerSchema(minimum: 0),
        "max_results": integerSchema(minimum: 1, maximum: 1_000),
      ],
      required: [id]
    )
  }

  private static func stringSchema() -> JSONValue {
    .object([
      "type": .string("string"),
      "minLength": .number(1),
      "maxLength": .number(1_048_576),
    ])
  }

  private static func booleanSchema() -> JSONValue {
    .object(["type": .string("boolean")])
  }

  private static func freeObjectSchema() -> JSONValue {
    .object([
      "type": .string("object"),
      "maxProperties": .number(1_000),
      "additionalProperties": .bool(true),
    ])
  }

  private static func arraySchema(items: JSONValue) -> JSONValue {
    .object([
      "type": .string("array"),
      "items": items,
      "maxItems": .number(1_000),
    ])
  }

  private static func integerSchema(minimum: Int, maximum: Int? = nil) -> JSONValue {
    var schema: [String: JSONValue] = [
      "type": .string("integer"),
      "minimum": .number(Double(minimum)),
    ]
    if let maximum {
      schema["maximum"] = .number(Double(maximum))
    }
    return .object(schema)
  }
}
