#if os(macOS)
  import ComputerMCPConfiguration
  import ComputerMCPCore
  import ComputerMCPPermissions
  import ComputerMCPPlatform
  import ComputerMCPPlugins
  import ComputerMCPSandbox
  import ComputerMCPTestSupport
  import ComputerMCPTransport
  import Crypto
  import Foundation
  import Testing

  @testable import ComputerMCPGateway
  @testable import ComputerMCPProcess

  @Suite(.nativeIntegration, .serialized, .timeLimit(.minutes(2)))
  struct VendorExecutionLifecycleTests {
    @Test func exactStopAndIndependentRetirementWithDeterministicPeer() async throws {
      let fixture = try Fixture()
      defer { fixture.base.remove() }
      let host = try VendorExecutionSession(
        source: fixture.vendor, launcher: fixture.base.platform.launcher)
      let transport = try MCPInheritedSocketTransport(
        takingOwnershipOf: host.providerChannel.takeEndpoint())
      try await transport.connect()
      var peer = Peer(transport: transport, replies: await transport.receive().makeAsyncIterator())
      do {
        let opening = try await fixture.prepare("open")
        if case .sandbox(let adapter) = opening.mode {
          #expect(!adapter.readableRoots.contains(fixture.vendor.executable))
        }
        #expect(opening.vendorSandbox?.readableRoots.contains(fixture.vendor.executable) == true)
        await #expect(throws: GatewayToolError.self) {
          try await host.admit(id: UUID(), tool: "open", arguments: [:], execution: opening)
        }
        let hello = try await peer.call(
          "initialize", ["capability": .string(VendorExecutionSource.capability)])
        #expect(hello["capability"] == .string(VendorExecutionSource.capability))

        let a = try await open("a", execution: opening, host: host, peer: &peer)
        let warm = try await fixture.prepare("open_async")
        let b = try await open("b", execution: warm, host: host, peer: &peer, detached: true)
        #expect(opening.executionID != warm.executionID && a.child != b.child)

        let interrupted = try await fixture.prepare("open")
        let openingID = UUID()
        try await host.admit(id: openingID, tool: "open", arguments: [:], execution: interrupted)
        var startup: [String: JSONValue] = [
          "call": .string(openingID.uuidString), "acquisition": .string(openingID.uuidString),
          "session": .string(String(repeating: "c", count: 32)),
        ]
        let reserved = try await peer.call("bind", startup)
        startup["child"] = try #require(reserved["probe"])
        _ = try await peer.call("probe", startup)
        await host.requestCancellation(openingID)
        startup["child"] = try #require(reserved["workload"])
        let stoppedStartup = try await peer.call("receipt", startup)
        #expect(stoppedStartup["probe_state"] == .string("retired"))
        #expect(stoppedStartup["workload_state"] == .string("never_dispatched"))
        #expect(try await peer.rejection("launch", startup) == "cancelled")
        await host.returned(openingID, confirmed: true)
        try interrupted.finishAdmission()
        #expect(try await peer.call("receipt", startup) == stoppedStartup)

        let prompt = try await admit("prompt", session: a, fixture: fixture, host: host)
        try await peer.write("wait", kind: "prompt", call: prompt, on: a)
        try await peer.expectOutput("begun\n", after: 0, call: prompt, on: a)

        let token = String(repeating: "a", count: 32)
        _ = try await peer.call(
          "pending", a.fields(prompt).merging(["token": .string(token)]) { _, new in new })
        let answer = try await admit(
          "answer", session: a, fixture: fixture, host: host, extra: ["request_id": .string(token)])
        let wrong = try await peer.rejection(
          "write",
          a.fields(answer).merging([
            "kind": .string("answer"), "token": .string(String(repeating: "b", count: 32)),
            "data": .string("answer"),
          ]) { _, new in new })
        #expect(wrong == "vendor_effect_denied")
        _ = try await peer.call(
          "write",
          a.fields(answer).merging([
            "kind": .string("answer"), "token": .string(token), "data": .string("answer"),
          ]) { _, new in new })
        try await peer.expectOutput("answer received\n", after: 1, call: prompt, on: a)
        #expect(
          try await peer.rejection(
            "write",
            a.fields(answer).merging([
              "kind": .string("answer"), "token": .string(token), "data": .string("answer"),
            ]) { _, new in new }) == "vendor_effect_denied")
        await host.returned(answer, confirmed: true)

        let nextToken = String(repeating: "c", count: 32)
        _ = try await peer.call(
          "pending", a.fields(prompt).merging(["token": .string(nextToken)]) { _, new in new })
        let lateAnswer = try await admit(
          "answer", session: a, fixture: fixture, host: host,
          extra: ["request_id": .string(nextToken)])
        let read = try await admit("list", session: a, fixture: fixture, host: host)
        #expect(
          try await peer.rejection(
            "write",
            a.fields(read).merging(["kind": .string("cancel"), "data": .string("cancel")]) {
              _, new in new
            }) == "vendor_effect_denied")
        let stop = try await admit("stop", session: a, fixture: fixture, host: host)
        let stopped = try await peer.call("stop", a.fields(stop))
        #expect(stopped["turn"] == .string(prompt.uuidString.lowercased()))
        #expect(
          try await peer.rejection(
            "write",
            a.fields(lateAnswer).merging([
              "kind": .string("answer"), "token": .string(nextToken), "data": .string("answer"),
            ]) { _, new in new }) == "vendor_effect_denied")
        await host.returned(lateAnswer, confirmed: true)
        try await peer.write("cancel", kind: "cancel", call: stop, on: a)
        try await peer.expectOutput("original:cancelled\n", after: 2, call: prompt, on: a)
        _ = try await peer.call("finish", a.fields(prompt))

        let ignored = try await admit("prompt", session: a, fixture: fixture, host: host)
        try await peer.write("ignore", kind: "prompt", call: ignored, on: a)
        try await peer.expectOutput("begun\n", after: 3, call: ignored, on: a)
        #expect(
          try await peer.rejection(
            "write",
            a.fields(stop).merging(["kind": .string("cancel"), "data": .string("cancel")]) {
              _, new in new
            }) == "vendor_effect_stale")
        await host.returned(stop, confirmed: true)
        let forced = try await admit("stop", session: a, fixture: fixture, host: host)
        _ = try await peer.call("stop", a.fields(forced))
        try await peer.write("cancel", kind: "cancel", call: forced, on: a)
        let retired = try await peer.call("retire", a.fields(ignored))
        #expect(retired["workload"] == .string(a.child.uuidString.lowercased()))
        #expect(retired["probe_state"] == .string("retired"))
        #expect(retired["workload_state"] == .string("retired"))
        #expect(retired["retired"] == .bool(true))
        #expect(try await peer.call("receipt", a.fields(ignored)) == retired)
        var wrongChild = a.fields(ignored)
        wrongChild["child"] = .string(b.child.uuidString)
        #expect(try await peer.rejection("receipt", wrongChild) == "vendor_effect_stale")

        let fresh = try await admit("prompt", session: b, fixture: fixture, host: host)
        let outbound = Data(("finish:" + String(repeating: "x", count: 1_048_568)).utf8)
        let frame = UUID()
        for offset in stride(from: 0, to: outbound.count, by: 196_608) {
          let end = min(offset + 196_608, outbound.count)
          _ = try await peer.call(
            "write",
            b.fields(fresh).merging([
              "kind": .string("prompt"), "frame": .string(frame.uuidString),
              "offset": .integer(Int64(offset)), "final": .bool(end == outbound.count),
              "data": .string(outbound.subdata(in: offset..<end).base64EncodedString()),
            ]) { _, new in new })
        }
        try await peer.expectOutput("done:1048575\n", after: 0, call: fresh, on: b)
        _ = try await peer.call("finish", b.fields(fresh))
        await transport.disconnect()
        for await _ in host.termination {}
        #expect(await host.shutdownConfirmed())
        try await fixture.cleanup()
      } catch {
        await transport.disconnect()
        await host.close()
        try? await fixture.cleanup()
        throw error
      }
    }

    @Test func selectedDependencyAndPackageFilesAreSourceBound() throws {
      let fixture = try Fixture()
      defer { fixture.base.remove() }
      #expect(fixture.vendor.executable == (try SandboxPath(fixture.executable.path)))
      try Data("changed encoder".utf8).write(to: fixture.adapter)
      #expect(throws: (any Error).self) { try fixture.vendor.verify() }
    }

    @Test func printReceivesEOFAndReportsNativeExitForItsOwnChild() async throws {
      let fixture = try Fixture(claudePrint: true)
      defer { fixture.base.remove() }
      let host = try VendorExecutionSession(
        source: fixture.vendor, launcher: fixture.base.platform.launcher)
      let transport = try MCPInheritedSocketTransport(
        takingOwnershipOf: host.providerChannel.takeEndpoint())
      try await transport.connect()
      var peer = Peer(transport: transport, replies: await transport.receive().makeAsyncIterator())
      do {
        _ = try await peer.call(
          "initialize", ["capability": .string(VendorExecutionSource.capability)])
        let execution = try await fixture.prepare("claude.run")
        let run = UUID()
        try await host.admit(
          id: run, tool: "claude.run", arguments: ["prompt": .string("--text")],
          execution: execution)
        let handle = String(repeating: "d", count: 32)
        let binding = try await peer.call(
          "bind",
          [
            "call": .string(run.uuidString), "acquisition": .string(run.uuidString),
            "session": .string(handle),
          ])
        let probe = try #require(binding["probe"]?.stringValue)
        let child = try #require(binding["workload"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let work = Workload(acquisition: run, child: child, handle: handle)
        var probeFields = work.fields(run)
        probeFields["child"] = .string(probe)
        _ = try await peer.call("probe", probeFields)
        let supplied = work.fields(run).merging(["argv": .array([.string("--unexpected")])]) {
          _, new in new
        }
        #expect(try await peer.rejection("launch", supplied) == "vendor_effect_denied")
        _ = try await peer.call("launch", work.fields(run))
        let output = work.fields(run)
        let write = output.merging(["kind": .string("setup"), "data": .string("unsafe")]) {
          _, new in new
        }
        #expect(try await peer.rejection("write", write) == "vendor_effect_denied")
        #expect(try await peer.rejection("ready", output) == "vendor_effect_denied")
        try await peer.expectOutput("received prompt after EOF\n", after: 0, call: run, on: work)
        var end = output
        end["after"] = .integer(1)
        let deadline = ContinuousClock.now + .seconds(5)
        while try await peer.call("read", end)["eof"] != .bool(true) {
          try #require(ContinuousClock.now < deadline)
        }
        var receipt = try await peer.call("receipt", output)
        while receipt["workload_settled"] != .bool(true) {
          try #require(ContinuousClock.now < deadline)
          try await Task.sleep(for: .milliseconds(20))
          receipt = try await peer.call("receipt", output)
        }
        #expect(receipt["exit_code"] == .integer(23))
        #expect(receipt["exit_signal"] == nil)
        let close = UUID()
        let closing = try await fixture.prepare("claude.run.cancel")
        try await host.admit(
          id: close, tool: "claude.run.cancel", arguments: ["run_id": .string(handle)],
          execution: closing)
        let retired = try await peer.call("retire", work.fields(close))
        #expect(retired["retired"] == .bool(true))
        #expect(retired["exit_code"] == receipt["exit_code"])
        await host.returned(close, confirmed: true)
        await host.returned(run, confirmed: true)
        await transport.disconnect()
        for await _ in host.termination {}
        #expect(await host.shutdownConfirmed())
        try await fixture.cleanup()
      } catch {
        await transport.disconnect()
        await host.close()
        try? await fixture.cleanup()
        throw error
      }
    }

    private func open(
      _ character: String, execution: PreparedExecutionContext, host: VendorExecutionSession,
      peer: inout Peer, detached: Bool = false
    ) async throws -> Workload {
      let call = UUID()
      try await host.admit(
        id: call, tool: detached ? "open_async" : "open", arguments: [:], execution: execution)
      if detached {
        _ = try await peer.call(
          "detach",
          [
            "call": .string(call.uuidString), "acquisition": .string(call.uuidString),
          ])
        await host.returned(call, confirmed: true)
        try execution.finishAdmission()
      }
      let handle = String(repeating: character, count: 32)
      let bind = try await peer.call(
        "bind",
        [
          "call": .string(call.uuidString), "acquisition": .string(call.uuidString),
          "session": .string(handle),
        ])
      let probe = try #require(bind["probe"]?.stringValue)
      let child = try #require(bind["workload"]?.stringValue.flatMap(UUID.init(uuidString:)))
      let workload = Workload(acquisition: call, child: child, handle: handle)
      var check = workload.fields(call)
      check["child"] = .string(probe)
      let verified = try await peer.call("probe", check)
      #expect(verified["probe_state"] == .string("retired"))
      _ = try await peer.call("launch", workload.fields(call))
      #expect(try await peer.rejection("launch", workload.fields(call)) == "vendor_effect_denied")
      for _ in 0..<3 { try await peer.write("setup", kind: "setup", call: call, on: workload) }
      _ = try await peer.call("ready", workload.fields(call))
      if detached {
        _ = try await peer.call("finish", workload.fields(call))
      } else {
        await host.returned(call, confirmed: true)
        try execution.finishAdmission()
      }
      return workload
    }

    private func admit(
      _ tool: String, session: Workload, fixture: Fixture, host: VendorExecutionSession,
      extra: [String: JSONValue] = [:]
    ) async throws -> UUID {
      let execution = try await fixture.prepare(tool)
      let id = UUID()
      try await host.admit(
        id: id, tool: tool,
        arguments: extra.merging(["session": .string(session.handle)]) {
          _, new in new
        }, execution: execution)
      return id
    }

    private struct Workload {
      let acquisition: UUID
      let child: UUID
      let handle: String

      func fields(_ call: UUID) -> [String: JSONValue] {
        [
          "call": .string(call.uuidString), "acquisition": .string(acquisition.uuidString),
          "child": .string(child.uuidString),
        ]
      }
    }

    private struct Peer {
      let transport: MCPInheritedSocketTransport
      var replies: AsyncThrowingStream<Data, any Error>.Iterator
      var nextID: Int64 = 0

      mutating func exchange(_ op: String, _ fields: [String: JSONValue]) async throws
        -> [String: JSONValue]
      {
        nextID += 1
        var request = fields
        request["id"] = .integer(nextID)
        request["op"] = .string(op)
        try await transport.send(JSONEncoder().encode(JSONValue.object(request)))
        let bytes = try #require(try await replies.next())
        let response = try #require(JSONDecoder().decode(JSONValue.self, from: bytes).objectValue)
        try #require(response["id"] == .integer(nextID))
        return response
      }

      mutating func call(_ op: String, _ fields: [String: JSONValue]) async throws
        -> [String: JSONValue]
      {
        let response = try await exchange(op, fields)
        return try #require(response["result"]?.objectValue, "\(op) \(response)")
      }

      mutating func rejection(_ op: String, _ fields: [String: JSONValue]) async throws -> String {
        let response = try await exchange(op, fields)
        return try #require(response["error"]?.stringValue, "\(op) \(response)")
      }

      mutating func write(_ line: String, kind: String, call: UUID, on work: Workload) async throws
      {
        _ = try await self.call(
          "write",
          work.fields(call).merging(["kind": .string(kind), "data": .string(line)]) {
            _, new in new
          })
      }

      mutating func expectOutput(
        _ expected: String, after: Int64, call: UUID, on work: Workload
      ) async throws {
        var fields = work.fields(call)
        fields["after"] = .integer(after)
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
          let result = try await self.call("read", fields)
          if let encoded = result["data"]?.stringValue {
            #expect(Data(base64Encoded: encoded) == Data(expected.utf8))
            #expect(result["cursor"] == .integer(after + 1))
            return
          }
          try #require(result["eof"] == .bool(false))
        }
        Issue.record("The deterministic peer did not return \(expected)")
      }
    }

    private final class Fixture {
      let base: WorktreeServiceFixture
      let adapter: URL
      let executable: URL
      let source: GatewayProviderSource
      let vendor: VendorExecutionSource
      let pluginID: String
      private var preparations: [PreparedExecutionContext] = []

      init(claudePrint: Bool = false) throws {
        let base = try WorktreeServiceFixture()
        self.base = base
        let root = base.root.appendingPathComponent("package")
        let tools = base.root.appendingPathComponent("tools")
        for url in [root, tools] {
          try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        adapter = root.appendingPathComponent("adapter")
        executable = tools.appendingPathComponent("vendor-peer")
        try writePythonTestExecutable("pass", to: adapter)
        pluginID = claudePrint ? "claude" : "vendor-fixture"
        let component = claudePrint ? "stream" : "acp"
        let dependency = claudePrint ? "claude-code" : "peer"
        let printPeer = #"""
          #!/bin/sh
          if [ "$#" -eq 1 ] && [ "$1" = --version ]; then
            printf 'deterministic print peer\n'
            exit 0
          fi
          if IFS= read -r unexpected; then exit 91; fi
          [ "$#" -eq 9 ] && [ "$1" = -p ] && [ "$7" = dontAsk ] &&
            [ "$8" = -- ] && [ "$9" = --text ] || exit 92
          printf 'received prompt after EOF\n'
          exit 23
          """#
        let acpPeer = #"""
          #!/bin/sh
          if [ "$#" -eq 1 ] && [ "$1" = --version ]; then
            printf 'ordinary-peer-1\n'
            exit 0
          fi
          [ "$#" -eq 1 ] && [ "$1" = acp ] || exit 1
          active=
          while IFS= read -r line; do
            case "$line" in
              wait|ignore) active=$line; printf 'begun\n' ;;
              cancel)
                if [ "$active" = wait ]; then
                  active=
                  printf 'original:cancelled\n'
                fi ;;
              answer) printf 'answer received\n' ;;
              finish:*) printf 'done:%s\n' "${#line}" ;;
            esac
          done
          """#
        try (claudePrint ? printPeer : acpPeer).write(
          to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let signature = root.appendingPathComponent("signature.json")
        let acpSignature = #"""
          {"capability":"io.github.computer-mcp/vendor-execution-v1","dependency":"peer",
           "tools":{"open":"acquire","open_async":"detached_acquire","prompt":"prompt","stop":"stop","answer":"answer","list":"observe"},
           "probe":["--version"],"workload":["acp"],"version_stdout":"ordinary-peer-1\n"}
          """#
        let printSignature = #"""
          {"capability":"io.github.computer-mcp/vendor-execution-v1","dependency":"claude-code",
           "tools":{"claude.run":"acquire","claude.run.start":"detached_acquire","claude.run.cancel":"close"},
           "probe":["--version"],"workload":\#(ClaudePrintRecipeTests.recipe),
           "version_stdout":"deterministic print peer\n"}
          """#
        try Data((claudePrint ? printSignature : acpSignature).utf8).write(to: signature)
        func digest(_ file: URL) throws -> String {
          SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        }
        try """
        id = '\(pluginID)'
        name = 'Deterministic vendor fixture'
        version = '1.0.0'
        plugin_api = 1
        [[permissions]]
        id = 'project'
        access = 'read'
        purpose = 'Read the test project.'
        [[dependencies]]
        id = '\(dependency)'
        commands = ['vendor-peer']
        instructions = 'Use the deterministic peer.'
        [[mcp]]
        id = '\(component)'
        transport = 'stdio'
        executable = { path = 'adapter' }
        requirements = { project = 'read' }
        vendor_execution = { dependency = '\(dependency)', signature = 'signature.json', files = { adapter = '\(digest(adapter))', 'signature.json' = '\(digest(signature))' } }
        """.write(
          to: root.appendingPathComponent(PluginManifest.filename), atomically: true,
          encoding: .utf8)
        let package = try PluginPackage.load(at: root)
        var state = try base.database.pluginStoreSnapshot()
        let installed = PluginInstallationRecord(
          id: UUID().uuidString, pluginID: package.manifest.id, version: package.manifest.version,
          source: .init(kind: .artifact, root: package.root, artifactSHA256: try digest(signature)),
          manifestDigest: try PluginStore.manifestDigest(package.manifest),
          declarations: PluginPermissionDeclarations(package.manifest), registeredAt: .now)
        state.installations.append(installed)
        state.selectedInstallations[installed.pluginID] = installed.id
        state.settings[installed.pluginID] = .init(
          enabled: true, mcp: [component: .init(enabled: true)])
        let revision = state.revision
        state.revision += 1
        _ = try base.database.savePluginStoreSnapshot(state, expectedRevision: revision)
        let resolved = try PluginStore.resolve(
          snapshot: state, bundled: [], hostVersion: .init("1.0.0"),
          architecture: PluginHost.architecture, searchDirectories: [tools],
          applications: TestApplicationBundleLocator())
        let composition = try GatewayPluginComposition(
          configuration: GatewayConfiguration(), plugins: resolved.plugins)
        let server = try #require(composition.runtimeConfiguration.mcp.servers.first)
        let owner = try GatewayPermissionOwner(
          context: .init(caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "owner"),
          validate: {})
        let view = try base.runtime.service.view(owner: owner)
        let review = try GatewayProviderReview(
          package: package, configuration: base.database.configurationState())
        var providerGrants = Permissions.newPrincipal
        try providerGrants.set(.granted(.read), for: .project("source"))
        _ = try base.runtime.service.approveProvider(
          review, permissions: providerGrants, fullAccess: false, owner: owner,
          expectedProviderRevision: nil, expectedRevision: view.revision,
          expectedEpoch: #require(view.epoch))
        source = try GatewayProviderSource.resolve(
          registration: .init(kind: .mcp, id: server.id),
          configuration: composition.runtimeConfiguration,
          origins: composition.origins, database: base.database)
        vendor = try #require(source.vendorExecution)
      }

      func prepare(_ tool: String) async throws -> PreparedExecutionContext {
        let caller = try base.runtime.store.transactionWithDatabase { _, ledger in
          let principal = Principal.client("vendor-fixture")
          let permission = Permission.plugin(pluginID)
          if ledger.permissions(for: principal).state(for: permission) != .granted(.use) {
            var grants = Permissions.newPrincipal
            try grants.set(.granted(.use), for: permission)
            try grants.set(.granted(.read), for: .project("source"))
            try ledger.setPermissions(grants, for: principal, expectedRevision: ledger.revision)
          }
          let decision = try ledger.authorize(
            invocation: .init(
              principal: principal, tool: tool, projectID: "source",
              argumentsDigest: UUID().uuidString),
            requirements: .init(
              actions: [
                .init(requirement: .init(permission, .use)),
                .init(requirement: .init(.project("source"), .read), scope: .project("source")),
              ], sandboxProjectID: "source"),
            now: Date())
          guard case .allowed(let authorization) = decision else {
            throw PermissionModelError.invalidAuthorization
          }
          return authorization
        }
        let execution = try await base.runtime.prepareProvider(
          review: source.review, registrationID: source.registrationID, authorization: caller,
          directory: base.source, connectionID: nil, source: source)
        preparations.append(execution)
        return execution
      }

      func cleanup() async throws {
        for execution in preparations { try execution.finishAdmission() }
        try await base.runtime.coordinator.stopExecutions(Set(preparations.map(\.executionID)))
      }
    }
  }
#endif
