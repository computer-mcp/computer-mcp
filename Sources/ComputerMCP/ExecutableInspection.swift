import ComputerMCPPlatform

package typealias ExecutableInspection = ComputerMCPPlatform.ExecutableInspection

extension ExecutableInspection {
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

}
