import CryptoKit
import Foundation

/// A publisher-declared compatibility assertion, executed only within an authorized
/// call. Probe argv and output are not included in diagnostics or tool results.
struct CLIExecutableCheck: Codable, Equatable, Sendable {
  let args: [String]
  var stdout: String? = nil
  var stdoutSHA256: String? = nil

  private enum CodingKeys: String, CodingKey {
    case args, stdout
    case stdoutSHA256 = "stdout_sha256"
  }

  func validate() throws {
    guard !args.isEmpty, args.count <= 128,
      args.allSatisfy({ !$0.contains("\0") }),
      args.reduce(0, { $0 + $1.utf8.count + 1 }) <= 65_536,
      (stdout != nil) != (stdoutSHA256 != nil), (stdout?.utf8.count ?? 0) <= 65_536,
      stdoutSHA256.map({
        $0.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
      }) ?? true
    else {
      throw CLITreeError.invalid(
        "Executable checks require bounded argv and one exact output assertion.")
    }
  }

  func matches(_ result: ShellSessionSnapshot) -> Bool {
    guard result.exitCode == 0, result.signal == nil,
      !result.timedOut, !result.cancelled, !result.isRunning,
      result.launchError == nil, result.streamErrors.isEmpty,
      !result.stdout.truncated, !result.stdout.missedBytes,
      !result.stderr.truncated, !result.stderr.missedBytes,
      let base64 = result.stdout.base64, let data = Data(base64Encoded: base64)
    else { return false }
    if let stdout { return data == Data(stdout.utf8) }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == stdoutSHA256
  }
}
