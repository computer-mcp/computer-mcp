import Foundation
import Subprocess
import WinSDK

/// A native Windows child used only by platform process tests.
@main
struct PlatformProcessFixture {
  static func main() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let mode = arguments.first else { ExitProcess(2) }
    switch mode {
    case "echo":
      let environment = ProcessInfo.processInfo.environment
      let value: [String: Any] = [
        "arguments": Array(arguments.dropFirst()),
        "cwd": FileManager.default.currentDirectoryPath,
        "value": environment.first(where: { $0.key.lowercased() == "fixture_value" })?.value ?? "",
        "path": environment.first(where: { $0.key.lowercased() == "path" })?.value ?? "",
        "userProfile": environment["USERPROFILE"] ?? "",
      ]
      try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: value))
    case "output":
      let count = Int(arguments[1])!
      let bytes = Data((0..<256).map(UInt8.init))
      for _ in 0..<count {
        try FileHandle.standardOutput.write(contentsOf: bytes)
        try FileHandle.standardError.write(contentsOf: Data(bytes.reversed()))
      }
      try Data("drained".utf8).write(to: URL(fileURLWithPath: arguments[2]))
    case "exit":
      ExitProcess(DWORD(arguments[1])!)
    case "stdin_eof":
      let input = try FileHandle.standardInput.readToEnd() ?? Data()
      try FileHandle.standardOutput.write(contentsOf: Data(String(input.count).utf8))
    case "leaf":
      try record("leaf", directory: arguments[1])
      try await Task.sleep(for: .seconds(60))
    case "branch", "tree", "tree_exit":
      let directory = arguments[1]
      let child = mode == "branch" ? "leaf" : "branch"
      _ = try await Subprocess.run(
        .path(.init(CommandLine.arguments[0])), arguments: Arguments([child, directory]),
        output: .discarded, error: .discarded
      ) { _ in
        try await waitFor(child, directory: directory)
        try record(mode == "branch" ? "branch" : "root", directory: directory)
        if mode == "tree_exit" {
          try await waitFor("release", directory: directory)
          ExitProcess(0)
        }
        try await Task.sleep(for: .seconds(60))
      }
    default:
      ExitProcess(3)
    }
  }

  private static func record(_ name: String, directory: String) throws {
    try Data(String(GetCurrentProcessId()).utf8).write(
      to: URL(fileURLWithPath: directory).appendingPathComponent(name), options: .atomic)
  }

  private static func waitFor(_ name: String, directory: String) async throws {
    let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !FileManager.default.fileExists(atPath: path) {
      guard ContinuousClock.now < deadline else { ExitProcess(4) }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}
