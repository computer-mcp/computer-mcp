import Foundation

package enum ProductJourney: String, Codable, CaseIterable, Sendable {
  case local
  case chatgpt
  case cloudflare
}

package enum ProductReadinessStatus: String, Codable, Equatable, Sendable {
  case notConfigured = "not_configured"
  case blocked
  case needsAttention = "needs_attention"
  case ready
  case verified
}

package enum ProductReadinessCheckStatus: String, Codable, Equatable, Sendable {
  case pass
  case warning
  case fail
  case notApplicable = "not_applicable"
}

package enum ProductReadinessActionKind: String, Codable, Equatable, Sendable {
  case openApp = "open_app"
  case openURL = "open_url"
  case runCommand = "run_command"
}

package struct ProductReadinessNextAction: Codable, Equatable, Sendable {
  package var kind: ProductReadinessActionKind
  package var label: String
  package var redactedTarget: String

  private enum CodingKeys: String, CodingKey {
    case kind
    case label
    case redactedTarget = "redacted_target"
  }

  package init(
    kind: ProductReadinessActionKind,
    label: String,
    redactedTarget: String
  ) {
    self.kind = kind
    self.label = label
    self.redactedTarget = redactedTarget
  }
}

package struct ProductReadinessCheck: Codable, Equatable, Identifiable, Sendable {
  package var id: String
  package var status: ProductReadinessCheckStatus
  package var required: Bool
  package var summary: String
  package var detail: String
  package var nextAction: ProductReadinessNextAction? = nil

  private enum CodingKeys: String, CodingKey {
    case id
    case status
    case required
    case summary
    case detail
  }

  package init(
    id: String,
    status: ProductReadinessCheckStatus,
    required: Bool,
    summary: String,
    detail: String,
    nextAction: ProductReadinessNextAction? = nil
  ) {
    self.id = id
    self.status = status
    self.required = required
    self.summary = summary
    self.detail = detail
    self.nextAction = nextAction
  }
}

package struct ProductVerifiedRequest: Codable, Equatable, Sendable {
  package var requestID: String
  package var timestamp: Date
  package var capability: String

  private enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
    case timestamp
    case capability
  }

  package init(requestID: String, timestamp: Date, capability: String) {
    self.requestID = requestID
    self.timestamp = timestamp
    self.capability = capability
  }
}

package struct ProductReadinessSnapshot: Codable, Equatable, Sendable {
  package static let schemaVersion = 1

  package var schemaVersion: Int
  package var generatedAt: Date
  package var journey: ProductJourney
  package var status: ProductReadinessStatus
  package var checks: [ProductReadinessCheck]
  package var nextAction: ProductReadinessNextAction?
  package var verifiedRequest: ProductVerifiedRequest?

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case generatedAt = "generated_at"
    case journey
    case status
    case checks
    case nextAction = "next_action"
    case verifiedRequest = "verified_request"
  }

  package init(
    schemaVersion: Int = Self.schemaVersion,
    generatedAt: Date = Date(),
    journey: ProductJourney,
    status: ProductReadinessStatus,
    checks: [ProductReadinessCheck],
    nextAction: ProductReadinessNextAction? = nil,
    verifiedRequest: ProductVerifiedRequest? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.generatedAt = generatedAt
    self.journey = journey
    self.status = status
    self.checks = checks
    self.nextAction = nextAction
    self.verifiedRequest = verifiedRequest
  }

  package static func appUnavailable(
    journey: ProductJourney,
    detail: String =
      "Computer MCP.app is not running or its owner-only control socket is unavailable."
  ) -> Self {
    let action = ProductReadinessNextAction(
      kind: .openApp,
      label: "Open Computer MCP",
      redactedTarget: "computer-mcp"
    )
    return Self(
      journey: journey,
      status: .blocked,
      checks: [
        ProductReadinessCheck(
          id: "app.control_socket",
          status: .fail,
          required: true,
          summary: "Computer MCP App is unavailable",
          detail: detail,
          nextAction: action
        )
      ],
      nextAction: action
    )
  }
}

package struct OpenAITunnelReadinessInput: Equatable, Sendable {
  package var configuration: OpenAITunnelConfiguration
  package var status: OpenAITunnelStatus
  package var dependencyAvailable: Bool
  package var credentialReady: Bool

  package init(
    configuration: OpenAITunnelConfiguration,
    status: OpenAITunnelStatus,
    dependencyAvailable: Bool,
    credentialReady: Bool
  ) {
    self.configuration = configuration
    self.status = status
    self.dependencyAvailable = dependencyAvailable
    self.credentialReady = credentialReady
  }
}

package struct CloudflareTunnelReadinessInput: Equatable, Sendable {
  package var configuration: CloudflareTunnelConfiguration
  package var status: CloudflareTunnelStatus
  package var dependencyAvailable: Bool
  package var tunnelTokenPresent: Bool
  package var accessTokenPresent: Bool

  package init(
    configuration: CloudflareTunnelConfiguration,
    status: CloudflareTunnelStatus,
    dependencyAvailable: Bool,
    tunnelTokenPresent: Bool,
    accessTokenPresent: Bool
  ) {
    self.configuration = configuration
    self.status = status
    self.dependencyAvailable = dependencyAvailable
    self.tunnelTokenPresent = tunnelTokenPresent
    self.accessTokenPresent = accessTokenPresent
  }
}

package struct ProductReadinessInput: Equatable, Sendable {
  package var generatedAt: Date
  package var gateway: AppGatewayServiceSnapshot
  package var cliInstallation: EmbeddedCLIInstallationStatus?
  package var workspaceCount: Int
  package var openAITunnels: [OpenAITunnelReadinessInput]
  package var cloudflareTunnels: [CloudflareTunnelReadinessInput]
  package var auditEvents: [AuditEvent]

  package init(
    generatedAt: Date = Date(),
    gateway: AppGatewayServiceSnapshot,
    cliInstallation: EmbeddedCLIInstallationStatus?,
    workspaceCount: Int,
    openAITunnels: [OpenAITunnelReadinessInput],
    cloudflareTunnels: [CloudflareTunnelReadinessInput],
    auditEvents: [AuditEvent]
  ) {
    self.generatedAt = generatedAt
    self.gateway = gateway
    self.cliInstallation = cliInstallation
    self.workspaceCount = workspaceCount
    self.openAITunnels = openAITunnels
    self.cloudflareTunnels = cloudflareTunnels
    self.auditEvents = auditEvents
  }
}

package enum ProductReadinessEvaluator {
  package static func evaluate(
    journey: ProductJourney,
    input: ProductReadinessInput
  ) -> ProductReadinessSnapshot {
    var checks = [
      ProductReadinessCheck(
        id: "app.control_socket",
        status: .pass,
        required: true,
        summary: "Computer MCP App is available",
        detail: "The owner-only local control socket is responding."
      ),
      gatewayCheck(input.gateway),
    ]
    var configured = true
    var blocked = false
    var verifiedRequest: ProductVerifiedRequest?

    switch journey {
    case .local:
      let cli = localCLICheck(input.cliInstallation)
      checks.append(cli)
      blocked = cli.status == .fail
      checks.append(workspaceCheck(count: input.workspaceCount))
      verifiedRequest = verifiedLocalRequest(input)

    case .chatgpt:
      guard let tunnel = preferredOpenAITunnel(input.openAITunnels) else {
        configured = false
        checks.append(notConfiguredCheck(journey: journey))
        break
      }
      let dependency = ProductReadinessCheck(
        id: "chatgpt.tunnel_client",
        status: tunnel.dependencyAvailable ? .pass : .fail,
        required: true,
        summary: tunnel.dependencyAvailable
          ? "OpenAI tunnel-client is available" : "OpenAI tunnel-client is unavailable",
        detail: tunnel.dependencyAvailable
          ? "The configured or discovered tunnel-client executable is available."
          : "Install tunnel-client from OpenAI and run the check again.",
        nextAction: tunnel.dependencyAvailable
          ? nil
          : ProductReadinessNextAction(
            kind: .openURL,
            label: "Open OpenAI setup documentation",
            redactedTarget: "https://github.com/openai/tunnel-client/releases/latest"
          )
      )
      checks.append(dependency)
      blocked = dependency.status == .fail
      let credential = ProductReadinessCheck(
        id: "chatgpt.api_key",
        status: tunnel.credentialReady ? .pass : .fail,
        required: true,
        summary: tunnel.credentialReady
          ? "Tunnel credential is ready" : "Tunnel credential is missing",
        detail: tunnel.credentialReady
          ? "The required credential is stored in Keychain or this profile does not require one."
          : "Save the OpenAI Tunnel API key in Computer MCP. It will remain in Keychain.",
        nextAction: tunnel.credentialReady
          ? nil
          : ProductReadinessNextAction(
            kind: .openApp,
            label: "Edit ChatGPT connection",
            redactedTarget: "chatgpt"
          )
      )
      checks.append(credential)
      blocked = blocked || credential.status == .fail
      checks.append(openAITunnelStateCheck(tunnel.status))
      checks.append(workspaceCheck(count: input.workspaceCount))
      verifiedRequest = verifiedOpenAIRequest(tunnel, input: input)

    case .cloudflare:
      guard let tunnel = preferredCloudflareTunnel(input.cloudflareTunnels) else {
        configured = false
        checks.append(notConfiguredCheck(journey: journey))
        break
      }
      let dependency = ProductReadinessCheck(
        id: "cloudflare.cloudflared",
        status: tunnel.dependencyAvailable ? .pass : .fail,
        required: true,
        summary: tunnel.dependencyAvailable
          ? "cloudflared is available" : "cloudflared is unavailable",
        detail: tunnel.dependencyAvailable
          ? "The configured or discovered cloudflared executable is available."
          : "Install cloudflared from Cloudflare and run the check again.",
        nextAction: tunnel.dependencyAvailable
          ? nil
          : ProductReadinessNextAction(
            kind: .openURL,
            label: "Open Cloudflare installation documentation",
            redactedTarget:
              "https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
          )
      )
      checks.append(dependency)
      blocked = dependency.status == .fail
      let credentialsReady = tunnel.tunnelTokenPresent && tunnel.accessTokenPresent
      let credentials = ProductReadinessCheck(
        id: "cloudflare.credentials",
        status: credentialsReady ? .pass : .fail,
        required: true,
        summary: credentialsReady
          ? "Named tunnel credentials are ready" : "Named tunnel credentials are incomplete",
        detail: credentialsReady
          ? "The named-tunnel token and Computer MCP Access Token are stored in Keychain."
          : "Save the named-tunnel token and generate a Computer MCP Access Token.",
        nextAction: credentialsReady
          ? nil
          : ProductReadinessNextAction(
            kind: .openApp,
            label: "Edit Cloudflare connection",
            redactedTarget: "cloudflare"
          )
      )
      checks.append(credentials)
      blocked = blocked || credentials.status == .fail
      checks.append(cloudflareTunnelStateCheck(tunnel.status))
      checks.append(workspaceCheck(count: input.workspaceCount))
      verifiedRequest = verifiedCloudflareRequest(tunnel, input: input)
    }

    let healthFailures = checks.filter { $0.required && $0.status == .fail }
    let healthWarnings = checks.filter { $0.required && $0.status == .warning }
    if !configured || blocked || !healthFailures.isEmpty || !healthWarnings.isEmpty {
      verifiedRequest = nil
    }

    let verification = ProductReadinessCheck(
      id: "\(journey.rawValue).verified_request",
      status: verifiedRequest == nil ? .warning : .pass,
      required: false,
      summary: verifiedRequest == nil
        ? "No current end-to-end request has been observed"
        : "A current end-to-end request was observed",
      detail: verifiedRequest == nil
        ? "Connect the consumer and make one successful MCP request to verify this path."
        : "The request is correlated with the current gateway or tunnel start boundary."
    )
    if configured {
      checks.append(verification)
    }

    let requiredFailures = checks.filter { $0.required && $0.status == .fail }
    let requiredWarnings = checks.filter { $0.required && $0.status == .warning }
    let status: ProductReadinessStatus
    if !configured {
      status = .notConfigured
    } else if blocked {
      status = .blocked
    } else if !requiredFailures.isEmpty || !requiredWarnings.isEmpty {
      status = .needsAttention
    } else if verifiedRequest != nil {
      status = .verified
    } else {
      status = .ready
    }

    let nextAction =
      checks.first {
        ($0.required && ($0.status == .fail || $0.status == .warning))
          || $0.id.hasSuffix(".configured")
      }?.nextAction
      ?? (status == .ready
        ? ProductReadinessNextAction(
          kind: .openApp,
          label: "Make a test MCP request",
          redactedTarget: journey.rawValue
        ) : nil)

    return ProductReadinessSnapshot(
      generatedAt: input.generatedAt,
      journey: journey,
      status: status,
      checks: checks,
      nextAction: nextAction,
      verifiedRequest: verifiedRequest
    )
  }

  private static func gatewayCheck(
    _ gateway: AppGatewayServiceSnapshot
  ) -> ProductReadinessCheck {
    let action = ProductReadinessNextAction(
      kind: .openApp,
      label: "Start Gateway",
      redactedTarget: "home"
    )
    switch gateway.state {
    case .running:
      return ProductReadinessCheck(
        id: "gateway.running",
        status: .pass,
        required: true,
        summary: "Gateway is running",
        detail: "The owner-only local gateway socket is accepting connections."
      )
    case .starting, .stopping:
      return ProductReadinessCheck(
        id: "gateway.running",
        status: .warning,
        required: true,
        summary: "Gateway state is changing",
        detail: "Wait for the Gateway to finish changing state, then run the check again."
      )
    case .stopped:
      return ProductReadinessCheck(
        id: "gateway.running",
        status: .fail,
        required: true,
        summary: "Gateway is stopped",
        detail: "Start the Gateway before connecting an MCP consumer.",
        nextAction: action
      )
    case .failed:
      return ProductReadinessCheck(
        id: "gateway.running",
        status: .fail,
        required: true,
        summary: "Gateway failed to start",
        detail: gateway.lastError ?? "Open Diagnostics for the latest failure.",
        nextAction: ProductReadinessNextAction(
          kind: .openApp,
          label: "Open Diagnostics",
          redactedTarget: "diagnostics"
        )
      )
    }
  }

  private static func localCLICheck(
    _ installation: EmbeddedCLIInstallationStatus?
  ) -> ProductReadinessCheck {
    guard let installation else {
      return ProductReadinessCheck(
        id: "local.cli",
        status: .fail,
        required: true,
        summary: "Command line tool status is unavailable",
        detail: "Open Computer MCP and inspect the command line tool installation.",
        nextAction: ProductReadinessNextAction(
          kind: .openApp,
          label: "Open Computer MCP",
          redactedTarget: "home"
        )
      )
    }
    guard installation.state == .installed else {
      return ProductReadinessCheck(
        id: "local.cli",
        status: .fail,
        required: true,
        summary: "Command line tool is not installed",
        detail: "Install the signed embedded CLI before registering a local MCP client.",
        nextAction: ProductReadinessNextAction(
          kind: .openApp,
          label: "Install Command Line Tool",
          redactedTarget: "home"
        )
      )
    }
    return ProductReadinessCheck(
      id: "local.cli",
      status: .pass,
      required: true,
      summary: "Command line tool is installed",
      detail: installation.destinationDirectoryIsOnPath
        ? "The App-owned CLI link is installed and its directory is on PATH."
        : "The App-owned CLI link is installed. Add ~/.local/bin to PATH to use it by name."
    )
  }

  private static func workspaceCheck(count: Int) -> ProductReadinessCheck {
    ProductReadinessCheck(
      id: "workspace.registered",
      status: count > 0 ? .pass : .warning,
      required: false,
      summary: count > 0 ? "A workspace is registered" : "No workspace is registered",
      detail: count > 0
        ? "Workspace-scoped tools can use the registered folder grants."
        : "Safe system tools remain available. Add a workspace before using workspace-scoped tools.",
      nextAction: count > 0
        ? nil
        : ProductReadinessNextAction(
          kind: .openApp,
          label: "Add Workspace",
          redactedTarget: "workspaces"
        )
    )
  }

  private static func notConfiguredCheck(
    journey: ProductJourney
  ) -> ProductReadinessCheck {
    let name = journey == .chatgpt ? "ChatGPT" : "Cloudflare"
    return ProductReadinessCheck(
      id: "\(journey.rawValue).configured",
      status: .fail,
      required: true,
      summary: "\(name) connection is not configured",
      detail: "Add one \(name) connection in Computer MCP to continue.",
      nextAction: ProductReadinessNextAction(
        kind: .openApp,
        label: "Configure \(name)",
        redactedTarget: journey.rawValue
      )
    )
  }

  private static func openAITunnelStateCheck(
    _ status: OpenAITunnelStatus
  ) -> ProductReadinessCheck {
    tunnelStateCheck(
      id: "chatgpt.tunnel_running",
      state: status.state.rawValue,
      running: status.state == .running,
      changing: status.state == .starting || status.state == .stopping,
      failed: status.state == .failed,
      error: status.lastError,
      destination: "chatgpt"
    )
  }

  private static func cloudflareTunnelStateCheck(
    _ status: CloudflareTunnelStatus
  ) -> ProductReadinessCheck {
    tunnelStateCheck(
      id: "cloudflare.tunnel_running",
      state: status.state.rawValue,
      running: status.state == .running,
      changing: status.state == .starting || status.state == .stopping,
      failed: status.state == .failed,
      error: status.lastError,
      destination: "cloudflare"
    )
  }

  private static func tunnelStateCheck(
    id: String,
    state: String,
    running: Bool,
    changing: Bool,
    failed: Bool,
    error: String?,
    destination: String
  ) -> ProductReadinessCheck {
    if running {
      return ProductReadinessCheck(
        id: id,
        status: .pass,
        required: true,
        summary: "Tunnel is running",
        detail: "The managed tunnel process is running."
      )
    }
    if changing {
      return ProductReadinessCheck(
        id: id,
        status: .warning,
        required: true,
        summary: "Tunnel state is changing",
        detail: "Wait for the tunnel to finish changing state, then run the check again."
      )
    }
    return ProductReadinessCheck(
      id: id,
      status: .fail,
      required: true,
      summary: failed ? "Tunnel failed" : "Tunnel is not running",
      detail: error ?? "Current tunnel state: \(state).",
      nextAction: ProductReadinessNextAction(
        kind: .openApp,
        label: failed ? "Run Tunnel Diagnostics" : "Start Tunnel",
        redactedTarget: destination
      )
    )
  }

  private static func preferredOpenAITunnel(
    _ tunnels: [OpenAITunnelReadinessInput]
  ) -> OpenAITunnelReadinessInput? {
    tunnels.first(where: { $0.status.state == .running }) ?? tunnels.first
  }

  private static func preferredCloudflareTunnel(
    _ tunnels: [CloudflareTunnelReadinessInput]
  ) -> CloudflareTunnelReadinessInput? {
    tunnels.first(where: { $0.status.state == .running }) ?? tunnels.first
  }

  private static func verifiedLocalRequest(
    _ input: ProductReadinessInput
  ) -> ProductVerifiedRequest? {
    verifiedRequest(in: input.auditEvents) { event in
      event.caller == .localMCP
        && event.decision == .allowed
        && event.occurredAt >= (input.gateway.startedAt ?? .distantFuture)
    }
  }

  private static func verifiedOpenAIRequest(
    _ tunnel: OpenAITunnelReadinessInput,
    input: ProductReadinessInput
  ) -> ProductVerifiedRequest? {
    verifiedRequest(in: input.auditEvents) { event in
      event.caller == .secureTunnel
        && event.profileID == tunnel.configuration.gatewayProfile
        && event.tunnelProfileID == tunnel.configuration.tunnelClientProfile
        && event.decision == .allowed
        && event.occurredAt >= (tunnel.status.startedAt ?? .distantFuture)
    }
  }

  private static func verifiedCloudflareRequest(
    _ tunnel: CloudflareTunnelReadinessInput,
    input: ProductReadinessInput
  ) -> ProductVerifiedRequest? {
    verifiedRequest(in: input.auditEvents) { event in
      event.caller == .cloudflareTunnel
        && event.profileID == tunnel.configuration.gatewayProfile
        && event.tunnelInstanceID == tunnel.configuration.id
        && event.tunnelProfileID == tunnel.configuration.tunnelName
        && event.decision == .allowed
        && event.occurredAt >= (tunnel.status.startedAt ?? .distantFuture)
    }
  }

  private static func verifiedRequest(
    in events: [AuditEvent],
    where predicate: (AuditEvent) -> Bool
  ) -> ProductVerifiedRequest? {
    events
      .filter(predicate)
      .max { $0.occurredAt < $1.occurredAt }
      .map {
        ProductVerifiedRequest(
          requestID: $0.requestID,
          timestamp: $0.occurredAt,
          capability: $0.capabilityID
        )
      }
  }
}

extension AppControlPlaneService {
  package func readinessSnapshot(
    journey: ProductJourney,
    gateway: AppGatewayServiceSnapshot,
    cliInstallation: EmbeddedCLIInstallationStatus? = try? EmbeddedCLIInstaller().status()
  ) async throws -> ProductReadinessSnapshot {
    let snapshot = try await snapshot()
    let statusByOpenAIID = Dictionary(
      uniqueKeysWithValues: snapshot.openAITunnelStatuses.map { ($0.profileID, $0) }
    )
    var openAIInputs = [OpenAITunnelReadinessInput]()
    for configuration in snapshot.openAITunnelConfigurations {
      let status =
        statusByOpenAIID[configuration.id]
        ?? OpenAITunnelStatus(profileID: configuration.id, state: .stopped)
      let credentialReady: Bool
      if let reference = configuration.apiKeyReference {
        credentialReady = try await hasOpenAITunnelAPIKey(reference: reference)
      } else {
        credentialReady = true
      }
      openAIInputs.append(
        OpenAITunnelReadinessInput(
          configuration: configuration,
          status: status,
          dependencyAvailable: status.state == .running
            || Self.executableAvailable(
              requestedPath: configuration.tunnelClientPath,
              names: ["tunnel-client"]
            ),
          credentialReady: credentialReady
        )
      )
    }

    let statusByCloudflareID = Dictionary(
      uniqueKeysWithValues: snapshot.cloudflareStatuses.map { ($0.profileID, $0) }
    )
    var cloudflareInputs = [CloudflareTunnelReadinessInput]()
    for configuration in snapshot.cloudflareProfiles {
      let status =
        statusByCloudflareID[configuration.id]
        ?? CloudflareTunnelStatus(
          profileID: configuration.id,
          state: .stopped,
          processID: nil,
          originURL: nil,
          publicURL: configuration.mcpURL?.absoluteString,
          metricsURL: nil,
          startedAt: nil,
          lastError: nil
        )
      let credential = try await cloudflareCredentialState(for: configuration)
      cloudflareInputs.append(
        CloudflareTunnelReadinessInput(
          configuration: configuration,
          status: status,
          dependencyAvailable: status.state == .running
            || Self.executableAvailable(
              requestedPath: configuration.cloudflaredPath,
              names: ["cloudflared"]
            ),
          tunnelTokenPresent: credential.tunnelTokenPresent,
          accessTokenPresent: credential.accessTokenPresent
        )
      )
    }

    return ProductReadinessEvaluator.evaluate(
      journey: journey,
      input: ProductReadinessInput(
        gateway: gateway,
        cliInstallation: cliInstallation,
        workspaceCount: try workspaces().count,
        openAITunnels: openAIInputs,
        cloudflareTunnels: cloudflareInputs,
        auditEvents: try auditEvents(limit: 1_000)
      )
    )
  }

  private nonisolated static func executableAvailable(
    requestedPath: String?,
    names: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> Bool {
    if let requestedPath {
      return fileManager.isExecutableFile(
        atPath: URL(fileURLWithPath: requestedPath).standardizedFileURL.path
      )
    }
    let directories =
      (environment["PATH"] ?? "")
      .split(separator: ":")
      .map(String.init)
      + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    return directories.contains { directory in
      names.contains { name in
        fileManager.isExecutableFile(
          atPath: URL(fileURLWithPath: directory).appendingPathComponent(name).path
        )
      }
    }
  }
}
