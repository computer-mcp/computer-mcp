import Combine
import ComputerMCP
import Foundation

@MainActor
final class PluginDoctorModel: ObservableObject {
  let pluginID: String
  @Published private(set) var report: PluginDoctorReport?
  @Published private(set) var isChecking = false
  @Published private(set) var errorMessage: String?

  private let controlPlane: any PluginManaging
  private var generation = 0
  private var request: Task<PluginDoctorReport, any Error>?

  init(controlPlane: any PluginManaging, pluginID: String) {
    self.controlPlane = controlPlane
    self.pluginID = pluginID
  }

  func check() async {
    guard !isChecking else { return }
    generation += 1
    let current = generation
    isChecking = true
    let controlPlane = controlPlane
    let pluginID = pluginID
    let task = Task {
      try Task.checkCancellation()
      return try await controlPlane.doctorPlugin(id: pluginID)
    }
    request = task
    defer {
      if generation == current {
        request = nil
        isChecking = false
      }
    }
    do {
      let next = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      guard generation == current, !Task.isCancelled, !task.isCancelled else { return }
      report = next
      errorMessage = nil
    } catch {
      guard generation == current, !Task.isCancelled, !task.isCancelled,
        !(error is CancellationError)
      else { return }
      errorMessage = AppLocalization.errorDescription(error)
    }
  }

  func cancel() {
    generation += 1
    request?.cancel()
    request = nil
    isChecking = false
  }
}
