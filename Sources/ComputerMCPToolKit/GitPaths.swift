import ComputerMCPCore

package func optionalGitPaths(in object: [String: JSONValue], literal: Bool = false) throws
  -> [String]
{
  let paths = try optionalStringArray("paths", in: object)
  for path in paths {
    guard !path.isEmpty else {
      throw GatewayToolError.invalidArguments("paths must not contain empty strings.")
    }
    guard !path.hasPrefix("/") else {
      throw GatewayToolError.invalidArguments("paths must be project-relative: \(path)")
    }
    guard literal || (!path.hasPrefix(":(") && !path.hasPrefix(":/")) else {
      throw GatewayToolError.invalidArguments("git pathspec magic is not supported: \(path)")
    }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.contains("..") else {
      throw GatewayToolError.invalidArguments("paths must not escape project: \(path)")
    }
  }
  return paths
}
