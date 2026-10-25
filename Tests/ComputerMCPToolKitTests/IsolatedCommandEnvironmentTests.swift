#if os(macOS)
  import ComputerMCPConfiguration
  import ComputerMCPDarwinTestSupport
  import ComputerMCPProcess
  import ComputerMCPTestSupport
  import ComputerMCPToolKit
  import Foundation
  import Testing

  @Suite(.nativeIntegration)
  struct IsolatedCommandEnvironmentTests {
    @Test(arguments: ["git", "sqlite3"])
    func registeredReadsKeepIsolationInsideReadOnlySandbox(program: String) throws {
      let temporary = try ScopedTemporaryDirectory()
      let root = temporary.url
      let suppliedHome = root.appendingPathComponent("owner")
      try FileManager.default.createDirectory(at: suppliedHome, withIntermediateDirectories: false)
      try Data("[guard]\nleaked = owner\n".utf8).write(
        to: suppliedHome.appendingPathComponent(".gitconfig"))
      try Data(".print owner-initialization\n".utf8).write(
        to: suppliedHome.appendingPathComponent(".sqliterc"))
      let executable = try testExecutable(program)
      let wrapper = root.appendingPathComponent("probe")
      let script = """
        #!/bin/sh
        set -eu
        test -z "${HOST_ONLY:-}"
        test -z "${USER:-}"
        test "$SELECTED" = explicit
        test "$LC_ALL" = C
        test "$HOME" != '\(suppliedHome.path)'
        test "$TMPDIR" = "$HOME/"
        test "$XDG_CACHE_HOME" = "$HOME"
        test -z "${HTTP_PROXY:-}"
        test -z "$NO_PROXY"
        if (printf forbidden > '\(root.path)/forbidden') 2>/dev/null; then exit 91; fi
        printf allowed > "$HOME/allowed"
        if test '\(program)' = git; then
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
        environment: [
          "PATH": systemUtilityPath, "HOME": suppliedHome.path, "SELECTED": "explicit",
          "LC_ALL": "C", "TMPDIR": suppliedHome.path,
          "HTTP_PROXY": "http://outside.invalid:8080", "NO_PROXY": "*",
          "GIT_CONFIG_SYSTEM": suppliedHome.appendingPathComponent(".gitconfig").path,
        ])
      let command = CLICommandConfig(id: program, executable: wrapper.path)
      let result = try HostExecutionPolicy.$current.withValue(.readOnly) {
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
