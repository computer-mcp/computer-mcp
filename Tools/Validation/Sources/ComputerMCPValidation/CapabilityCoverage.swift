import Foundation

public enum ValidationEvidenceLayer: String, Codable, CaseIterable, Sendable {
  case contract
  case runtime
  case externalConsumer = "external_consumer"
}

public enum ValidationStatus: String, Codable, CaseIterable, Sendable {
  case passed
  case failed
  case unavailable
  case pending
  case notApplicable = "not_applicable"
}

public struct CapabilityCoverageEvidence: Codable, Equatable, Sendable {
  public var id: String
  public var configuration: String
  public var toolName: String
  public var layer: ValidationEvidenceLayer
  public var status: ValidationStatus
  public var transport: String
  public var profileDigest: String
  public var fixtureDigest: String?
  public var testCaseID: String?
  public var runID: String?
  public var requestIDs: [String]
  public var auditEventIDs: [String]
  public var detail: String?
  public var recordedAt: String

  public init(
    id: String = UUID().uuidString,
    configuration: String,
    toolName: String,
    layer: ValidationEvidenceLayer,
    status: ValidationStatus,
    transport: String,
    profileDigest: String = "",
    fixtureDigest: String? = nil,
    testCaseID: String? = nil,
    runID: String? = nil,
    requestIDs: [String] = [],
    auditEventIDs: [String] = [],
    detail: String? = nil,
    recordedAt: String = ValidationTimestamp.now()
  ) {
    self.id = id
    self.configuration = configuration
    self.toolName = toolName
    self.layer = layer
    self.status = status
    self.transport = transport
    self.profileDigest = profileDigest
    self.fixtureDigest = fixtureDigest
    self.testCaseID = testCaseID
    self.runID = runID
    self.requestIDs = requestIDs
    self.auditEventIDs = auditEventIDs
    self.detail = detail.map { String($0.prefix(2_048)) }
    self.recordedAt = recordedAt
  }
}

public struct CapabilityLayerResult: Codable, Equatable, Sendable {
  public var status: ValidationStatus
  public var evidenceID: String?
  public var transport: String?
  public var testCaseID: String?
  public var runID: String?
  public var requestIDs: [String]
  public var auditEventIDs: [String]
  public var detail: String?

  public init(
    status: ValidationStatus,
    evidenceID: String? = nil,
    transport: String? = nil,
    testCaseID: String? = nil,
    runID: String? = nil,
    requestIDs: [String] = [],
    auditEventIDs: [String] = [],
    detail: String? = nil
  ) {
    self.status = status
    self.evidenceID = evidenceID
    self.transport = transport
    self.testCaseID = testCaseID
    self.runID = runID
    self.requestIDs = requestIDs
    self.auditEventIDs = auditEventIDs
    self.detail = detail
  }
}

public struct CapabilityCoverageEntry: Codable, Equatable, Sendable {
  public var configuration: String
  public var caller: String
  public var profile: String
  public var toolName: String
  public var domain: String
  public var risk: String
  public var workspaceRequirement: String
  public var localOnly: Bool
  public var usesNetwork: Bool
  public var contract: CapabilityLayerResult
  public var runtime: CapabilityLayerResult
  public var externalConsumer: CapabilityLayerResult
}

public struct ValidationTestCaseResult: Codable, Equatable, Sendable {
  public var id: String
  public var status: ValidationStatus
  public var requiredTransports: [ValidationTransport]
  public var observedTransports: [ValidationTransport]
  public var requiredProfiles: [String]
  public var observedProfiles: [String]
  public var runIDs: [String]
  public var evidenceIDs: [String]
  public var detail: String?
}

public struct ProductionReadinessIssue: Codable, Equatable, Sendable {
  public var code: String
  public var evidenceID: String?
  public var message: String

  public init(code: String, evidenceID: String? = nil, message: String) {
    self.code = code
    self.evidenceID = evidenceID
    self.message = message
  }
}

public struct CapabilityCoverageSummary: Codable, Equatable, Sendable {
  public var entryCount: Int
  public var domainCount: Int
  public var contractPassedCount: Int
  public var runtimePassedCount: Int
  public var externalConsumerPassedCount: Int
  public var pendingCount: Int
  public var failedCount: Int
  public var unavailableCount: Int
  public var notApplicableCount: Int
  public var testCaseCount: Int
  public var testCasePassedCount: Int
  public var testCasePendingCount: Int
  public var testCaseFailedCount: Int
  public var issueCount: Int
}

public struct ProductionReadinessReport: Codable, Equatable, Sendable {
  public static let schemaVersion = 1

  public var schemaVersion = Self.schemaVersion
  public var generatedAt: String
  public var inventoryGeneratedAt: String
  public var fixtureEntryCount: Int?
  public var fixtureDigest: String?
  public var summary: CapabilityCoverageSummary
  public var capabilityCoverage: [CapabilityCoverageEntry]
  public var testCases: [ValidationTestCaseResult]
  public var issues: [ProductionReadinessIssue]

  public var isReady: Bool {
    summary.pendingCount == 0
      && summary.failedCount == 0
      && summary.unavailableCount == 0
      && summary.contractPassedCount == summary.entryCount
      && summary.testCasePassedCount == summary.testCaseCount
      && issues.isEmpty
  }

  public func encodedJSON() throws -> Data {
    try ValidationJSONCoding.encode(self)
  }

  public static func decodeJSON(_ data: Data) throws -> ProductionReadinessReport {
    let report = try ValidationJSONCoding.decode(Self.self, from: data)
    guard report.schemaVersion == schemaVersion else {
      throw ValidationArtifactError.unsupportedSchema(
        artifact: "Production Readiness Report",
        expected: schemaVersion,
        actual: report.schemaVersion
      )
    }
    try ValidationJSONCoding.requireExactShape(
      report,
      input: data,
      artifact: "Production Readiness Report"
    )
    return report
  }

  public func markdown() -> String {
    var lines = [
      "# Computer MCP Production Readiness Report",
      "",
      "- Generated at: \(generatedAt)",
      "- Inventory generated at: \(inventoryGeneratedAt)",
      "- Capability entries: \(summary.entryCount)",
      "- Capability domains: \(summary.domainCount)",
      "- Contract passed: \(summary.contractPassedCount)",
      "- Runtime passed: \(summary.runtimePassedCount)",
      "- External consumer passed: \(summary.externalConsumerPassedCount)",
      "- Validation Test Cases passed: \(summary.testCasePassedCount)/\(summary.testCaseCount)",
      "- Issues: \(summary.issueCount)",
      "- Ready: \(isReady ? "yes" : "no")",
      "",
      "## Capability Coverage",
      "",
      "| Domain | Entries | Runtime passed | External consumer passed | Pending |",
      "| --- | ---: | ---: | ---: | ---: |",
    ]
    for domain in Set(capabilityCoverage.map(\.domain)).sorted() {
      let entries = capabilityCoverage.filter { $0.domain == domain }
      let layers = entries.flatMap { [$0.runtime, $0.externalConsumer] }
      lines.append(
        "| \(domain) | \(entries.count) | "
          + "\(entries.filter { $0.runtime.status == .passed }.count) | "
          + "\(entries.filter { $0.externalConsumer.status == .passed }.count) | "
          + "\(layers.filter { $0.status == .pending }.count) |"
      )
    }
    lines.append(contentsOf: ["", "## Validation Test Cases", ""])
    lines.append("| Test Case | Status | Required transports | Observed transports | Runs |")
    lines.append("| --- | --- | --- | --- | --- |")
    for testCase in testCases {
      lines.append(
        "| `\(testCase.id)` | \(testCase.status.rawValue) | "
          + "\(testCase.requiredTransports.map(\.rawValue).joined(separator: ", ")) | "
          + "\(testCase.observedTransports.map(\.rawValue).joined(separator: ", ")) | "
          + "\(testCase.runIDs.joined(separator: ", ")) |"
      )
    }
    lines.append(contentsOf: ["", "## Issues", ""])
    if issues.isEmpty {
      lines.append("None.")
    } else {
      lines.append(contentsOf: issues.map { "- `\($0.code)`: \($0.message)" })
    }
    lines.append("")
    return lines.joined(separator: "\n")
  }
}

public struct ProductionReadinessReportBuilder: Sendable {
  public init() {}

  public func build(
    inventory: CapabilityInventoryReport,
    fixtureReport: CapabilityFixtureReport? = nil,
    evidenceBundles: [ValidationEvidenceBundle] = [],
    generatedAt: Date = Date()
  ) -> ProductionReadinessReport {
    var issues = inventory.issues.map {
      ProductionReadinessIssue(code: "inventory.\($0.code)", message: $0.message)
    }
    let catalog: ValidationTestCaseCatalog
    do {
      catalog = try ValidationTestCaseCatalog.bundled()
      issues.append(
        contentsOf: catalog.validate().map {
          ProductionReadinessIssue(
            code: "test_case.invalid",
            message: "\($0.testCaseID) [\($0.field)] \($0.message)"
          )
        }
      )
    } catch {
      catalog = ValidationTestCaseCatalog(testCases: [])
      issues.append(
        ProductionReadinessIssue(
          code: "test_case.catalog_unavailable",
          message: error.localizedDescription
        )
      )
    }
    if inventory.profiles.contains(where: \.requiresRuntimeEvidence), fixtureReport == nil {
      issues.append(
        ProductionReadinessIssue(
          code: "fixture.missing",
          message: "Runtime validation requires a deterministic fixture report."
        )
      )
    }

    var verifiedBundles: [ValidationEvidenceBundle] = []
    var verifiedRows: [CapabilityCoverageEvidence] = []
    let verifier = ValidationEvidenceBundleVerifier()
    for bundle in evidenceBundles {
      do {
        let verified = try verifier.verifiedCoverageEvidence(from: bundle)
        verifiedBundles.append(bundle)
        verifiedRows.append(contentsOf: verified.rows)
      } catch ValidationEvidenceBundleVerificationError.rejected(let verificationIssues) {
        issues.append(
          contentsOf: verificationIssues.map {
            ProductionReadinessIssue(
              code: "evidence_bundle.\($0.code)",
              evidenceID: bundle.id,
              message: "\($0.path): \($0.message)"
            )
          }
        )
      } catch {
        issues.append(
          ProductionReadinessIssue(
            code: "evidence_bundle.verification_failed",
            evidenceID: bundle.id,
            message: error.localizedDescription
          )
        )
      }
    }

    var inventoryTargets: [String: (CapabilityInventoryProfile, CapabilityInventoryTool)] = [:]
    for profile in inventory.profiles {
      for tool in profile.tools {
        let key = Self.key(configuration: profile.configuration, toolName: tool.name)
        if inventoryTargets.updateValue((profile, tool), forKey: key) != nil {
          issues.append(
            ProductionReadinessIssue(
              code: "inventory.duplicate_capability",
              message: "Inventory contains duplicate capability target '\(key)'."
            )
          )
        }
      }
    }
    var validRows: [CapabilityCoverageEvidence] = []
    let controlTestCaseIDs = Set(
      catalog.testCases.filter { $0.transports.contains(.controlSocket) }.map(\.id)
    )
    for row in verifiedRows {
      guard
        let (profile, tool) = inventoryTargets[
          Self.key(configuration: row.configuration, toolName: row.toolName)
        ]
      else {
        if row.transport == ValidationTransport.controlSocket.rawValue,
          row.testCaseID.map(controlTestCaseIDs.contains) == true
        {
          continue
        }
        issues.append(
          ProductionReadinessIssue(
            code: "evidence.unknown_capability",
            evidenceID: row.id,
            message: "Evidence references an unknown inventory capability."
          )
        )
        continue
      }
      let rowIssues = Self.validate(row: row, profile: profile, tool: tool, fixture: fixtureReport)
      issues.append(contentsOf: rowIssues)
      if rowIssues.isEmpty { validRows.append(row) }
    }

    let latest = Self.latestRows(validRows)
    var coverage: [CapabilityCoverageEntry] = []
    for profile in inventory.profiles {
      for tool in profile.tools {
        let target = Self.key(configuration: profile.configuration, toolName: tool.name)
        let contractPassed =
          tool.hasDescription && tool.hasInputSchema && tool.hasOutputSchema
          && tool.hasAnnotations && tool.schemaDigest.count == 64
        let contract = CapabilityLayerResult(
          status: contractPassed ? .passed : .failed,
          evidenceID: "inventory:\(profile.configuration):\(tool.name)",
          transport: "static_inventory"
        )
        let runtime: CapabilityLayerResult
        if profile.requiresRuntimeEvidence {
          runtime =
            latest[Self.layerKey(target, .runtime)].map(Self.layerResult)
            ?? CapabilityLayerResult(status: .pending)
        } else {
          runtime = CapabilityLayerResult(status: .notApplicable)
        }
        let external: CapabilityLayerResult
        let remoteCaller =
          profile.caller == GatewayCallerKind.secureTunnel.rawValue
          || profile.caller == GatewayCallerKind.cloudflareTunnel.rawValue
        if profile.requiresRuntimeEvidence && remoteCaller && !tool.localOnly {
          external =
            latest[Self.layerKey(target, .externalConsumer)].map(Self.layerResult)
            ?? CapabilityLayerResult(status: .pending)
        } else {
          external = CapabilityLayerResult(status: .notApplicable)
        }
        coverage.append(
          CapabilityCoverageEntry(
            configuration: profile.configuration,
            caller: profile.caller,
            profile: profile.profile,
            toolName: tool.name,
            domain: tool.domain,
            risk: tool.risk,
            workspaceRequirement: tool.workspaceRequirement,
            localOnly: tool.localOnly,
            usesNetwork: tool.usesNetwork,
            contract: contract,
            runtime: runtime,
            externalConsumer: external
          )
        )
      }
    }
    coverage.sort { ($0.configuration, $0.toolName) < ($1.configuration, $1.toolName) }

    let testCaseResults = Self.testCaseResults(catalog: catalog, bundles: verifiedBundles)
    for result in testCaseResults where result.status != .passed {
      issues.append(
        ProductionReadinessIssue(
          code: "test_case.correlation_incomplete",
          message: "\(result.id): \(result.detail ?? "required evidence is incomplete")"
        )
      )
    }
    issues.sort {
      ($0.code, $0.evidenceID ?? "", $0.message) < ($1.code, $1.evidenceID ?? "", $1.message)
    }

    let layers = coverage.flatMap { [$0.runtime, $0.externalConsumer] }
    let summary = CapabilityCoverageSummary(
      entryCount: coverage.count,
      domainCount: Set(coverage.map(\.domain)).count,
      contractPassedCount: coverage.filter { $0.contract.status == .passed }.count,
      runtimePassedCount: coverage.filter { $0.runtime.status == .passed }.count,
      externalConsumerPassedCount: coverage.filter { $0.externalConsumer.status == .passed }.count,
      pendingCount: layers.filter { $0.status == .pending }.count,
      failedCount: layers.filter { $0.status == .failed }.count,
      unavailableCount: layers.filter { $0.status == .unavailable }.count,
      notApplicableCount: layers.filter { $0.status == .notApplicable }.count,
      testCaseCount: testCaseResults.count,
      testCasePassedCount: testCaseResults.filter { $0.status == .passed }.count,
      testCasePendingCount: testCaseResults.filter { $0.status == .pending }.count,
      testCaseFailedCount: testCaseResults.filter { $0.status == .failed }.count,
      issueCount: issues.count
    )
    return ProductionReadinessReport(
      generatedAt: ValidationTimestamp.string(from: generatedAt),
      inventoryGeneratedAt: inventory.generatedAt,
      fixtureEntryCount: fixtureReport?.entryCount,
      fixtureDigest: fixtureReport?.contentDigest,
      summary: summary,
      capabilityCoverage: coverage,
      testCases: testCaseResults,
      issues: issues
    )
  }

  private static func validate(
    row: CapabilityCoverageEvidence,
    profile: CapabilityInventoryProfile,
    tool: CapabilityInventoryTool,
    fixture: CapabilityFixtureReport?
  ) -> [ProductionReadinessIssue] {
    var issues: [ProductionReadinessIssue] = []
    func issue(_ code: String, _ message: String) {
      issues.append(ProductionReadinessIssue(code: code, evidenceID: row.id, message: message))
    }
    guard row.status == .passed else {
      issue("evidence.pass_required", "Only verified PASS evidence contributes to readiness.")
      return issues
    }
    if row.profileDigest != profile.acceptanceDigest {
      issue(
        "evidence.profile_digest_mismatch", "Evidence does not bind the current profile digest.")
    }
    if row.testCaseID?.isEmpty != false || row.runID?.isEmpty != false {
      issue(
        "evidence.test_case_or_run_missing",
        "Test Case and Validation Run identifiers are required.")
    }
    if row.requestIDs.isEmpty || row.requestIDs.count != row.auditEventIDs.count {
      issue(
        "evidence.audit_correlation_missing", "Requests and audit events must correlate one-to-one."
      )
    }
    if fixture != nil && Self.fixtureDomains.contains(tool.domain)
      && row.fixtureDigest != fixture?.contentDigest
    {
      issue(
        "evidence.fixture_digest_mismatch", "Evidence does not bind the current fixture digest.")
    }
    if row.layer == .contract {
      issue(
        "evidence.contract_pass_disallowed", "Contract PASS is derived from inventory, not a probe."
      )
    }
    return issues
  }

  private static func testCaseResults(
    catalog: ValidationTestCaseCatalog,
    bundles: [ValidationEvidenceBundle]
  ) -> [ValidationTestCaseResult] {
    let sources = bundles.flatMap { bundle in
      bundle.runs.flatMap { run in
        run.attempts.map { (bundle, run, $0) }
      }
    }
    return catalog.testCases.map { testCase in
      let matching = sources.filter { $0.2.testCaseID == testCase.id }
      let observedTransports = Set(matching.map { $0.1.transport.transport })
      let observedProfiles = Set(matching.map { $0.2.profileID.rawValue })
      let missingTransports = Set(testCase.transports).subtracting(observedTransports)
      let missingProfiles = Set(testCase.profiles).subtracting(observedProfiles)
      let observedAssertions = Set(matching.flatMap { $0.2.assertions.map(\.id) })
      let observedPostconditions = Set(
        matching.flatMap { $0.2.independentPostconditions.map(\.id) }
      )
      let requiredStepAssertions = Set(testCase.steps.map { "step.\($0.id)" })
      let requiredResultAssertions = Set(
        testCase.expectedResults.indices.map { "expected_result.\($0 + 1)" }
      )
      let requiredCleanupPostconditions = Set(
        testCase.cleanupSteps.indices.map { "cleanup.\($0 + 1)" }
      )
      let missingAssertions =
        requiredStepAssertions
        .union(requiredResultAssertions)
        .subtracting(observedAssertions)
      let missingPostconditions = requiredCleanupPostconditions.subtracting(
        observedPostconditions
      )
      let passed =
        !matching.isEmpty && missingTransports.isEmpty && missingProfiles.isEmpty
        && missingAssertions.isEmpty && missingPostconditions.isEmpty
      var details: [String] = []
      if matching.isEmpty { details.append("no verified Evidence Bundle attempt") }
      if !missingTransports.isEmpty {
        details.append("missing transports: \(missingTransports.map(\.rawValue).sorted())")
      }
      if !missingProfiles.isEmpty {
        details.append("missing profiles: \(missingProfiles.sorted())")
      }
      if !missingAssertions.isEmpty {
        details.append("missing assertions: \(missingAssertions.sorted())")
      }
      if !missingPostconditions.isEmpty {
        details.append("missing postconditions: \(missingPostconditions.sorted())")
      }
      return ValidationTestCaseResult(
        id: testCase.id,
        status: passed ? .passed : .pending,
        requiredTransports: testCase.transports,
        observedTransports: observedTransports.sorted { $0.rawValue < $1.rawValue },
        requiredProfiles: testCase.profiles,
        observedProfiles: observedProfiles.sorted(),
        runIDs: Set(matching.map { $0.1.id }).sorted(),
        evidenceIDs: matching.map { "\($0.0.id)/\($0.1.id)/\($0.2.id)" }.sorted(),
        detail: details.isEmpty ? nil : details.joined(separator: "; ")
      )
    }
  }

  private static func layerResult(_ row: CapabilityCoverageEvidence) -> CapabilityLayerResult {
    CapabilityLayerResult(
      status: row.status,
      evidenceID: row.id,
      transport: row.transport,
      testCaseID: row.testCaseID,
      runID: row.runID,
      requestIDs: row.requestIDs,
      auditEventIDs: row.auditEventIDs,
      detail: row.detail
    )
  }

  private static func latestRows(
    _ rows: [CapabilityCoverageEvidence]
  ) -> [String: CapabilityCoverageEvidence] {
    var latest: [String: CapabilityCoverageEvidence] = [:]
    for row in rows {
      let target = key(configuration: row.configuration, toolName: row.toolName)
      let key = layerKey(target, row.layer)
      if latest[key]?.recordedAt ?? "" <= row.recordedAt { latest[key] = row }
    }
    return latest
  }

  private static func key(configuration: String, toolName: String) -> String {
    "\(configuration)\u{1f}\(toolName)"
  }

  private static func layerKey(_ target: String, _ layer: ValidationEvidenceLayer) -> String {
    "\(target)\u{1f}\(layer.rawValue)"
  }

  private static let fixtureDomains: Set<String> = [
    "archive", "csv", "file", "git", "image", "json", "jsonl", "markdown", "media",
    "pdf", "plist", "skills", "sqlite", "structured", "toml", "workspace", "xml", "yaml",
  ]
}

public enum ValidationTimestamp {
  public static func now() -> String { string(from: Date()) }

  public static func string(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}
