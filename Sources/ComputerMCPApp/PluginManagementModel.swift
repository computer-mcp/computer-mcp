import Combine
import ComputerMCPControlPlane
import ComputerMCPPlugins
import Foundation

@MainActor
protocol PluginManaging: PluginCatalogManaging {
  func doctorPlugin(id: String) async throws -> PluginDoctorReport
  func pluginReleaseArtifacts(repository: String, repositoryID: Int64, tag: String?, page: Int)
    async throws -> GitHubPluginReleaseArtifacts
  func fetchPlugins() async throws -> PluginHostSnapshot
  func changePlugins(_ change: PluginHostChange, expectedRevision: Int64) async throws
    -> PluginHostSnapshot
  func reviewPluginEnablement(_ change: PluginHostChange, expectedRevision: Int64) async throws
    -> ProviderEnablementReview?
  func changePlugins(
    _ change: PluginHostChange, expectedRevision: Int64, approval: ProviderEnablementApproval
  ) async throws -> PluginHostSnapshot
}

extension PluginManaging {
  func reviewPluginEnablement(_ change: PluginHostChange, expectedRevision: Int64) async throws
    -> ProviderEnablementReview?
  { nil }

  func changePlugins(
    _ change: PluginHostChange, expectedRevision: Int64, approval: ProviderEnablementApproval
  ) async throws -> PluginHostSnapshot {
    throw ProviderEnablementError.reviewRequired
  }
}

@MainActor
final class PluginManagementModel: ObservableObject {
  let catalog: PluginCatalogModel
  @Published private(set) var snapshot: PluginHostSnapshot?
  @Published private(set) var isRefreshing = false
  @Published private(set) var isSaving = false
  @Published private(set) var isCancelling = false
  @Published private(set) var errorMessage: String?
  @Published private(set) var refusal: PluginCompatibilityRefusal?
  @Published private(set) var enablementReview: ProviderEnablementReview?
  private var reviewedChange: (PluginHostChange, Int64)?
  @Published var selectedID: String?

  let controlPlane: any PluginManaging
  private var refreshGeneration = 0
  private enum MutationOutcome {
    case review(ProviderEnablementReview)
    case saved(PluginHostSnapshot)
  }
  private var mutation: Task<MutationOutcome, any Error>?

  init(controlPlane: any PluginManaging) {
    self.controlPlane = controlPlane
    catalog = PluginCatalogModel(controlPlane: controlPlane)
  }

  var pluginIDs: [String] {
    guard let snapshot else { return [] }
    return Set(snapshot.state.installations.map(\.pluginID))
      .union(snapshot.bundled.map { $0.manifest.id })
      .union(snapshot.state.settings.keys).union(snapshot.issues.map(\.pluginID)).sorted()
  }

  func reload() async {
    refreshGeneration += 1
    let generation = refreshGeneration
    isRefreshing = true
    defer { if generation == refreshGeneration { isRefreshing = false } }
    do {
      let next = try await controlPlane.fetchPlugins()
      guard generation == refreshGeneration else { return }
      accept(next)
    } catch {
      guard generation == refreshGeneration else { return }
      report(error)
    }
  }

  @discardableResult
  func apply(_ change: PluginHostChange, expectedRevision: Int64) async -> Bool {
    guard enablementReview == nil else { return false }
    return await perform(change, expectedRevision: expectedRevision, approval: nil)
  }

  @discardableResult
  func confirmEnablement(reviewID: UUID, selection: ProviderEnablementSelection) async -> Bool {
    guard !isSaving, let review = enablementReview, reviewID == review.id,
      let (change, revision) = reviewedChange
    else { return false }
    cancelEnablement(reviewID: reviewID)
    return await perform(
      change, expectedRevision: revision,
      approval: ProviderEnablementApproval(review: review, selection: selection))
  }

  func cancelEnablement(reviewID: UUID) {
    guard !isSaving, enablementReview?.id == reviewID else { return }
    enablementReview = nil
    reviewedChange = nil
  }

  private func perform(
    _ change: PluginHostChange, expectedRevision: Int64, approval: ProviderEnablementApproval?
  ) async -> Bool {
    guard !isSaving else { return false }
    isSaving = true
    errorMessage = nil
    refusal = nil
    // In-flight reads cannot replace a committed result or its actionable failure.
    refreshGeneration += 1
    isRefreshing = false
    let controlPlane = controlPlane
    let task = Task<MutationOutcome, any Error> {
      try Task.checkCancellation()
      if let approval {
        return .saved(
          try await controlPlane.changePlugins(
            change, expectedRevision: expectedRevision, approval: approval))
      }
      if let review = try await controlPlane.reviewPluginEnablement(
        change, expectedRevision: expectedRevision)
      {
        try Task.checkCancellation()
        return .review(review)
      }
      try Task.checkCancellation()
      return .saved(
        try await controlPlane.changePlugins(change, expectedRevision: expectedRevision))
    }
    mutation = task
    defer {
      mutation = nil
      isSaving = false
      isCancelling = false
    }
    do {
      let outcome = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      switch outcome {
      case .review(let review):
        try Task.checkCancellation()
        guard !isCancelling else { throw CancellationError() }
        reviewedChange = (change, expectedRevision)
        enablementReview = review
        return false
      case .saved(let next):
        // A cancellation request cannot turn a committed operation into a reported rollback.
        accept(next)
        return true
      }
    } catch {
      // Refresh the list, but never retry a write or rebase an open editor's revision.
      await reload()
      if error is CancellationError {
        errorMessage = AppLocalization.string(
          "The operation was cancelled. Check the selected source before retrying.")
      } else {
        report(error)
      }
      return false
    }
  }

  func cancelChange() {
    guard isSaving, !isCancelling else { return }
    isCancelling = true
    mutation?.cancel()
  }

  func report(_ error: any Error) {
    refusal = error as? PluginCompatibilityRefusal ?? (error as? ControlSocketCallError)?.refusal
    if case PluginCatalogError.httpStatus(let status) = error {
      errorMessage = AppLocalization.formatted(
        "GitHub request failed with HTTP %@.", String(status))
    } else {
      errorMessage = refusal?.message ?? AppLocalization.errorDescription(error)
    }
  }

  private func accept(_ next: PluginHostSnapshot) {
    guard next.state.revision >= (snapshot?.state.revision ?? 0) else { return }
    snapshot = next
    errorMessage = nil
    refusal = nil
    if !pluginIDs.contains(selectedID ?? "") {
      selectedID = pluginIDs.first
    }
  }
}

enum PluginToolSelection: String, CaseIterable {
  case whitelist
  case all
}

struct PluginMCPDraft: Identifiable {
  let id: String
  var settings: PluginMCPSettings
  var selection: PluginToolSelection
  var toolNames: String
  var overridesArguments: Bool
  var arguments: [PluginArgumentDraft]
  private var priorPrefix: String?

  var preservesNativeNames: Bool {
    get { settings.prefix == "" }
    set {
      guard newValue != preservesNativeNames else { return }
      if newValue {
        priorPrefix = settings.prefix
        settings.prefix = ""
      } else {
        settings.prefix = priorPrefix
      }
    }
  }

  init(id: String, settings: PluginMCPSettings) {
    self.id = id
    self.settings = settings
    priorPrefix = settings.prefix?.isEmpty == false ? settings.prefix : nil
    selection = settings.allowAnyTool ? .all : .whitelist
    toolNames = settings.allowedTools.joined(separator: "\n")
    overridesArguments = settings.args != nil
    arguments = (settings.args ?? []).map { PluginArgumentDraft(value: $0) }
  }

  var value: PluginMCPSettings {
    var result = settings
    result.allowAnyTool = selection == .all
    result.allowedTools =
      selection == .all ? [] : toolNames.split(whereSeparator: \.isNewline).map(String.init)
    result.args = overridesArguments ? arguments.map(\.value) : nil
    return result
  }
}

struct PluginArgumentDraft: Identifiable {
  let id = UUID()
  var value: String
}

struct PluginCLIDraft: Identifiable {
  let id: String
  var settings: PluginCLISettings
}

struct PluginSkillDraft: Identifiable {
  let id: String
  var settings: PluginSkillSettings
}

struct PluginDependencyDraft: Identifiable {
  let id = UUID()
  var name: String
  var path: String
}

/// A draft retains the exact source revision and every host-owned override until explicitly saved.
struct PluginSettingsDraft: Identifiable {
  let id: String
  let revision: Int64
  var enabled: Bool
  var mcp: [PluginMCPDraft]
  var cli: [PluginCLIDraft]
  var skills: [PluginSkillDraft]
  var dependencies: [PluginDependencyDraft]

  init(id: String, snapshot: PluginHostSnapshot) {
    self.id = id
    revision = snapshot.state.revision
    let settings = snapshot.settings(for: id)
    enabled = settings.enabled
    mcp = settings.mcp.sorted { $0.key < $1.key }.map {
      PluginMCPDraft(id: $0.key, settings: $0.value)
    }
    cli = settings.cli.sorted { $0.key < $1.key }.map {
      PluginCLIDraft(id: $0.key, settings: $0.value)
    }
    skills = settings.skills.sorted { $0.key < $1.key }.map {
      PluginSkillDraft(id: $0.key, settings: $0.value)
    }
    dependencies = settings.dependencyExecutables.sorted { $0.key < $1.key }.map {
      PluginDependencyDraft(name: $0.key, path: $0.value)
    }
  }

  func settings() throws -> PluginSettings {
    guard Set(dependencies.map(\.name)).count == dependencies.count else {
      throw AppControlPlaneError.unavailable(
        AppLocalization.string("Dependency names must be unique."))
    }
    return PluginSettings(
      enabled: enabled,
      mcp: Dictionary(uniqueKeysWithValues: mcp.map { ($0.id, $0.value) }),
      cli: Dictionary(uniqueKeysWithValues: cli.map { ($0.id, $0.settings) }),
      skills: Dictionary(uniqueKeysWithValues: skills.map { ($0.id, $0.settings) }),
      dependencyExecutables: Dictionary(
        uniqueKeysWithValues: dependencies.map { ($0.name, $0.path) })
    )
  }
}
