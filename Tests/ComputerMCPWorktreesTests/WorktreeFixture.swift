import ComputerMCPPersistence
import ComputerMCPTestSupport
import Foundation

@testable import ComputerMCPWorktrees

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// A pinned native Git adapter used only with disposable test repositories.
struct WorktreeTestGit: WorktreeGitExecuting {
  let executable: URL
  init() throws { executable = URL(fileURLWithPath: try testExecutable("git")) }

  func withPreparedTransaction(_ command: WorktreeGitCommand, _ body: () throws -> Void) throws {
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    let process = Process()
    process.executableURL = executable
    process.arguments = command.arguments
    process.currentDirectoryURL = command.directory
    process.environment = command.environment
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(command.timeoutMilliseconds))
    try process.run()
    defer {
      try? input.fileHandleForWriting.close()
      if process.isRunning { process.terminate() }
      let end = ContinuousClock.now.advanced(by: .seconds(1))
      while process.isRunning, ContinuousClock.now < end { Thread.sleep(forTimeInterval: 0.002) }
      if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
    }
    func line() throws -> String {
      var data = Data()
      while ContinuousClock.now < deadline, data.count < command.maxOutputBytes {
        var descriptor = pollfd(
          fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 10) > 0 else { continue }
        guard let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else {
          throw WorktreeError.commandFailed("Reference transaction ended before acknowledgement.")
        }
        data.append(byte)
        if byte == Data([10]) { return String(decoding: data, as: UTF8.self) }
      }
      throw WorktreeError.commandFailed("Reference transaction exceeded its bounds.")
    }
    try input.fileHandleForWriting.write(contentsOf: command.input)
    guard try line() == "start: ok\n", try line() == "prepare: ok\n" else {
      throw WorktreeError.commandFailed("Reference transaction did not prepare.")
    }
    do {
      try body()
      guard ContinuousClock.now < deadline else {
        throw WorktreeError.busy("Reference deadline expired.")
      }
      try input.fileHandleForWriting.write(contentsOf: Data("commit\n".utf8))
      guard try line() == "commit: ok\n" else {
        throw WorktreeError.commandFailed("Commit failed.")
      }
    } catch {
      if process.isRunning {
        try? input.fileHandleForWriting.write(contentsOf: Data("abort\n".utf8))
        _ = try? line()
      }
      throw error
    }
  }

  func execute(_ command: WorktreeGitCommand) throws -> WorktreeGitResult {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let inputURL = temporary.appendingPathComponent("input")
    let outputURL = temporary.appendingPathComponent("output")
    let errorURL = temporary.appendingPathComponent("error")
    try command.input.write(to: inputURL)
    try Data().write(to: outputURL)
    try Data().write(to: errorURL)
    let input = try FileHandle(forReadingFrom: inputURL)
    let output = try FileHandle(forWritingTo: outputURL)
    let error = try FileHandle(forWritingTo: errorURL)
    defer {
      try? input.close()
      try? output.close()
      try? error.close()
    }
    let process = Process()
    process.executableURL = executable
    process.arguments = command.arguments
    process.currentDirectoryURL = command.directory
    process.environment = command.environment
    process.standardInput = input
    process.standardOutput = output
    process.standardError = error
    try process.run()
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(command.timeoutMilliseconds))
    while process.isRunning, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.002) }
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
      throw WorktreeError.commandFailed("Test Git timed out.")
    }
    process.waitUntilExit()
    let stdout = try Data(contentsOf: outputURL)
    let stderr = try Data(contentsOf: errorURL)
    guard stdout.count <= command.maxOutputBytes, stderr.count <= command.maxOutputBytes else {
      throw WorktreeError.commandFailed("Test Git output exceeded its bound.")
    }
    return .init(output: stdout, error: stderr, exitCode: process.terminationStatus)
  }
}

struct WorktreeFixture {
  let directory: URL
  let repository: URL
  let database: URL
  let source: DerivedProjectSource
  let storage: WorktreeStorage
  let executor: WorktreeTestGit
  let store: SQLiteDerivedProjectStore

  init(_ directory: URL, format: String = "sha1", commit: Bool = true) throws {
    self.directory = directory
    repository = directory.appendingPathComponent("repository")
    let host = directory.appendingPathComponent("host")
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: host, withIntermediateDirectories: false)
    database = host.appendingPathComponent("host.sqlite")
    source = .init(
      id: "source", root: repository.path, registeredAt: Date(timeIntervalSince1970: 1_700_000_000))
    storage = WorktreeStorage(databaseURL: database)!
    executor = try WorktreeTestGit()
    store = try SQLiteDerivedProjectStore(
      connection: GatewayDatabaseConnection(path: database.path))
    _ = try raw(["init", "--initial-branch=main", "--object-format=" + format])
    _ = try raw(["config", "user.name", "Fixture"])
    _ = try raw(["config", "user.email", "fixture@example.invalid"])
    if commit {
      try Data("initial\n".utf8).write(to: repository.appendingPathComponent("file.txt"))
      _ = try raw(["add", "file.txt"])
      _ = try raw(["commit", "-m", "initial"])
    }
  }

  func service(
    store: (any DerivedProjectStore)? = nil, roots: [URL]? = nil,
    executor: (any WorktreeGitExecuting)? = nil, journalIO: WorktreeJournalIO = .init()
  ) throws
    -> WorktreeRepository
  {
    try WorktreeRepository(
      source: source, store: store ?? self.store, storage: storage,
      executor: executor ?? self.executor, registeredProjectRoots: roots ?? [repository],
      timeoutMilliseconds: 10_000, maxOutputBytes: 1_048_576, lockTimeout: .seconds(1),
      journalIO: journalIO)
  }

  @discardableResult
  func raw(_ arguments: [String], root: URL? = nil, environment: [String: String] = [:]) throws
    -> String
  {
    var env = HostGitConfiguration.environment(home: directory)
    env["GIT_AUTHOR_NAME"] = "Fixture"
    env["GIT_AUTHOR_EMAIL"] = "fixture@example.invalid"
    env["GIT_COMMITTER_NAME"] = "Fixture"
    env["GIT_COMMITTER_EMAIL"] = "fixture@example.invalid"
    env.merge(environment) { _, new in new }
    let result = try executor.execute(
      .init(
        arguments: HostGitConfiguration.arguments + arguments,
        directory: root ?? repository, environment: env, timeoutMilliseconds: 10_000,
        maxOutputBytes: 1_048_576))
    guard result.exitCode == 0 else {
      throw WorktreeError.commandFailed(
        "Fixture Git failed: " + String(decoding: result.error, as: UTF8.self))
    }
    return String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .newlines)
  }

  func privateCommit(_ service: WorktreeRepository, projectID: String) throws -> String {
    let topology = try service.topology(projectID: projectID)
    try Data("private\n".utf8).write(to: topology.root.url.appendingPathComponent("file.txt"))
    let arguments = [
      "--git-dir=" + topology.gitDirectory.url.path, "--work-tree=" + topology.root.url.path,
    ]
    let env: [String: String] = [:]
    try raw(arguments + ["add", "file.txt"], root: topology.root.url, environment: env)
    try raw(arguments + ["commit", "-m", "private"], root: topology.root.url, environment: env)
    return try raw(arguments + ["rev-parse", "HEAD"], root: topology.root.url, environment: env)
  }
}

final class WorktreeActivationFailure: DerivedProjectStore, @unchecked Sendable {
  let store: SQLiteDerivedProjectStore
  let afterCommit: Bool
  init(_ store: SQLiteDerivedProjectStore, afterCommit: Bool = false) {
    self.store = store
    self.afterCommit = afterCommit
  }
  func records() throws -> [DerivedProjectRecord] { try store.records() }
  func remove(_ id: String, expecting revision: Int64) throws {
    try store.remove(id, expecting: revision)
  }
  func protectedBranches() throws -> [ProtectedWorktreeBranch] { try store.protectedBranches() }
  func releaseProtection(_ branch: ProtectedWorktreeBranch) throws {
    try store.releaseProtection(branch)
  }
  func commit(
    _ record: DerivedProjectRecord, expecting revision: Int64?,
    protecting branch: ProtectedWorktreeBranch?
  ) throws {
    if record.state == .active, !afterCommit { throw DerivedProjectStoreError.revisionConflict }
    try store.commit(record, expecting: revision, protecting: branch)
    if record.state == .active { throw DerivedProjectStoreError.revisionConflict }
  }
}
