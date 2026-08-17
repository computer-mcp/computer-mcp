import ArgumentParser
import ComputerMCPValidation
import CryptoKit
import Darwin
import Foundation
import MCP

@main
struct ComputerMCPValidationCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "computer-mcp-validate",
    abstract: "Generate, correlate, and verify Computer MCP validation artifacts.",
    subcommands: [
      TestCaseCommand.self,
      RunbookCommand.self,
      InventoryCommand.self,
      FixtureCommand.self,
      ProbeCommand.self,
      EvidenceCommand.self,
      ReportCommand.self,
    ]
  )
}

struct InventoryCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "inventory",
    abstract: "Generate the machine-readable capability inventory.",
    subcommands: [Inventory.self]
  )
}

struct FixtureCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "fixture",
    abstract: "Generate or serve deterministic validation fixtures.",
    subcommands: [
      WorkspaceFixtureCommand.self, ManifestFixtureCommand.self, MCPFixtureCommand.self,
    ]
  )
}

struct WorkspaceFixtureCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "workspace",
    subcommands: [WorkspaceFixtureGenerate.self]
  )
}

struct ManifestFixtureCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "manifest",
    subcommands: [ManifestFixtureGenerate.self]
  )
}

struct MCPFixtureCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mcp",
    subcommands: [MCPFixtureServe.self]
  )
}

struct ProbeCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "probe",
    abstract: "Collect auxiliary observations that cannot independently produce PASS.",
    subcommands: [
      AppProbeCommand.self, ProviderProbeCommand.self, HTTPProbeCommand.self,
      DownstreamProbeCommand.self, GatewayProbeCommand.self, CodexProbeCommand.self,
    ]
  )
}

struct AppProbeCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "app",
    subcommands: [
      AppCatalogProbe.self, AppCallProbe.self, AppFullCatalogProbe.self,
      AppComputerUseSurfaceProbe.self,
    ]
  )
}

struct ProviderProbeCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "provider",
    subcommands: [ProviderDiscover.self]
  )
}

struct HTTPProbeCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "http",
    subcommands: [HTTPCallProbe.self]
  )
}

struct DownstreamProbeCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "downstream",
    subcommands: [DownstreamProbeVerify.self]
  )
}

struct GatewayProbeCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "gateway",
    subcommands: [GatewayProbeVerify.self]
  )
}

struct CodexProbeCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "codex",
    subcommands: [CodexProbeVerify.self]
  )
}

struct EvidenceCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "evidence",
    abstract: "Correlate and verify Validation Evidence Bundles.",
    subcommands: [EvidenceCorrelate.self, EvidenceVerify.self]
  )
}

struct ReportCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "report",
    abstract: "Generate a fail-closed Production Readiness Report.",
    subcommands: [
      ReportGenerate.self,
      ReportVerify.self,
      VerificationRecordCommand.self,
      ReleaseManifestGenerate.self,
      ReleaseManifestVerify.self,
    ]
  )
}

struct ManifestFixtureGenerate: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "generate",
    abstract:
      "Generate a runtime-default manifest with the deterministic downstream MCP fixture."
  )

  @Option(name: .long, help: "Destination for the validated TOML manifest.")
  var output: String

  @Option(name: .long, help: "Absolute path to the computer-mcp-validate executable.")
  var fixtureExecutable: String

  @Option(name: .long, help: "Absolute provider-start marker path.")
  var startMarker: String

  @Flag(name: .long, help: "Replace an existing destination.")
  var force = false

  mutating func run() throws {
    let destination = URL(fileURLWithPath: output).standardizedFileURL
    let executable = URL(fileURLWithPath: fixtureExecutable).standardizedFileURL
    let marker = URL(fileURLWithPath: startMarker).standardizedFileURL
    guard executable.path.hasPrefix("/"), marker.path.hasPrefix("/") else {
      throw ValidationError("fixture-executable and start-marker must be absolute paths.")
    }
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw ValidationError("fixture-executable is missing or is not executable.")
    }
    if FileManager.default.fileExists(atPath: destination.path), !force {
      throw ValidationError("output already exists; pass --force to replace it.")
    }

    let product = try ValidationProductCommand()
    let defaultManifest = String(decoding: try product.run(["config", "defaults"]), as: UTF8.self)
    let manifest =
      defaultManifest.trimmingCharacters(in: .whitespacesAndNewlines)
        + """


        [[mcp.servers]]
        id = "fixture-stdio"
        transport = "stdio"
        command = \(Self.tomlString(executable.path))
        args = [
          "fixture",
          "mcp",
          "serve",
          "--start-marker",
          \(Self.tomlString(marker.path)),
        ]
        exposure = "reexport"
        prefix = "fixture_stdio"
        capabilities = ["tools", "resources", "prompts"]
        allowed_tools = [
          "fixture_echo",
          "fixture_hang",
          "fixture_enable_drift",
          "fixture_crash",
        ]
        startup_timeout_ms = 5000
        request_timeout_ms = 5000
        """
      + "\n"

    let directory = destination.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let validationURL = directory.appendingPathComponent(
      ".\(destination.lastPathComponent).\(UUID().uuidString).validation"
    )
    defer { try? FileManager.default.removeItem(at: validationURL) }
    try Data(manifest.utf8).write(to: validationURL, options: .atomic)
    _ = try product.run(["config", "validate", "--config", validationURL.path])
    try Data(manifest.utf8).write(to: destination, options: .atomic)
    print(destination.path)
  }

  private static func tomlString(_ value: String) -> String {
    "\""
      + value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r")
      .replacingOccurrences(of: "\t", with: "\\t")
      + "\""
  }
}

struct Inventory: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "generate",
    abstract: "Generate a static capability inventory without executing tools."
  )

  @Option(name: .long, help: "Directory containing computer-mcp TOML profiles.")
  var examplesDir: String

  @Option(name: .long, help: "Destination path for the machine-readable JSON report.")
  var json: String

  @Option(name: .long, help: "Destination path for the Markdown report.")
  var markdown: String

  @Option(
    name: .customLong("runtime-config"),
    help:
      "Validated current manifest to project across all built-in profiles. Repeat for multiple manifests."
  )
  var runtimeConfigs: [String] = []

  @Flag(
    name: .long,
    help: "Exclude embedded runtime defaults; requires at least one --runtime-config."
  )
  var omitRuntimeDefaults = false

  @Flag(name: .long, help: "Exit nonzero after writing reports when inventory issues exist.")
  var strict = false

  mutating func run() throws {
    guard !omitRuntimeDefaults || !runtimeConfigs.isEmpty else {
      throw ValidationError(
        "--omit-runtime-defaults requires at least one --runtime-config."
      )
    }
    let temporaryDefaultManifest = FileManager.default.temporaryDirectory
      .appendingPathComponent("computer-mcp-default-\(UUID().uuidString).toml")
    defer { try? FileManager.default.removeItem(at: temporaryDefaultManifest) }
    var runtimeConfigurations: [CapabilityInventoryConfiguration] = []
    if !omitRuntimeDefaults {
      try ValidationProductCommand().run(["config", "defaults"]).write(
        to: temporaryDefaultManifest,
        options: .atomic
      )
      runtimeConfigurations = try CapabilityInventoryConfiguration.runtimeManifest(
        at: temporaryDefaultManifest
      ).map { configuration in
        CapabilityInventoryConfiguration(
          name: configuration.name.replacingOccurrences(
            of: temporaryDefaultManifest.deletingPathExtension().lastPathComponent,
            with: "runtime-default"
          ),
          configurationURL: configuration.configurationURL,
          caller: configuration.caller,
          profileID: configuration.profileID,
          requiresRuntimeEvidence: configuration.requiresRuntimeEvidence
        )
      }
    }
    for path in runtimeConfigs {
      runtimeConfigurations.append(
        contentsOf: try CapabilityInventoryConfiguration.runtimeManifest(
          at: URL(fileURLWithPath: path)
        )
      )
    }
    let report = try CapabilityInventoryBuilder().build(
      examplesDirectory: URL(fileURLWithPath: examplesDir, isDirectory: true),
      additionalConfigurations: runtimeConfigurations
    )
    try writeAtomically(
      report.encodedJSON(),
      to: URL(fileURLWithPath: json)
    )
    try writeAtomically(
      Data(report.markdown().utf8),
      to: URL(fileURLWithPath: markdown)
    )

    print(
      "Inventory: \(report.summary.profileCount) profiles, "
        + "\(report.summary.uniqueToolCount) unique tools, "
        + "\(report.summary.issueCount) issues."
    )
    if strict && !report.isValid {
      throw ExitCode.failure
    }
  }

  private func writeAtomically(_ data: Data, to destination: URL) throws {
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: destination, options: .atomic)
  }
}

struct WorkspaceFixtureGenerate: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "generate",
    abstract: "Generate an isolated deterministic capability fixture workspace."
  )

  @Option(
    name: .long,
    help: "Destination directory for the generated fixture workspace."
  )
  var destination = ".build/validation/fixtures"

  @Option(name: .long, help: "Optional destination for the fixture JSON report.")
  var json: String?

  @Flag(
    name: .long,
    help: "Replace an existing destination only when it has the Validation owner marker."
  )
  var force = false

  mutating func run() throws {
    let report = try CapabilityFixtureGenerator().generate(
      at: URL(fileURLWithPath: destination, isDirectory: true),
      force: force
    )
    let data = try report.encodedJSON()
    if let json {
      let destination = URL(fileURLWithPath: json)
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: destination, options: .atomic)
    } else {
      print(String(decoding: data, as: UTF8.self))
    }
    print("WorkspaceFixtureGenerate: \(report.entryCount) entries at \(report.rootPath).")
  }
}

struct ReportGenerate: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "generate",
    abstract: "Generate a fail-closed Production Readiness Report."
  )

  @Option(name: .long, help: "Capability inventory JSON path.")
  var inventory: String

  @Option(name: .long, help: "Optional capability fixture JSON path.")
  var fixture: String?

  @Option(
    name: .customLong("evidence-bundle"),
    help: "Verified Validation Evidence Bundle path. Repeat for multiple bundles."
  )
  var evidenceBundles: [String] = []

  @Option(name: .long, help: "Destination path for the report JSON.")
  var json: String

  @Option(name: .long, help: "Destination path for the report Markdown.")
  var markdown: String

  mutating func run() throws {
    let inventoryReport = try CapabilityInventoryReport.decodeJSON(
      Data(contentsOf: URL(fileURLWithPath: inventory))
    )
    let fixtureReport: CapabilityFixtureReport?
    if let fixture {
      fixtureReport = try CapabilityFixtureReport.decodeJSON(
        Data(contentsOf: URL(fileURLWithPath: fixture))
      )
    } else {
      fixtureReport = nil
    }
    let bundles = try evidenceBundles.map {
      try ValidationEvidenceBundle.decodeCanonicalJSON(
        Data(contentsOf: URL(fileURLWithPath: $0))
      )
    }
    let report = ProductionReadinessReportBuilder().build(
      inventory: inventoryReport,
      fixtureReport: fixtureReport,
      evidenceBundles: bundles
    )
    try write(report.encodedJSON(), to: URL(fileURLWithPath: json))
    try write(Data(report.markdown().utf8), to: URL(fileURLWithPath: markdown))
    print(
      "Production Readiness Report: \(report.summary.entryCount) capabilities, "
        + "\(report.summary.pendingCount) pending, "
        + "\(report.summary.failedCount) failed, "
        + "\(report.summary.testCasePendingCount) Test Cases pending, "
        + "\(report.summary.issueCount) issues."
    )
    if !report.isReady {
      throw ExitCode.failure
    }
  }

  private func write(_ data: Data, to destination: URL) throws {
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: destination, options: .atomic)
  }
}

struct ReportVerify: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "verify",
    abstract: "Verify a canonical ready Production Readiness Report."
  )

  @Option(name: .long, help: "Production Readiness Report JSON path.")
  var report: String

  func run() throws {
    let value = try ProductionReadinessReport.decodeJSON(
      Data(contentsOf: URL(fileURLWithPath: report).standardizedFileURL)
    )
    print(
      "Production Readiness Report verified: "
        + "\(value.summary.testCasePassedCount)/\(value.summary.testCaseCount), "
        + "\(value.summary.issueCount) issues."
    )
    guard value.isReady else { throw ExitCode.failure }
  }
}

struct VerificationRecordCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "verification-record",
    abstract: "Generate or verify a digest-only journey or platform record.",
    subcommands: [VerificationRecordGenerate.self, VerificationRecordVerify.self]
  )
}

struct VerificationRecordGenerate: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "generate",
    abstract: "Seal one digest-only release verification record."
  )

  @Option(name: .customLong("app-bundle"), help: "Final Computer MCP.app bundle path.")
  var appBundle: String

  @Option(name: .long, help: "Final notarized DMG path.")
  var dmg: String

  @Option(name: .long, help: "One required journey.* or platform.* record ID.")
  var id: String

  @Option(name: .long, help: "Redacted procedure record to hash.")
  var procedure: String

  @Option(name: .long, help: "Redacted result record to hash.")
  var result: String

  @Option(name: .long, help: "Redacted cleanup record to hash.")
  var cleanup: String

  @Option(name: .customLong("generated-at"), help: "Optional stable ISO-8601 timestamp.")
  var generatedAt: String?

  @Option(name: .long, help: "Destination for the canonical record JSON.")
  var output: String

  func run() throws {
    let record = try ReleaseVerificationRecordDocument.sealed(
      id: id,
      generatedAt: generatedAt ?? ValidationTimestamp.now(),
      candidate: try resolveReleaseCandidate(appBundle: appBundle, dmg: dmg),
      procedureSHA256: try releaseFileDigest(URL(fileURLWithPath: procedure)),
      resultSHA256: try releaseFileDigest(URL(fileURLWithPath: result)),
      cleanupSHA256: try releaseFileDigest(URL(fileURLWithPath: cleanup))
    )
    let destination = URL(fileURLWithPath: output).standardizedFileURL
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try record.canonicalJSON().write(to: destination, options: .atomic)
    print("Release Verification Record \(record.id): digest \(record.contentDigest).")
  }
}

struct VerificationRecordVerify: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "verify",
    abstract: "Verify one canonical digest-only release record."
  )

  @Option(name: .long, help: "Release Verification Record JSON path.")
  var record: String

  func run() throws {
    let value = try ReleaseVerificationRecordDocument.decodeCanonicalJSON(
      Data(contentsOf: URL(fileURLWithPath: record).standardizedFileURL)
    )
    print("Release Verification Record \(value.id) verified: digest \(value.contentDigest).")
  }
}

struct ReleaseManifestGenerate: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "release-manifest",
    abstract: "Generate the redacted public manifest for a verified release."
  )

  @Option(name: .customLong("app-bundle"), help: "Final Computer MCP.app bundle path.")
  var appBundle: String

  @Option(name: .long, help: "Final notarized DMG path.")
  var dmg: String

  @Option(name: .customLong("readiness-report"), help: "Ready report JSON path.")
  var readinessReport: String

  @Option(name: .customLong("evidence-archive"), help: "Private evidence archive path.")
  var evidenceArchive: String

  @Option(
    name: .customLong("evidence-bundle"),
    help: "Verified Evidence Bundle path. Repeat for every bundle used by the report."
  )
  var evidenceBundles: [String] = []

  @Option(
    name: .customLong("verification-record"),
    help: "Redacted journey or platform record as id=path. Repeat for all five required IDs."
  )
  var verificationRecords: [String] = []

  @Option(name: .long, help: "Signed release tag, for example v1.0.0.")
  var tag: String

  @Option(name: .customLong("generated-at"), help: "Optional stable ISO-8601 timestamp.")
  var generatedAt: String?

  @Option(name: .long, help: "Destination for the canonical public manifest JSON.")
  var output: String

  mutating func run() throws {
    let candidate = try resolveReleaseCandidate(appBundle: appBundle, dmg: dmg)
    let reportURL = URL(fileURLWithPath: readinessReport).standardizedFileURL
    let report = try ProductionReadinessReport.decodeJSON(Data(contentsOf: reportURL))
    let bundleInputs = try evidenceBundles.map { path in
      let url = URL(fileURLWithPath: path).standardizedFileURL
      return (
        sha256: try releaseFileDigest(url),
        bundle: try ValidationEvidenceBundle.decodeCanonicalJSON(Data(contentsOf: url))
      )
    }
    let identity = ReleaseArtifactIdentity(
      version: candidate.version,
      build: candidate.build,
      tag: tag,
      commit: candidate.commit,
      teamID: candidate.teamID,
      appExecutableSHA256: candidate.appExecutableSHA256,
      embeddedCLISHA256: candidate.embeddedCLISHA256,
      dmgSHA256: candidate.dmgSHA256,
      readinessReportSHA256: try releaseFileDigest(reportURL),
      evidenceArchiveSHA256: try releaseFileDigest(
        URL(fileURLWithPath: evidenceArchive).standardizedFileURL
      )
    )
    let records = try verificationRecords.map {
      try parseVerificationRecord($0, release: identity)
    }
    let manifest = try ReleaseEvidenceManifestBuilder.build(
      generatedAt: generatedAt ?? ValidationTimestamp.now(),
      release: identity,
      readinessReport: report,
      evidenceBundles: bundleInputs,
      verificationRecords: records
    )
    let destination = URL(fileURLWithPath: output).standardizedFileURL
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try manifest.canonicalJSON().write(to: destination, options: .atomic)
    print(
      "Release Evidence Manifest: \(report.summary.testCasePassedCount)/"
        + "\(report.summary.testCaseCount) Test Cases, "
        + "\(bundleInputs.count) Evidence Bundles, digest \(manifest.contentDigest)."
    )
  }

  private func parseVerificationRecord(
    _ value: String,
    release: ReleaseArtifactIdentity
  ) throws -> ReleaseVerificationRecord {
    guard let separator = value.firstIndex(of: "=") else {
      throw ValidationError("verification-record must use id=path.")
    }
    let id = String(value[..<separator])
    let path = String(value[value.index(after: separator)...])
    guard !id.isEmpty, !path.isEmpty else {
      throw ValidationError("verification-record must use non-empty id=path values.")
    }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let document = try ReleaseVerificationRecordDocument.decodeCanonicalJSON(
      Data(contentsOf: url)
    )
    let expectedCandidate = ReleaseCandidateIdentity(
      version: release.version,
      build: release.build,
      commit: release.commit,
      teamID: release.teamID,
      appExecutableSHA256: release.appExecutableSHA256,
      embeddedCLISHA256: release.embeddedCLISHA256,
      dmgSHA256: release.dmgSHA256
    )
    guard document.id == id, document.candidate == expectedCandidate else {
      throw ValidationError(
        "verification-record '\(id)' does not match its ID or release candidate."
      )
    }
    return ReleaseVerificationRecord(
      id: id,
      sha256: try releaseFileDigest(url)
    )
  }
}

struct ReleaseManifestVerify: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "verify-release-manifest",
    abstract: "Verify a canonical redacted Release Evidence Manifest."
  )

  @Option(name: .long, help: "Release Evidence Manifest JSON path.")
  var manifest: String

  func run() throws {
    let value = try ReleaseEvidenceManifest.decodeCanonicalJSON(
      Data(contentsOf: URL(fileURLWithPath: manifest).standardizedFileURL)
    )
    print(
      "Release Evidence Manifest verified: "
        + "\(value.acceptance.testCasePassedCount)/\(value.acceptance.testCaseCount), "
        + "\(value.evidenceBundles.count) Evidence Bundles, digest \(value.contentDigest)."
    )
  }
}

private func resolveReleaseCandidate(
  appBundle: String,
  dmg: String
) throws -> ReleaseCandidateIdentity {
  let appURL = URL(fileURLWithPath: appBundle, isDirectory: true).standardizedFileURL
  let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
  let appExecutable = appURL.appendingPathComponent("Contents/MacOS/Computer MCP")
  let embeddedCLI = appURL.appendingPathComponent("Contents/Resources/computer-mcp")
  let infoData = try Data(contentsOf: infoURL)
  guard
    let info = try PropertyListSerialization.propertyList(from: infoData, format: nil)
      as? [String: Any],
    let version = info["CFBundleShortVersionString"] as? String,
    let build = info["CFBundleVersion"] as? String,
    let commit = info["ComputerMCPSourceCommit"] as? String,
    let teamID = info["ComputerMCPTeamIdentifier"] as? String,
    let expectedCLIHash = info["ComputerMCPEmbeddedCLIHash"] as? String
  else {
    throw ValidationError("App Info.plist is missing the signed release identity.")
  }
  let appHash = try releaseFileDigest(appExecutable)
  let cliHash = try releaseFileDigest(embeddedCLI)
  guard cliHash == expectedCLIHash else {
    throw ValidationError("Embedded CLI digest does not match the signed App identity.")
  }
  return ReleaseCandidateIdentity(
    version: version,
    build: build,
    commit: commit,
    teamID: teamID,
    appExecutableSHA256: appHash,
    embeddedCLISHA256: cliHash,
    dmgSHA256: try releaseFileDigest(URL(fileURLWithPath: dmg).standardizedFileURL)
  )
}

private func releaseFileDigest(_ url: URL) throws -> String {
  let data = try Data(contentsOf: url.standardizedFileURL, options: [.mappedIfSafe])
  return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

struct GatewaySocketIdentityOptions: ParsableArguments {
  @Option(
    name: .customLong("tunnel-credential-file"),
    help: "Optional App-generated credential used to bind a Secure Tunnel identity."
  )
  var tunnelCredentialFile: String?

  @Option(
    name: .customLong("tunnel-profile-id"),
    help: "Stable Tunnel profile id. Required with --tunnel-credential-file."
  )
  var tunnelProfileID: String?

  @Option(
    name: .customLong("tunnel-instance-id"),
    help: "Optional Tunnel instance id recorded in audit provenance."
  )
  var tunnelInstanceID: String?

  var isConfigured: Bool {
    tunnelCredentialFile != nil || tunnelProfileID != nil || tunnelInstanceID != nil
  }

  func configuration(socketURL: URL) throws -> GatewaySocketConfiguration {
    guard (tunnelCredentialFile == nil) == (tunnelProfileID == nil) else {
      throw ValidationError(
        "--tunnel-credential-file and --tunnel-profile-id must be provided together."
      )
    }
    guard tunnelCredentialFile != nil || tunnelInstanceID == nil else {
      throw ValidationError(
        "--tunnel-instance-id requires --tunnel-credential-file and --tunnel-profile-id."
      )
    }
    var configuration = GatewaySocketConfiguration(socketURL: socketURL)
    if let tunnelCredentialFile, let tunnelProfileID {
      let credentialURL = URL(fileURLWithPath: tunnelCredentialFile)
      let instanceID = tunnelInstanceID ?? "computer-mcp-validate-\(UUID().uuidString)"
      configuration.tunnelCredentialFile = credentialURL
      configuration.clientIdentity = .secureTunnel(
        credentialFile: credentialURL,
        tunnelInstanceID: instanceID,
        tunnelProfileID: tunnelProfileID
      )
    }
    return configuration
  }
}

struct AppCatalogProbe: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "catalog",
    abstract: "Inspect the catalog returned by the active App Unix socket."
  )

  @Option(name: .long, help: "Path to the Computer MCP App gateway socket.")
  var socket: String?

  @OptionGroup var socketIdentity: GatewaySocketIdentityOptions

  @Option(name: .long, help: "Optional destination for the JSON report.")
  var json: String?

  mutating func run() async throws {
    let socketURL =
      socket.map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(
        "Library/Application Support/Computer MCP/Runtime/gateway.sock"
      )
    let socketConfiguration = try socketIdentity.configuration(socketURL: socketURL)
    let report = try await GatewaySocketCatalogInspector().inspect(
      configuration: socketConfiguration
    )
    let data = try report.encodedJSON()
    if let json {
      let destination = URL(fileURLWithPath: json)
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: destination, options: .atomic)
    } else {
      print(String(decoding: data, as: UTF8.self))
    }
  }
}

struct AppCallProbe: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "call",
    abstract: "Call one tool through the active App Unix socket."
  )

  @Option(name: .long, help: "Path to the Computer MCP App gateway socket.")
  var socket: String?

  @OptionGroup var socketIdentity: GatewaySocketIdentityOptions

  @Option(name: .long, help: "Exact MCP tool name.")
  var tool: String

  @Option(name: .long, help: "JSON object containing tool arguments.")
  var argumentsJSON = "{}"

  @Option(name: .long, help: "Optional destination for the JSON report.")
  var json: String?

  @Flag(
    name: .customLong("control-socket"),
    help: "Call the owner-only App Control Socket instead of the Gateway Socket."
  )
  var controlSocket = false

  @Option(name: .customLong("run-id"), help: "Validation Run identifier for observations.")
  var runID: String?

  @Option(name: .customLong("test-case"), help: "Validation Test Case identifier.")
  var testCaseID: String?

  @Option(
    name: .customLong("assertion-id"),
    help: "Explicit passed assertion id. Repeat for each observed step and expected result."
  )
  var assertionIDs: [String] = []

  @Option(name: .customLong("postcondition-id"), help: "Independent cleanup postcondition id.")
  var postconditionID: String?

  @Option(
    name: .customLong("postcondition-observer"),
    help: "Independent observer name; gateway_result is prohibited."
  )
  var postconditionObserver: String?

  @Option(
    name: .customLong("postcondition-digest"),
    help: "Lowercase SHA-256 digest captured by the independent observer."
  )
  var postconditionDigest: String?

  @Option(
    name: .long,
    help: "Optional destination for a runtime Validation Observation Bundle."
  )
  var observations: String?

  @Flag(name: .customLong("expected-denial"), help: "Require and record an expected denial.")
  var expectedDenial = false

  mutating func run() async throws {
    let socketURL =
      socket.map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(
        controlSocket
          ? "Library/Application Support/Computer MCP/Runtime/control.sock"
          : "Library/Application Support/Computer MCP/Runtime/gateway.sock"
      )
    let configuration: GatewaySocketConfiguration
    if controlSocket {
      guard !socketIdentity.isConfigured else {
        throw ValidationError(
          "Secure Tunnel identity options cannot be used with --control-socket.")
      }
      configuration = GatewaySocketConfiguration(
        socketURL: socketURL,
        clientIdentity: .localCLI
      )
    } else {
      configuration = try socketIdentity.configuration(socketURL: socketURL)
    }
    let report = try await GatewayCallInspector().callSocket(
      configuration: configuration,
      toolName: tool,
      arguments: try decodeArguments(argumentsJSON)
    )
    try writeReport(report, destination: json)
    if let observations {
      try writeObservationBundle(report, destination: observations)
    }
  }

  private func writeObservationBundle(
    _ report: GatewayCallReport,
    destination: String
  ) throws {
    guard let runID, !runID.isEmpty, let testCaseID, !testCaseID.isEmpty,
      !assertionIDs.isEmpty,
      let postconditionID, !postconditionID.isEmpty,
      let postconditionObserver, !postconditionObserver.isEmpty,
      postconditionObserver != "gateway_result",
      let postconditionDigest, isSHA256(postconditionDigest),
      let gatewayRequestID = report.gatewayRequestID,
      let gatewayExecution = report.result.objectValue?["structuredContent"]?
        .objectValue?["gateway_execution"]?.objectValue,
      let socketConnectionID = gatewayExecution["socket_connection_id"]?.stringValue
    else {
      throw ValidationError(
        "Observations require --run-id, --test-case, --assertion-id, all postcondition fields, and correlated Gateway metadata."
      )
    }
    let isError = report.result.objectValue?["isError"]?.boolValue == true
    guard isError == expectedDenial else {
      throw ValidationError(
        expectedDenial
          ? "The call did not return the required expected denial."
          : "The call returned an error; use --expected-denial only for a reviewed denial."
      )
    }
    let resultData = try report.encodedJSON(prettyPrinted: false)
    let observation = ValidationObservation(
      id: "\(runID).\(tool)",
      testCaseID: testCaseID,
      generatedAt: report.generatedAt,
      toolName: tool,
      transportRequestID: report.requestID,
      gatewayRequestID: gatewayRequestID,
      passed: true,
      observationDigest: sha256(resultData),
      assertionIDs: assertionIDs,
      expectedOutcome: expectedDenial ? .expectedDenial : .passed,
      independentPostconditions: [
        ValidationPostcondition(
          id: postconditionID,
          passed: true,
          observer: postconditionObserver,
          observationDigest: postconditionDigest
        )
      ]
    )
    let transport: ValidationTransportProvenance
    if controlSocket {
      transport = ValidationTransportProvenance(
        transport: .controlSocket,
        socketConnectionID: socketConnectionID
      )
    } else {
      guard let callerValue = gatewayExecution["caller"]?.stringValue,
        let caller = GatewayCallerKind(rawValue: callerValue)
      else {
        throw ValidationError(
          "Gateway observations require a recognized authenticated caller."
        )
      }
      transport = try ValidationTransportProvenance.authenticatedGatewaySocket(
        caller: caller,
        socketConnectionID: socketConnectionID,
        tunnelInstanceID: gatewayExecution["tunnel_instance_id"]?.stringValue,
        tunnelProfileID: gatewayExecution["tunnel_profile_id"]?.stringValue
      )
    }
    let bundle = ValidationObservationBundle(
      generatedAt: report.generatedAt,
      layer: .runtime,
      transport: transport,
      observations: [observation]
    )
    let destinationURL = URL(fileURLWithPath: destination).standardizedFileURL
    try FileManager.default.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try bundle.encodedJSON().write(to: destinationURL, options: .atomic)
  }

  private func isSHA256(_ value: String) -> Bool {
    value.count == 64
      && value.utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
      }
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

struct HTTPCallProbe: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "call",
    abstract: "Call one tool through an MCP Streamable HTTP endpoint."
  )

  @Option(name: .long, help: "Absolute MCP HTTP endpoint URL.")
  var endpoint: String

  @Option(name: .long, help: "Exact MCP tool name.")
  var tool: String

  @Option(name: .long, help: "JSON object containing tool arguments.")
  var argumentsJSON = "{}"

  @Option(
    name: .long,
    help: "Optional environment variable containing a bearer token."
  )
  var accessTokenEnv: String?

  @Flag(name: .long, help: "Use request/response HTTP without the streaming receive channel.")
  var nonStreaming = false

  @Option(name: .long, help: "Optional destination for the JSON report.")
  var json: String?

  @Option(
    name: .customLong("validation-transport"),
    help: "Outer Cloudflare transport recorded when producing observations."
  )
  var validationTransport: ValidationTransport?

  @Option(name: .customLong("run-id"), help: "Validation Run identifier for observations.")
  var runID: String?

  @Option(name: .customLong("test-case"), help: "Validation Test Case identifier.")
  var testCaseID: String?

  @Option(name: .customLong("assertion-id"), help: "Explicit passed assertion id; repeatable.")
  var assertionIDs: [String] = []

  @Option(name: .customLong("consumer-kind"), help: "External MCP consumer kind.")
  var consumerKind: String?

  @Option(name: .customLong("tunnel-instance-id"), help: "Exact Tunnel runtime instance id.")
  var tunnelInstanceID: String?

  @Option(name: .customLong("tunnel-profile-id"), help: "Named Tunnel profile id.")
  var tunnelProfileID: String?

  @Option(name: .customLong("postcondition-id"), help: "Independent cleanup postcondition id.")
  var postconditionID: String?

  @Option(name: .customLong("postcondition-observer"), help: "Independent observer name.")
  var postconditionObserver: String?

  @Option(name: .customLong("postcondition-digest"), help: "Independent lowercase SHA-256 digest.")
  var postconditionDigest: String?

  @Option(name: .long, help: "Optional destination for a Validation Observation Bundle.")
  var observations: String?

  @Flag(name: .customLong("expected-denial"), help: "Require and record an expected denial.")
  var expectedDenial = false

  mutating func run() async throws {
    guard let endpointURL = URL(string: endpoint),
      let scheme = endpointURL.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      endpointURL.host != nil
    else {
      throw ValidationError("endpoint must be an absolute http or https URL.")
    }
    let accessToken = try accessTokenEnv.map { name in
      guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
        throw ValidationError("Environment variable \(name) is missing or empty.")
      }
      return value
    }
    let report = try await GatewayCallInspector().callHTTP(
      endpoint: endpointURL,
      toolName: tool,
      arguments: try decodeArguments(argumentsJSON),
      accessToken: accessToken,
      streaming: !nonStreaming
    )
    try writeReport(report, destination: json)
    if let observations {
      try writeObservationBundle(report, destination: observations)
    }
  }

  private func writeObservationBundle(
    _ report: GatewayCallReport,
    destination: String
  ) throws {
    guard let validationTransport,
      [.cloudflareTunnel, .cloudflareQuickTunnel].contains(validationTransport),
      let runID, !runID.isEmpty, let testCaseID, !testCaseID.isEmpty,
      !assertionIDs.isEmpty,
      let tunnelInstanceID, !tunnelInstanceID.isEmpty,
      let postconditionID, !postconditionID.isEmpty,
      let postconditionObserver, !postconditionObserver.isEmpty,
      postconditionObserver != "gateway_result",
      let postconditionDigest, isSHA256(postconditionDigest),
      let gatewayRequestID = report.gatewayRequestID
    else {
      throw ValidationError(
        "HTTP observations require a Cloudflare validation transport, run, Test Case, assertions, Tunnel instance, postcondition fields, and correlated Gateway metadata."
      )
    }
    let layer: ValidationEvidenceLayer
    let consumer: ValidationConsumer?
    let profileID: String?
    switch validationTransport {
    case .cloudflareTunnel:
      guard let consumerKind, !consumerKind.isEmpty,
        let tunnelProfileID, !tunnelProfileID.isEmpty
      else {
        throw ValidationError(
          "Named Cloudflare Tunnel observations require --consumer-kind and --tunnel-profile-id."
        )
      }
      layer = .externalConsumer
      consumer = ValidationConsumer(kind: consumerKind)
      profileID = tunnelProfileID
    case .cloudflareQuickTunnel:
      guard consumerKind == nil, tunnelProfileID == nil else {
        throw ValidationError(
          "Quick Tunnel observations cannot claim an external consumer or release profile."
        )
      }
      layer = .runtime
      consumer = nil
      profileID = nil
    default:
      throw ValidationError("Unsupported HTTP Validation transport.")
    }
    let isError = report.result.objectValue?["isError"]?.boolValue == true
    guard isError == expectedDenial else {
      throw ValidationError(
        expectedDenial
          ? "The HTTP call did not return the required expected denial."
          : "The HTTP call returned an error; use --expected-denial only for a reviewed denial."
      )
    }
    let resultData = try report.encodedJSON(prettyPrinted: false)
    let observation = ValidationObservation(
      id: "\(runID).\(tool)",
      testCaseID: testCaseID,
      generatedAt: report.generatedAt,
      toolName: tool,
      transportRequestID: report.requestID,
      consumerResultID: layer == .externalConsumer ? "\(runID).\(tool)" : nil,
      gatewayRequestID: gatewayRequestID,
      passed: true,
      observationDigest: sha256(resultData),
      assertionIDs: assertionIDs,
      expectedOutcome: expectedDenial ? .expectedDenial : .passed,
      independentPostconditions: [
        ValidationPostcondition(
          id: postconditionID,
          passed: true,
          observer: postconditionObserver,
          observationDigest: postconditionDigest
        )
      ]
    )
    let bundle = ValidationObservationBundle(
      generatedAt: report.generatedAt,
      layer: layer,
      consumer: consumer,
      transport: ValidationTransportProvenance(
        transport: validationTransport,
        tunnelInstanceID: tunnelInstanceID,
        tunnelProfileID: profileID
      ),
      observations: [observation]
    )
    let destinationURL = URL(fileURLWithPath: destination).standardizedFileURL
    try FileManager.default.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try bundle.encodedJSON().write(to: destinationURL, options: .atomic)
  }

  private func isSHA256(_ value: String) -> Bool {
    value.count == 64
      && value.utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
      }
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

extension ValidationTransport: ExpressibleByArgument {}

struct MCPFixtureServe: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "serve",
    abstract: "Run the deterministic downstream MCP stdio fixture."
  )

  @Option(name: .long, help: "Optional file that receives one line per provider start.")
  var startMarker: String?

  mutating func run() async throws {
    if let startMarker {
      try appendFixtureLine("started", to: URL(fileURLWithPath: startMarker))
    }

    let state = DownstreamFixtureState()
    let server = MCP.Server(
      name: "computer-mcp-downstream-fixture",
      version: "1",
      capabilities: .init(
        prompts: .init(listChanged: true),
        resources: .init(listChanged: true),
        tools: .init(listChanged: true)
      )
    )

    await server.withMethodHandler(MCP.ListTools.self) { _ in
      let driftEnabled = await state.driftEnabled
      var tools = downstreamFixtureTools()
      if driftEnabled {
        tools.append(
          MCP.Tool(
            name: "fixture_added",
            description: "A tool added after the reviewed fixture catalog.",
            inputSchema: .object(["type": .string("object")])
          )
        )
      }
      Task {
        try? await Task.sleep(for: .milliseconds(10))
        try? await server.notify(MCP.ToolListChangedNotification.message())
        try? await server.notify(MCP.ResourceListChangedNotification.message())
        try? await server.notify(MCP.PromptListChangedNotification.message())
      }
      return MCP.ListTools.Result(tools: tools)
    }

    await server.withMethodHandler(MCP.CallTool.self) { params in
      switch params.name {
      case "fixture_echo":
        let value = params.arguments?["value"]?.stringValue ?? ""
        return try MCP.CallTool.Result(
          content: [.text(text: "echo:\(value)", annotations: nil, _meta: nil)],
          structuredContent: ["echo": value],
          isError: false
        )

      case "fixture_hang":
        try await Task.sleep(for: .seconds(300))
        return MCP.CallTool.Result(
          content: [.text(text: "unexpected", annotations: nil, _meta: nil)],
          isError: false
        )

      case "fixture_enable_drift":
        await state.enableDrift()
        try? await server.notify(MCP.ToolListChangedNotification.message())
        return MCP.CallTool.Result(
          content: [.text(text: "drift-enabled", annotations: nil, _meta: nil)],
          isError: false
        )

      case "fixture_crash":
        Task {
          try? await Task.sleep(for: .milliseconds(100))
          Darwin.exit(86)
        }
        return MCP.CallTool.Result(
          content: [.text(text: "provider-exiting", annotations: nil, _meta: nil)],
          isError: false
        )

      case "fixture_added":
        return MCP.CallTool.Result(
          content: [.text(text: "added", annotations: nil, _meta: nil)],
          isError: false
        )

      default:
        throw MCPError.invalidRequest("Unknown fixture tool: \(params.name)")
      }
    }

    await server.withMethodHandler(MCP.ListResources.self) { _ in
      MCP.ListResources.Result(resources: [
        MCP.Resource(
          name: "Fixture Resource",
          uri: "fixture://sample",
          description: "Deterministic downstream resource.",
          mimeType: "text/plain"
        )
      ])
    }
    await server.withMethodHandler(MCP.ListResourceTemplates.self) { _ in
      MCP.ListResourceTemplates.Result(templates: [
        MCP.Resource.Template(
          uriTemplate: "fixture://{name}",
          name: "Fixture Template",
          description: "Deterministic downstream resource template.",
          mimeType: "text/plain"
        )
      ])
    }
    await server.withMethodHandler(MCP.ReadResource.self) { params in
      MCP.ReadResource.Result(contents: [
        .text("resource:\(params.uri)", uri: params.uri, mimeType: "text/plain")
      ])
    }
    await server.withMethodHandler(MCP.ListPrompts.self) { _ in
      MCP.ListPrompts.Result(prompts: [
        MCP.Prompt(
          name: "fixture_prompt",
          description: "Deterministic downstream prompt.",
          arguments: [
            .init(name: "value", description: "Value to echo.", required: false)
          ]
        )
      ])
    }
    await server.withMethodHandler(MCP.GetPrompt.self) { params in
      let value = params.arguments?["value"] ?? "default"
      return MCP.GetPrompt.Result(
        description: "Fixture prompt response.",
        messages: [.user(.text(text: "prompt:\(value)"))]
      )
    }

    try await server.start(transport: MCP.StdioTransport())
    await server.waitUntilCompleted()
  }
}

private actor DownstreamFixtureState {
  private(set) var driftEnabled = false

  func enableDrift() {
    driftEnabled = true
  }
}

private func downstreamFixtureTools() -> [MCP.Tool] {
  [
    MCP.Tool(
      name: "fixture_echo",
      description: "Echo one string through the downstream MCP provider.",
      inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
          "value": .object(["type": .string("string")])
        ]),
      ]),
      annotations: .init(
        title: "Fixture Echo",
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
      ),
      outputSchema: .object([
        "type": .string("object"),
        "properties": .object([
          "echo": .object(["type": .string("string")])
        ]),
        "required": .array([.string("echo")]),
      ])
    ),
    MCP.Tool(
      name: "fixture_hang",
      description: "Wait until the caller cancels the request.",
      inputSchema: .object(["type": .string("object")])
    ),
    MCP.Tool(
      name: "fixture_enable_drift",
      description: "Add one unreviewed tool and emit tools/list_changed.",
      inputSchema: .object(["type": .string("object")])
    ),
    MCP.Tool(
      name: "fixture_crash",
      description: "Return once, then terminate the fixture provider.",
      inputSchema: .object(["type": .string("object")])
    ),
  ]
}

private func appendFixtureLine(_ line: String, to destination: URL) throws {
  try FileManager.default.createDirectory(
    at: destination.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  if !FileManager.default.fileExists(atPath: destination.path) {
    try Data().write(to: destination, options: .atomic)
  }
  let handle = try FileHandle(forWritingTo: destination)
  defer { try? handle.close() }
  try handle.seekToEnd()
  try handle.write(contentsOf: Data("\(line)\n".utf8))
}

struct DownstreamProbeVerify: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "verify",
    abstract:
      "Exercise downstream stdio and HTTP MCP providers through one persistent Gateway session."
  )

  @Option(name: .long, help: "Absolute MCP Streamable HTTP endpoint URL for the Gateway.")
  var endpoint: String?

  @Option(name: .long, help: "Absolute active App Unix socket path.")
  var socket: String?

  @OptionGroup var socketIdentity: GatewaySocketIdentityOptions

  @Option(name: .long, help: "Registered id of the deterministic stdio fixture provider.")
  var stdioServer = "fixture-stdio"

  @Option(name: .long, help: "Registered id of the official HTTP fixture provider.")
  var httpServer = "fixture-http"

  @Option(name: .long, help: "Top-level reexport name for the fixture echo tool.")
  var stdioReexportTool = "fixture_stdio.fixture_echo"

  @Option(name: .long, help: "Provider start marker written by `fixture mcp serve`.")
  var stdioStartMarker: String

  @Option(
    name: .long,
    help: "Optional environment variable containing a Gateway bearer token."
  )
  var accessTokenEnv: String?

  @Option(name: .long, help: "Destination for the bounded JSON report.")
  var json: String

  @Option(name: .customLong("run-id"), help: "Validation Run identifier for observations.")
  var runID: String?

  @Option(
    name: .long,
    help: "Optional destination for lifecycle and drift Validation observations."
  )
  var observations: String?

  mutating func run() async throws {
    guard (endpoint == nil) != (socket == nil) else {
      throw ValidationError("Provide exactly one of --endpoint or --socket.")
    }
    guard endpoint == nil || !socketIdentity.isConfigured else {
      throw ValidationError("Secure Tunnel socket identity options require --socket.")
    }
    let accessToken = try accessTokenEnv.map { name in
      guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
        throw ValidationError("Environment variable \(name) is missing or empty.")
      }
      return value
    }
    let session: GatewayClientSession
    if let endpoint {
      guard let endpointURL = URL(string: endpoint),
        let scheme = endpointURL.scheme?.lowercased(),
        ["http", "https"].contains(scheme),
        endpointURL.host != nil
      else {
        throw ValidationError("endpoint must be an absolute http or https URL.")
      }
      session = try await GatewayClientSession.connectHTTP(
        endpoint: endpointURL,
        accessToken: accessToken
      )
    } else if let socket {
      guard socket.hasPrefix("/") else {
        throw ValidationError("socket must be an absolute path.")
      }
      guard accessTokenEnv == nil else {
        throw ValidationError("access-token-env is available only with --endpoint.")
      }
      let socketConfiguration = try socketIdentity.configuration(
        socketURL: URL(fileURLWithPath: socket)
      )
      session = try await GatewayClientSession.connectSocket(
        configuration: socketConfiguration
      )
    } else {
      throw ValidationError("Provide exactly one of --endpoint or --socket.")
    }
    do {
      var runner = DownstreamProbeVerifyRunner(
        session: session,
        stdioServer: stdioServer,
        httpServer: socket == nil ? httpServer : nil,
        stdioReexportTool: socket == nil ? stdioReexportTool : nil,
        stdioStartMarker: URL(fileURLWithPath: stdioStartMarker)
      )
      let report = try await runner.run()
      await session.disconnect()
      try writeJSONValue(report, destination: json)
      if let observations {
        guard let runID, !runID.isEmpty else {
          throw ValidationError("--observations requires --run-id.")
        }
        let bundle = try runner.observationBundle(runID: runID, report: report)
        let destination = URL(fileURLWithPath: observations).standardizedFileURL
        try FileManager.default.createDirectory(
          at: destination.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try bundle.encodedJSON().write(to: destination, options: .atomic)
      }
    } catch {
      await session.disconnect()
      throw error
    }
  }
}

private struct DownstreamProbeVerifyRunner {
  let session: GatewayClientSession
  let stdioServer: String
  let httpServer: String?
  let stdioReexportTool: String?
  let stdioStartMarker: URL

  private var requestIDs: [String] = []
  private var callReports: [GatewayCallReport] = []

  init(
    session: GatewayClientSession,
    stdioServer: String,
    httpServer: String?,
    stdioReexportTool: String?,
    stdioStartMarker: URL
  ) {
    self.session = session
    self.stdioServer = stdioServer
    self.httpServer = httpServer
    self.stdioReexportTool = stdioReexportTool
    self.stdioStartMarker = stdioStartMarker
  }

  mutating func run() async throws -> JSONValue {
    let servers = try payload(
      await call("mcp.servers.list")
    )
    guard contains(stdioServer, in: servers) else {
      throw ValidationError("Gateway did not expose the downstream stdio fixture provider.")
    }
    if let httpServer, !contains(httpServer, in: servers) {
      throw ValidationError("Gateway did not expose the downstream HTTP fixture provider.")
    }

    let stdio = try await exerciseStdio()
    let http: JSONValue
    if httpServer == nil {
      http = .null
    } else {
      http = try await exerciseHTTP()
    }
    return .object([
      "schema_version": .number(1),
      "generated_at": .string(ValidationTimestamp.now()),
      "request_ids": .array(requestIDs.map(JSONValue.string)),
      "stdio": stdio,
      "http": http,
    ])
  }

  func observationBundle(
    runID: String,
    report: JSONValue
  ) throws -> ValidationObservationBundle {
    let drift = try requiredReport(
      label: "tool drift denial",
      where: { errorCode($0) == "mcp.tool_not_approved" }
    )
    let cancellation = try requiredReport(
      label: "downstream cancellation",
      where: { targetCapability($0) == "mcp.requests.cancel" && !isError($0) }
    )
    let reconnect = try requiredReport(
      label: "post-crash reconnect",
      where: { $0.toolName == "mcp.tools.list" && !isError($0) },
      last: true
    )
    let selected = [drift, cancellation, reconnect]
    let transport = try socketTransportProvenance(reports: selected)
    let postconditionDigest = try downstreamPostconditionDigest(report: report)

    return ValidationObservationBundle(
      generatedAt: report.objectValue?["generated_at"]?.stringValue ?? ValidationTimestamp.now(),
      layer: .runtime,
      transport: transport,
      observations: [
        try observation(
          report: drift,
          runID: runID,
          testCaseID: "mcp.tool_drift_denied",
          expectedOutcome: .expectedDenial,
          postconditionDigest: postconditionDigest
        ),
        try observation(
          report: cancellation,
          runID: runID,
          testCaseID: "runtime.cancellation_propagated",
          expectedOutcome: .passed,
          postconditionDigest: postconditionDigest
        ),
        try observation(
          report: reconnect,
          runID: runID,
          testCaseID: "mcp.downstream_reconnect",
          expectedOutcome: .passed,
          postconditionDigest: postconditionDigest
        ),
      ]
    )
  }

  private func observation(
    report: GatewayCallReport,
    runID: String,
    testCaseID: String,
    expectedOutcome: ValidationAttemptOutcome,
    postconditionDigest: String
  ) throws -> ValidationObservation {
    guard let gatewayRequestID = report.gatewayRequestID else {
      throw ValidationError("Downstream observation is missing Gateway request metadata.")
    }
    return ValidationObservation(
      id: "\(runID).\(testCaseID)",
      testCaseID: testCaseID,
      generatedAt: report.generatedAt,
      toolName: report.toolName,
      transportRequestID: report.requestID,
      gatewayRequestID: gatewayRequestID,
      passed: true,
      observationDigest: sha256(try report.encodedJSON(prettyPrinted: false)),
      assertionIDs: ["step.1", "expected_result.1"],
      expectedOutcome: expectedOutcome,
      independentPostconditions: [
        ValidationPostcondition(
          id: "cleanup.1",
          passed: true,
          observer: "downstream_fixture_report_and_start_marker",
          observationDigest: postconditionDigest
        )
      ]
    )
  }

  private func requiredReport(
    label: String,
    where predicate: (GatewayCallReport) -> Bool,
    last: Bool = false
  ) throws -> GatewayCallReport {
    let report =
      last
      ? callReports.last(where: predicate)
      : callReports.first(where: predicate)
    guard let report else {
      throw ValidationError("Downstream probe did not capture the \(label) request.")
    }
    return report
  }

  private func socketTransportProvenance(
    reports: [GatewayCallReport]
  ) throws -> ValidationTransportProvenance {
    let executions = try reports.map { report -> [String: JSONValue] in
      guard
        let execution = report.result.objectValue?["structuredContent"]?
          .objectValue?["gateway_execution"]?.objectValue
      else {
        throw ValidationError("Downstream observation is missing Gateway execution metadata.")
      }
      return execution
    }
    let callers = Set(executions.compactMap { $0["caller"]?.stringValue })
    let socketConnectionIDs = Set(
      executions.compactMap { $0["socket_connection_id"]?.stringValue }
    )
    guard callers.count == 1, let callerValue = callers.first,
      let caller = GatewayCallerKind(rawValue: callerValue),
      socketConnectionIDs.count == 1, let socketConnectionID = socketConnectionIDs.first
    else {
      throw ValidationError("Downstream observations do not share one authenticated socket.")
    }
    let tunnelInstanceIDs = Set(
      executions.compactMap { $0["tunnel_instance_id"]?.stringValue }
    )
    let tunnelProfileIDs = Set(
      executions.compactMap { $0["tunnel_profile_id"]?.stringValue }
    )
    return try ValidationTransportProvenance.authenticatedGatewaySocket(
      caller: caller,
      socketConnectionID: socketConnectionID,
      tunnelInstanceID: tunnelInstanceIDs.count == 1 ? tunnelInstanceIDs.first : nil,
      tunnelProfileID: tunnelProfileIDs.count == 1 ? tunnelProfileIDs.first : nil
    )
  }

  private func downstreamPostconditionDigest(report: JSONValue) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var data = try encoder.encode(report)
    data.append(try Data(contentsOf: stdioStartMarker))
    return sha256(data)
  }

  private func targetCapability(_ report: GatewayCallReport) -> String? {
    report.result.objectValue?["structuredContent"]?.objectValue?["target_execution"]?
      .objectValue?["capability_id"]?.stringValue
  }

  private func errorCode(_ report: GatewayCallReport) -> String? {
    report.result.objectValue?["structuredContent"]?.objectValue?["error"]?
      .objectValue?["code"]?.stringValue
  }

  private func isError(_ report: GatewayCallReport) -> Bool {
    report.result.objectValue?["isError"]?.boolValue == true
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private mutating func exerciseStdio() async throws -> JSONValue {
    let eventBaseline = try payload(
      await call(
        "mcp.events.read",
        arguments: [
          "server": .string(stdioServer),
          "after_cursor": .number(0),
          "max_results": .number(100),
        ]
      )
    )
    let eventBaselineCursor = eventBaseline.objectValue?["next_cursor"]?.intValue ?? 0
    let tools = try payload(
      await call("mcp.tools.list", arguments: ["server": .string(stdioServer)])
    )
    let status = try payload(
      await call(
        "mcp.servers.status",
        arguments: ["server": .string(stdioServer)]
      )
    )
    let reviewedNames = toolNames(in: tools)
    let requiredNames = Set([
      "fixture_echo", "fixture_hang", "fixture_enable_drift", "fixture_crash",
    ])
    guard requiredNames.isSubset(of: Set(reviewedNames)) else {
      throw ValidationError("The stdio fixture reviewed catalog is incomplete.")
    }

    let described = try payload(
      await call(
        "mcp.tools.describe",
        arguments: [
          "server": .string(stdioServer),
          "tool": .string("fixture_echo"),
        ]
      )
    )
    guard contains("fixture_echo", in: described), contains("mcp.tools.call", in: described)
    else {
      throw ValidationError("mcp.tools.describe did not preserve the fixture contract.")
    }

    let found = try payload(
      await call(
        "mcp.tools.find",
        arguments: [
          "server": .string(stdioServer),
          "query": .string("echo"),
        ]
      )
    )
    guard found.objectValue?["result_count"]?.intValue == 1 else {
      throw ValidationError("mcp.tools.find did not return the reviewed echo tool.")
    }

    let eventsBeforeDrift = try await waitForEvents(
      server: stdioServer,
      requiredKinds: [
        MCP.ToolListChangedNotification.name,
        MCP.ResourceListChangedNotification.name,
        MCP.PromptListChangedNotification.name,
      ],
      afterCursor: eventBaselineCursor
    )

    let echo = try await destructiveCall(
      "mcp.tools.call",
      arguments: [
        "server": .string(stdioServer),
        "tool": .string("fixture_echo"),
        "arguments": .object(["value": .string("gateway")]),
      ]
    )
    guard contains("echo:gateway", in: echo.result) else {
      throw ValidationError("The stdio fixture echo result was not preserved.")
    }
    if let stdioReexportTool {
      let reexport = try await call(
        stdioReexportTool,
        arguments: ["value": .string("reexport")]
      )
      guard contains("echo:reexport", in: reexport.result) else {
        throw ValidationError("The reviewed reexport did not reach the stdio provider.")
      }
    }

    let resources = try payload(
      await call(
        "mcp.resources.list",
        arguments: ["server": .string(stdioServer)]
      )
    )
    let resource = try payload(
      await call(
        "mcp.resources.read",
        arguments: [
          "server": .string(stdioServer),
          "uri": .string("fixture://sample"),
        ]
      )
    )
    let templates = try payload(
      await call(
        "mcp.resources.templates.list",
        arguments: ["server": .string(stdioServer)]
      )
    )
    guard resources.objectValue?["resource_count"]?.intValue == 1,
      templates.objectValue?["template_count"]?.intValue == 1,
      contains("resource:", in: resource),
      resource.objectValue?["uri"]?.stringValue == "fixture://sample"
    else {
      throw ValidationError("The stdio resource surface did not round-trip.")
    }

    let prompts = try payload(
      await call(
        "mcp.prompts.list",
        arguments: ["server": .string(stdioServer)]
      )
    )
    let prompt = try payload(
      await call(
        "mcp.prompts.get",
        arguments: [
          "server": .string(stdioServer),
          "name": .string("fixture_prompt"),
          "arguments": .object(["value": .string("gateway")]),
        ]
      )
    )
    guard prompts.objectValue?["prompt_count"]?.intValue == 1,
      contains("prompt:gateway", in: prompt)
    else {
      throw ValidationError("The stdio prompt surface did not round-trip.")
    }

    _ = try await destructiveCall(
      "mcp.tools.call",
      arguments: [
        "server": .string(stdioServer),
        "tool": .string("fixture_enable_drift"),
      ]
    )
    let driftBaselineCursor =
      eventsBeforeDrift.objectValue?["next_cursor"]?.intValue ?? eventBaselineCursor
    let driftEvents = try await waitForEvents(
      server: stdioServer,
      requiredKinds: [MCP.ToolListChangedNotification.name],
      afterCursor: driftBaselineCursor
    )
    let afterDrift = try payload(
      await call("mcp.tools.list", arguments: ["server": .string(stdioServer)])
    )
    guard !toolNames(in: afterDrift).contains("fixture_added") else {
      throw ValidationError("Provider drift escaped the reviewed allowed_tools catalog.")
    }
    let driftDenial = await expectedDestructiveFailure(
      "mcp.tools.call",
      arguments: [
        "server": .string(stdioServer),
        "tool": .string("fixture_added"),
      ]
    )

    let cancellation = try await exerciseCancellation()

    _ = try await destructiveCall(
      "mcp.tools.call",
      arguments: [
        "server": .string(stdioServer),
        "tool": .string("fixture_crash"),
      ]
    )
    try await Task.sleep(for: .milliseconds(250))
    let crashFailure = await expectedFailure(
      "mcp.tools.list",
      arguments: ["server": .string(stdioServer)]
    )
    let restartedTools = try payload(
      await call("mcp.tools.list", arguments: ["server": .string(stdioServer)])
    )
    let startCount = try providerStartCount()
    guard requiredNames.isSubset(of: Set(toolNames(in: restartedTools))), startCount >= 2 else {
      throw ValidationError("The stdio provider did not reconnect after process exit.")
    }

    return .object([
      "status_connected": .bool(contains("connected", in: status)),
      "reviewed_tool_count": .number(Double(reviewedNames.count)),
      "resource_count": resources.objectValue?["resource_count"] ?? .number(0),
      "template_count": templates.objectValue?["template_count"] ?? .number(0),
      "prompt_count": prompts.objectValue?["prompt_count"] ?? .number(0),
      "initial_event_count": .number(Double(eventCount(in: eventsBeforeDrift))),
      "drift_event_count": .number(Double(eventCount(in: driftEvents))),
      "drift_denial": .string(driftDenial),
      "cancellation": cancellation,
      "crash_failure": .string(crashFailure),
      "provider_start_count": .number(Double(startCount)),
      "reconnected": .bool(true),
      "reexport_exercised": .bool(stdioReexportTool != nil),
    ])
  }

  private mutating func exerciseHTTP() async throws -> JSONValue {
    guard let httpServer else {
      throw ValidationError("The downstream HTTP fixture provider is not configured.")
    }
    let tools = try payload(
      await call("mcp.tools.list", arguments: ["server": .string(httpServer)])
    )
    let names = toolNames(in: tools)
    guard names.contains("get-sum"), names.contains("echo") else {
      throw ValidationError("The official HTTP fixture tools were not discovered.")
    }
    let sum = try await destructiveCall(
      "mcp.tools.call",
      arguments: [
        "server": .string(httpServer),
        "tool": .string("get-sum"),
        "arguments": .object([
          "a": .number(2),
          "b": .number(3),
        ]),
      ]
    )
    let resources = try payload(
      await call(
        "mcp.resources.list",
        arguments: ["server": .string(httpServer)]
      )
    )
    let resource = try payload(
      await call(
        "mcp.resources.read",
        arguments: [
          "server": .string(httpServer),
          "uri": .string("demo://resource/static/document/architecture.md"),
        ]
      )
    )
    let prompts = try payload(
      await call(
        "mcp.prompts.list",
        arguments: ["server": .string(httpServer)]
      )
    )
    let prompt = try payload(
      await call(
        "mcp.prompts.get",
        arguments: [
          "server": .string(httpServer),
          "name": .string("args-prompt"),
          "arguments": .object([
            "city": .string("Shanghai"),
            "state": .string("CN"),
          ]),
        ]
      )
    )
    let status = try payload(
      await call(
        "mcp.servers.status",
        arguments: ["server": .string(httpServer)]
      )
    )
    guard
      contains("The sum of 2 and 3 is 5.", in: sum.result),
      resources.objectValue?["resource_count"]?.intValue ?? 0 >= 7,
      contains("Everything Server", in: resource),
      prompts.objectValue?["prompt_count"]?.intValue ?? 0 >= 4,
      contains("Shanghai, CN", in: prompt),
      contains("connected", in: status)
    else {
      throw ValidationError("The official HTTP fixture surface did not round-trip.")
    }

    return .object([
      "status_connected": .bool(contains("connected", in: status)),
      "reviewed_tool_count": .number(Double(names.count)),
      "resource_count": resources.objectValue?["resource_count"] ?? .number(0),
      "prompt_count": prompts.objectValue?["prompt_count"] ?? .number(0),
      "tool_call_succeeded": .bool(true),
      "persistent_session": .bool(contains("persistent_session", in: status)),
    ])
  }

  private mutating func exerciseCancellation() async throws -> JSONValue {
    let requestID = "fixture-hang-\(UUID().uuidString)"
    let server = stdioServer
    let targetArguments: [String: JSONValue] = [
      "server": .string(server),
      "tool": .string("fixture_hang"),
      "request_id": .string(requestID),
      "wait_for_result": .bool(false),
    ]
    let prepared = try payload(
      await call(
        "operations.prepare",
        arguments: [
          "tool": .string("mcp.tools.call"),
          "arguments": .object(targetArguments),
        ]
      )
    )
    guard let ticketID = prepared.objectValue?["ticket_id"]?.stringValue else {
      throw ValidationError("The hanging downstream call received no operation ticket.")
    }
    let started = try payload(
      await call(
        "operations.commit",
        arguments: [
          "ticket_id": .string(ticketID),
          "tool": .string("mcp.tools.call"),
          "arguments": .object(targetArguments),
        ]
      )
    )
    guard started.objectValue?["state"]?.stringValue == "running" else {
      throw ValidationError("The downstream request did not enter the running state.")
    }

    var observedActive = false
    for _ in 0..<40 {
      let requests = try payload(
        await call(
          "mcp.requests.list",
          arguments: ["server": .string(stdioServer)]
        )
      )
      if contains(requestID, in: requests) {
        observedActive = true
        break
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    guard observedActive else {
      throw ValidationError("The hanging downstream request was not observable.")
    }

    let cancelled = try payload(
      await destructiveCall(
        "mcp.requests.cancel",
        arguments: [
          "server": .string(stdioServer),
          "request_id": .string(requestID),
          "reason": .string("downstream fixture cancellation"),
        ]
      )
    )
    guard cancelled.objectValue?["cancelled"]?.boolValue == true else {
      throw ValidationError("The downstream cancellation request was not accepted.")
    }

    _ = try payload(
      await call("mcp.tools.list", arguments: ["server": .string(stdioServer)])
    )
    return .object([
      "active_request_observed": .bool(observedActive),
      "cancelled": .bool(true),
      "terminal": .string("cancelled"),
      "provider_usable_after_cancel": .bool(true),
    ])
  }

  private mutating func waitForEvents(
    server: String,
    requiredKinds: Set<String>,
    afterCursor: Int
  ) async throws -> JSONValue {
    var latest: JSONValue = .object([:])
    var cursor = afterCursor
    var observedKinds: Set<String> = []
    var observedEvents: [JSONValue] = []
    for _ in 0..<40 {
      latest = try payload(
        await call(
          "mcp.events.read",
          arguments: [
            "server": .string(server),
            "after_cursor": .number(Double(cursor)),
            "max_results": .number(100),
          ]
        )
      )
      cursor = latest.objectValue?["next_cursor"]?.intValue ?? cursor
      let events = latest.objectValue?["events"]?.arrayValue ?? []
      observedEvents.append(contentsOf: events)
      let kinds = Set(
        events.compactMap {
          $0.objectValue?["kind"]?.stringValue
        }
      )
      observedKinds.formUnion(kinds)
      if requiredKinds.isSubset(of: observedKinds), events.isEmpty {
        return .object([
          "events": .array(observedEvents),
          "next_cursor": .number(Double(cursor)),
          "returned_events": .number(Double(observedEvents.count)),
        ])
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    throw ValidationError(
      "Downstream events did not include: \(requiredKinds.sorted().joined(separator: ", "))."
    )
  }

  private mutating func call(
    _ tool: String,
    arguments: [String: JSONValue] = [:]
  ) async throws -> GatewayCallReport {
    let report = try await session.call(
      toolName: tool,
      arguments: .object(arguments)
    )
    requestIDs.append(report.requestID)
    callReports.append(report)
    guard report.result.objectValue?["isError"]?.boolValue != true else {
      throw ValidationError("Tool \(tool) returned an MCP error result.")
    }
    return report
  }

  private mutating func destructiveCall(
    _ tool: String,
    arguments: [String: JSONValue]
  ) async throws -> GatewayCallReport {
    let prepared = try payload(
      await call(
        "operations.prepare",
        arguments: [
          "tool": .string(tool),
          "arguments": .object(arguments),
        ]
      )
    )
    guard let ticketID = prepared.objectValue?["ticket_id"]?.stringValue else {
      throw ValidationError("operations.prepare returned no ticket for \(tool).")
    }
    return try await call(
      "operations.commit",
      arguments: [
        "ticket_id": .string(ticketID),
        "tool": .string(tool),
        "arguments": .object(arguments),
      ]
    )
  }

  private mutating func expectedDestructiveFailure(
    _ tool: String,
    arguments: [String: JSONValue]
  ) async -> String {
    do {
      _ = try await destructiveCall(tool, arguments: arguments)
      return "unexpected-success"
    } catch {
      return "request-failed"
    }
  }

  private func expectedFailure(
    _ tool: String,
    arguments: [String: JSONValue]
  ) async -> String {
    do {
      let report = try await session.call(
        toolName: tool,
        arguments: .object(arguments)
      )
      return report.result.objectValue?["isError"]?.boolValue == true
        ? "error-result"
        : "unexpected-success"
    } catch {
      return "request-failed"
    }
  }

  private func payload(_ report: GatewayCallReport) throws -> JSONValue {
    if let structured = report.result.objectValue?["structuredContent"] {
      return structured.objectValue?["result"] ?? structured
    }
    if let text = report.result.objectValue?["content"]?.arrayValue?.compactMap({
      $0.objectValue?["text"]?.stringValue
    }).first,
      let data = text.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
    {
      return decoded.objectValue?["result"] ?? decoded
    }
    throw ValidationError("Tool \(report.toolName) returned no structured JSON payload.")
  }

  private func toolNames(in payload: JSONValue) -> [String] {
    payload.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue } ?? []
  }

  private func eventCount(in payload: JSONValue) -> Int {
    payload.objectValue?["events"]?.arrayValue?.count ?? 0
  }

  private func providerStartCount() throws -> Int {
    let content = try String(contentsOf: stdioStartMarker, encoding: .utf8)
    return content.split(whereSeparator: \.isNewline).count
  }

  private func contains(_ marker: String, in value: JSONValue) -> Bool {
    encodedString(value).localizedCaseInsensitiveContains(marker)
  }

  private func encodedString(_ value: JSONValue) -> String {
    guard let data = try? JSONEncoder().encode(value) else {
      return ""
    }
    return String(decoding: data, as: UTF8.self)
  }
}

struct CodexProbeVerify: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "verify",
    abstract: "Exercise Codex App Server, Exec, and MCP through one persistent MCP session."
  )

  @Option(name: .long, help: "Absolute MCP Streamable HTTP endpoint URL.")
  var endpoint: String?

  @Option(name: .long, help: "Path to the Computer MCP App gateway socket.")
  var socket: String?

  @OptionGroup var socketIdentity: GatewaySocketIdentityOptions

  @Option(
    name: .long,
    help: "Optional active Gateway database used to correlate App/socket audit events."
  )
  var database: String?

  @Option(name: .long, help: "Stable workspace id bound to Codex.")
  var workspaceID: String

  @Option(
    name: .long,
    help: "Optional environment variable containing a bearer token."
  )
  var accessTokenEnv: String?

  @Option(name: .long, help: "Maximum seconds for each Codex operation.")
  var timeoutSeconds = 180

  @Option(name: .long, help: "Destination for the bounded JSON report.")
  var json: String

  mutating func run() async throws {
    guard (endpoint == nil) != (socket == nil) else {
      throw ValidationError("Exactly one of --endpoint or --socket is required.")
    }
    guard timeoutSeconds > 0, timeoutSeconds <= 900 else {
      throw ValidationError("timeout-seconds must be between 1 and 900.")
    }
    if socket != nil, accessTokenEnv != nil {
      throw ValidationError("--bearer-token-env is only valid with --endpoint.")
    }
    if endpoint != nil, database != nil {
      throw ValidationError("--database is only valid with --socket.")
    }
    if endpoint != nil, socketIdentity.isConfigured {
      throw ValidationError("Secure Tunnel socket identity options require --socket.")
    }

    let session: GatewayClientSession
    let transport: String
    let target: String
    let gatewayDatabase: GatewayDatabase?
    let databasePath: String?
    if let endpoint {
      guard let endpointURL = URL(string: endpoint),
        let scheme = endpointURL.scheme?.lowercased(),
        ["http", "https"].contains(scheme),
        endpointURL.host != nil
      else {
        throw ValidationError("endpoint must be an absolute http or https URL.")
      }

      let accessToken = try accessTokenEnv.map { name in
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
          throw ValidationError("Environment variable \(name) is missing or empty.")
        }
        return value
      }
      session = try await GatewayClientSession.connectHTTP(
        endpoint: endpointURL,
        accessToken: accessToken
      )
      transport = "streamable_http"
      target = endpointURL.absoluteString
      gatewayDatabase = nil
      databasePath = nil
    } else {
      guard let socket, !socket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ValidationError("socket path must not be empty.")
      }
      let socketURL = URL(fileURLWithPath: socket).standardizedFileURL
      let socketConfiguration = try socketIdentity.configuration(socketURL: socketURL)
      session = try await GatewayClientSession.connectSocket(
        configuration: socketConfiguration
      )
      transport = "gateway_socket"
      target = socketURL.path
      if let database {
        guard !database.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw ValidationError("database path must not be empty.")
        }
        let databaseURL = URL(fileURLWithPath: database).standardizedFileURL
        gatewayDatabase = try GatewayDatabase(path: databaseURL.path)
        databasePath = databaseURL.path
      } else {
        gatewayDatabase = nil
        databasePath = nil
      }
    }

    do {
      var runner = CodexProbeVerifyRunner(
        session: session,
        workspaceID: workspaceID,
        timeout: .seconds(timeoutSeconds),
        transport: transport,
        target: target,
        database: gatewayDatabase,
        databasePath: databasePath
      )
      let report = try await runner.run()
      await session.disconnect()
      try writeJSONValue(report, destination: json)
    } catch {
      await session.disconnect()
      throw error
    }
  }
}

private struct CodexProbeVerifyRunner {
  let session: GatewayClientSession
  let workspaceID: String
  let timeout: Duration
  let transport: String
  let target: String
  let database: GatewayDatabase?
  let databasePath: String?

  private var transportRequestIDs: [String] = []
  private var gatewayRequestIDs: [String] = []

  init(
    session: GatewayClientSession,
    workspaceID: String,
    timeout: Duration,
    transport: String,
    target: String,
    database: GatewayDatabase?,
    databasePath: String?
  ) {
    self.session = session
    self.workspaceID = workspaceID
    self.timeout = timeout
    self.transport = transport
    self.target = target
    self.database = database
    self.databasePath = databasePath
  }

  mutating func run() async throws -> JSONValue {
    let app = try await exerciseAppServer()
    let exec = try await exerciseExec()
    let mcp = try await exerciseMCP()
    let audit = try auditCorrelation()
    let verificationComplete =
      app.objectValue?["verification_complete"]?.boolValue == true
      && audit.complete
    return .object([
      "schema_version": .number(1),
      "generated_at": .string(ValidationTimestamp.now()),
      "verification_complete": .bool(verificationComplete),
      "transport": .string(transport),
      "target": .string(target),
      "database_path": databasePath.map(JSONValue.string) ?? .null,
      "workspace_id": .string(workspaceID),
      "request_ids": .array(transportRequestIDs.map(JSONValue.string)),
      "gateway_request_ids": .array(gatewayRequestIDs.map(JSONValue.string)),
      "audit_event_ids": .array(audit.eventIDs.map(JSONValue.string)),
      "correlation_complete": .bool(audit.complete),
      "app_server": app,
      "exec": exec,
      "mcp": mcp,
    ])
  }

  private mutating func exerciseAppServer() async throws -> JSONValue {
    let status = try await call("codex.app.status")
    let methods = try await call("codex.app.methods.list")
    let models = try await call("codex.app.models.list")
    let skills = try await call("codex.app.skills.list")
    let apps = try await callAllowingError("codex.app.apps.list")
    let appsListSucceeded = apps.result.objectValue?["isError"]?.boolValue != true
    let appsListErrorCode =
      apps.result.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"]?
      .stringValue
    let usage = try await call(
      "codex.app.methods.call",
      arguments: ["method": .string("account/usage/read")]
    )
    let experimentalFeatures = try await call(
      "codex.app.methods.call",
      arguments: [
        "method": .string("experimentalFeature/list"),
        "params": .object([:]),
      ]
    )
    let started = try await call(
      "codex.app.thread.start",
      arguments: ["ephemeral": .bool(true)]
    )
    let threadID = try requiredString(
      in: payload(started),
      path: ["thread", "id"],
      label: "Codex App Server thread id"
    )
    let marker = "CMCP_APP_SERVER_OK"
    let turn = try await call(
      "codex.app.turn.start",
      arguments: [
        "thread_id": .string(threadID),
        "prompt": .string(
          "Reply with exactly \(marker). Do not call tools and do not modify files."
        ),
      ]
    )
    let turnID = try requiredString(
      in: payload(turn),
      path: ["turn", "id"],
      label: "Codex App Server turn id"
    )

    var cursor = 0
    var eventCount = 0
    var observedMarker = false
    var finalThreadState = "unknown"
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      let events = try await call(
        "codex.app.events.read",
        arguments: [
          "after_cursor": .number(Double(cursor)),
          "max_results": .number(100),
        ]
      )
      let eventPayload = payload(events)
      cursor = eventPayload.objectValue?["next_cursor"]?.intValue ?? cursor
      eventCount += eventPayload.objectValue?["returned_events"]?.intValue ?? 0
      observedMarker = observedMarker || contains(marker, in: eventPayload)

      let thread = try await call(
        "codex.app.thread.read",
        arguments: [
          "thread_id": .string(threadID),
          "include_turns": .bool(false),
        ]
      )
      let threadPayload = payload(thread)
      finalThreadState =
        value(in: threadPayload, path: ["thread", "status", "type"])?.stringValue
        ?? value(in: threadPayload, path: ["status", "type"])?.stringValue
        ?? finalThreadState
      observedMarker = observedMarker || contains(marker, in: threadPayload)
      if observedMarker {
        break
      }
      try await Task.sleep(for: .milliseconds(500))
    }
    guard observedMarker else {
      throw ValidationError("Codex App Server did not return \(marker) before timeout.")
    }

    let cancelledThread = try await call(
      "codex.app.thread.start",
      arguments: ["ephemeral": .bool(true)]
    )
    let cancelledThreadID = try requiredString(
      in: payload(cancelledThread),
      path: ["thread", "id"],
      label: "Codex App Server cancellation thread id"
    )
    let cancellationTurn = try await call(
      "codex.app.turn.start",
      arguments: [
        "thread_id": .string(cancelledThreadID),
        "prompt": .string(
          "Use the terminal to run `sleep 60`, then reply with CMCP_APP_CANCEL_MISSED. "
            + "Do not modify files."
        ),
      ]
    )
    let cancellationTurnID = try requiredString(
      in: payload(cancellationTurn),
      path: ["turn", "id"],
      label: "Codex App Server cancellation turn id"
    )
    let interruption = try await call(
      "codex.app.turn.interrupt",
      arguments: [
        "thread_id": .string(cancelledThreadID),
        "turn_id": .string(cancellationTurnID),
      ]
    )
    let interrupted = try await waitForAppInterruption(
      turnID: cancellationTurnID,
      afterCursor: cursor
    )

    return .object([
      "verification_complete": .bool(appsListSucceeded),
      "initial_state":
        payload(status).objectValue?["state"] ?? .null,
      "method_count": .number(Double(arrayCount(in: payload(methods), keys: ["methods"]))),
      "model_count": .number(Double(arrayCount(in: payload(models), keys: ["data", "models"]))),
      "skill_count": .number(Double(arrayCount(in: payload(skills), keys: ["data", "skills"]))),
      "apps_list_succeeded": .bool(appsListSucceeded),
      "apps_list_error_code": appsListErrorCode.map(JSONValue.string) ?? .null,
      "app_count": .number(
        Double(appsListSucceeded ? arrayCount(in: payload(apps), keys: ["data", "apps"]) : 0)
      ),
      "usage_read_succeeded": .bool(payload(usage) != .null),
      "experimental_feature_count": .number(
        Double(arrayCount(in: payload(experimentalFeatures), keys: ["data", "features"]))
      ),
      "thread_id": .string(threadID),
      "turn_id": .string(turnID),
      "event_count": .number(Double(eventCount)),
      "final_thread_state": .string(finalThreadState),
      "marker": .string(marker),
      "marker_observed": .bool(observedMarker),
      "cancellation_thread_id": .string(cancelledThreadID),
      "cancellation_turn_id": .string(cancellationTurnID),
      "interruption_response_received": .bool(payload(interruption) != .null),
      "interruption_event_count": .number(Double(interrupted.eventCount)),
      "interrupted": .bool(interrupted.observed),
    ])
  }

  private mutating func exerciseExec() async throws -> JSONValue {
    let marker = "CMCP_EXEC_OK"
    let started = try await call(
      "codex.exec.start",
      arguments: [
        "prompt": .string(
          "Reply with exactly \(marker). Do not call tools and do not modify files."
        )
      ]
    )
    let sessionID = try requiredString(
      in: payload(started),
      path: ["session_id"],
      label: "Codex Exec session id"
    )
    let first = try await waitForExec(sessionID: sessionID, marker: marker)
    let upstreamID = try requiredString(
      in: first.result,
      path: ["upstream_session_id"],
      label: "Codex Exec upstream session id"
    )

    let resumeMarker = "CMCP_EXEC_RESUME_OK"
    let resumed = try await call(
      "codex.exec.resume",
      arguments: [
        "upstream_session_id": .string(upstreamID),
        "prompt": .string(
          "Reply with exactly \(resumeMarker). Do not call tools and do not modify files."
        ),
      ]
    )
    let resumeSessionID = try requiredString(
      in: payload(resumed),
      path: ["session_id"],
      label: "Codex Exec resume session id"
    )
    let second = try await waitForExec(
      sessionID: resumeSessionID,
      marker: resumeMarker
    )

    let cancellationStarted = try await call(
      "codex.exec.start",
      arguments: [
        "prompt": .string(
          "Use the terminal to run `sleep 60`, then reply with CMCP_EXEC_CANCEL_MISSED. "
            + "Do not modify files."
        )
      ]
    )
    let cancellationSessionID = try requiredString(
      in: payload(cancellationStarted),
      path: ["session_id"],
      label: "Codex Exec cancellation session id"
    )
    let cancellation = payload(
      try await call(
        "codex.exec.cancel",
        arguments: ["session_id": .string(cancellationSessionID)]
      )
    )
    let cancellationEvents = payload(
      try await call(
        "codex.exec.events",
        arguments: [
          "session_id": .string(cancellationSessionID),
          "after_cursor": .number(0),
          "max_results": .number(100),
        ]
      )
    )
    let cancellationResult = payload(
      try await call(
        "codex.exec.result",
        arguments: ["session_id": .string(cancellationSessionID)]
      )
    )
    let cancellationState =
      cancellationResult.objectValue?["state"]?.stringValue ?? "unknown"
    guard cancellation.objectValue?["cancelled"]?.boolValue == true,
      cancellationState == "cancelled",
      contains("session.cancelled", in: cancellationEvents)
    else {
      throw ValidationError(
        "Codex Exec cancellation did not reach the deterministic cancelled state."
      )
    }

    return .object([
      "session_id": .string(sessionID),
      "upstream_session_id": .string(upstreamID),
      "state": .string(first.state),
      "event_count": .number(Double(first.eventCount)),
      "marker": .string(marker),
      "marker_observed": .bool(contains(marker, in: first.result)),
      "resume_session_id": .string(resumeSessionID),
      "resume_state": .string(second.state),
      "resume_event_count": .number(Double(second.eventCount)),
      "resume_marker": .string(resumeMarker),
      "resume_marker_observed": .bool(contains(resumeMarker, in: second.result)),
      "cancellation_session_id": .string(cancellationSessionID),
      "cancellation_state": .string(cancellationState),
      "cancellation_event_count": .number(
        Double(cancellationEvents.objectValue?["returned_events"]?.intValue ?? 0)
      ),
      "cancellation_event_observed": .bool(
        contains("session.cancelled", in: cancellationEvents)
      ),
    ])
  }

  private mutating func exerciseMCP() async throws -> JSONValue {
    let tools = try await call("codex.mcp.tools.list")
    let marker = "CMCP_CODEX_MCP_OK"
    let started = try await call(
      "codex.mcp.run",
      arguments: [
        "prompt": .string(
          "Reply with exactly \(marker). Do not call tools and do not modify files."
        )
      ]
    )
    let callID = try requiredString(
      in: payload(started),
      path: ["call_id"],
      label: "Codex MCP call id"
    )
    let first = try await waitForMCP(callID: callID, marker: marker)
    let threadID = try requiredString(
      in: first.result,
      path: ["result", "thread_id"],
      label: "Codex MCP thread id"
    )

    let replyMarker = "CMCP_CODEX_MCP_REPLY_OK"
    let replied = try await call(
      "codex.mcp.reply",
      arguments: [
        "thread_id": .string(threadID),
        "prompt": .string(
          "Reply with exactly \(replyMarker). Do not call tools and do not modify files."
        ),
      ]
    )
    let replyCallID = try requiredString(
      in: payload(replied),
      path: ["call_id"],
      label: "Codex MCP reply call id"
    )
    let second = try await waitForMCP(
      callID: replyCallID,
      marker: replyMarker
    )

    let cancellationStarted = try await call(
      "codex.mcp.run",
      arguments: [
        "prompt": .string(
          "Use the terminal to run `sleep 60`, then reply with CMCP_MCP_CANCEL_MISSED. "
            + "Do not modify files."
        )
      ]
    )
    let cancellationCallID = try requiredString(
      in: payload(cancellationStarted),
      path: ["call_id"],
      label: "Codex MCP cancellation call id"
    )
    let cancellation = payload(
      try await call(
        "codex.mcp.cancel",
        arguments: ["call_id": .string(cancellationCallID)]
      )
    )
    guard cancellation.objectValue?["cancellation_requested"]?.boolValue == true else {
      throw ValidationError("Codex MCP did not accept the cancellation request.")
    }
    let cancelled = try await waitForMCPTerminal(
      callID: cancellationCallID,
      requiredEvent: "cancellation_requested"
    )

    return .object([
      "tool_count": .number(Double(arrayCount(in: payload(tools), keys: ["tools"]))),
      "call_id": .string(callID),
      "thread_id": .string(threadID),
      "state": .string(first.state),
      "event_count": .number(Double(first.eventCount)),
      "marker": .string(marker),
      "marker_observed": .bool(contains(marker, in: first.result)),
      "reply_call_id": .string(replyCallID),
      "reply_state": .string(second.state),
      "reply_event_count": .number(Double(second.eventCount)),
      "reply_marker": .string(replyMarker),
      "reply_marker_observed": .bool(contains(replyMarker, in: second.result)),
      "cancellation_call_id": .string(cancellationCallID),
      "cancellation_state": .string(cancelled.state),
      "cancellation_event_count": .number(Double(cancelled.eventCount)),
      "cancellation_event_observed": .bool(cancelled.observedEvent),
    ])
  }

  private mutating func waitForAppInterruption(
    turnID: String,
    afterCursor: Int
  ) async throws -> (observed: Bool, eventCount: Int) {
    var cursor = afterCursor
    var eventCount = 0
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      let events = try await call(
        "codex.app.events.read",
        arguments: [
          "after_cursor": .number(Double(cursor)),
          "max_results": .number(100),
        ]
      )
      let eventPayload = payload(events)
      cursor = eventPayload.objectValue?["next_cursor"]?.intValue ?? cursor
      eventCount += eventPayload.objectValue?["returned_events"]?.intValue ?? 0
      let hasTurn = contains(turnID, in: eventPayload)
      let hasInterruption =
        contains("interrupted", in: eventPayload)
        || contains("cancelled", in: eventPayload)
      if hasTurn && hasInterruption {
        return (true, eventCount)
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    throw ValidationError("Codex App Server turn \(turnID) did not report interruption.")
  }

  private mutating func waitForExec(
    sessionID: String,
    marker: String
  ) async throws -> (state: String, eventCount: Int, result: JSONValue) {
    var cursor = 0
    var eventCount = 0
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      let events = try await call(
        "codex.exec.events",
        arguments: [
          "session_id": .string(sessionID),
          "after_cursor": .number(Double(cursor)),
          "max_results": .number(100),
        ]
      )
      let eventPayload = payload(events)
      cursor = eventPayload.objectValue?["next_cursor"]?.intValue ?? cursor
      eventCount += eventPayload.objectValue?["returned_events"]?.intValue ?? 0

      let listed = try await call("codex.exec.list")
      let sessions = payload(listed).objectValue?["sessions"]?.arrayValue ?? []
      let row = sessions.first {
        $0.objectValue?["session_id"]?.stringValue == sessionID
      }
      let state = row?.objectValue?["state"]?.stringValue ?? "unknown"
      if ["completed", "failed", "cancelled"].contains(state) {
        let result = payload(
          try await call(
            "codex.exec.result",
            arguments: ["session_id": .string(sessionID)]
          )
        )
        guard state == "completed", contains(marker, in: result) else {
          throw ValidationError(
            "Codex Exec session \(sessionID) ended as \(state) without \(marker)."
          )
        }
        return (state, eventCount, result)
      }
      try await Task.sleep(for: .milliseconds(500))
    }
    throw ValidationError("Codex Exec session \(sessionID) timed out.")
  }

  private mutating func waitForMCP(
    callID: String,
    marker: String
  ) async throws -> (state: String, eventCount: Int, result: JSONValue) {
    var cursor = 0
    var eventCount = 0
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      let events = try await call(
        "codex.mcp.events",
        arguments: [
          "call_id": .string(callID),
          "after_cursor": .number(Double(cursor)),
          "max_results": .number(100),
        ]
      )
      let eventPayload = payload(events)
      cursor = eventPayload.objectValue?["next_cursor"]?.intValue ?? cursor
      eventCount += eventPayload.objectValue?["returned_events"]?.intValue ?? 0

      let result = payload(
        try await call(
          "codex.mcp.result",
          arguments: ["call_id": .string(callID)]
        )
      )
      let state = value(in: result, path: ["call", "state"])?.stringValue ?? "unknown"
      if ["cancelled", "completed", "failed"].contains(state) {
        guard state == "completed", contains(marker, in: result) else {
          throw ValidationError(
            "Codex MCP call \(callID) ended as \(state) without \(marker)."
          )
        }
        return (state, eventCount, result)
      }
      try await Task.sleep(for: .milliseconds(500))
    }
    throw ValidationError("Codex MCP call \(callID) timed out.")
  }

  private mutating func waitForMCPTerminal(
    callID: String,
    requiredEvent: String
  ) async throws -> (state: String, eventCount: Int, observedEvent: Bool) {
    var cursor = 0
    var eventCount = 0
    var observedEvent = false
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      let events = try await call(
        "codex.mcp.events",
        arguments: [
          "call_id": .string(callID),
          "after_cursor": .number(Double(cursor)),
          "max_results": .number(100),
        ]
      )
      let eventPayload = payload(events)
      cursor = eventPayload.objectValue?["next_cursor"]?.intValue ?? cursor
      eventCount += eventPayload.objectValue?["returned_events"]?.intValue ?? 0
      observedEvent = observedEvent || contains(requiredEvent, in: eventPayload)

      let result = payload(
        try await call(
          "codex.mcp.result",
          arguments: ["call_id": .string(callID)]
        )
      )
      let state = value(in: result, path: ["call", "state"])?.stringValue ?? "unknown"
      if ["cancelled", "completed", "failed"].contains(state) {
        guard observedEvent else {
          throw ValidationError(
            "Codex MCP call \(callID) became terminal without \(requiredEvent)."
          )
        }
        return (state, eventCount, observedEvent)
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    throw ValidationError("Codex MCP cancellation for \(callID) timed out.")
  }

  private mutating func call(
    _ tool: String,
    arguments: [String: JSONValue] = [:]
  ) async throws -> GatewayCallReport {
    let report = try await callAllowingError(tool, arguments: arguments)
    guard report.result.objectValue?["isError"]?.boolValue != true else {
      throw ValidationError("Tool \(tool) returned an MCP error result.")
    }
    return report
  }

  private mutating func callAllowingError(
    _ tool: String,
    arguments: [String: JSONValue] = [:]
  ) async throws -> GatewayCallReport {
    var boundArguments = arguments
    boundArguments["workspace_id"] = .string(workspaceID)
    let report = try await session.call(
      toolName: tool,
      arguments: .object(boundArguments)
    )
    transportRequestIDs.append(report.requestID)
    if let gatewayRequestID = report.gatewayRequestID {
      gatewayRequestIDs.append(gatewayRequestID)
    }
    return report
  }

  private func auditCorrelation() throws -> (eventIDs: [String], complete: Bool) {
    guard let database else {
      return ([], false)
    }
    var eventIDs: [String] = []
    for requestID in gatewayRequestIDs {
      guard let event = try database.auditEvent(requestID: requestID) else {
        continue
      }
      eventIDs.append(event.id)
    }
    return (
      eventIDs,
      transportRequestIDs.count == gatewayRequestIDs.count
        && gatewayRequestIDs.count == eventIDs.count
    )
  }

  private func payload(_ report: GatewayCallReport) -> JSONValue {
    report.result.objectValue?["structuredContent"]?.objectValue?["result"] ?? .null
  }

  private func requiredString(
    in root: JSONValue,
    path: [String],
    label: String
  ) throws -> String {
    guard let result = value(in: root, path: path)?.stringValue, !result.isEmpty else {
      throw ValidationError("\(label) is missing.")
    }
    return result
  }

  private func value(in root: JSONValue, path: [String]) -> JSONValue? {
    path.reduce(Optional(root)) { current, key in
      current?.objectValue?[key]
    }
  }

  private func contains(_ marker: String, in value: JSONValue) -> Bool {
    guard let data = try? JSONEncoder().encode(value) else {
      return false
    }
    return String(decoding: data, as: UTF8.self).contains(marker)
  }

  private func arrayCount(in root: JSONValue, keys: [String]) -> Int {
    for key in keys {
      if let count = root.objectValue?[key]?.arrayValue?.count {
        return count
      }
    }
    return 0
  }
}

private func decodeArguments(_ value: String) throws -> JSONValue {
  let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(value.utf8))
  guard decoded.objectValue != nil else {
    throw ValidationError("arguments-json must encode a JSON object.")
  }
  return decoded
}

private func writeJSONValue(_ value: JSONValue, destination: String) throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  let data = try encoder.encode(value)
  let destinationURL = URL(fileURLWithPath: destination)
  try FileManager.default.createDirectory(
    at: destinationURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try data.write(to: destinationURL, options: .atomic)
}

private func writeReport(
  _ report: GatewayCallReport,
  destination: String?
) throws {
  let data = try report.encodedJSON()
  if let destination {
    let destinationURL = URL(fileURLWithPath: destination)
    try FileManager.default.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: destinationURL, options: .atomic)
  } else {
    print(String(decoding: data, as: UTF8.self))
  }
}
