import ComputerMCPCore
import Foundation

/// Program configuration for Git launched by host-owned operations.
package enum HostGitConfiguration {
  // A non-executable device prevents program lookup through the caller's PATH.
  package static let arguments = [
    "--no-pager",
    "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
    "-c", "core.editor=/dev/null", "-c", "sequence.editor=/dev/null",
    "-c", "core.pager=", "-c", "core.askPass=/dev/null",
    "-c", "credential.helper=", "-c", "core.sshCommand=/dev/null",
    "-c", "core.gitProxy=/dev/null", "-c", "core.alternateRefsCommand=/dev/null",
    "-c", "gpg.program=/dev/null", "-c", "gpg.openpgp.program=/dev/null",
    "-c", "gpg.x509.program=/dev/null", "-c", "gpg.ssh.program=/dev/null",
    "-c", "gpg.ssh.defaultKeyCommand=/dev/null",
    "-c", "rebase.instructionFormat=", "-c", "uploadpack.packObjectsHook=/dev/null",
    "-c", "pull.twohead=ort", "-c", "pull.octopus=octopus",
    "-c", "commit.gpgSign=false", "-c", "tag.gpgSign=false",
    "-c", "diff.external=/dev/null", "-c", "interactive.diffFilter=/dev/null",
    "-c", "gc.auto=0", "-c", "maintenance.auto=false", "-c", "submodule.recurse=false",
  ]

  package static func environment(_ source: [String: String], home: URL) -> [String: String] {
    var result = source.filter { !$0.key.hasPrefix("GIT_") }
    result["HOME"] = home.path
    result["XDG_CONFIG_HOME"] = home.path
    result["GIT_CONFIG_NOSYSTEM"] = "1"
    result["GIT_CONFIG_GLOBAL"] = "/dev/null"
    result["GIT_TERMINAL_PROMPT"] = "0"
    result["GIT_NO_LAZY_FETCH"] = "1"
    result["GIT_ALLOW_PROTOCOL"] = ""
    result["GIT_CONFIG_COUNT"] = "0"
    result["GIT_CONFIG_PARAMETERS"] = ""
    result["GIT_EXTERNAL_DIFF"] = "/dev/null"
    result["GIT_ATTR_NOSYSTEM"] = "1"
    result["GIT_PAGER"] = ""
    result["GIT_EDITOR"] = "/dev/null"
    result["GIT_SEQUENCE_EDITOR"] = "/dev/null"
    result["GIT_ASKPASS"] = "/dev/null"
    result["GIT_SSH_COMMAND"] = "/dev/null"
    return result
  }

  /// Owner identity is read as configuration data before isolating program execution.
  package static func identityEnvironment(_ source: [String: String]) -> [String: String] {
    source.filter {
      !$0.key.hasPrefix("GIT_") || ["GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM"].contains($0.key)
    }
  }

  /// Configuration names are NUL-delimited; subsection names can contain newlines.
  package static func overrides(for names: String) throws -> [String] {
    var result: [String] = []
    for key in Set(names.split(separator: "\0").map(String.init)).sorted() {
      let lower = key.lowercased()
      guard !lower.hasPrefix("include."), !lower.hasPrefix("includeif.") else {
        throw GatewayToolError.executionFailed(
          "Host Git operations refuse repository configuration includes.")
      }
      let value: String?
      if lower.hasPrefix("filter.") {
        if lower.hasSuffix(".required") {
          value = "false"
        } else if [".clean", ".smudge", ".process"].contains(where: lower.hasSuffix) {
          value = ""
        } else {
          value = nil
        }
      } else if lower.hasPrefix("hook."),
        lower.hasSuffix(".command") || lower.hasSuffix(".enabled") || lower.hasSuffix(".event")
      {
        guard !key.contains("=") else {
          throw GatewayToolError.executionFailed("Invalid Git configuration key.")
        }
        let subsection = key[..<key.lastIndex(of: ".")!]
        result += [
          "-c", "\(subsection).enabled=false", "-c", "\(subsection).command=/dev/null",
        ]
        value = nil
      } else if lower.hasPrefix("diff."),
        lower.hasSuffix(".command") || lower.hasSuffix(".textconv")
      {
        value = "/dev/null"
      } else if lower.hasPrefix("branch."), lower.hasSuffix(".mergeoptions") {
        value = ""
      } else if lower.hasPrefix("merge."), lower.hasSuffix(".driver") {
        value = "/dev/null"
      } else if lower.hasPrefix("credential."), lower.hasSuffix(".helper") {
        value = ""
      } else if lower.hasPrefix("pager.") {
        value = "false"
      } else if lower.hasPrefix("gpg."),
        lower.hasSuffix(".program") || lower.hasSuffix(".defaultkeycommand")
      {
        value = "/dev/null"
      } else if lower.hasPrefix("trailer."), lower.hasSuffix(".command") || lower.hasSuffix(".cmd")
      {
        value = "/dev/null"
      } else if lower.hasPrefix("remote."),
        lower.hasSuffix(".uploadpack") || lower.hasSuffix(".receivepack")
      {
        value = "/dev/null"
      } else {
        value = nil
      }
      if let value {
        guard !key.contains("="), !key.contains("\0") else {
          throw GatewayToolError.executionFailed("Invalid Git configuration key.")
        }
        result += ["-c", "\(key)=\(value)"]
      }
    }
    return result
  }
}
