import Darwin
import Foundation

/// A bounded, non-executing observation of a launch path and its script interpreters.
/// Passing these checks does not establish binary compatibility, trust, permissions or protocol health.
package struct ExecutableInspection: Codable, Equatable, Sendable {
  package enum Status: String, Codable, Sendable {
    case passed, missing, unreadable
    case invalidPath = "invalid_path"
    case notRegularFile = "not_regular_file"
    case notExecutable = "not_executable"
    case invalidShebang = "invalid_shebang"
    case interpreterUnavailable = "interpreter_unavailable"
    case unverified
  }

  package var executable: String
  package var path: String?
  package var source: String
  package var exists = false
  package var isExecutable = false
  package var isRegularFile = false
  package var isScript = false
  package var status: Status = .missing
  package var interpreters: [ExecutableInspection] = []

  package var hasKnownFailure: Bool {
    switch status {
    case .passed, .unverified, .unreadable: false
    default: true
    }
  }

  package var message: String {
    switch status {
    case .passed: "File and interpreter checks passed; actual startup has not been verified."
    case .missing: "The executable was not found in the configured location or launch search path."
    case .invalidPath: "The executable path is empty, too long or contains NUL."
    case .notRegularFile: "The executable path does not identify a regular file."
    case .notExecutable: "The current user cannot execute this file."
    case .unreadable: "The executable header could not be safely read; check access and retry."
    case .invalidShebang: "The script has an invalid interpreter declaration for macOS."
    case .interpreterUnavailable:
      "A script interpreter is unavailable in the launch environment. Check its path and runtime installation."
    case .unverified:
      "This interpreter invocation needs further verification; no script or probe was executed."
    }
  }

  package var json: JSONValue {
    .object([
      "executable": .string(executable),
      "resolved_path": path.map(JSONValue.string) ?? .null,
      "resolution_source": .string(source),
      "exists": .bool(exists), "is_executable": .bool(isExecutable),
      "is_regular_file": .bool(isRegularFile), "is_script": .bool(isScript),
      "status": .string(status.rawValue), "message": .string(message),
      "interpreters": .array(interpreters.map(\.json)),
    ])
  }

  /// `environment` is the complete child environment, after host-owned overrides.
  /// Explicit paths and the first executable PATH match are never replaced after a failed inspection.
  package static func inspect(
    _ executable: String, workingDirectory: URL,
    environment: [String: String]
  ) -> Self {
    inspect(executable, workingDirectory: workingDirectory, environment: environment, depth: 0)
  }

  private static func inspect(
    _ executable: String, workingDirectory: URL, environment: [String: String], depth: Int
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
    let runtime = inspect(
      command, workingDirectory: workingDirectory, environment: environment, depth: depth + 1)
    result.interpreters.append(runtime)
    result.status = runtime.hasKnownFailure ? .interpreterUnavailable : runtime.status
    return result
  }

  private static func absolute(_ path: String, base: URL) -> URL {
    (path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path))
      .standardizedFileURL
  }
}
