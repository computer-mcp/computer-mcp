import ComputerMCPPlatformDarwin
import ComputerMCPProcess
import ComputerMCPSandbox
import Darwin
import Foundation
import ObjectiveC
import Subprocess
import System

@main struct ExecutionResponsibilityProbe {
  static func main() async throws {
    let arguments = CommandLine.arguments
    if arguments.count == 4, arguments[1] == "ownership-host",
      let method = ExecutionLaunchMethod(rawValue: arguments[3])
    {
      let root = try SandboxPath(arguments[2])
      let sandbox = try SandboxConfiguration(
        worktree: root, temporaryDirectory: root, homeDirectory: root, cacheDirectory: root,
        readableRoots: [.init("/")])
      let environment = try ExecutionEnvironment(
        searchPath: [.init("/bin")], home: root, temporary: root, cache: root)
      let owner = try await ExecutionLauncher(platform: DarwinExecutionPlatform()).start(
        executable: .init("/bin/sh"),
        arguments: ["-c", "echo ready > ready; while [ ! -f finish ]; do /bin/sleep 0.01; done"],
        directory: root, environment: environment, mode: .sandbox(sandbox), method: method)
      guard try await owner.wait(until: .now.advanced(by: .seconds(15))).status == 0 else {
        exit(15)
      }
      try Data().write(to: URL(fileURLWithPath: root.value + "/complete"))
      let deadline = ContinuousClock.now.advanced(by: .seconds(10))
      while !FileManager.default.fileExists(atPath: root.value + "/release") {
        guard ContinuousClock.now < deadline else { exit(16) }
        try await Task.sleep(for: .milliseconds(10))
      }
      withExtendedLifetime(owner) {}
      return
    }
    if arguments.count == 4, arguments[1] == "journal-host" {
      let root = URL(fileURLWithPath: arguments[2])
      let launcher = ExecutionLauncher(platform: DarwinExecutionPlatform())
      let sessions = GatewayTerminalSessions()
      try sessions.enablePersistence(at: root, launcher: launcher)
      let runtime = ShellSessionRuntime(
        launcher: launcher, sessions: sessions,
        scope: .isolated(UUID(uuidString: arguments[3])!))
      let id = try runtime.spawn(
        request: .init(
          mode: .argv, executable: "/bin/sh",
          argv: ["-c", "sleep 60 & echo ready:$!; wait"]), defaultShell: "/bin/sh",
        defaultWorkingDirectory: root, timeoutMilliseconds: nil, maxOutputBytes: 4096,
        maxSessions: 1)
      for _ in 0..<100 {
        let value = try runtime.read(
          sessionID: id, stdoutCursor: 0, stderrCursor: 0,
          maxReadBytes: 4096, encoding: .utf8)
        if let text = value.stdout.text, text.hasPrefix("ready:"),
          let end = text.firstIndex(of: "\n"),
          let pid = Int32(text[text.index(text.startIndex, offsetBy: 6)..<end]), pid > 0
        {
          // A read can observe output that arrived after its checkpoint was captured.
          // Persist the complete receipt before simulating the host crash.
          _ = try runtime.read(
            sessionID: id, stdoutCursor: 0, stderrCursor: 0,
            maxReadBytes: 4096, encoding: .utf8)
          try FileHandle.standardOutput.write(contentsOf: Data(id.utf8))
          _exit(0)
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      await runtime.shutdown()
      throw ExecutionEnvironmentError.launchFailed("Journal fixture did not receive a ready line")
    }
    if arguments.count >= 3, arguments[1] == "child" {
      describe(arguments[2])
      if arguments.count == 3 {
        for disclaimed in [false, true] {
          try spawn(
            arguments: ["child", arguments[2] + (disclaimed ? "/disclaim" : "/inherit"), "leaf"],
            disclaim: disclaimed)
        }
      }
      return
    }
    guard arguments.count == 3, arguments[1] == "host" else { exit(2) }
    let output = open(arguments[2], O_CREAT | O_WRONLY | O_TRUNC, 0o600)
    guard output >= 0 else { exit(3) }
    dup2(output, STDOUT_FILENO)
    dup2(output, STDERR_FILENO)
    close(output)
    setbuf(stdout, nil)
    describe("host")
    let root = URL(fileURLWithPath: arguments[2]).deletingLastPathComponent().path
    let path = try SandboxPath(root)
    let environment = try ExecutionEnvironment(
      searchPath: [.init("/usr/bin"), .init("/bin")], home: path, temporary: path, cache: path)
    for method in ExecutionLaunchMethod.allCases {
      let result = try await ExecutionLauncher(platform: DarwinExecutionPlatform()).run(
        executable: .init(arguments[0]), arguments: ["child", method.rawValue + "-disclaim"],
        directory: path, environment: environment, mode: .fullAccess, method: method)
      guard result.status == 0 else { exit(4) }
    }
    try spawn(arguments: ["child", "posixSpawn-inherit"], disclaim: false)
    for explicitFalse in [false, true] {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: arguments[0])
      process.arguments = ["child", explicitFalse ? "foundation-false" : "foundation-default"]
      process.environment = try environment.variables()
      if explicitFalse {
        let selector = NSSelectorFromString("setSpawnedProcessDisclaimed:")
        guard let method = class_getInstanceMethod(type(of: process), selector) else { exit(5) }
        let setter = unsafeBitCast(
          method_getImplementation(method),
          to: (@convention(c) (AnyObject, Selector, Bool) -> Void).self)
        setter(process, selector, false)
      }
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { exit(6) }
    }
    let result = try await Subprocess.run(
      .path(FilePath(arguments[0])), arguments: ["child", "subprocess-inherit"],
      environment: .custom(["PATH=/usr/bin:/bin"].map { Array($0.utf8) }),
      output: .fileDescriptor(.standardOutput, closeAfterSpawningProcess: false),
      error: .fileDescriptor(.standardError, closeAfterSpawningProcess: false))
    guard result.terminationStatus.isSuccess else { exit(7) }
    print("complete")
  }

  static func describe(_ label: String) {
    guard
      let pointer = dlsym(
        UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
    else { exit(8) }
    let responsible = unsafeBitCast(pointer, to: (@convention(c) (pid_t) -> pid_t).self)
    print("\(label) \(getpid()) \(getppid()) \(responsible(getpid()))")
    fflush(stdout)
  }

  static func spawn(arguments: [String], disclaim: Bool) throws {
    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else { exit(9) }
    defer { posix_spawnattr_destroy(&attributes) }
    if disclaim {
      guard
        let pointer = dlsym(
          UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim")
      else { exit(10) }
      let set = unsafeBitCast(
        pointer,
        to: (@convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32).self)
      guard set(&attributes, 1) == 0 else { exit(11) }
    }
    let argv = ([CommandLine.arguments[0]] + arguments).map { strdup($0) } + [nil]
    let environment = [strdup("PATH=/usr/bin:/bin"), nil]
    defer { for pointer in argv + environment { free(pointer) } }
    var pid: pid_t = 0
    let result = argv.withUnsafeBufferPointer { args in
      environment.withUnsafeBufferPointer { env in
        posix_spawn(
          &pid, CommandLine.arguments[0], nil, &attributes,
          UnsafeMutablePointer(mutating: args.baseAddress!),
          UnsafeMutablePointer(mutating: env.baseAddress!))
      }
    }
    guard result == 0 else { exit(12) }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 { if errno != EINTR { exit(13) } }
    guard status == 0 else { exit(14) }
  }
}
