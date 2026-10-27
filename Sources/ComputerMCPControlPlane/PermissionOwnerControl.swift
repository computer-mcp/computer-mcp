import ComputerMCPCore
import ComputerMCPGateway
import ComputerMCPPermissions
import Foundation

enum PermissionOwnerControl {
  static let contracts: [ControlToolContract] = [
    .init("permissions.requests", readOnly: true),
    .init(
      "permissions.answer",
      arguments: ["id": .string, "answer": .string, "expected_revision": .integer],
      required: ["id", "answer", "expected_revision"], readOnly: false),
    .init(
      "permissions.confirm_authority",
      arguments: [
        "epoch": .string, "expected_permission_revision": .integer, "profiles": .objects,
      ],
      required: ["epoch", "expected_permission_revision", "profiles"], readOnly: false),
  ]

  static func call(name: String, arguments: [String: JSONValue], service: PermissionControlService)
    throws -> JSONValue
  {
    switch name {
    case "permissions.requests":
      let view = try service.view()
      return .object([
        "revision": .integer(Int64(view.revision)), "suspended": .bool(view.suspended),
        "epoch": view.epoch.map { .string($0.uuidString) } ?? .null,
        "unconfirmed_profile_ids": .array(
          view.unconfirmedProfileIDs.map(\.rawValue).sorted().map(JSONValue.string)),
        "profiles": try ControlToolResponse.encodedPayload(view.profiles),
        "sources": try ControlToolResponse.encodedPayload(view.sources),
        "requests": .array(
          try view.requests.map { item in
            .object([
              "request": try ControlToolResponse.encodedPayload(item.request),
              "profile_id": item.profileID.map { .string($0.rawValue) } ?? .null,
              "always_is_shared": .bool(item.alwaysIsShared),
            ])
          }),
      ])
    case "permissions.confirm_authority":
      guard let epoch = arguments["epoch"]?.stringValue.flatMap(UUID.init(uuidString:)),
        let revision = arguments["expected_permission_revision"]?.intValue, revision >= 0,
        let reviewed = arguments["profiles"]
      else {
        throw GatewayToolError.invalidArguments(
          "An epoch UUID, expected_permission_revision, and complete reviewed profiles array are required."
        )
      }
      let profiles = try CanonicalJSONCoding.decoder().decode(
        [ProfileGrant].self, from: JSONEncoder().encode(reviewed))
      try service.confirmAuthority(
        epoch: epoch, expectedRevision: UInt64(revision), profileEdits: profiles)
      return .object(["confirmed": .string(epoch.uuidString)])
    case "permissions.answer":
      guard let id = arguments["id"]?.stringValue.flatMap(UUID.init(uuidString:)),
        let revision = arguments["expected_revision"]?.intValue, revision >= 0
      else {
        throw GatewayToolError.invalidArguments(
          "A request UUID and expected_revision are required.")
      }
      switch arguments["answer"]?.stringValue {
      case "only_this_time":
        _ = try service.answerRequest(id, answer: .onlyThisTime, expectedRevision: UInt64(revision))
      case "always":
        _ = try service.answerRequest(id, answer: .always, expectedRevision: UInt64(revision))
      case "deny": _ = try service.declineRequest(id, expectedRevision: UInt64(revision))
      default:
        throw GatewayToolError.invalidArguments("answer must be only_this_time, always or deny.")
      }
      return .object(["answered": .string(id.uuidString)])
    default: throw GatewayToolError.unknownTool(name)
    }
  }
}
