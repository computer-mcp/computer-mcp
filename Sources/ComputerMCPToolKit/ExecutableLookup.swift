import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPProcess
import Foundation

package func validateExecutableLookupName(_ name: String) throws {
  try validateUTF8ByteLimit(name, name: "name", maxBytes: 128)
  guard !name.isEmpty else {
    throw GatewayToolError.invalidArguments("name must not be empty.")
  }
  guard !name.hasPrefix("-") else {
    throw GatewayToolError.invalidArguments("name must not start with an option marker.")
  }
  guard name != "." && name != ".." else {
    throw GatewayToolError.invalidArguments("name must be an executable basename.")
  }
  let allowed = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._+@-")
  guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
    throw GatewayToolError.invalidArguments(
      "name must be an executable basename without slashes or whitespace.")
  }
}

package func executableResolutionJSON(_ resolution: ExecutableInspection) -> JSONValue {
  resolution.json
}

package func pathExecutables(_ executable: String, allMatches: Bool, environment: [String: String])
  -> [String]
{
  var matches: [String] = []
  var seen = Set<String>()
  for directory in pathSearchDirectories(environment: environment) {
    let candidate = URL(fileURLWithPath: directory).appendingPathComponent(executable).path
    guard FileManager.default.isExecutableFile(atPath: candidate) else {
      continue
    }
    guard seen.insert(candidate).inserted else {
      continue
    }
    matches.append(candidate)
    if !allMatches {
      break
    }
  }
  return matches
}

package func pathSearchDirectories(environment: [String: String]) -> [String] {
  let pathValue =
    environment["PATH"]
    ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  return pathValue.split(separator: ":").map(String.init).filter { !$0.isEmpty }
}
