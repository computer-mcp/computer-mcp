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
  /// The client whose preview or change is in progress.
  @Published private(set) var busyClient: RegistrationClient?
  @Published var review: LocalClientReview?
  @Published var outcome: LocalClientOutcome?
  /// Clients whose last change ended without a confirmed process exit. Reading their state
  /// starts more client processes, so it waits for an explicit refresh.
  @Published private(set) var uncertainClients: Set<RegistrationClient> = []

  private let controlPlane: any LocalClientRegistering
  /// Every registration call can start client processes, so at most one runs at a time.
  @Published private(set) var callInFlight = false
  /// A read requested while a call ran: nil for none, true when it was an explicit refresh.
  /// It runs after that call only if the call left nothing uncertain.
  private var pendingReload: Bool?

  init(controlPlane: any LocalClientRegistering) { self.controlPlane = controlPlane }

  func status(for client: RegistrationClient) -> ClientRegistrationStatus? {
    statuses.first { $0.client == client }
  }

  /// Reading states starts each client's CLI, so callers reload on demand, not on a timer.
  /// After anything uncertain only an explicit reload reads again.
  func reload(explicit: Bool = false) async {
    if callInFlight {
      pendingReload = (pendingReload ?? false) || explicit
      return
    }
    if explicit {
      uncertainClients = []
    } else if !uncertainClients.isEmpty {
      return
    }
    callInFlight = true
    var uncertain = false
    do {
      let loaded = try await controlPlane.fetchClientRegistrations()
      statuses = loaded
      let unconfirmed = loaded.filter(\.uncertain).map(\.client)
      uncertain = !unconfirmed.isEmpty
      markUncertain(unconfirmed)
      loadError = nil
    } catch {
      loadError = AppLocalization.errorDescription(error)
    }
    await finishCall(uncertain: uncertain)
  }

  func beginReview(_ client: RegistrationClient, operation: ClientRegistrationOperation) async {
    guard !callInFlight, review == nil, !uncertainClients.contains(client) else { return }
    callInFlight = true
    busyClient = client
    var uncertain = false
    do {
      let plan = try await controlPlane.previewClientRegistration(
        client: client, operation: operation)
      if plan.display.refusalCode == .uncertain {
        uncertain = true
        markUncertain([client])
        outcome = LocalClientOutcome(
          title: AppLocalization.string("Result unknown"),
          message: Self.message(for: .uncertain, client: client))
      } else {
        review = LocalClientReview(plan: plan)
      }
    } catch {
      outcome = Self.failure(error, client: client)
    }
    busyClient = nil
    await finishCall(uncertain: uncertain)
  }

  func cancelReview() { review = nil }

  /// Applies exactly the plan the owner reviewed; the service refuses it if anything changed.
  func confirm(_ reviewed: LocalClientReview) async {
    guard !callInFlight, review?.id == reviewed.id,
      !uncertainClients.contains(reviewed.plan.display.client)
    else { return }
    review = nil
    let plan = reviewed.plan
    let client = plan.display.client
    callInFlight = true
    busyClient = client
    var uncertain = false
    do {
      let result = try await controlPlane.applyClientRegistration(plan)
      uncertain = result.outcome == .uncertain
      outcome = Self.outcome(result, plan: plan.display)
    } catch {
      uncertain = (error as? ClientRegistrationError)?.code == .uncertain
      outcome = Self.failure(error, client: client)
    }
    busyClient = nil
    if uncertain {
      markUncertain([client])
    } else {
      pendingReload = pendingReload ?? false
    }
    await finishCall(uncertain: uncertain)
  }

  /// Records clients whose last process exit is unconfirmed and closes any review of them.
  private func markUncertain(_ clients: [RegistrationClient]) {
    uncertainClients.formUnion(clients)
    if let open = review, clients.contains(open.plan.display.client) { review = nil }
  }

  /// Ends the running call and runs the coalesced read unless the call left anything uncertain.
  private func finishCall(uncertain: Bool) async {
    callInFlight = false
    let pending = pendingReload
    pendingReload = nil
    guard !uncertain, let explicit = pending else { return }
    await reload(explicit: explicit)
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
      let step = result.steps.last { $0.outcome == .uncertain }?.step
      return LocalClientOutcome(
        title: AppLocalization.string("Result unknown"),
        message: AppLocalization.formatted(
          "Computer MCP couldn't confirm whether %@ finished %@. It last showed: %@. Check its settings, then refresh before trying again.",
          name, stepDescription(step), AppLocalization.string(result.finalState.localClientLabel)))
    case .failed:
      var sentences = [message(for: result.errorCode ?? .processFailed, client: plan.client)]
      switch result.recovery {
      case .restored:
        sentences.append(AppLocalization.string("The previous entry was restored."))
      case .notRestored:
        sentences.append(
          AppLocalization.formatted(
            "The previous entry couldn't be restored. Check %@'s settings.", name))
      case nil:
        break
      }
      sentences.append(
        AppLocalization.formatted(
          "It now shows: %@.", AppLocalization.string(result.finalState.localClientLabel)))
      return LocalClientOutcome(
        title: AppLocalization.formatted("Couldn't change %@", name),
        message: sentences.joined(separator: " "))
    }
  }

  /// Describes a registration step for a sentence that follows "finished".
  static func stepDescription(_ step: String?) -> String {
    switch step {
    case "remove": AppLocalization.string("removing the old entry")
    case "add": AppLocalization.string("adding the new entry")
    case "restore": AppLocalization.string("restoring the previous entry")
    case "register": AppLocalization.string("saving the entry")
    case "read": AppLocalization.string("reading its settings")
    case "probe": AppLocalization.string("checking its command")
    default: AppLocalization.string("the change")
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
      return AppLocalization.formatted(
        "%@ isn't available: it isn't installed, or its command didn't respond.", name)
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

extension ClientRegistrationState {
  /// Localization key for the state as shown in Home and in result messages.
  var localClientLabel: String {
    switch self {
    case .registered: "Connected"
    case .notRegistered: "Not connected"
    case .different: "Different entry"
    case .unavailable: "Unavailable"
    case .unreadable: "Settings can't be read"
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
