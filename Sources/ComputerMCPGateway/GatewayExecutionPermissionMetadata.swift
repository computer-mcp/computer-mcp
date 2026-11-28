import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPProcess
import Foundation

enum GatewayExecutionPermissionMetadata {
  /// A result can describe several retained executions. Each request group stays
  /// bound to its original call, while the result and its execution handles survive.
  static func payload(_ groups: [ExecutionPermissionRequestGroup]) -> [JSONValue] {
    groups.filter { !$0.requests.isEmpty }.sorted {
      $0.executionID.uuidString < $1.executionID.uuidString
    }.map { group in
      let requests = Dictionary(grouping: group.requests, by: \.id).values.compactMap(\.first)
        .sorted { $0.id.uuidString < $1.id.uuidString }
      var fields = GatewayPermissionCallError.required(requests, afterDispatch: true).fields
      fields["request_group_id"] = .string(group.executionID.uuidString)
      fields["execution_id"] = .string(group.executionID.uuidString)
      return .object(fields)
    }
  }

  static func attach(to result: JSONValue, groups: [ExecutionPermissionRequestGroup]) -> JSONValue {
    let groups = payload(groups)
    guard !groups.isEmpty, var object = result.objectValue else { return result }
    if var content = object["structuredContent"]?.objectValue {
      var execution = content["gateway_execution"]?.objectValue ?? [:]
      execution["permission_requests"] = .array(groups)
      content["gateway_execution"] = .object(execution)
      object["structuredContent"] = .object(content)
    }
    var metadata = object["_meta"]?.objectValue ?? [:]
    var execution = metadata["computer_mcp"]?.objectValue ?? [:]
    execution["permission_requests"] = .array(groups)
    metadata["computer_mcp"] = .object(execution)
    object["_meta"] = .object(metadata)
    return .object(object)
  }
}

/// A discovered need does not establish why the encompassing provider failed.
/// Keep its error intact while making the independently attributed retry visible.
struct GatewayExecutionPermissionFailure: Error, LocalizedError {
  let underlying: any Error
  let groups: [ExecutionPermissionRequestGroup]

  var errorDescription: String? {
    (underlying as? any LocalizedError)?.errorDescription ?? String(describing: underlying)
  }
}
