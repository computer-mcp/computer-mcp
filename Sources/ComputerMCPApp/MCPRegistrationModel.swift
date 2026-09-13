import Combine
import ComputerMCP
import Foundation

@MainActor
protocol MCPRegistrationManaging {
  func mcpCredentialStatus(id: String) async throws -> MCPRegistrationCredentialStatus
  func changeMCPCredential(id: String, expectedBindingDigest: String, token: String?) async throws
  func fetchMCPRegistrations() async throws -> MCPRegistrationSnapshot
  func doctorMCPRegistration(id: String, workspaceID: String) async throws
    -> MCPRegistrationDoctorReport
  func recoverMCPProcessReceipt(
    id: String, workspaceID: String, receiptID: String, expectedReceiptDigest: String,
    expectedCurrentDigest: String
  ) async throws
  func changeMCPRegistration(
    _ change: MCPRegistrationChange, apply: Bool, expectedCurrentDigest: String?
  ) async throws -> MCPRegistrationChangePreview
}

@MainActor
final class MCPRegistrationModel: ObservableObject {
  @Published private(set) var snapshot: MCPRegistrationSnapshot?
  @Published private(set) var isBusy = false
  @Published private(set) var errorMessage: String?
  @Published private(set) var preview: MCPRegistrationChangePreview?
  @Published private(set) var doctorReport: MCPRegistrationDoctorReport?
  @Published private(set) var processRecovered = false
  @Published private(set) var credentialStatus: MCPRegistrationCredentialStatus?
  private var change: MCPRegistrationChange?
  private let controlPlane: any MCPRegistrationManaging

  init(controlPlane: any MCPRegistrationManaging) { self.controlPlane = controlPlane }

  func loadCredential(id: String) async {
    guard !isBusy, preview == nil else { return }
    isBusy = true
    credentialStatus = nil
    errorMessage = nil
    defer { isBusy = false }
    do { credentialStatus = try await controlPlane.mcpCredentialStatus(id: id) } catch {
      errorMessage = AppLocalization.errorDescription(error)
    }
  }

  func saveCredential(id: String, token: String?) async -> Bool {
    guard !isBusy, let status = credentialStatus, status.registrationID == id else { return false }
    isBusy = true
    credentialStatus = nil
    errorMessage = nil
    defer { isBusy = false }
    do {
      try await controlPlane.changeMCPCredential(
        id: id, expectedBindingDigest: status.bindingDigest, token: token)
      credentialStatus = try await controlPlane.mcpCredentialStatus(id: id)
      return true
    } catch {
      errorMessage = AppLocalization.errorDescription(error)
      return false
    }
  }

  func checkConnection(id: String, workspaceID: String) async {
    guard !isBusy, preview == nil else { return }
    isBusy = true
    doctorReport = nil
    processRecovered = false
    errorMessage = nil
    defer { isBusy = false }
    do {
      doctorReport = try await controlPlane.doctorMCPRegistration(id: id, workspaceID: workspaceID)
    } catch { errorMessage = AppLocalization.errorDescription(error) }
  }

  func clearConnectionReport() {
    guard !isBusy else { return }
    doctorReport = nil
    processRecovered = false
  }

  func recoverProcess(id: String, workspaceID: String, receipt: MCPProcessReceiptStatus) async {
    guard !isBusy, preview == nil, let report = doctorReport,
      report.registrationID == id, report.workspaceID == workspaceID,
      receipt.recoverable, report.processReceipts?.contains(receipt) == true
    else { return }
    isBusy = true
    errorMessage = nil
    doctorReport = nil
    processRecovered = false
    defer { isBusy = false }
    do {
      try await controlPlane.recoverMCPProcessReceipt(
        id: id, workspaceID: workspaceID, receiptID: receipt.id,
        expectedReceiptDigest: receipt.digest, expectedCurrentDigest: report.currentDigest)
      processRecovered = true
    } catch { errorMessage = AppLocalization.errorDescription(error) }
  }

  func reload() async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      snapshot = try await controlPlane.fetchMCPRegistrations()
      errorMessage = nil
    } catch { errorMessage = AppLocalization.errorDescription(error) }
  }

  func review(_ proposed: MCPRegistrationChange) async -> Bool {
    guard !isBusy else { return false }
    isBusy = true
    preview = nil
    doctorReport = nil
    change = nil
    defer { isBusy = false }
    do {
      preview = try await controlPlane.changeMCPRegistration(
        proposed, apply: false, expectedCurrentDigest: nil)
      change = proposed
      errorMessage = nil
      return true
    } catch {
      errorMessage = AppLocalization.errorDescription(error)
      return false
    }
  }

  func cancelReview() {
    guard !isBusy else { return }
    preview = nil
    change = nil
  }

  func apply() async {
    guard !isBusy, let preview, let change else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      _ = try await controlPlane.changeMCPRegistration(
        change, apply: true, expectedCurrentDigest: preview.currentDigest)
      self.preview = nil
      self.change = nil
      snapshot = try await controlPlane.fetchMCPRegistrations()
      errorMessage = nil
    } catch {
      self.preview = nil
      self.change = nil
      errorMessage = AppLocalization.errorDescription(error)
    }
  }
}

struct MCPRegistrationDraft {
  var server: MCPServerConfig
  var argumentsJSON: String
  var environmentJSON: String
  var allowedToolsText: String
  var riskJSON: String

  init(server: MCPServerConfig) {
    self.server = server
    argumentsJSON = Self.json(server.args)
    environmentJSON = Self.json(server.env)
    allowedToolsText = server.allowedTools.joined(separator: "\n")
    riskJSON = Self.json(server.toolRisks)
  }

  func value() throws -> MCPServerConfig {
    var result = server
    result.args = try JSONDecoder().decode([String].self, from: Data(argumentsJSON.utf8))
    result.env = try JSONDecoder().decode([String: String].self, from: Data(environmentJSON.utf8))
    result.toolRisks = try JSONDecoder().decode(
      [String: CapabilityRisk].self, from: Data(riskJSON.utf8))
    result.allowedTools =
      result.allowAnyTool ? [] : allowedToolsText.split(separator: "\n").map(String.init)
    return result
  }

  private static func json<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? ""
  }
}
