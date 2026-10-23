import Testing

@testable import ComputerMCPCore

struct ExecutionContextTests {
  @Test func equalityComparesEveryFieldAndTheSessionByIdentity() {
    let session = StubSessionAuthority()
    var base = ExecutionContext(
      requestID: "request", caller: .localApp, profileID: .localAdmin, projectID: "alpha",
      transportTrace: .init(transport: "socket"), trustedPrincipalID: "principal")
    base.controlSession = session
    var same = base
    same.controlSession = session
    #expect(base == same)

    var variants: [ExecutionContext] = []
    var context = base
    context.requestID = "other"
    variants.append(context)
    context = base
    context.caller = .localCLI
    variants.append(context)
    context = base
    context.profileID = .chatGPTOperate
    variants.append(context)
    context = base
    context.projectID = nil
    variants.append(context)
    context = base
    context.transportTrace = .init(transport: "http")
    variants.append(context)
    context = base
    context.trustedPrincipalID = nil
    variants.append(context)
    context = base
    context.controlSession = StubSessionAuthority()
    variants.append(context)
    context = base
    context.controlSession = nil
    variants.append(context)
    for variant in variants { #expect(variant != base) }
  }

  /// A new stored property must also be compared by `==` and, unless it is session state,
  /// encoded.
  @Test func equalityCoversTheStoredProperties() {
    let labels = Mirror(
      reflecting: ExecutionContext(caller: .localApp, profileID: .localAdmin)
    ).children.compactMap(\.label)
    #expect(
      labels == [
        "requestID", "caller", "profileID", "projectID", "transportTrace",
        "trustedPrincipalID", "controlSession",
      ])
  }
}

private final class StubSessionAuthority: GatewaySessionAuthority {
  let id = "stub"
  let revision: Int64 = 0

  func apply(to grant: ProfileGrant, context: ExecutionContext) throws -> ProfileGrant { grant }

  func requireRevision(_ expected: Int64?) throws {}
}
