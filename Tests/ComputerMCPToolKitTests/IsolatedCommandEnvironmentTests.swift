#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

#if os(macOS)
  import ComputerMCPConfiguration
  import ComputerMCPDarwinTestSupport
  import ComputerMCPPlatform
  import ComputerMCPPlatformPOSIX
  import ComputerMCPProcess
  import ComputerMCPSandbox
  import ComputerMCPTestSupport
  import ComputerMCPToolKit
  import Foundation
  import Testing

  @Suite(.nativeIntegration)
  struct IsolatedCommandEnvironmentTests {
    @Test(arguments: ["git", "sqlite3"], [false, true])
    func registeredReadsUseExplicitVariables(program: String, readOnly: Bool) throws {
      let sentinel = "PROCESS_SECRET_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
      setenv(sentinel, "private", 1)
      defer { unsetenv(sentinel) }
      let temporary = try ScopedTemporaryDirectory()
      let root = temporary.url
      let suppliedHome = root.appendingPathComponent("owner")
      try FileManager.default.createDirectory(at: suppliedHome, withIntermediateDirectories: false)
      try Data("[guard]\nleaked = owner\n".utf8).write(
        to: suppliedHome.appendingPathComponent(".gitconfig"))
      try Data(".print owner-initialization\n".utf8).write(
        to: suppliedHome.appendingPathComponent(".sqliterc"))
      let executable: String
      if program == "git" {
        let lookup = Process()
        let output = Pipe()
        lookup.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        lookup.arguments = ["--find", "git"]
        lookup.standardOutput = output
        lookup.standardError = FileHandle.nullDevice
        try lookup.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        lookup.waitUntilExit()
        try #require(lookup.terminationStatus == 0)
        executable = String(decoding: data, as: UTF8.self).trimmingCharacters(
          in: .whitespacesAndNewlines)
        try #require(executable.hasPrefix("/") && !executable.contains("\n"))
      } else {
        executable = try testExecutable(program)
      }
      let wrapper = root.appendingPathComponent("probe")
      let script = """
        #!/bin/sh
        set -eu
        test -z "${HOST_ONLY:-}"
        test -z "${USER:-}"
        test -z "${SELECTED:-}"
        test -z "${\(sentinel):-}"
        test "$HOME" != '\(suppliedHome.path)'
        if \(readOnly ? "true" : "false"); then
        test "$TMPDIR" = "$HOME/"
        test "$XDG_CACHE_HOME" = "$HOME"
        test -z "${HTTP_PROXY:-}"
        test -z "$NO_PROXY"
        if (printf forbidden > '\(root.path)/forbidden') 2>/dev/null; then exit 91; fi
        fi
        printf allowed > "$HOME/allowed"
        if test '\(program)' = git; then
          test "$LC_ALL" = C
          test "$GIT_CONFIG_NOSYSTEM" = 1
          test "$GIT_CONFIG_GLOBAL" = /dev/null
          test "$GIT_NO_LAZY_FETCH" = 1
          test "$GIT_CONFIG_COUNT" = 0
          test -z "$GIT_ALLOW_PROTOCOL"
        else
          test "$1" = -init && test "$2" = /dev/null && test "$3" = -safe
        fi
        exec '\(executable)' "$@"
        """
      try Data(script.utf8).write(to: wrapper)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
      let launcher = testExecutionLauncher()
      let commands = RegisteredCommands(
        configuration: .init(projectDirectory: root), launcher: launcher,
        commandRunner: ProcessCommandRunner(
          launcher: launcher, environment: ["HOST_ONLY": "private", "USER": "host"]),
        environment: ProcessInfo.processInfo.environment.merging([
          "PATH": systemUtilityPath, "HOME": suppliedHome.path, "SELECTED": "explicit",
          "LC_ALL": "C", "TMPDIR": suppliedHome.path,
          "HTTP_PROXY": "http://outside.invalid:8080", "NO_PROXY": "*",
          "GIT_CONFIG_SYSTEM": suppliedHome.appendingPathComponent(".gitconfig").path,
        ]) { _, value in value })
      let command = CLICommandConfig(id: program, executable: wrapper.path)
      let scratch = try ScopedTemporaryDirectory()
      let home = try SandboxPath(ProjectPathResolver.canonicalProject(scratch.url).path)
      let administration: ExecutionAdministration
      if readOnly {
        let project = try SandboxPath(ProjectPathResolver.canonicalProject(root).path)
        // The fixture executes the selected Git binary with its isolated environment.
        let developerReads = try [
          "/Applications", "/Library/Developer",
        ].map(SandboxPath.init)
        let reads = [project] + launcher.hostSystemReadPaths + developerReads
        var ancestorPaths: Set<String> = ["/"]
        for path in reads + [home] {
          var parent = (path.value as NSString).deletingLastPathComponent
          while parent != "/" {
            ancestorPaths.insert(parent)
            parent = (parent as NSString).deletingLastPathComponent
          }
        }
        let sandbox = try SandboxConfiguration(
          readOnly: true, worktree: project, temporaryDirectory: home, homeDirectory: home,
          cacheDirectory: home, readableRoots: reads,
          listableAncestors: ancestorPaths.sorted().map(SandboxPath.init))
        administration = try .init(
          mode: .sandbox(sandbox),
          environment: .init(
            searchPath: systemUtilityPath.split(separator: ":").map { try SandboxPath(String($0)) },
            home: home, temporary: home, cache: home))
      } else {
        administration = try .init(mode: .fullAccess, environment: .init(fullAccessVariables: [:]))
      }
      defer { withExtendedLifetime(scratch) {} }
      let result = try ExecutionAdministration.$current.withValue(administration) {
        if program == "git" {
          return try commands.runHostGit(
            command: command, args: ["config", "--list"], timeout: 10_000)
        }
        return try commands.runSQLite(
          command: command, args: ["-readonly", ":memory:", "SELECT 42;"],
          timeout: 10_000, maxOutputBytes: 4096)
      }
      #expect(result.exitCode == 0, "stdout: \(result.stdout); stderr: \(result.stderr)")
      #expect(!result.stdout.contains("owner"))
      if program == "sqlite3" { #expect(result.stdout == "42\n") }
      #expect(
        !FileManager.default.fileExists(atPath: root.appendingPathComponent("forbidden").path))
    }
  }
#endif
