import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPPermissions
import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPTransport
import Foundation

/// Exactly one registered adapter generation owns this endpoint and its acquisitions.
final class VendorExecutionSession: MCPHostSessionHandle {
  let providerChannel: ProviderHostServiceChannel
  let termination: AsyncStream<Void>
  let observationTools: Set<String>
  private let transport: MCPInheritedSocketTransport
  private let acquisitions: VendorExecutionAcquisitions
  private let serving: Task<Void, Never>

  init(source: VendorExecutionSource, launcher: ExecutionLauncher) throws {
    try source.verify()
    observationTools = Set(
      source.signature.tools.compactMap { $0.value == .observe ? $0.key : nil })
    let pair = try ProviderHostServiceChannel.make(metadata: VendorExecutionSource.capability)
    providerChannel = pair.channel
    let transport = try MCPInheritedSocketTransport(takingOwnershipOf: pair.host)
    self.transport = transport
    let acquisitions = VendorExecutionAcquisitions(source: source, launcher: launcher)
    self.acquisitions = acquisitions
    let (termination, terminated) = AsyncStream<Void>.makeStream()
    self.termination = termination
    serving = Task {
      defer { terminated.finish() }
      do {
        try await transport.connect()
        let messages = await transport.receive()
        await withDiscardingTaskGroup { group in
          do {
            var iterator = messages.makeAsyncIterator()
            if let first = try await iterator.next() {
              let request = try Request(first)
              guard request.operation == "initialize" else {
                throw PermissionModelError.invalidAuthorization
              }
              try await Self.respond(request, transport: transport, owner: acquisitions)
              while let message = try await iterator.next() {
                let request = try Request(message)
                guard await acquisitions.beginRequest(control: request.control) else {
                  try await Self.send(
                    request.id, outcome: ["error": .string(VendorExecutionFailure.busy.rawValue)],
                    transport: transport)
                  continue
                }
                group.addTask {
                  do {
                    try await Self.respond(request, transport: transport, owner: acquisitions)
                  } catch {
                    await transport.disconnect()
                  }
                  await acquisitions.endRequest(control: request.control)
                }
              }
            }
          } catch {}
          // Seal before waiting on handlers that may be trying to finish a launch.
          await acquisitions.close()
        }
      } catch {
        await acquisitions.close()
      }
      await transport.disconnect()
    }
  }

  private struct Request: Sendable {
    let fields: [String: JSONValue]
    let id: Int64
    let operation: String

    var control: Bool {
      switch operation {
      case "read", "bind", "probe", "launch": false
      case "write": ["cancel", "close"].contains(fields["kind"]?.stringValue)
      default: true
      }
    }

    init(_ data: Data) throws {
      guard let fields = try JSONDecoder().decode(JSONValue.self, from: data).objectValue,
        let id = fields["id"]?.int64Value, let operation = fields["op"]?.stringValue
      else { throw PermissionModelError.invalidAuthorization }
      self.fields = fields
      self.id = id
      self.operation = operation
    }
  }

  private static func respond(
    _ request: Request, transport: MCPInheritedSocketTransport, owner: VendorExecutionAcquisitions
  ) async throws {
    let outcome: [String: JSONValue]
    do {
      let payload = try await owner.handle(request.operation, fields: request.fields)
      outcome = ["result": .object(payload)]
    } catch let error as VendorExecutionFailure {
      outcome = ["error": .string(error.rawValue)]
    } catch {
      outcome = ["error": .string(VendorExecutionFailure.denied.rawValue)]
    }
    try await send(request.id, outcome: outcome, transport: transport)
  }

  private static func send(
    _ id: Int64, outcome: [String: JSONValue], transport: MCPInheritedSocketTransport
  ) async throws {
    var frame = outcome
    frame["id"] = .integer(id)
    try await transport.send(JSONEncoder().encode(JSONValue.object(frame)))
  }

  func admit(
    id: UUID, tool: String, arguments: [String: JSONValue], execution: PreparedExecutionContext
  ) async throws {
    do {
      try await acquisitions.admit(id, tool: tool, arguments: arguments, execution: execution)
    } catch let error as VendorExecutionFailure {
      throw GatewayToolError.invalidArguments("Vendor effect refused: \(error.rawValue)")
    }
  }

  func returned(_ id: UUID, confirmed: Bool) async {
    await acquisitions.returned(id, confirmed: confirmed)
  }

  func requestCancellation(_ id: UUID) async { await acquisitions.cancelInvocation(id) }

  func stopInvocation(_ id: UUID) async { await acquisitions.stopInvocation(id) }

  func stopExecution(_ id: UUID) async { await acquisitions.stopExecution(id) }

  func timeOut(_ id: UUID) async { await acquisitions.timeOut(id) }

  func close() async {
    providerChannel.close()
    await transport.disconnect()
    await serving.value
  }

  func shutdownConfirmed() async -> Bool { await acquisitions.cleanupConfirmed }

  func negotiated() async -> Bool { await acquisitions.negotiatedForDispatch }
}

enum VendorExecutionFailure: String, Error {
  case denied = "vendor_effect_denied"
  case busy = "vendor_busy"
  case capacity = "vendor_capacity"
  case stale = "vendor_effect_stale"
  case queuedCancel = "vendor_queued_cancelled"
  case startupCancelled = "cancelled"
  case badVersion = "incompatible_vendor"
  case writeUnknown = "vendor_write_unknown"
  case outputFailed = "vendor_output_failed"
  case outputTruncated = "vendor_output_truncated"
  case unconfirmed = "cleanup_unconfirmed"
}

private actor VendorExecutionAcquisitions {
  private typealias Effect = VendorExecutionSource.Effect

  private static let maximumFrameBytes = 1_048_576
  private static let maximumChunkBytes = 196_608

  private struct OutboundFrame {
    let id: UUID
    let call: UUID
    let kind: String
    let token: String?
    var bytes = Data()
  }

  private struct Invocation {
    let effect: Effect
    let execution: PreparedExecutionContext
    let acquisition: UUID
    let targetTurn: UUID?
    let arguments: [String: JSONValue]
    let deadline: ContinuousClock.Instant
    var detached = false
    var detachedLease: ExecutionWorkLease?
  }

  private final class Acquisition {
    let execution: PreparedExecutionContext
    let probe: VendorExecutionPhase
    let workload: VendorExecutionPhase
    let argv: [String]
    var handle: String?
    var probeTask: Task<Bool, Never>?
    var workloadProcess: ManagedLineProcess?
    var outputTask: Task<Void, Never>?
    var expiry: Task<Void, Never>?
    var retirement: Task<Bool, Never>?
    var retirementRequested = false
    var retired = false
    var output: [Data] = []
    var outputBytes = 0
    var outputAcknowledged: Int64 = 0
    var outputOffered = false
    var outputEnded = false
    var outputFailure: VendorExecutionFailure?
    var startupCancelled = false
    var outputReadWaiting = false
    var setupWrites = 0
    var trae: TraeVendorProtocol?
    var traeOpenFinished = false
    var closingCall: UUID?
    var nativeCloseCall: UUID?
    var completedTurns: [UUID] = []
    var exitCode: Int32?
    var exitSignal: Int32?
    var turn: UUID?
    var retiredTurn: UUID?
    var dispatched = false
    var stopRequested = false
    var stopSent = false
    var queuedWrites = 0
    var outbound: OutboundFrame?
    var launching = false
    var pending: Set<String> = []
    var issuedTokens: Set<String> = []

    init(
      execution: PreparedExecutionContext, probe: VendorExecutionPhase,
      workload: VendorExecutionPhase, argv: [String], trae: TraeVendorProtocol?
    ) {
      self.execution = execution
      self.probe = probe
      self.workload = workload
      self.argv = argv
      self.trae = trae
    }
  }

  private let source: VendorExecutionSource
  private let launcher: ExecutionLauncher
  private var negotiated = false
  private var closed = false
  private var controlRequests = 0
  private var dataRequests = 0
  private var acquisitions: [UUID: Acquisition] = [:]
  private var handles: [String: UUID] = [:]
  private var invocations: [UUID: Invocation] = [:]

  init(source: VendorExecutionSource, launcher: ExecutionLauncher) {
    self.source = source
    self.launcher = launcher
  }

  var cleanupConfirmed: Bool { closed && acquisitions.values.allSatisfy(\.retired) }
  var negotiatedForDispatch: Bool { negotiated && !closed }

  func beginRequest(control: Bool) -> Bool {
    if control {
      guard controlRequests < 8 else { return false }
      controlRequests += 1
    } else {
      guard dataRequests < 16 else { return false }
      dataRequests += 1
    }
    return true
  }

  func endRequest(control: Bool) {
    if control { controlRequests -= 1 } else { dataRequests -= 1 }
  }

  private var chargedAcquisitions: [UUID: Acquisition] {
    acquisitions.filter { !$0.value.retired }
  }

  func admit(
    _ id: UUID, tool: String, arguments: [String: JSONValue], execution: PreparedExecutionContext
  ) throws {
    guard !closed, negotiated else { throw VendorExecutionFailure.denied }
    guard let effect = source.signature.tools[tool] else { throw VendorExecutionFailure.denied }
    try validate(execution)
    if effect == .observe { return }
    if invocations.count >= 64 {
      invocations = invocations.filter { acquisitions[$0.value.acquisition]?.retired == false }
    }
    guard invocations.count < 64 else { throw VendorExecutionFailure.capacity }
    let defaultTimeout = source.protocolKind == .cursor ? 300 : 600
    let timeout = min(1800, max(1, arguments["timeout_seconds"]?.intValue ?? defaultTimeout))
    let deadline = ContinuousClock.now + .seconds(timeout)
    if effect.acquires {
      guard chargedAcquisitions.count < 8 else {
        throw VendorExecutionFailure.capacity
      }
      let argv = try source.signature.workload.arguments(arguments)
      let trae =
        source.protocolKind == .trae
        ? try TraeVendorProtocol(open: arguments, directory: directory(execution).value) : nil
      // Keep a bounded set of exact receipts on this generation.
      if acquisitions.count == 64, let receipt = acquisitions.first(where: { $0.value.retired }) {
        acquisitions.removeValue(forKey: receipt.key)
        if let handle = receipt.value.handle { handles[handle] = nil }
        invocations = invocations.filter { $0.value.acquisition != receipt.key }
      }
      let slots = try ExecutionRevocationCoordinator.reserveVendorExecutionPhases(
        execution: execution)
      let acquisition = Acquisition(
        execution: execution, probe: slots.probe, workload: slots.workload, argv: argv, trae: trae)
      acquisitions[id] = acquisition
      invocations[id] = Invocation(
        effect: effect, execution: execution, acquisition: id, targetTurn: nil,
        arguments: arguments, deadline: deadline)
      acquisition.expiry = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(min(60, timeout))) } catch { return }
        await self?.expireStartup(id)
      }
    } else {
      let target: UUID?
      let key: UUID?
      if source.protocolKind == .trae, effect == .stop {
        target = uuid(arguments["turn_id"])
        key = target.flatMap { turn in
          if let active = invocations[turn], Self.isPrompt(active.effect) {
            return active.acquisition
          }
          return acquisitions.first(where: { $0.value.completedTurns.contains(turn) })?.key
        }
      } else {
        target = nil
        key = arguments[source.protocolKind.handleArgument]?.stringValue.flatMap { handles[$0] }
      }
      guard let key,
        let acquisition = acquisitions[key],
        effect == .close || (effect == .stop && target != nil)
          || (!acquisition.retirementRequested && acquisition.closingCall == nil),
        let original = acquisition.execution.provider?.delegatingAuthorization?.invocation,
        let admitted = execution.provider?.delegatingAuthorization?.invocation,
        admitted.principal == original.principal, admitted.projectID == original.projectID
      else { throw VendorExecutionFailure.stale }
      if effect == .close {
        if source.protocolKind == .trae {
          guard acquisition.closingCall.flatMap({ invocations[$0] }) == nil else {
            throw VendorExecutionFailure.busy
          }
          acquisition.closingCall = id
        }
        if !acquisition.retirementRequested, acquisition.workload.sealPendingBootstrap() {
          // Admission wins over any launch still awaiting its probe or sandbox.
          acquisition.startupCancelled = true
          Task { _ = await retire(key) }
        }
      }
      if Self.ownsTurn(effect) {
        guard source.protocolKind != .trae || acquisition.traeOpenFinished,
          acquisition.turn == nil, acquisition.queuedWrites == 0
        else {
          throw VendorExecutionFailure.busy
        }
        acquisition.turn = id
        acquisition.dispatched = false
        acquisition.stopRequested = false
        acquisition.stopSent = false
        acquisition.outbound = nil
        acquisition.pending.removeAll()
        acquisition.issuedTokens.removeAll()
      } else if (effect == .stop && (target == nil || target == acquisition.turn))
        || (effect == .close && source.protocolKind == .trae),
        let turn = acquisition.turn,
        invocations[turn].map({ Self.isPrompt($0.effect) }) == true
      {
        acquisition.stopRequested = true
      }
      invocations[id] = Invocation(
        effect: effect, execution: execution, acquisition: key,
        targetTurn: target ?? acquisition.turn,
        arguments: arguments, deadline: deadline)
    }
  }

  private func validate(_ execution: PreparedExecutionContext) throws {
    guard let provider = execution.provider, provider.identity == .package(source.pluginID),
      provider.registrationID == source.registrationID,
      provider.sourceDigest == source.manifestDigest,
      let project = provider.delegatingAuthorization?.invocation.projectID,
      provider.providerAuthorization.invocation.projectID == project,
      case .sandbox(let sandbox) = execution.mode, !sandbox.hostNetwork
    else { throw VendorExecutionFailure.denied }
    try execution.validateProviderLaunch()
  }

  private func expireStartup(_ id: UUID) async {
    guard acquisitions[id]?.expiry != nil else { return }
    _ = await retire(id)
  }

  func returned(_ id: UUID, confirmed: Bool) async {
    guard let invocation = invocations[id], let acquisition = acquisitions[invocation.acquisition]
    else { return }
    if invocation.effect.acquires {
      if confirmed && invocation.detached { return }
      if !confirmed || acquisition.expiry != nil || source.protocolKind == .claudePrint {
        _ = await retire(id)
      }
    } else if acquisition.turn == id {
      if confirmed && invocation.detached { return }
      if !confirmed || acquisition.dispatched {
        _ = await retire(invocation.acquisition)
      } else {
        acquisition.turn = nil
        rememberTurn(id, acquisition: acquisition)
      }
    }
    try? invocation.detachedLease?.finish()
    invocations.removeValue(forKey: id)
  }

  func cancelInvocation(_ id: UUID) async {
    guard let invocation = invocations[id], let acquisition = acquisitions[invocation.acquisition]
    else { return }
    if invocation.effect.acquires, acquisition.expiry != nil || source.protocolKind == .claudePrint
    {
      acquisition.startupCancelled = true
      _ = await retire(invocation.acquisition)
    } else if acquisition.turn == id {
      acquisition.stopRequested = true
    }
  }

  func stopInvocation(_ id: UUID) async {
    guard let invocation = invocations[id], let acquisition = acquisitions[invocation.acquisition],
      invocation.effect.acquires || acquisition.turn == id
    else { return }
    _ = await retire(invocation.acquisition)
  }

  func stopExecution(_ id: UUID) async {
    let keys = acquisitions.filter { $0.value.execution.executionID == id }.map(\.key)
    for key in keys { _ = await retire(key) }
  }

  func timeOut(_ executionID: UUID) async {
    for (id, invocation) in invocations where invocation.execution.executionID == executionID {
      guard let acquisition = acquisitions[invocation.acquisition] else { continue }
      if invocation.effect.acquires || acquisition.turn == id {
        _ = await retire(invocation.acquisition)
      }
    }
  }

  func handle(_ op: String, fields: [String: JSONValue]) async throws -> [String: JSONValue] {
    guard !closed else { throw VendorExecutionFailure.denied }
    if op == "initialize" {
      guard !negotiated, fields["capability"]?.stringValue == VendorExecutionSource.capability
      else { throw VendorExecutionFailure.denied }
      negotiated = true
      return ["capability": .string(VendorExecutionSource.capability)]
    }
    guard negotiated, let call = uuid(fields["call"]), let key = uuid(fields["acquisition"]),
      let acquisition = acquisitions[key]
    else { throw VendorExecutionFailure.denied }
    let invocation = invocations[call]
    guard invocation?.acquisition == key || (invocation == nil && call == key) else {
      throw VendorExecutionFailure.denied
    }
    if op == "receipt" || (op == "retire" && invocation == nil && acquisition.retirementRequested) {
      if let child = fields["child"], child != .null {
        guard let id = uuid(child), id == acquisition.probe.id || id == acquisition.workload.id
        else { throw VendorExecutionFailure.stale }
      }
      try source.verify()
      let execution = invocation?.execution ?? acquisition.execution
      _ = try execution.authority.access(execution.executionID, operation: .readResult)
      if op == "retire" {
        guard uuid(fields["child"]) == acquisition.workload.id else {
          throw VendorExecutionFailure.stale
        }
        guard await retire(key) else { throw VendorExecutionFailure.unconfirmed }
      }
      return receipt(acquisition)
    }
    guard let invocation,
      ["receipt", "retire", "finish"].contains(op) || ContinuousClock.now < invocation.deadline
    else { throw VendorExecutionFailure.denied }

    // Empty reads and buffered write fragments carry no authority to emit
    // native bytes. Check live proofs when a read exposes data or at final write.
    let checksAuthorityAtIO = op == "read" || op == "write"
    if !checksAuthorityAtIO { try validate(invocation.execution) }
    if op == "detach" {
      let canDetach =
        (invocation.effect == .detachedPrompt && acquisition.turn == call
          && uuid(fields["child"]) == acquisition.workload.id && !acquisition.dispatched)
        || (invocation.effect == .detachedAcquire && acquisition.expiry != nil
          && acquisition.handle == nil)
      guard canDetach, !invocation.detached, !acquisition.retirementRequested
      else { throw VendorExecutionFailure.denied }
      let lease = try invocation.execution.retainWork { [weak self] in
        await self?.stopInvocation(call)
      }
      invocations[call]?.detachedLease = lease
      invocations[call]?.detached = true
      return [:]
    }
    if op == "retire" {
      guard
        invocation.effect == .close || (invocation.effect.acquires && call == key)
          || ((acquisition.turn == call || acquisition.retiredTurn == call)
            && Self.ownsTurn(invocation.effect)),
        (acquisition.workloadProcess == nil && acquisition.workload.receipt != .retired)
          || uuid(fields["child"]) == acquisition.workload.id
      else { throw VendorExecutionFailure.denied }
      guard await retire(key) else { throw VendorExecutionFailure.unconfirmed }
      return receipt(acquisition)
    }
    if !checksAuthorityAtIO, invocation.execution !== acquisition.execution {
      try validate(acquisition.execution)
    }
    if op == "stop", source.protocolKind == .trae, invocation.effect == .stop,
      invocation.targetTurn != acquisition.turn
    {
      guard uuid(fields["child"]) == acquisition.workload.id else {
        throw VendorExecutionFailure.stale
      }
      return [:]
    }
    if op == "read" {
      try checkOutputFailure(fields, invocation: invocation, call: call, acquisition: acquisition)
    }
    try await requireActive(acquisition, id: key)
    switch op {
    case "bind":
      guard invocation.effect.acquires, call == key, let handle = fields["session"]?.stringValue,
        handle.utf8.count == 32, handles[handle] == nil, acquisition.handle == nil,
        source.protocolKind == .cursor
          || handle.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
          })
      else { throw VendorExecutionFailure.denied }
      acquisition.handle = handle
      handles[handle] = key
      let deadline = ContinuousClock.now + .seconds(5)
      acquisition.probe.limitStart(to: deadline)
      let context = try await phaseContext(acquisition, phase: acquisition.probe)
      try await requireActive(acquisition, id: key)
      let launcher = launcher
      let source = source
      acquisition.probeTask = Task {
        await Self.probe(context, source: source, launcher: launcher, deadline: deadline)
      }
      return receipt(acquisition)
    case "probe":
      guard invocation.effect.acquires, call == key,
        uuid(fields["child"]) == acquisition.probe.id, let task = acquisition.probeTask
      else { throw VendorExecutionFailure.denied }
      let passed = await task.value
      try await requireActive(acquisition, id: key)
      guard passed, acquisition.probe.receipt == .retired else {
        throw VendorExecutionFailure.badVersion
      }
      return receipt(acquisition)
    case "launch":
      guard invocation.effect.acquires, call == key, acquisition.workloadProcess == nil,
        uuid(fields["child"]) == acquisition.workload.id, let probe = acquisition.probeTask,
        !fields.keys.contains("argv"), !fields.keys.contains("arguments")
      else { throw VendorExecutionFailure.denied }
      let passed = await probe.value
      try await requireActive(acquisition, id: key)
      guard passed, acquisition.probe.receipt == .retired else {
        throw VendorExecutionFailure.badVersion
      }
      guard acquisition.workloadProcess == nil, !acquisition.launching else {
        throw VendorExecutionFailure.stale
      }
      acquisition.launching = true
      defer { acquisition.launching = false }
      try validate(invocation.execution)
      let context = try await phaseContext(acquisition, phase: acquisition.workload)
      try await requireActive(acquisition, id: key)
      try validate(invocation.execution)
      let print = source.protocolKind == .claudePrint
      let process = try context.withValue {
        try ManagedLineProcess(
          launcher: launcher,
          configuration: .init(
            executable: source.executable.value, arguments: acquisition.argv,
            workingDirectory: URL(fileURLWithPath: try directory(context).value),
            terminationGraceMilliseconds: 100, maximumMessageBytes: Self.maximumFrameBytes - 1,
            closesInputOnLaunch: print, requiresCompleteOutputLines: true))
      }
      acquisition.workloadProcess = process
      if print {
        acquisition.expiry?.cancel()
        acquisition.expiry = nil
      }
      acquisition.outputTask = Task { [weak self] in
        do {
          for try await line in process.inboundLines {
            guard await self?.append(Data((line + "\n").utf8), to: key) == true else { return }
          }
          let outcome = print ? await process.snapshot() : nil
          await self?.endOutput(key, exitCode: outcome?.exitCode, signal: outcome?.signal)
        } catch ManagedLineProcessError.unterminatedOutput {
          await self?.failOutput(key, failure: .outputTruncated)
        } catch {
          await self?.failOutput(key, failure: .outputFailed)
        }
      }
      return receipt(acquisition)
    default:
      guard uuid(fields["child"]) == acquisition.workload.id,
        let process = acquisition.workloadProcess
      else { throw VendorExecutionFailure.denied }
      switch op {
      case "ready":
        guard invocation.effect.acquires, call == key,
          acquisition.trae.map(\.sessionReady)
            ?? (source.protocolKind == .cursor && acquisition.setupWrites >= 3)
        else { throw VendorExecutionFailure.denied }
        acquisition.expiry?.cancel()
        acquisition.expiry = nil
      case "read":
        guard ownsIO(invocation, id: call, acquisition: acquisition),
          !acquisition.outputReadWaiting,
          let after = fields["after"]?.int64Value
        else { throw VendorExecutionFailure.denied }
        // A timed-out poll may outlive its subscriber. Keep the head until the
        // adapter acknowledges buffering it, including across turn boundaries.
        if acquisition.outputOffered, after == acquisition.outputAcknowledged + 1 {
          try validateIO(invocation, acquisition: acquisition)
          acquisition.outputBytes -= acquisition.output.removeFirst().count
          acquisition.outputAcknowledged = after
          acquisition.outputOffered = false
        }
        guard after == acquisition.outputAcknowledged else { throw VendorExecutionFailure.stale }
        if acquisition.output.isEmpty && !acquisition.outputEnded {
          // Park one idle read per workload. Empty polls otherwise compete
          // with control admission for synchronous permission-store access.
          acquisition.outputReadWaiting = true
          defer { acquisition.outputReadWaiting = false }
          let until = min(ContinuousClock.now + .milliseconds(250), invocation.deadline)
          while acquisition.output.isEmpty && !acquisition.outputEnded && .now < until {
            try await Task.sleep(until: min(ContinuousClock.now + .milliseconds(10), until))
            try checkOutputFailure(
              fields, invocation: invocation, call: call, acquisition: acquisition)
            guard !closed, !acquisition.retirementRequested,
              invocations[call] != nil, ownsIO(invocation, id: call, acquisition: acquisition)
            else { throw VendorExecutionFailure.stale }
          }
        }
        if !acquisition.output.isEmpty || acquisition.outputEnded {
          try validateIO(invocation, acquisition: acquisition)
        }
        if let bytes = acquisition.output.first {
          acquisition.outputOffered = true
          return [
            "cursor": .integer(after + 1), "data": .string(bytes.base64EncodedString()),
          ]
        }
        return ["eof": .bool(acquisition.outputEnded)]
      case "stop":
        guard invocation.effect == .stop, let turn = invocation.targetTurn,
          acquisition.turn == turn, invocations[turn].map({ Self.isPrompt($0.effect) }) == true
        else { return [:] }
        acquisition.stopRequested = true
        return [
          "turn": .string(turn.uuidString.lowercased()),
          "dispatched": .bool(acquisition.dispatched),
          "sent": .bool(acquisition.stopSent),
        ]
      case "finish":
        let finishedDetachedOpen =
          invocation.effect == .detachedAcquire && invocation.detached
          && acquisition.expiry == nil && acquisition.turn == nil
        guard source.protocolKind != .claudePrint,
          acquisition.queuedWrites == 0, acquisition.trae?.promptInFlight != true,
          (acquisition.turn == call && !invocation.effect.acquires) || finishedDetachedOpen
            || (invocation.effect == .detachedAcquire && acquisition.turn == call)
        else { throw VendorExecutionFailure.stale }
        if acquisition.turn == call { rememberTurn(call, acquisition: acquisition) }
        acquisition.turn = nil
        acquisition.outbound = nil
        acquisition.pending.removeAll()
        acquisition.issuedTokens.removeAll()
        acquisition.trae?.finishTurn()
        try invocation.detachedLease?.finish()
        if finishedDetachedOpen, source.protocolKind == .trae {
          acquisition.traeOpenFinished = true
        }
        invocations.removeValue(forKey: call)
      case "pending":
        guard ownsIO(invocation, id: call, acquisition: acquisition),
          source.protocolKind != .claudePrint,
          let token = fields["token"]?.stringValue, token.utf8.count == 32,
          acquisition.pending.count < 16, acquisition.issuedTokens.count < 256,
          !acquisition.issuedTokens.contains(token)
        else { throw VendorExecutionFailure.denied }
        try acquisition.trae?.bindPermission(token)
        acquisition.issuedTokens.insert(token)
        acquisition.pending.insert(token)
      case "write":
        try await write(
          fields, call: call, invocation: invocation, acquisition: acquisition, process: process)
      default: throw VendorExecutionFailure.denied
      }
      return [:]
    }
  }

  private func requireActive(_ acquisition: Acquisition, id: UUID) async throws {
    if acquisition.startupCancelled {
      guard await retire(id) else { throw VendorExecutionFailure.unconfirmed }
      throw VendorExecutionFailure.startupCancelled
    }
    guard !acquisition.retirementRequested, acquisition.outputFailure == nil else {
      throw VendorExecutionFailure.stale
    }
  }

  private func ownsIO(_ invocation: Invocation, id: UUID, acquisition: Acquisition) -> Bool {
    (invocation.effect.acquires
      && (acquisition.expiry != nil || acquisition.turn == id
        || source.protocolKind == .claudePrint))
      || (Self.ownsTurn(invocation.effect) && acquisition.turn == id)
      || (acquisition.nativeCloseCall == id && acquisition.closingCall == id
        && acquisition.turn == nil)
  }

  private func checkOutputFailure(
    _ fields: [String: JSONValue], invocation: Invocation, call: UUID, acquisition: Acquisition
  ) throws {
    guard let failure = acquisition.outputFailure else { return }
    guard uuid(fields["child"]) == acquisition.workload.id,
      ownsIO(invocation, id: call, acquisition: acquisition)
        || (acquisition.retiredTurn == call && Self.ownsTurn(invocation.effect))
        || (invocation.effect.acquires && invocation.acquisition == call)
    else { throw VendorExecutionFailure.stale }
    try validateIO(invocation, acquisition: acquisition)
    throw failure
  }

  private func rememberTurn(_ id: UUID, acquisition: Acquisition) {
    guard source.protocolKind == .trae else { return }
    if acquisition.completedTurns.count == 8 { acquisition.completedTurns.removeFirst() }
    acquisition.completedTurns.append(id)
  }

  private static func isPrompt(_ effect: Effect) -> Bool {
    effect == .prompt || effect == .detachedPrompt
  }

  private static func ownsTurn(_ effect: Effect) -> Bool {
    isPrompt(effect) || effect == .mode
  }

  private func validateIO(_ invocation: Invocation, acquisition: Acquisition) throws {
    guard ContinuousClock.now < invocation.deadline else { throw VendorExecutionFailure.stale }
    try validate(invocation.execution)
    if invocation.execution !== acquisition.execution { try validate(acquisition.execution) }
    guard ContinuousClock.now < invocation.deadline else { throw VendorExecutionFailure.stale }
  }

  private func write(
    _ fields: [String: JSONValue], call: UUID, invocation: Invocation, acquisition: Acquisition,
    process: ManagedLineProcess
  ) async throws {
    guard source.protocolKind != .claudePrint, let kind = fields["kind"]?.stringValue,
      let data = fields["data"]?.stringValue,
      acquisition.queuedWrites < 8
    else { throw VendorExecutionFailure.denied }
    let token = fields["token"]?.stringValue
    try authorizeWrite(
      kind, token: token, call: call, invocation: invocation,
      acquisition: acquisition, commit: false)
    guard
      let collected = try collectLine(
        fields, data: data, kind: kind, token: token,
        call: call, acquisition: acquisition)
    else { return }
    let line = acquisition.trae == nil ? collected : try TraeVendorProtocol.canonicalLine(collected)
    guard line.utf8.count < Self.maximumFrameBytes else { throw VendorExecutionFailure.denied }
    let key = invocation.acquisition
    acquisition.queuedWrites += 1
    defer { acquisition.queuedWrites -= 1 }
    do {
      try await acquisition.execution.withValue {
        try await process.sendLine(line) { [self] in
          try await admitWrite(
            kind, line: line, token: token, call: call, acquisitionID: key, child: process)
        }
      }
    } catch let refusal as VendorExecutionFailure {
      throw refusal
    } catch {
      _ = await retire(key)
      throw VendorExecutionFailure.writeUnknown
    }
  }

  private func collectLine(
    _ fields: [String: JSONValue], data: String, kind: String, token: String?,
    call: UUID, acquisition: Acquisition
  ) throws -> String? {
    guard fields["frame"] != nil else {
      guard data.utf8.count < Self.maximumFrameBytes, !data.utf8.contains(0x0A) else {
        throw VendorExecutionFailure.denied
      }
      return data
    }
    guard let frameID = uuid(fields["frame"]), let offset = fields["offset"]?.intValue,
      let final = fields["final"]?.boolValue, let chunk = Data(base64Encoded: data),
      !chunk.isEmpty, chunk.count <= Self.maximumChunkBytes, !chunk.contains(0x0A)
    else { throw VendorExecutionFailure.denied }
    var frame: OutboundFrame
    if let current = acquisition.outbound {
      guard current.id == frameID, current.call == call, current.kind == kind,
        current.token == token, current.bytes.count == offset
      else { throw VendorExecutionFailure.stale }
      frame = current
    } else {
      guard offset == 0 else { throw VendorExecutionFailure.stale }
      frame = OutboundFrame(id: frameID, call: call, kind: kind, token: token)
    }
    guard frame.bytes.count + chunk.count < Self.maximumFrameBytes else {
      acquisition.outbound = nil
      throw VendorExecutionFailure.denied
    }
    frame.bytes.append(chunk)
    if !final {
      acquisition.outbound = frame
      return nil
    }
    acquisition.outbound = nil
    guard let line = String(data: frame.bytes, encoding: .utf8) else {
      throw VendorExecutionFailure.denied
    }
    return line
  }

  /// This runs after the process writer obtains its turn and before any vendor bytes.
  private func admitWrite(
    _ kind: String, line: String, token: String?, call: UUID, acquisitionID: UUID,
    child: ManagedLineProcess
  ) throws {
    guard !closed, let acquisition = acquisitions[acquisitionID],
      !acquisition.retirementRequested, acquisition.workloadProcess === child,
      let invocation = invocations[call], invocation.acquisition == acquisitionID,
      ContinuousClock.now < invocation.deadline
    else { throw VendorExecutionFailure.stale }
    do {
      try validateIO(invocation, acquisition: acquisition)
    } catch let failure as VendorExecutionFailure {
      throw failure
    } catch {
      throw VendorExecutionFailure.denied
    }
    try authorizeWrite(
      kind, token: token, call: call, invocation: invocation,
      acquisition: acquisition, commit: false)
    try acquisition.trae?.commitWrite(
      kind, line: line, token: token, arguments: invocation.arguments)
    try authorizeWrite(
      kind, token: token, call: call, invocation: invocation,
      acquisition: acquisition, commit: true)
  }

  private func authorizeWrite(
    _ kind: String, token: String?, call: UUID, invocation: Invocation, acquisition: Acquisition,
    commit: Bool
  ) throws {
    switch kind {
    case "setup":
      guard invocation.effect.acquires, acquisition.expiry != nil,
        acquisition.setupWrites < 4
      else { throw VendorExecutionFailure.denied }
      if commit { acquisition.setupWrites += 1 }
    case "prompt", "mode":
      let oneShot =
        invocation.effect.acquires && kind == "prompt"
        && invocation.arguments["prompt"]?.stringValue != nil && acquisition.turn == nil
      guard oneShot || acquisition.turn == call, !acquisition.dispatched,
        kind == "prompt"
          ? (Self.isPrompt(invocation.effect) || invocation.effect.acquires)
          : invocation.effect == .mode
      else { throw VendorExecutionFailure.denied }
      guard !acquisition.stopRequested else { throw VendorExecutionFailure.queuedCancel }
      if commit {
        if oneShot { acquisition.turn = call }
        acquisition.dispatched = true
      }
    case "cancel":
      guard acquisition.turn != nil,
        invocation.effect == .stop
          ? acquisition.turn == invocation.targetTurn : acquisition.turn == call,
        acquisition.dispatched, acquisition.stopRequested, !acquisition.stopSent
      else { throw VendorExecutionFailure.stale }
      if commit { acquisition.stopSent = true }
    case "answer":
      guard invocation.effect == .answer, let turn = invocation.targetTurn,
        acquisition.turn == turn, !acquisition.stopRequested,
        let token,
        invocation.arguments[source.protocolKind.permissionArgument]?.stringValue == token,
        acquisition.pending.contains(token)
      else { throw VendorExecutionFailure.denied }
      if commit { acquisition.pending.remove(token) }
    case "housekeeping":
      guard ownsIO(invocation, id: call, acquisition: acquisition)
      else { throw VendorExecutionFailure.denied }
      if let token {
        guard acquisition.pending.contains(token) else { throw VendorExecutionFailure.stale }
        if commit { acquisition.pending.remove(token) }
      }
    case "close":
      guard acquisition.trae != nil, invocation.effect == .close, acquisition.closingCall == call,
        acquisition.turn == nil, acquisition.nativeCloseCall == nil
      else { throw VendorExecutionFailure.denied }
      if commit { acquisition.nativeCloseCall = call }
    default: throw VendorExecutionFailure.denied
    }
  }

  private func append(_ bytes: Data, to key: UUID) async -> Bool {
    guard let acquisition = acquisitions[key], !acquisition.retirementRequested else {
      return false
    }
    acquisition.trae?.observe(bytes)
    let chunks = bytes.isEmpty ? 0 : (bytes.count - 1) / Self.maximumChunkBytes + 1
    guard bytes.count + acquisition.outputBytes <= 2_097_152,
      acquisition.output.count + chunks <= 32
    else {
      await failOutput(key, failure: .outputFailed)
      return false
    }
    var offset = 0
    while offset < bytes.count {
      let end = min(bytes.count, offset + Self.maximumChunkBytes)
      acquisition.output.append(bytes.subdata(in: offset..<end))
      offset = end
    }
    acquisition.outputBytes += bytes.count
    return true
  }

  private func endOutput(_ key: UUID, exitCode: Int32?, signal: Int32?) {
    guard let acquisition = acquisitions[key], !acquisition.retirementRequested else { return }
    acquisition.exitCode = exitCode
    acquisition.exitSignal = signal
    acquisition.outputEnded = true
  }

  private func failOutput(_ key: UUID, failure: VendorExecutionFailure) async {
    guard let acquisition = acquisitions[key], !acquisition.retirementRequested,
      acquisition.outputFailure == nil
    else { return }
    acquisition.outputFailure = failure
    _ = await retire(key)
  }

  private func uuid(_ value: JSONValue?) -> UUID? {
    value?.stringValue.flatMap(UUID.init(uuidString:))
  }

  private func receipt(_ acquisition: Acquisition) -> [String: JSONValue] {
    let print = source.protocolKind == .claudePrint
    let mayReportExit =
      acquisition.workload.completed
      && (acquisition.outputEnded || acquisition.retired || acquisition.workloadProcess == nil)
    var result: [String: JSONValue] = [
      "probe": .string(acquisition.probe.id.uuidString.lowercased()),
      "workload": .string(acquisition.workload.id.uuidString.lowercased()),
      "probe_settled": .bool(acquisition.probe.completed),
      "workload_settled": .bool(print ? mayReportExit : acquisition.workload.completed),
      "probe_state": .string(acquisition.probe.receipt.rawValue),
      "workload_state": .string(acquisition.workload.receipt.rawValue),
      "retired": .bool(acquisition.retired),
    ]
    if print && mayReportExit {
      if let code = acquisition.exitCode { result["exit_code"] = .integer(Int64(code)) }
      if let signal = acquisition.exitSignal { result["exit_signal"] = .integer(Int64(signal)) }
    }
    if let failure = acquisition.outputFailure {
      result["output_error"] = .string(failure.rawValue)
    }
    return result
  }

  private func directory(_ execution: PreparedExecutionContext) throws -> SandboxPath {
    guard case .sandbox(let sandbox) = execution.mode else { throw VendorExecutionFailure.denied }
    return sandbox.worktree
  }

  private func phaseContext(_ acquisition: Acquisition, phase: VendorExecutionPhase) async throws
    -> PreparedExecutionContext
  {
    let parent = acquisition.execution
    guard let sandbox = parent.vendorSandbox else { throw VendorExecutionFailure.denied }
    let childSandbox = try await phase.configureEgress(sandbox)
    let source = source
    return PreparedExecutionContext(
      authority: phase, mode: .sandbox(childSandbox), environment: parent.environment,
      limits: parent.limits, reservedChildID: phase.id,
      validateProvider: {
        try phase.checkGateOpen()
        try source.verify()
        try source.verifyInterpreter(searchPath: parent.environment.searchPath)
        try parent.validateProviderLaunch()
      })
  }

  private func retire(_ id: UUID) async -> Bool {
    guard let acquisition = acquisitions[id] else { return false }
    if acquisition.retired { return true }
    if let existing = acquisition.retirement { return await existing.value }
    acquisition.retirementRequested = true
    acquisition.expiry?.cancel()
    acquisition.expiry = nil
    let probe = acquisition.probe
    let workload = acquisition.workload
    let process = acquisition.workloadProcess
    let version = acquisition.probeTask
    let retirement = Task { [weak self] in
      async let probeStop: Void? = try? probe.stop()
      async let workloadStop: Void? = try? workload.stop()
      async let close: Void? = process?.close()
      _ = await version?.value
      _ = await (probeStop, workloadStop, close)
      let probeConfirmed = await probe.awaitReceipt()
      let workloadConfirmed = await workload.awaitReceipt()
      let confirmed = probeConfirmed && workloadConfirmed
      let outcome = await process?.snapshot()
      await self?.finishRetirement(id, confirmed: confirmed, outcome: outcome)
      return confirmed
    }
    acquisition.retirement = retirement
    return await retirement.value
  }

  private func finishRetirement(
    _ id: UUID, confirmed: Bool, outcome: ManagedLineProcessSnapshot?
  ) {
    guard let acquisition = acquisitions[id] else { return }
    acquisition.retirement = nil
    if confirmed {
      if let outcome {
        acquisition.exitCode = outcome.exitCode
        acquisition.exitSignal = outcome.signal
      }
      acquisition.retired = true
      acquisition.outputTask?.cancel()
      acquisition.outputTask = nil
      acquisition.output.removeAll()
      acquisition.probeTask = nil
      acquisition.workloadProcess = nil
      acquisition.retiredTurn = acquisition.turn
      if let turn = acquisition.turn { rememberTurn(turn, acquisition: acquisition) }
      acquisition.turn = nil
      acquisition.outbound = nil
      for invocation in invocations.values where invocation.acquisition == id {
        try? invocation.detachedLease?.finish()
      }
    }
  }

  func close() async {
    closed = true
    await withDiscardingTaskGroup { group in
      for (id, acquisition) in acquisitions where !acquisition.retired {
        group.addTask { [self] in _ = await retire(id) }
      }
    }
  }

  private static func probe(
    _ context: PreparedExecutionContext, source: VendorExecutionSource, launcher: ExecutionLauncher,
    deadline: ContinuousClock.Instant
  ) async -> Bool {
    guard case .sandbox(let sandbox) = context.mode,
      let phase = context.authority as? VendorExecutionPhase
    else { return false }
    let output = Pipe()
    let data = VendorVersionOutput()
    var ownership: (any ExecutionOwnership)?
    do {
      let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
      let error = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
      defer {
        try? input.close()
        try? error.close()
      }
      let reader = try ProcessOutputReader(
        handle: output.fileHandleForReading, consume: { try await data.append($0) },
        onError: { _ in await data.fail() })
      reader.start()
      do {
        let owner = try await context.withValue {
          try await launcher.start(
            executable: source.executable, arguments: source.signature.probe,
            directory: sandbox.worktree,
            environment: context.environment, mode: context.mode,
            input: input.fileDescriptor, output: output.fileHandleForWriting.fileDescriptor,
            error: error.fileDescriptor)
        }
        ownership = owner
        try output.fileHandleForWriting.close()
        let outcome = try await owner.wait(until: deadline)
        await reader.stop(drainRemainingOutput: true)
        let matches = await data.matches(source.signature.versionStdout)
        let confirmed = await phase.awaitReceipt()
        return outcome.status == 0 && outcome.signal == nil && confirmed
          && phase.receipt == .retired && matches
      } catch {
        try? output.fileHandleForWriting.close()
        await reader.stop(drainRemainingOutput: false)
        throw error
      }
    } catch {
      _ = try? await ownership?.cancel()
      try? await phase.stop()
      return false
    }
  }
}

private actor VendorVersionOutput {
  private var bytes = Data()
  private var failed = false

  func append(_ data: Data) throws {
    guard bytes.count + data.count <= 65_536 else {
      failed = true
      throw VendorExecutionFailure.badVersion
    }
    bytes.append(data)
  }

  func fail() { failed = true }

  func matches(_ expected: String) -> Bool { !failed && bytes == Data(expected.utf8) }
}
