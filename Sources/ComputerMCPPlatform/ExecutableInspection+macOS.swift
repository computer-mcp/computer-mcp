#if os(macOS)
  import Darwin
  import Foundation

  extension ExecutableInspection {
    /// `environment` is the complete child environment, after host-owned overrides.
    /// Explicit paths and the first executable PATH match are never replaced after a failed inspection.
    package static func inspect(
      _ executable: String, workingDirectory: URL,
      environment: [String: String]
    ) -> Self {
      inspect(executable, workingDirectory: workingDirectory, environment: environment, depth: 0)
    }

    /// Only declared env interpreter names receive bindings; fixed shebang paths keep their meaning.
    package static func invocation(
      _ executable: String, workingDirectory: URL, environment: [String: String],
      interpreterBindings: [String: String]
    ) -> ExecutableInvocation {
      var invocation: (executable: String, arguments: [String])?
      let inspection = inspect(
        executable, workingDirectory: workingDirectory, environment: environment, depth: 0,
        interpreterBindings: interpreterBindings, invocation: &invocation)
      return ExecutableInvocation(
        inspection: inspection, executable: invocation?.executable ?? inspection.path,
        arguments: invocation?.arguments ?? [])
    }

    private static func inspect(
      _ executable: String, workingDirectory: URL, environment: [String: String], depth: Int
    ) -> Self {
      var invocation: (executable: String, arguments: [String])?
      return inspect(
        executable, workingDirectory: workingDirectory, environment: environment, depth: depth,
        interpreterBindings: [:], invocation: &invocation)
    }

    private static func inspect(
      _ executable: String, workingDirectory: URL, environment: [String: String], depth: Int,
      interpreterBindings: [String: String],
      invocation: inout (executable: String, arguments: [String])?
    ) -> Self {
      var result = Self(
        executable: executable.utf8.count < Int(PATH_MAX) ? executable : "",
        path: nil,
        source: executable.contains("/")
          ? (executable.hasPrefix("/") ? "absolute_path" : "relative_path") : "path")
      guard !executable.isEmpty, !executable.contains("\0"), executable.utf8.count < Int(PATH_MAX)
      else {
        result.status = .invalidPath
        return result
      }
      let url: URL
      if executable.contains("/") {
        url = absolute(executable, base: workingDirectory)
      } else {
        // Darwin execvp uses _PATH_DEFPATH when PATH is absent. Empty entries mean child cwd.
        let path = environment["PATH"] ?? "/usr/bin:/bin"
        guard !path.contains("\0") else {
          result.status = .invalidPath
          return result
        }
        guard path.utf8.count <= 65_536, path.filter({ $0 == ":" }).count < 1_024 else {
          result.status = .unverified
          return result
        }
        let candidates = path.split(separator: ":", omittingEmptySubsequences: false).map {
          absolute(String($0), base: workingDirectory).appendingPathComponent(executable)
        }
        guard
          let candidate = candidates.first(where: { url in
            var info = stat()
            return stat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
              && access(url.path, X_OK) == 0
          })
        else { return result }
        url = candidate
      }
      result.path = url.path
      var info = stat()
      guard stat(url.path, &info) == 0 else {
        result.status = errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable
        return result
      }
      result.exists = true
      result.isExecutable = access(url.path, X_OK) == 0
      result.isRegularFile = info.st_mode & S_IFMT == S_IFREG
      guard result.isRegularFile else {
        result.status = .notRegularFile
        return result
      }
      guard result.isExecutable else {
        result.status = .notExecutable
        return result
      }
      // Nonblocking open and fstat prevent a replaced path/FIFO from hanging header inspection.
      let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
      guard descriptor >= 0 else {
        result.status = .unreadable
        return result
      }
      defer { close(descriptor) }
      var opened = stat()
      guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
        opened.st_dev == info.st_dev, opened.st_ino == info.st_ino
      else {
        result.status = .unreadable
        return result
      }
      // XNU bounds interpreter declarations to IMG_SHSIZE (512 bytes).
      var bytes = [UInt8](repeating: 0, count: 512)
      let count = pread(descriptor, &bytes, bytes.count, 0)
      guard count >= 0 else {
        result.status = .unreadable
        return result
      }
      bytes.removeSubrange(count...)
      result.status = .passed
      guard bytes.starts(with: [35, 33]) else { return result }
      result.isScript = true
      guard depth < 4 else {
        result.status = .unverified
        return result
      }
      guard let end = bytes.dropFirst(2).firstIndex(where: { $0 == 10 || $0 == 35 }),
        !bytes[2..<end].contains(0)
      else {
        result.status = .invalidShebang
        return result
      }
      guard let line = String(bytes: bytes[2..<end], encoding: .utf8) else {
        result.status = .unverified
        return result
      }
      let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
      guard let interpreter = words.first else {
        result.status = .invalidShebang
        return result
      }
      let interpreterURL = absolute(interpreter, base: workingDirectory)
      let direct = inspect(
        interpreterURL.path, workingDirectory: workingDirectory, environment: environment,
        depth: depth + 1)
      result.interpreters = [direct]
      if direct.hasKnownFailure {
        result.status = .interpreterUnavailable
      } else if direct.isScript {
        // XNU does not recursively activate a script as the kernel interpreter.
        result.status = .invalidShebang
      } else {
        result.status = direct.status
      }
      guard result.status == .passed,
        interpreterURL.resolvingSymlinksInPath().path == "/usr/bin/env"
      else { return result }

      var arguments = Array(words.dropFirst())
      // Plain -S tokens have no quoting, escapes or variable expansion to interpret.
      if arguments.first == "-S" {
        arguments.removeFirst()
        guard arguments.allSatisfy({ !$0.contains(where: { "'\"\\$".contains($0) }) }) else {
          result.status = .unverified
          return result
        }
      }
      if arguments.first == "--" { arguments.removeFirst() }
      guard let command = arguments.first, !command.hasPrefix("-"), !command.contains("=") else {
        result.status = .unverified
        return result
      }
      let bound = interpreterBindings[command]
      var runtime = inspect(
        bound ?? command, workingDirectory: workingDirectory, environment: environment,
        depth: depth + 1)
      if bound != nil { runtime.source = "host_binding" }
      result.interpreters.append(runtime)
      result.status = runtime.hasKnownFailure ? .interpreterUnavailable : runtime.status
      if bound != nil, !runtime.hasKnownFailure, let path = runtime.path {
        invocation = (path, Array(arguments.dropFirst()) + [url.path])
      }
      return result
    }

    private static func absolute(_ path: String, base: URL) -> URL {
      (path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path))
        .standardizedFileURL
    }
  }
#endif
