import Foundation

/// The stable, machine-readable definition of one Computer MCP validation obligation.
public struct ValidationTestCase: Codable, Equatable, Sendable {
  public let id: String
  public let category: ValidationTestCaseCategory
  public let transports: [ValidationTransport]
  public let profiles: [String]
  public let prerequisites: [String]
  public let steps: [ValidationTestStep]
  public let expectedResults: [String]
  public let evidenceRequirements: [ValidationEvidenceRequirement]
  public let cleanupSteps: [String]
  public let riskLevel: ValidationRiskLevel

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case category
    case transports
    case profiles
    case prerequisites
    case steps
    case expectedResults = "expected_results"
    case evidenceRequirements = "evidence_requirements"
    case cleanupSteps = "cleanup_steps"
    case riskLevel = "risk_level"
  }
}

public enum ValidationTestCaseCategory: String, Codable, CaseIterable, Sendable {
  case security
  case lifecycle
  case catalog
  case connector
  case transport
  case installation
  case release
}

public enum ValidationTransport: String, Codable, CaseIterable, Sendable {
  case gatewaySocket = "gateway_socket"
  case controlSocket = "control_socket"
  case openAISecureMCPTunnel = "openai_secure_mcp_tunnel"
  case cloudflareTunnel = "cloudflare_tunnel"
  case cloudflareQuickTunnel = "cloudflare_quick_tunnel"
}

public enum ValidationRiskLevel: String, Codable, CaseIterable, Sendable {
  case low
  case medium
  case high
  case critical
}

public struct ValidationTestStep: Codable, Equatable, Sendable {
  public let id: String
  public let instruction: String
}

public enum ValidationEvidenceRequirementKind: String, Codable, CaseIterable, Sendable {
  case transport
  case request
  case audit
  case result
}

public struct ValidationEvidenceRequirement: Codable, Equatable, Sendable {
  public let kind: ValidationEvidenceRequirementKind
  public let correlationKey: String
  public let description: String

  enum CodingKeys: String, CodingKey, CaseIterable {
    case kind
    case correlationKey = "correlation_key"
    case description
  }
}

public struct ValidationTestCaseIssue: Codable, Equatable, Sendable {
  public let testCaseID: String
  public let field: String
  public let message: String

  enum CodingKeys: String, CodingKey {
    case testCaseID = "test_case_id"
    case field
    case message
  }
}

public struct ValidationTestCaseCatalog: Sendable {
  public static let schemaVersion = 1

  public let testCases: [ValidationTestCase]

  public init(testCases: [ValidationTestCase]) {
    self.testCases = testCases
  }

  public static func bundled() throws -> Self {
    guard
      let url = Bundle.module.url(
        forResource: "validation-test-cases",
        withExtension: "json"
      )
    else {
      throw ValidationTestCaseCatalogError.resourceMissing
    }
    let data = try Data(contentsOf: url)
    try ValidationTestCaseSchema.validate(data)
    let document = try JSONDecoder().decode(ValidationTestCaseDocument.self, from: data)
    guard document.schemaVersion == schemaVersion else {
      throw ValidationTestCaseCatalogError.unsupportedSchema(document.schemaVersion)
    }
    return Self(testCases: document.testCases)
  }

  public func validate() -> [ValidationTestCaseIssue] {
    var issues: [ValidationTestCaseIssue] = []
    var seen = Set<String>()
    let requiredKinds = Set(ValidationEvidenceRequirementKind.allCases)

    for testCase in testCases {
      func record(_ field: String, _ message: String) {
        issues.append(
          ValidationTestCaseIssue(testCaseID: testCase.id, field: field, message: message)
        )
      }

      if testCase.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        record("id", "must not be empty")
      } else if !seen.insert(testCase.id).inserted {
        record("id", "must be unique")
      }
      if testCase.transports.isEmpty { record("transports", "must not be empty") }
      if testCase.prerequisites.isEmpty { record("prerequisites", "must not be empty") }
      if testCase.steps.isEmpty { record("steps", "must not be empty") }
      if Set(testCase.steps.map(\.id)).count != testCase.steps.count {
        record("steps", "step identifiers must be unique within a test case")
      }
      if testCase.steps.contains(where: {
        $0.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }) {
        record("steps.instruction", "must not be empty")
      }
      if testCase.expectedResults.isEmpty { record("expected_results", "must not be empty") }
      if testCase.cleanupSteps.isEmpty { record("cleanup_steps", "must not be empty") }
      let evidenceKinds = Set(testCase.evidenceRequirements.map(\.kind))
      if evidenceKinds != requiredKinds {
        record(
          "evidence_requirements",
          "must require transport, request, audit, and independent result correlation"
        )
      }
      if testCase.evidenceRequirements.contains(where: {
        $0.correlationKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }) {
        record("evidence_requirements.correlation_key", "must not be empty")
      }
    }
    return issues
  }

  public func runbook(testCaseID: String? = nil) throws -> String {
    let selected: [ValidationTestCase]
    if let testCaseID {
      guard let testCase = testCases.first(where: { $0.id == testCaseID }) else {
        throw ValidationTestCaseCatalogError.unknownTestCase(testCaseID)
      }
      selected = [testCase]
    } else {
      selected = testCases
    }

    var lines = [
      "# Computer MCP Validation Runbook",
      "",
      "Schema: \(Self.schemaVersion)",
      "",
      "A PASS is valid only when every required correlation is present in a verified Validation Evidence Bundle. Probes and local tests are auxiliary and cannot independently produce PASS.",
      "",
    ]
    for testCase in selected {
      lines.append("## \(testCase.id)")
      lines.append("")
      lines.append("- Category: `\(testCase.category.rawValue)`")
      lines.append(
        "- Transports: " + testCase.transports.map { "`\($0.rawValue)`" }.joined(separator: ", ")
      )
      lines.append(
        "- Profiles: " + testCase.profiles.map { "`\($0)`" }.joined(separator: ", ")
      )
      lines.append("- Risk: `\(testCase.riskLevel.rawValue)`")
      lines.append("")
      appendSection("Prerequisites", values: testCase.prerequisites, to: &lines)
      lines.append("### Steps")
      lines.append("")
      for step in testCase.steps { lines.append("\(step.id). \(step.instruction)") }
      lines.append("")
      appendSection("Expected results", values: testCase.expectedResults, to: &lines)
      lines.append("### Required correlation evidence")
      lines.append("")
      for evidence in testCase.evidenceRequirements {
        lines.append(
          "- `\(evidence.kind.rawValue)` / `\(evidence.correlationKey)`: \(evidence.description)"
        )
      }
      lines.append("")
      appendSection("Cleanup", values: testCase.cleanupSteps, to: &lines)
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private func appendSection(_ title: String, values: [String], to lines: inout [String]) {
    lines.append("### \(title)")
    lines.append("")
    for value in values { lines.append("- \(value)") }
    lines.append("")
  }
}

private struct ValidationTestCaseDocument: Codable {
  let schemaVersion: Int
  let testCases: [ValidationTestCase]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case testCases = "test_cases"
  }
}

private enum ValidationTestCaseSchema {
  private static let rootKeys: Set<String> = ["schema_version", "test_cases"]
  private static let testCaseKeys = Set(ValidationTestCase.CodingKeys.allCases.map(\.rawValue))
  private static let stepKeys: Set<String> = ["id", "instruction"]
  private static let evidenceKeys = Set(
    ValidationEvidenceRequirement.CodingKeys.allCases.map(\.rawValue))

  static func validate(_ data: Data) throws {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ValidationTestCaseCatalogError.invalidShape("root must be an object")
    }
    try rejectUnknown(root.keys, allowed: rootKeys, path: "$")
    guard let testCases = root["test_cases"] as? [[String: Any]] else {
      throw ValidationTestCaseCatalogError.invalidShape("test_cases must be an array")
    }
    for (index, testCase) in testCases.enumerated() {
      let path = "$.test_cases[\(index)]"
      try rejectUnknown(testCase.keys, allowed: testCaseKeys, path: path)
      guard let steps = testCase["steps"] as? [[String: Any]] else {
        throw ValidationTestCaseCatalogError.invalidShape("\(path).steps must be an array")
      }
      for (stepIndex, step) in steps.enumerated() {
        try rejectUnknown(step.keys, allowed: stepKeys, path: "\(path).steps[\(stepIndex)]")
      }
      guard let requirements = testCase["evidence_requirements"] as? [[String: Any]] else {
        throw ValidationTestCaseCatalogError.invalidShape(
          "\(path).evidence_requirements must be an array"
        )
      }
      for (requirementIndex, requirement) in requirements.enumerated() {
        try rejectUnknown(
          requirement.keys,
          allowed: evidenceKeys,
          path: "\(path).evidence_requirements[\(requirementIndex)]"
        )
      }
    }
  }

  private static func rejectUnknown(
    _ keys: Dictionary<String, Any>.Keys,
    allowed: Set<String>,
    path: String
  ) throws {
    let unknown = Set(keys).subtracting(allowed).sorted()
    guard unknown.isEmpty else {
      throw ValidationTestCaseCatalogError.unknownFields(path: path, fields: unknown)
    }
  }
}

public enum ValidationTestCaseCatalogError: Error, LocalizedError, Equatable {
  case resourceMissing
  case unsupportedSchema(Int)
  case unknownTestCase(String)
  case invalidShape(String)
  case unknownFields(path: String, fields: [String])

  public var errorDescription: String? {
    switch self {
    case .resourceMissing:
      "The bundled Validation Test Case catalog is missing."
    case .unsupportedSchema(let version):
      "Unsupported Validation Test Case schema version \(version)."
    case .unknownTestCase(let id):
      "Unknown Validation Test Case \(id)."
    case .invalidShape(let message):
      "Invalid Validation Test Case catalog: \(message)."
    case .unknownFields(let path, let fields):
      "Unknown Validation Test Case fields at \(path): \(fields.joined(separator: ", "))."
    }
  }
}
