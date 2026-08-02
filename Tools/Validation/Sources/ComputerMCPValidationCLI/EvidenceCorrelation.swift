@preconcurrency import AppKit
import ArgumentParser
import ComputerMCPValidation
import CryptoKit
import Foundation

struct EvidenceCorrelate: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "correlate",
    abstract:
      "Correlate observed results with transport, gateway request, audit, and independent evidence."
  )

  @Option(name: .customLong("run-id"), help: "Stable identifier for this Validation Run.")
  var runID: String

  @Option(name: .long, help: "Current Validation Observation Bundle JSON path.")
  var observations: String

  @Option(name: .long, help: "Capability inventory JSON path.")
  var inventory: String

  @Option(name: .long, help: "Inventory configuration bound to this Validation Run.")
  var configurationName = "runtime-default.chatgpt-observe.toml"

  @Option(name: .long, help: "Content-addressed capability fixture report path.")
  var fixtures: String

  @Option(name: .long, help: "Path to the Computer MCP active Gateway database.")
  var database: String?

  @Option(name: .long, help: "Path to the Computer MCP App gateway socket.")
  var socket: String?

  @Option(name: .long, help: "Computer MCP.app bundle used to bind build identity.")
  var appBundle: String?

  @Option(
    name: .customLong("gateway-executable"),
    help: "Gateway executable used by this run. Defaults to the App's embedded CLI."
  )
  var gatewayExecutable: String?

  @Option(name: .long, help: "Active current manifest used to bind configuration identity.")
  var manifest: String?

  @Option(
    name: .customLong("evidence-bundle"),
    help: "Destination for the canonical Validation Evidence Bundle."
  )
  var evidenceBundlePath: String

  mutating func run() async throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let observationBundle = try ValidationObservationBundle.decodeJSON(
      Data(contentsOf: URL(fileURLWithPath: observations))
    )
    let databaseURL =
      database.map { URL(fileURLWithPath: $0) }
      ?? home.appendingPathComponent(
        "Library/Application Support/Computer MCP/gateway.sqlite"
      )
    let socketURL =
      socket.map { URL(fileURLWithPath: $0) }
      ?? home.appendingPathComponent(
        observationBundle.transport.transport == .controlSocket
          ? "Library/Application Support/Computer MCP/Runtime/control.sock"
          : "Library/Application Support/Computer MCP/Runtime/gateway.sock"
      )
    let manifestURL =
      manifest.map { URL(fileURLWithPath: $0) }
      ?? home.appendingPathComponent(
        "Library/Application Support/Computer MCP/Configuration/computer-mcp.toml"
      )
    let inventoryReport = try CapabilityInventoryReport.decodeJSON(
      Data(contentsOf: URL(fileURLWithPath: inventory))
    )
    guard
      let inventoryProfile = inventoryReport.profiles.first(where: {
        $0.configuration == configurationName
      })
    else {
      throw ValidationError(
        "Inventory has no current profile '\(configurationName)'."
      )
    }
    if !inventoryProfile.requiresRuntimeEvidence,
      ![ValidationTransport.controlSocket, .cloudflareQuickTunnel].contains(
        observationBundle.transport.transport
      )
    {
      throw ValidationError(
        "Inventory profile '\(configurationName)' is contract-only for this transport."
      )
    }
    let fixtureReport = try CapabilityFixtureReport.decodeJSON(
      Data(contentsOf: URL(fileURLWithPath: fixtures))
    )
    let catalogDigest = try await catalogDigest(
      for: observationBundle.transport,
      socketURL: socketURL,
      inventoryProfile: inventoryProfile
    )
    let appURL = try resolveAppBundle()
    let environment = try makeEnvironment(
      appURL: appURL,
      manifestURL: manifestURL,
      inventoryProfile: inventoryProfile,
      fixtureReport: fixtureReport,
      catalogDigest: catalogDigest
    )
    let gatewayDatabase = try GatewayDatabase(path: databaseURL.path)
    let evidenceBundle = try ValidationObservationCollector(
      database: gatewayDatabase
    ).collect(
      observations: observationBundle,
      runID: runID,
      environment: environment
    )
    let destination = URL(fileURLWithPath: evidenceBundlePath)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try evidenceBundle.canonicalJSON().write(to: destination, options: .atomic)
    let attemptCount = evidenceBundle.runs.reduce(0) { $0 + $1.attempts.count }
    print(
      "Validation Evidence Bundle \(evidenceBundle.id): \(attemptCount) attempts, "
        + "digest \(evidenceBundle.contentDigest)."
    )
  }

  private func resolveAppBundle() throws -> URL {
    if let appBundle {
      return URL(fileURLWithPath: appBundle, isDirectory: true)
    }
    if let running = NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.showxu.computer-mcp"
    ).first?.bundleURL {
      return running
    }
    throw ValidationError(
      "Computer MCP.app is not running. Pass --app-bundle to bind an explicit bundle."
    )
  }

  private func validateCatalog(
    _ tools: [GatewaySocketCatalogTool],
    against profile: CapabilityInventoryProfile
  ) throws -> String {
    let actualNames = tools.map(\.name)
    guard actualNames == profile.toolNames.sorted() else {
      let missing = Set(profile.toolNames).subtracting(actualNames).sorted()
      let unexpected = Set(actualNames).subtracting(profile.toolNames).sorted()
      throw ValidationError(
        "Active App catalog differs from inventory; missing=\(missing), unexpected=\(unexpected)."
      )
    }
    let expected = Dictionary(
      uniqueKeysWithValues: profile.tools.map { ($0.name, $0.schemaDigest) }
    )
    let mismatched = try tools.compactMap { tool -> String? in
      let actual = digest(try sortedJSON(tool.gatewayToolJSON))
      return expected[tool.name] == actual ? nil : tool.name
    }
    guard mismatched.isEmpty else {
      throw ValidationError(
        "Active App tool schemas differ from inventory: \(mismatched.sorted())."
      )
    }
    return digest(try sortedJSON(tools.map(\.gatewayToolJSON)))
  }

  private func catalogDigest(
    for provenance: ValidationTransportProvenance,
    socketURL: URL,
    inventoryProfile: CapabilityInventoryProfile
  ) async throws -> String {
    switch provenance.transport {
    case .gatewaySocket, .openAISecureMCPTunnel:
      let catalog = try await GatewaySocketCatalogInspector().inspect(
        configuration: try ValidationSocketCatalogConfiguration.resolve(
          socketURL: socketURL,
          provenance: provenance
        )
      )
      return try validateCatalog(catalog.tools, against: inventoryProfile)
    case .controlSocket:
      let catalog = try await GatewaySocketCatalogInspector().inspect(
        configuration: try ValidationSocketCatalogConfiguration.resolve(
          socketURL: socketURL,
          provenance: provenance
        )
      )
      return digest(try sortedJSON(catalog.tools.map(\.gatewayToolJSON)))
    case .cloudflareTunnel, .cloudflareQuickTunnel:
      return digest(
        try sortedJSON(
          inventoryProfile.tools.map {
            ["name": $0.name, "schema_digest": $0.schemaDigest]
          }
        )
      )
    }
  }

  private func makeEnvironment(
    appURL: URL,
    manifestURL: URL,
    inventoryProfile: CapabilityInventoryProfile,
    fixtureReport: CapabilityFixtureReport,
    catalogDigest: String
  ) throws -> ValidationEnvironment {
    guard let bundle = Bundle(url: appURL),
      let executableURL = bundle.executableURL,
      let profileID = GatewayProfileID(rawValue: inventoryProfile.profile)
    else {
      throw ValidationError("App bundle or inventory release profile is invalid.")
    }
    let embeddedCLI =
      gatewayExecutable.map { URL(fileURLWithPath: $0).standardizedFileURL }
      ?? appURL.appendingPathComponent(
        "Contents/Resources/computer-mcp",
        isDirectory: false
      )
    return ValidationEnvironment(
      appBundleIdentifier:
        bundle.bundleIdentifier
        ?? "com.showxu.computer-mcp",
      appVersion:
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "development",
      appBuild:
        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        ?? "development",
      appDigest: try fileDigest(executableURL),
      buildDigest: try fileDigest(embeddedCLI),
      configuration: inventoryProfile.configuration,
      configurationDigest: try fileDigest(manifestURL),
      catalogDigest: catalogDigest,
      profileID: profileID,
      profileDigest: inventoryProfile.acceptanceDigest,
      fixtureDigest: fixtureReport.contentDigest
    )
  }

  private func sortedJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func fileDigest(_ url: URL) throws -> String {
    digest(try Data(contentsOf: url, options: [.mappedIfSafe]))
  }
}

struct EvidenceVerify: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "verify",
    abstract: "Verify a Validation Evidence Bundle and its optional live audit rows."
  )

  @Option(name: .customLong("evidence-bundle"), help: "Validation Evidence Bundle path.")
  var evidenceBundle: String

  @Option(name: .long, help: "Optional Gateway database for exact audit-row verification.")
  var database: String?

  @Option(name: .long, help: "Optional destination for the verification JSON.")
  var output: String?

  func run() throws {
    let bundle = try ValidationEvidenceBundle.decodeCanonicalJSON(
      Data(contentsOf: URL(fileURLWithPath: evidenceBundle))
    )
    let verifier = ValidationEvidenceBundleVerifier()
    let report: ValidationEvidenceVerificationReport
    if let database {
      report = verifier.verify(bundle, database: try GatewayDatabase(path: database))
    } else {
      report = verifier.verify(bundle)
    }
    let encoder = CanonicalJSONCoding.encoder(
      outputFormatting: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    let data = try encoder.encode(report)
    if let output {
      let url = URL(fileURLWithPath: output).standardizedFileURL
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: url, options: .atomic)
    } else {
      print(String(decoding: data, as: UTF8.self))
    }
    guard report.isVerified else { throw ExitCode.failure }
  }
}
