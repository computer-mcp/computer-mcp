import ComputerMCPConfiguration
import ComputerMCPCore
import Foundation

package func environmentEntry(
  key: String,
  owner: String,
  purpose: String,
  valueOrigin: String,
  processEnvironment: [String: String],
  declaredKeys: inout Set<String>
) -> JSONValue {
  declaredKeys.insert(key)
  return .object([
    "key": .string(key),
    "owner": .string(owner),
    "purpose": .string(purpose),
    "value_origin": .string(valueOrigin),
    "process_environment_present": .bool(processEnvironment[key] != nil),
    "value_redacted": .bool(true),
  ])
}

package func httpAuthMode(configuration: GatewayConfiguration) -> String {
  if configuration.server.http.accessTokenEnv != nil {
    return "bearer"
  }
  return "none"
}
