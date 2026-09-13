import ArgumentParser
import ComputerMCP
import Darwin
import Foundation

struct PluginArchiveCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "_plugin-archive",
    abstract: "Internal archive worker; input is a read-only regular file on stdin.",
    shouldDisplay: false)

  @Option(name: .long) var sha256: String

  func run() throws {
    do {
      let monitor = try constrainWorker()
      defer { monitor.cancel() }
      let receipt = try PluginArchiveWorker.prepare(
        input: STDIN_FILENO,
        inJobDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        expectedSHA256: sha256)
      try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(receipt))
    } catch {
      let failure = error as? PluginArchiveError ?? .workerFailed
      try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(failure))
      throw ExitCode.failure
    }
  }

  /// Changes only this short-lived process. Never called by the gateway host.
  private func constrainWorker() throws -> any DispatchSourceTimer {
    for (resource, ceiling) in [
      (RLIMIT_CPU, rlim_t(30)), (RLIMIT_FSIZE, rlim_t(512 * 1_024 * 1_024)),
      (RLIMIT_CORE, rlim_t(0)),
    ] {
      var limit = rlimit()
      guard getrlimit(resource, &limit) == 0 else {
        throw PluginArchiveError.resourceLimitUnavailable
      }
      limit.rlim_cur = min(limit.rlim_cur, ceiling)
      limit.rlim_max = min(limit.rlim_max, ceiling)
      guard setrlimit(resource, &limit) == 0 else {
        throw PluginArchiveError.resourceLimitUnavailable
      }
    }
    alarm(60)
    // macOS rejects small RLIMIT_AS/DATA values for Swift's reserved VM space.
    // Sample resident memory independently of the parser, not a claimed hard
    // allocation bound: one allocation may overshoot before the next sample.
    let monitor = DispatchSource.makeTimerSource(
      queue: DispatchQueue(label: "plugin.archive.memory"))
    monitor.setEventHandler {
      var info = mach_task_basic_info()
      var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
      let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
          task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
      }
      if status != KERN_SUCCESS || info.resident_size > 512 * 1_024 * 1_024 {
        _exit(75)
      }
    }
    monitor.schedule(deadline: .now(), repeating: .milliseconds(20))
    monitor.resume()
    return monitor
  }
}
