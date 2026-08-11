import CryptoKit
import Foundation

public struct ReleaseArtifactIdentity: Codable, Equatable, Sendable {
  public let version: String
  public let build: String
  public let tag: String
  public let commit: String
  public let teamID: String
  public let appExecutableSHA256: String
  public let embeddedCLISHA256: String
  public let dmgSHA256: String
  public let readinessReportSHA256: String
  public let evidenceArchiveSHA256: String

  public init(
    version: String,
    build: String,
    tag: String,
    commit: String,
    teamID: String,
    appExecutableSHA256: String,
    embeddedCLISHA256: String,
    dmgSHA256: String,
    readinessReportSHA256: String,
    evidenceArchiveSHA256: String
  ) {
    self.version = version
    self.build = build
    self.tag = tag
    self.commit = commit
    self.teamID = teamID
    self.appExecutableSHA256 = appExecutableSHA256
    self.embeddedCLISHA256 = embeddedCLISHA256
    self.dmgSHA256 = dmgSHA256
    self.readinessReportSHA256 = readinessReportSHA256
    self.evidenceArchiveSHA256 = evidenceArchiveSHA256
  }
}

public struct ReleaseCandidateIdentity: Codable, Equatable, Sendable {
  public let version: String
  public let build: String
  public let commit: String
  public let teamID: String
  public let appExecutableSHA256: String
  public let embeddedCLISHA256: String
  public let dmgSHA256: String

  public init(
    version: String,
    build: String,
    commit: String,
    teamID: String,
    appExecutableSHA256: String,
    embeddedCLISHA256: String,
    dmgSHA256: String
  ) {
    self.version = version
    self.build = build
    self.commit = commit
    self.teamID = teamID
    self.appExecutableSHA256 = appExecutableSHA256
    self.embeddedCLISHA256 = embeddedCLISHA256
    self.dmgSHA256 = dmgSHA256
  }
}

public struct ReleaseVerificationRecordDocument: Codable, Equatable, Sendable {
  public static let schemaVersion = 1
  public static let requiredIDs = [
    "journey.local",
    "journey.chatgpt",
    "journey.cloudflare",
    "platform.apple_silicon_native",
    "platform.rosetta_x86_64",
  ]

  public let schemaVersion: Int
  public let id: String
  public let generatedAt: String
  public let status: String
  public let candidate: ReleaseCandidateIdentity
  public let procedureSHA256: String
  public let resultSHA256: String
  public let cleanupSHA256: String
  public let redactionPolicy: String
  public let contentDigest: String

  private init(
    schemaVersion: Int = Self.schemaVersion,
    id: String,
    generatedAt: String,
    status: String,
    candidate: ReleaseCandidateIdentity,
    procedureSHA256: String,
    resultSHA256: String,
    cleanupSHA256: String,
    redactionPolicy: String,
    contentDigest: String
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.generatedAt = generatedAt
    self.status = status
    self.candidate = candidate
    self.procedureSHA256 = procedureSHA256
    self.resultSHA256 = resultSHA256
    self.cleanupSHA256 = cleanupSHA256
    self.redactionPolicy = redactionPolicy
    self.contentDigest = contentDigest
  }

  public static func sealed(
    id: String,
    generatedAt: String,
    candidate: ReleaseCandidateIdentity,
    procedureSHA256: String,
    resultSHA256: String,
    cleanupSHA256: String
  ) throws -> ReleaseVerificationRecordDocument {
    let unsealed = ReleaseVerificationRecordDocument(
      id: id,
      generatedAt: generatedAt,
      status: "passed",
      candidate: candidate,
      procedureSHA256: procedureSHA256,
      resultSHA256: resultSHA256,
      cleanupSHA256: cleanupSHA256,
      redactionPolicy: "digest_only",
      contentDigest: ""
    )
    try unsealed.validate()
    return ReleaseVerificationRecordDocument(
      id: unsealed.id,
      generatedAt: unsealed.generatedAt,
      status: unsealed.status,
      candidate: unsealed.candidate,
      procedureSHA256: unsealed.procedureSHA256,
      resultSHA256: unsealed.resultSHA256,
      cleanupSHA256: unsealed.cleanupSHA256,
      redactionPolicy: unsealed.redactionPolicy,
      contentDigest: try unsealed.calculatedContentDigest()
    )
  }

  public func canonicalJSON() throws -> Data {
    try ValidationJSONCoding.encode(self, prettyPrinted: false)
  }

  public static func decodeCanonicalJSON(
    _ data: Data
  ) throws -> ReleaseVerificationRecordDocument {
    let record = try ValidationJSONCoding.decode(Self.self, from: data)
    guard record.schemaVersion == schemaVersion else {
      throw ValidationArtifactError.unsupportedSchema(
        artifact: "Release Verification Record",
        expected: schemaVersion,
        actual: record.schemaVersion
      )
    }
    try ValidationJSONCoding.requireExactShape(
      record,
      input: data,
      artifact: "Release Verification Record"
    )
    try record.validate()
    guard try record.calculatedContentDigest() == record.contentDigest else {
      throw ReleaseEvidenceManifestError.contentDigestMismatch
    }
    return record
  }

  private func validate() throws {
    guard Self.requiredIDs.contains(id), status == "passed", redactionPolicy == "digest_only" else {
      throw ReleaseEvidenceManifestError.verificationRecordsIncomplete
    }
    guard Self.isISO8601Timestamp(generatedAt) else {
      throw ReleaseEvidenceManifestError.invalidGeneratedAt
    }
    let versionComponents = candidate.version.split(
      separator: ".",
      omittingEmptySubsequences: false
    )
    guard versionComponents.count == 3,
      versionComponents.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
      !candidate.build.isEmpty,
      candidate.build.allSatisfy(\.isNumber),
      Self.isHexDigest(candidate.commit, length: 40),
      candidate.teamID.count == 10,
      candidate.teamID.allSatisfy({ $0.isNumber || ($0.isLetter && $0.isUppercase) })
    else {
      throw ReleaseEvidenceManifestError.invalidReleaseIdentity
    }
    for digest in [
      candidate.appExecutableSHA256,
      candidate.embeddedCLISHA256,
      candidate.dmgSHA256,
      procedureSHA256,
      resultSHA256,
      cleanupSHA256,
    ] where !Self.isHexDigest(digest, length: 64) {
      throw ReleaseEvidenceManifestError.invalidDigest
    }
  }

  private func calculatedContentDigest() throws -> String {
    let unsealed = ReleaseVerificationRecordDocument(
      id: id,
      generatedAt: generatedAt,
      status: status,
      candidate: candidate,
      procedureSHA256: procedureSHA256,
      resultSHA256: resultSHA256,
      cleanupSHA256: cleanupSHA256,
      redactionPolicy: redactionPolicy,
      contentDigest: ""
    )
    let data = try ValidationJSONCoding.encode(unsealed, prettyPrinted: false)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func isHexDigest(_ value: String, length: Int) -> Bool {
    value.count == length && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }

  private static func isISO8601Timestamp(_ value: String) -> Bool {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if formatter.date(from: value) != nil { return true }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value) != nil
  }
}

public struct ReleaseVerificationRecord: Codable, Equatable, Sendable {
  public let id: String
  public let sha256: String

  public init(id: String, sha256: String) {
    self.id = id
    self.sha256 = sha256
  }
}

public struct ReleaseAcceptanceSummary: Codable, Equatable, Sendable {
  public let status: String
  public let testCaseCount: Int
  public let testCasePassedCount: Int
  public let verificationRecords: [ReleaseVerificationRecord]

  public init(
    status: String,
    testCaseCount: Int,
    testCasePassedCount: Int,
    verificationRecords: [ReleaseVerificationRecord]
  ) {
    self.status = status
    self.testCaseCount = testCaseCount
    self.testCasePassedCount = testCasePassedCount
    self.verificationRecords = verificationRecords
  }
}

public struct ReleaseEvidenceBundleSummary: Codable, Equatable, Sendable {
  public let sha256: String
  public let contentDigest: String
  public let runCount: Int
  public let attemptCount: Int
  public let testCaseIDs: [String]
  public let transports: [String]
  public let profiles: [String]

  public init(
    sha256: String,
    contentDigest: String,
    runCount: Int,
    attemptCount: Int,
    testCaseIDs: [String],
    transports: [String],
    profiles: [String]
  ) {
    self.sha256 = sha256
    self.contentDigest = contentDigest
    self.runCount = runCount
    self.attemptCount = attemptCount
    self.testCaseIDs = testCaseIDs
    self.transports = transports
    self.profiles = profiles
  }
}

public struct ReleaseEvidenceRedaction: Codable, Equatable, Sendable {
  public let policy: String
  public let omittedFields: [String]

  public init(policy: String, omittedFields: [String]) {
    self.policy = policy
    self.omittedFields = omittedFields
  }
}

public struct ReleaseEvidenceManifest: Codable, Equatable, Sendable {
  public static let schemaVersion = 1
  public static let requiredVerificationRecordIDs = ReleaseVerificationRecordDocument.requiredIDs

  public let schemaVersion: Int
  public let generatedAt: String
  public let release: ReleaseArtifactIdentity
  public let acceptance: ReleaseAcceptanceSummary
  public let evidenceBundles: [ReleaseEvidenceBundleSummary]
  public let redaction: ReleaseEvidenceRedaction
  public let contentDigest: String

  private init(
    schemaVersion: Int = Self.schemaVersion,
    generatedAt: String,
    release: ReleaseArtifactIdentity,
    acceptance: ReleaseAcceptanceSummary,
    evidenceBundles: [ReleaseEvidenceBundleSummary],
    redaction: ReleaseEvidenceRedaction,
    contentDigest: String
  ) {
    self.schemaVersion = schemaVersion
    self.generatedAt = generatedAt
    self.release = release
    self.acceptance = acceptance
    self.evidenceBundles = evidenceBundles
    self.redaction = redaction
    self.contentDigest = contentDigest
  }

  public static func sealed(
    generatedAt: String,
    release: ReleaseArtifactIdentity,
    acceptance: ReleaseAcceptanceSummary,
    evidenceBundles: [ReleaseEvidenceBundleSummary]
  ) throws -> ReleaseEvidenceManifest {
    try validate(
      generatedAt: generatedAt,
      release: release,
      acceptance: acceptance,
      evidenceBundles: evidenceBundles
    )
    let redaction = ReleaseEvidenceRedaction(
      policy: "summary_only",
      omittedFields: [
        "audit_event_id",
        "consumer_result_id",
        "credential",
        "input",
        "local_path",
        "output",
        "request_id",
        "transport_request_id",
      ]
    )
    let sortedAcceptance = ReleaseAcceptanceSummary(
      status: acceptance.status,
      testCaseCount: acceptance.testCaseCount,
      testCasePassedCount: acceptance.testCasePassedCount,
      verificationRecords: acceptance.verificationRecords.sorted { $0.id < $1.id }
    )
    let unsealed = ReleaseEvidenceManifest(
      generatedAt: generatedAt,
      release: release,
      acceptance: sortedAcceptance,
      evidenceBundles: evidenceBundles.sorted { $0.contentDigest < $1.contentDigest },
      redaction: redaction,
      contentDigest: ""
    )
    return ReleaseEvidenceManifest(
      generatedAt: unsealed.generatedAt,
      release: unsealed.release,
      acceptance: unsealed.acceptance,
      evidenceBundles: unsealed.evidenceBundles,
      redaction: unsealed.redaction,
      contentDigest: try unsealed.calculatedContentDigest()
    )
  }

  public func canonicalJSON() throws -> Data {
    try ValidationJSONCoding.encode(self, prettyPrinted: false)
  }

  public static func decodeCanonicalJSON(_ data: Data) throws -> ReleaseEvidenceManifest {
    let manifest = try ValidationJSONCoding.decode(Self.self, from: data)
    guard manifest.schemaVersion == schemaVersion else {
      throw ValidationArtifactError.unsupportedSchema(
        artifact: "Release Evidence Manifest",
        expected: schemaVersion,
        actual: manifest.schemaVersion
      )
    }
    try ValidationJSONCoding.requireExactShape(
      manifest,
      input: data,
      artifact: "Release Evidence Manifest"
    )
    try validate(
      generatedAt: manifest.generatedAt,
      release: manifest.release,
      acceptance: manifest.acceptance,
      evidenceBundles: manifest.evidenceBundles
    )
    guard try manifest.calculatedContentDigest() == manifest.contentDigest else {
      throw ReleaseEvidenceManifestError.contentDigestMismatch
    }
    return manifest
  }

  private func calculatedContentDigest() throws -> String {
    let unsealed = ReleaseEvidenceManifest(
      generatedAt: generatedAt,
      release: release,
      acceptance: acceptance,
      evidenceBundles: evidenceBundles,
      redaction: redaction,
      contentDigest: ""
    )
    let data = try ValidationJSONCoding.encode(unsealed, prettyPrinted: false)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func validate(
    generatedAt: String,
    release: ReleaseArtifactIdentity,
    acceptance: ReleaseAcceptanceSummary,
    evidenceBundles: [ReleaseEvidenceBundleSummary]
  ) throws {
    guard isISO8601Timestamp(generatedAt) else {
      throw ReleaseEvidenceManifestError.invalidGeneratedAt
    }
    let versionComponents = release.version.split(separator: ".", omittingEmptySubsequences: false)
    guard release.tag == "v\(release.version)",
      versionComponents.count == 3,
      versionComponents.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
      !release.build.isEmpty,
      release.build.allSatisfy(\.isNumber)
    else {
      throw ReleaseEvidenceManifestError.invalidReleaseIdentity
    }
    guard isHexDigest(release.commit, length: 40),
      release.teamID.count == 10,
      release.teamID.allSatisfy({ $0.isNumber || ($0.isLetter && $0.isUppercase) })
    else {
      throw ReleaseEvidenceManifestError.invalidReleaseIdentity
    }
    for digest in [
      release.appExecutableSHA256,
      release.embeddedCLISHA256,
      release.dmgSHA256,
      release.readinessReportSHA256,
      release.evidenceArchiveSHA256,
    ] where !isHexDigest(digest, length: 64) {
      throw ReleaseEvidenceManifestError.invalidDigest
    }
    guard acceptance.status == "passed",
      acceptance.testCaseCount == 23,
      acceptance.testCasePassedCount == acceptance.testCaseCount
    else {
      throw ReleaseEvidenceManifestError.acceptanceIncomplete
    }
    let verificationIDs = acceptance.verificationRecords.map(\.id).sorted()
    guard verificationIDs == requiredVerificationRecordIDs.sorted(),
      Set(verificationIDs).count == verificationIDs.count,
      acceptance.verificationRecords.allSatisfy({ isHexDigest($0.sha256, length: 64) })
    else {
      throw ReleaseEvidenceManifestError.verificationRecordsIncomplete
    }
    guard !evidenceBundles.isEmpty else {
      throw ReleaseEvidenceManifestError.evidenceBundlesMissing
    }
    for summary in evidenceBundles {
      guard isHexDigest(summary.sha256, length: 64),
        isHexDigest(summary.contentDigest, length: 64),
        summary.runCount > 0,
        summary.attemptCount > 0,
        !summary.testCaseIDs.isEmpty,
        !summary.transports.isEmpty,
        !summary.profiles.isEmpty
      else {
        throw ReleaseEvidenceManifestError.invalidEvidenceBundleSummary
      }
    }
    guard Set(evidenceBundles.map(\.sha256)).count == evidenceBundles.count,
      Set(evidenceBundles.map(\.contentDigest)).count == evidenceBundles.count
    else {
      throw ReleaseEvidenceManifestError.invalidEvidenceBundleSummary
    }
    let catalogIDs = Set(try ValidationTestCaseCatalog.bundled().testCases.map(\.id))
    let manifestIDs = Set(evidenceBundles.flatMap(\.testCaseIDs))
    guard catalogIDs.count == 23, manifestIDs == catalogIDs else {
      throw ReleaseEvidenceManifestError.acceptanceIncomplete
    }
  }

  private static func isHexDigest(_ value: String, length: Int) -> Bool {
    value.count == length && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }

  private static func isISO8601Timestamp(_ value: String) -> Bool {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if formatter.date(from: value) != nil { return true }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value) != nil
  }
}

public enum ReleaseEvidenceManifestBuilder {
  public static func build(
    generatedAt: String,
    release: ReleaseArtifactIdentity,
    readinessReport: ProductionReadinessReport,
    evidenceBundles: [(sha256: String, bundle: ValidationEvidenceBundle)],
    verificationRecords: [ReleaseVerificationRecord]
  ) throws -> ReleaseEvidenceManifest {
    guard readinessReport.isReady,
      readinessReport.summary.testCaseCount == 23,
      readinessReport.summary.testCasePassedCount == 23,
      readinessReport.testCases.allSatisfy({ $0.status == .passed })
    else {
      throw ReleaseEvidenceManifestError.acceptanceIncomplete
    }

    let reportEvidenceIDs = Set(readinessReport.testCases.flatMap(\.evidenceIDs))
    let providedEvidenceIDs = Set(evidenceBundles.map(\.bundle.id))
    guard reportEvidenceIDs == providedEvidenceIDs else {
      throw ReleaseEvidenceManifestError.reportEvidenceMismatch
    }

    let verifier = ValidationEvidenceBundleVerifier()
    let summaries = try evidenceBundles.map { input in
      let verification = verifier.verify(input.bundle)
      guard verification.isVerified else {
        throw ReleaseEvidenceManifestError.evidenceBundleRejected(input.bundle.id)
      }
      let environments = [input.bundle.environment] + input.bundle.runs.map(\.environment)
      guard
        environments.allSatisfy({ environment in
          environment.appVersion == release.version
            && environment.appBuild == release.build
            && environment.appDigest == release.appExecutableSHA256
            && environment.buildDigest == release.embeddedCLISHA256
        })
      else {
        throw ReleaseEvidenceManifestError.evidenceArtifactMismatch(input.bundle.id)
      }
      let attempts = input.bundle.runs.flatMap(\.attempts)
      return ReleaseEvidenceBundleSummary(
        sha256: input.sha256,
        contentDigest: input.bundle.contentDigest,
        runCount: input.bundle.runs.count,
        attemptCount: attempts.count,
        testCaseIDs: Set(attempts.map(\.testCaseID)).sorted(),
        transports: Set(input.bundle.runs.map(\.transport.transport.rawValue)).sorted(),
        profiles: Set(attempts.map(\.profileID.rawValue)).sorted()
      )
    }

    return try ReleaseEvidenceManifest.sealed(
      generatedAt: generatedAt,
      release: release,
      acceptance: ReleaseAcceptanceSummary(
        status: "passed",
        testCaseCount: readinessReport.summary.testCaseCount,
        testCasePassedCount: readinessReport.summary.testCasePassedCount,
        verificationRecords: verificationRecords
      ),
      evidenceBundles: summaries
    )
  }
}

public enum ReleaseEvidenceManifestError: Error, LocalizedError, Equatable, Sendable {
  case invalidGeneratedAt
  case invalidReleaseIdentity
  case invalidDigest
  case acceptanceIncomplete
  case verificationRecordsIncomplete
  case evidenceBundlesMissing
  case invalidEvidenceBundleSummary
  case reportEvidenceMismatch
  case evidenceBundleRejected(String)
  case evidenceArtifactMismatch(String)
  case contentDigestMismatch

  public var errorDescription: String? {
    switch self {
    case .invalidGeneratedAt:
      return "Release Evidence Manifest generated_at is not an ISO-8601 timestamp."
    case .invalidReleaseIdentity:
      return "Release Evidence Manifest identity is invalid."
    case .invalidDigest:
      return "Release Evidence Manifest contains an invalid digest."
    case .acceptanceIncomplete:
      return "Release Evidence Manifest requires a ready 23/23 acceptance report."
    case .verificationRecordsIncomplete:
      return "Release Evidence Manifest requires all journey and platform verification records."
    case .evidenceBundlesMissing:
      return "Release Evidence Manifest requires at least one verified Evidence Bundle."
    case .invalidEvidenceBundleSummary:
      return "Release Evidence Manifest contains an invalid Evidence Bundle summary."
    case .reportEvidenceMismatch:
      return "Readiness report Evidence Bundles do not match the manifest inputs."
    case .evidenceBundleRejected(let id):
      return "Evidence Bundle '\(id)' failed verification."
    case .evidenceArtifactMismatch(let id):
      return "Evidence Bundle '\(id)' is not bound to the release App and embedded CLI."
    case .contentDigestMismatch:
      return "Release Evidence Manifest content digest does not match."
    }
  }
}
