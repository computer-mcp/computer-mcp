import Foundation
import Testing

@testable import ComputerMCPValidation

@Suite("Release Evidence Manifest")
struct ReleaseEvidenceManifestTests {
  @Test("Verification record is sealed and digest-only")
  func verificationRecord() throws {
    let digest = String(repeating: "a", count: 64)
    let record = try ReleaseVerificationRecordDocument.sealed(
      id: "journey.chatgpt",
      generatedAt: "2026-08-11T00:00:00.000Z",
      candidate: candidate(digest: digest),
      procedureSHA256: digest,
      resultSHA256: digest,
      cleanupSHA256: digest
    )
    let encoded = try record.canonicalJSON()
    let text = String(decoding: encoded, as: UTF8.self)

    #expect(try ReleaseVerificationRecordDocument.decodeCanonicalJSON(encoded) == record)
    #expect(text.contains("\"redaction_policy\":\"digest_only\""))
    #expect(!text.contains("request-id"))
    #expect(!text.contains("consumer-result"))
  }

  @Test("Verification record rejects a nonrelease Team ID")
  func verificationRecordRejectsAdHocIdentity() {
    let digest = String(repeating: "a", count: 64)
    expectThrows(
      try ReleaseVerificationRecordDocument.sealed(
        id: "journey.local",
        generatedAt: "2026-08-11T00:00:00.000Z",
        candidate: ReleaseCandidateIdentity(
          version: "1.0.0",
          build: "1",
          commit: String(repeating: "b", count: 40),
          teamID: "adhoc",
          appExecutableSHA256: digest,
          embeddedCLISHA256: digest,
          dmgSHA256: digest
        ),
        procedureSHA256: digest,
        resultSHA256: digest,
        cleanupSHA256: digest
      )
    )
  }

  @Test("Canonical manifest is sealed and contains summaries only")
  func canonicalManifest() throws {
    let manifest = try makeManifest()
    let encoded = try manifest.canonicalJSON()
    let text = String(decoding: encoded, as: UTF8.self)

    #expect(try ReleaseEvidenceManifest.decodeCanonicalJSON(encoded) == manifest)
    #expect(text.contains("\"schema_version\":1"))
    #expect(text.contains("\"test_case_passed_count\":23"))
    #expect(!text.contains("consumer-result-secret"))
    #expect(!text.contains("/Users/"))
  }

  @Test("Content digest tampering is rejected")
  func rejectsTampering() throws {
    let manifest = try makeManifest()
    let tampered = Data(
      String(decoding: try manifest.canonicalJSON(), as: UTF8.self)
        .replacingOccurrences(
          of: "\"test_case_passed_count\":23",
          with: "\"test_case_passed_count\":22"
        )
        .utf8
    )

    expectThrows(try ReleaseEvidenceManifest.decodeCanonicalJSON(tampered))
  }

  @Test("Incomplete acceptance fails closed")
  func incompleteAcceptance() {
    let digest = String(repeating: "a", count: 64)
    expectThrows(
      try ReleaseEvidenceManifest.sealed(
        generatedAt: "2026-08-11T00:00:00.000Z",
        release: identity(digest: digest),
        acceptance: ReleaseAcceptanceSummary(
          status: "pending",
          testCaseCount: 23,
          testCasePassedCount: 22,
          verificationRecords: []
        ),
        evidenceBundles: []
      )
    )
  }

  private func makeManifest() throws -> ReleaseEvidenceManifest {
    let digest = String(repeating: "a", count: 64)
    return try ReleaseEvidenceManifest.sealed(
      generatedAt: "2026-08-11T00:00:00.000Z",
      release: identity(digest: digest),
      acceptance: ReleaseAcceptanceSummary(
        status: "passed",
        testCaseCount: 23,
        testCasePassedCount: 23,
        verificationRecords: ReleaseEvidenceManifest.requiredVerificationRecordIDs.map {
          ReleaseVerificationRecord(id: $0, sha256: digest)
        }
      ),
      evidenceBundles: [
        ReleaseEvidenceBundleSummary(
          sha256: digest,
          contentDigest: digest,
          runCount: 3,
          attemptCount: 23,
          testCaseIDs: try ValidationTestCaseCatalog.bundled().testCases.map(\.id),
          transports: ["openai_secure_mcp_tunnel"],
          profiles: ["chatgpt-observe"]
        )
      ]
    )
  }

  private func identity(digest: String) -> ReleaseArtifactIdentity {
    ReleaseArtifactIdentity(
      version: "1.0.0",
      build: "1",
      tag: "v1.0.0",
      commit: String(repeating: "b", count: 40),
      teamID: "A7JC3DY3PU",
      appExecutableSHA256: digest,
      embeddedCLISHA256: digest,
      dmgSHA256: digest,
      readinessReportSHA256: digest,
      evidenceArchiveSHA256: digest
    )
  }

  private func candidate(digest: String) -> ReleaseCandidateIdentity {
    ReleaseCandidateIdentity(
      version: "1.0.0",
      build: "1",
      commit: String(repeating: "b", count: 40),
      teamID: "A7JC3DY3PU",
      appExecutableSHA256: digest,
      embeddedCLISHA256: digest,
      dmgSHA256: digest
    )
  }
}
