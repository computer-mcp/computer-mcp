import ComputerMCPControlPlane
import Foundation

@MainActor
protocol LocalClientRegistering {
  func fetchClientRegistrations() async throws -> [ClientRegistrationStatus]
  func previewClientRegistration(client: RegistrationClient, operation: ClientRegistrationOperation)
    async throws -> ClientRegistrationPlan
  func applyClientRegistration(_ plan: ClientRegistrationPlan) async throws
    -> ClientRegistrationResult
}

struct LocalClientReview: Identifiable {
  let id = UUID()
  let plan: ClientRegistrationPlan
}

struct LocalClientOutcome: Identifiable {
  let id = UUID()
  let title: String
  let message: String
}

@MainActor
final class LocalClientsModel: ObservableObject {
  @Published private(set) var statuses: [ClientRegistrationStatus] = []
  @Published private(set) var loadError: String?
  /// The client whose preview or change is in progress; one at a time.
  @Published private(set) var busyClient: RegistrationClient?
  @Published var review: LocalClientReview?
  @Published var outcome: LocalClientOutcome?

  private let controlPlane: any LocalClientRegistering
  private var loadGeneration = 0

  init(controlPlane: any LocalClientRegistering) { self.controlPlane = controlPlane }

  func status(for client: RegistrationClient) -> ClientRegistrationStatus? {
    statuses.first { $0.client == client }
  }

  /// Reading states starts each client's CLI, so callers reload on demand, not on a timer.
  func reload() async {
    loadGeneration += 1
    let generation = loadGeneration
    do {
      let loaded = try await controlPlane.fetchClientRegistrations()
      guard generation == loadGeneration else { return }
      statuses = loaded
      loadError = nil
    } catch {
      guard generation == loadGeneration else { return }
      loadError = AppLocalization.errorDescription(error)
    }
  }

  func beginReview(_ client: RegistrationClient, operation: ClientRegistrationOperation) async {
    guard busyClient == nil, review == nil else { return }
    busyClient = client
    defer { busyClient = nil }
    do {
      review = LocalClientReview(
        plan: try await controlPlane.previewClientRegistration(client: client, operation: operation)
      )
    } catch {
      outcome = Self.failure(error, client: client)
    }
  }

  func cancelReview() { review = nil }

  /// Applies exactly the plan the owner reviewed; the service refuses it if anything changed.
  func confirm(_ reviewed: LocalClientReview) async {
    guard busyClient == nil, review?.id == reviewed.id else { return }
    review = nil
    let plan = reviewed.plan
    busyClient = plan.display.client
    do {
      outcome = Self.outcome(
        try await controlPlane.applyClientRegistration(plan), plan: plan.display)
    } catch {
      outcome = Self.failure(error, client: plan.display.client)
    }
    busyClient = nil
    await reload()
  }

  static func outcome(_ result: ClientRegistrationResult, plan: ClientRegistrationDisplayPlan)
    -> LocalClientOutcome
  {
    let name = AppLocalization.string(plan.client.displayName)
    switch result.outcome {
    case .succeeded:
      return LocalClientOutcome(
        title: AppLocalization.formatted(
          plan.operation == .register
            ? (plan.state == .different ? "Updated Computer MCP in %@" : "Connected to %@")
            : "Removed from %@", name),
        message: AppLocalization.string(result.appliesAfter))
    case .uncertain:
      return LocalClientOutcome(
        title: AppLocalization.string("Result unknown"),
        message: AppLocalization.formatted(
          "Computer MCP couldn't confirm whether %@ applied the change. Check its settings before trying again.",
          name))
    case .failed:
      return LocalClientOutcome(
        title: AppLocalization.formatted("Couldn't change %@", name),
        message: message(for: result.errorCode ?? .processFailed, client: plan.client))
    }
  }

  static func failure(_ error: any Error, client: RegistrationClient) -> LocalClientOutcome {
    let name = AppLocalization.string(client.displayName)
    let message =
      (error as? ClientRegistrationError).map { Self.message(for: $0.code, client: client) }
      ?? AppLocalization.errorDescription(error)
    return LocalClientOutcome(
      title: AppLocalization.formatted("Couldn't change %@", name), message: message)
  }

  static func message(for code: ClientRegistrationErrorCode, client: RegistrationClient) -> String {
    let name = AppLocalization.string(client.displayName)
    switch code {
    case .changedSincePreview:
      return AppLocalization.formatted(
        "%@'s settings changed after you reviewed them. Nothing was changed; review again.", name)
    case .confirmationRequired:
      return AppLocalization.string("Review the change before applying it.")
    case .unsupportedEntry:
      return AppLocalization.formatted(
        "The existing entry uses settings Computer MCP couldn't restore if replacing it failed. Remove it in %@ first.",
        name)
    case .clientRunning:
      return AppLocalization.formatted("Quit %@, then try again.", name)
    case .unavailable:
      return AppLocalization.formatted("%@ isn't installed on this Mac.", name)
    case .unreadable:
      return AppLocalization.formatted(
        "Computer MCP couldn't read %@'s settings. Nothing was changed.", name)
    case .writerBusy:
      return AppLocalization.string("Another client change is in progress. Try again shortly.")
    case .writeFailed:
      return AppLocalization.formatted("The change couldn't be saved to %@'s settings.", name)
    case .invalidInput, .invalidServerExecutable:
      return AppLocalization.string(
        "Computer MCP's own command isn't available. Reinstall the App, then try again.")
    case .supportDirectoryMissing:
      return AppLocalization.formatted("Open %@ once, then try again.", name)
    case .processFailed:
      return AppLocalization.formatted("%@ reported an error while changing its settings.", name)
    case .uncertain:
      return AppLocalization.formatted(
        "Computer MCP couldn't confirm whether %@ applied the change. Check its settings before trying again.",
        name)
    }
  }
}

extension RegistrationClient {
  var displayName: String {
    switch self {
    case .codex: "Codex"
    case .claudeCode: "Claude Code"
    case .claudeDesktop: "Claude Desktop"
    }
  }
}
