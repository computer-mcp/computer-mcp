#if os(macOS)
  import ComputerMCPConfiguration
  import ComputerMCPCore
  import ComputerMCPPermissions
  import ComputerMCPPlugins
  import ComputerMCPPlatform
  import ComputerMCPPlatformPOSIX
  @testable import ComputerMCPProcess
  import ComputerMCPTestSupport
  import Foundation
  import Testing

  @testable import ComputerMCPGateway

  @Suite(.nativeIntegration, .serialized, .timeLimit(.minutes(2)))
  struct GatewayProviderLifecycleTests {
    @Test(arguments: [false, true], [false, true])
    func readExceptionIdentityIsRecheckedAfterPreparation(
      projectOverride: Bool, replaceTarget: Bool
    ) async throws {
      let f = try WorktreeServiceFixture()
      defer { f.remove() }
      let defaultTarget = f.root.appendingPathComponent("default-config")
      let target = projectOverride ? f.root.appendingPathComponent("project-config") : defaultTarget
      for file in Set([defaultTarget, target]) { try Data("approved".utf8).write(to: file) }
      let defaultException = try GatewayProviderReadExceptions.resolve(
        declaredPath: "~/fixture-config", purpose: "Read provider configuration",
        replacement: .init(defaultTarget.path))
      let selectedException = try GatewayProviderReadExceptions.resolve(
        declaredPath: "~/fixture-config", purpose: "Read provider configuration",
        replacement: .init(target.path))
      let worktree =
        try projectOverride ? f.call(.add(name: "exception", branch: nil, base: nil)) : nil
      let projectID = worktree?.objectValue?["project_id"]?.stringValue
      let worktreeDirectory = worktree?.objectValue?["path"]?.stringValue
      let server = MCPServerConfig(id: "read-exception", transport: .stdio, command: "/bin/cat")
      let owner = try GatewayPermissionOwner(
        context: .init(caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "owner"),
        validate: {})
      let view = try f.runtime.service.view(owner: owner)
      let review = try GatewayProviderReview(
        server: server, configuration: f.database.configurationState())
      var permissions = Permissions.newPrincipal
      try permissions.set(.granted(.write), for: .project("source"))
      _ = try f.runtime.service.approveProvider(
        review, permissions: permissions, fullAccess: false,
        sandboxSettings: .init(
          defaults: .init(readExceptions: [defaultException]),
          projects: projectOverride ? ["source": .init(readExceptions: [selectedException])] : [:]),
        owner: owner,
        expectedProviderRevision: nil, expectedRevision: view.revision,
        expectedEpoch: #require(view.epoch))
      let current = try GatewayProviderReview(
        server: server, configuration: f.database.configurationState())
      let proof: InvocationAuthorization? = try projectID.map { projectID in
        try f.runtime.store.transactionWithDatabase { _, ledger in
          let principal = Principal.client("read-exception")
          var grants = permissions
          try grants.set(.granted(.all), for: .mcpServer(server.id))
          _ = try ledger.setPermissions(grants, for: principal, expectedRevision: ledger.revision)
          let decision = try ledger.authorize(
            invocation: .init(
              principal: principal, tool: "read-config", projectID: projectID,
              argumentsDigest: "config"),
            requirements: .init(
              actions: [
                .init(requirement: .init(.mcpServer(server.id), .all)),
                .init(requirement: .init(.project("source"), .write), scope: .project("source")),
              ], sandboxProjectID: "source"), now: Date())
          guard case .allowed(let proof) = decision else {
            throw PermissionModelError.invalidAuthorization
          }
          return proof
        }
      }
      let prepared = try await f.runtime.prepareProvider(
        review: current, registrationID: server.id, authorization: proof,
        directory: worktreeDirectory.map { URL(fileURLWithPath: $0) }, connectionID: nil)
      if projectOverride {
        // An overridden default is not part of this launch's compiled opening.
        try Data("unused replacement".utf8).write(to: defaultTarget, options: .atomic)
      }
      if replaceTarget { try Data("replacement".utf8).write(to: target, options: .atomic) }
      let directory = URL(fileURLWithPath: try #require(prepared.providerWorkingDirectory).value)
      let run = {
        try prepared.withValue {
          try ProcessCommandRunner(launcher: f.platform.launcher).run(
            executable: "/bin/cat", arguments: [target.path],
            workingDirectory: directory,
            environment: [:], timeoutMilliseconds: 2000, maxOutputBytes: 1024)
        }
      }
      do {
        if replaceTarget {
          #expect(throws: (any Error).self) { try run() }
        } else {
          let result = try run()
          #expect(result.exitCode == 0 && result.stdout == "approved")
        }
        try prepared.finishAdmission()
        try await f.runtime.coordinator.stopExecutions([prepared.executionID])
      } catch {
        try? prepared.finishAdmission()
        try? await f.runtime.coordinator.stopExecutions([prepared.executionID])
        throw error
      }
    }

    @Test func discoveryResolvesItsCommandFromTheRegistrationAndRunsInPrivateScratch()
      async throws
    {
      let f = try WorktreeServiceFixture()
      defer { f.remove() }
      let container = try f.database.prepareProviderContainer(.localServer("relative"))
      let registrationDirectory = URL(fileURLWithPath: try container.sandbox.home.value)
      let marker = f.source.appendingPathComponent("discovery-write")
      try writePythonTestExecutable(
        #"""
        import json, os, sys
        if not os.path.samefile(os.getcwd(), os.environ["TMPDIR"]): sys.exit(11)
        try:
            with open(sys.argv[1], "w") as file: file.write("forbidden")
            sys.exit(12)
        except PermissionError:
            pass
        with open(os.path.join(os.environ["HOME"], "discovery-cwd"), "w") as file:
            file.write(os.getcwd())
        for line in sys.stdin:
            message = json.loads(line)
            if "id" not in message: continue
            if message["method"] == "initialize":
                result = {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}}, "serverInfo": {"name": "relative", "version": "1"}}
            elif message["method"] == "tools/list":
                result = {"tools": [{"name": "discovered", "inputSchema": {"type": "object"}}]}
            else:
                result = {}
            print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}), flush=True)
        """#, to: registrationDirectory.appendingPathComponent("provider.py"))
      // The relative command resolves against the registration directory, while
      // projectless discovery runs in its compiled private scratch.
      let server = MCPServerConfig(
        id: "relative", transport: .stdio, command: "./provider.py", args: [marker.path],
        startupTimeoutMs: 5000, requestTimeoutMs: 5000)
      let review = try GatewayProviderReview(
        server: server, configuration: f.database.configurationState())
      let owner = try GatewayPermissionOwner(
        context: .init(caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "owner"),
        validate: {})
      let view = try f.runtime.service.view(owner: owner)
      _ = try f.runtime.service.approveProvider(
        review, permissions: .newPrincipal, fullAccess: false, owner: owner,
        expectedProviderRevision: nil, expectedRevision: view.revision,
        expectedEpoch: #require(view.epoch))
      let prepared = try await f.runtime.prepareProvider(
        review: review, registrationID: server.id, authorization: nil, directory: nil,
        connectionID: nil)
      var host = MCPHostContext(
        runtimeID: UUID(), context: .init(caller: .localMCP, profileID: .localAdmin),
        projectID: "source", rootURL: f.source, readOnly: true,
        processOwnershipRoot: f.root.appendingPathComponent("ownership"))
      host.providerSource = { _ in
        .init(digest: review.sourceDigest, prepareDiscovery: { prepared })
      }
      let client = MCPProxyClient(
        launcher: f.platform.launcher, workingDirectory: registrationDirectory, hostContext: host)
      do {
        let tools = try await BlockingOperationExecutor(label: "relative-provider-discovery")
          .perform { try client.listTools(server: server, context: .empty) }
        #expect(tools.map(\.name) == ["discovered"])
        let scratch = try #require(prepared.providerWorkingDirectory).value
        let recorded = try String(
          contentsOf: registrationDirectory.appendingPathComponent("discovery-cwd"),
          encoding: .utf8)
        #expect(recorded == scratch && recorded != registrationDirectory.path)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        await client.shutdown()
        try prepared.finishAdmission()
        try await f.runtime.coordinator.stopExecutions([prepared.executionID])
      } catch {
        await client.shutdown()
        try? prepared.finishAdmission()
        try? await f.runtime.coordinator.stopExecutions([prepared.executionID])
        throw error
      }
    }

    @Test func pluginDependencyExecutableIsVerifiedReadableAndLaunched() async throws {
      let f = try WorktreeServiceFixture()
      defer { f.remove() }
      let packageRoot = f.root.appendingPathComponent("dependency-plugin")
      try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: false)
      try """
      id = 'dependency-plugin'
      name = 'Dependency fixture'
      version = '1.0.0'
      plugin_api = 1
      [[dependencies]]
      id = 'vendor'
      commands = ['vendor-mcp']
      instructions = 'Use the fixture vendor.'
      [[mcp]]
      id = 'server'
      transport = 'stdio'
      executable = { dependency = 'vendor' }
      """.write(
        to: packageRoot.appendingPathComponent(PluginManifest.filename), atomically: true,
        encoding: .utf8)
      // Outside the package and the system read roots, as an installed vendor tool is.
      let vendorDirectory = f.root.appendingPathComponent("vendor")
      try FileManager.default.createDirectory(
        at: vendorDirectory, withIntermediateDirectories: false)
      let vendor = vendorDirectory.appendingPathComponent("vendor-mcp")
      try writePythonTestExecutable(Self.responder(tool: "vendor"), to: vendor)
      let package = try PluginPackage.load(at: packageRoot)
      let plugin = try PluginResolver.resolve(
        package: package, source: .init(kind: .development, root: packageRoot),
        settings: .init(enabled: true), dependencyExecutables: ["vendor": vendor],
        hostVersion: PluginVersion("1.0.0"), architecture: PluginHost.architecture)
      let composition = try GatewayPluginComposition(
        configuration: GatewayConfiguration(), plugins: [plugin])
      let server = try #require(composition.runtimeConfiguration.mcp.servers.first)
      let owner = try GatewayPermissionOwner(
        context: .init(caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "owner"),
        validate: {})
      let view = try f.runtime.service.view(owner: owner)
      _ = try f.runtime.service.approveProvider(
        GatewayProviderReview(package: package, configuration: f.database.configurationState()),
        permissions: .newPrincipal, fullAccess: false, owner: owner,
        expectedProviderRevision: nil, expectedRevision: view.revision,
        expectedEpoch: #require(view.epoch))
      let source = try GatewayProviderSource.resolve(
        registration: .init(kind: .mcp, id: server.id),
        configuration: composition.runtimeConfiguration, origins: composition.origins,
        database: f.database)
      let prepared = try await f.runtime.prepareProvider(
        review: source.review, registrationID: server.id, authorization: nil, directory: nil,
        connectionID: nil, source: source)
      let client = Self.client(f, prepared: prepared, digest: source.review.sourceDigest)
      do {
        let tools = try await BlockingOperationExecutor(label: "dependency-provider-discovery")
          .perform { try client.listTools(server: server, context: .empty) }
        #expect(tools.map(\.name) == ["vendor"])
        await client.shutdown()
        // A replaced dependency fails the launch recheck rather than running.
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: vendor, options: .atomic)
        #expect(throws: (any Error).self) { try prepared.validateProviderLaunch() }
        try prepared.finishAdmission()
        try await f.runtime.coordinator.stopExecutions([prepared.executionID])
      } catch {
        await client.shutdown()
        try? prepared.finishAdmission()
        try? await f.runtime.coordinator.stopExecutions([prepared.executionID])
        throw error
      }
    }

    @Test func localServerLaunchesTheExecutableItsSourceVerified() async throws {
      let f = try WorktreeServiceFixture()
      defer { f.remove() }
      var executables: [String: URL] = [:]
      for name in ["verified", "other"] {
        let directory = f.root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try writePythonTestExecutable(
          Self.responder(tool: name), to: directory.appendingPathComponent("provider-tool"))
        executables[name] = directory
      }
      // The source resolves the relative command from its configuration; the client's
      // own base would find a different file.
      var configuration = GatewayConfiguration()
      configuration.projectDirectory = try #require(executables["verified"])
      let server = MCPServerConfig(
        id: "verified-path", transport: .stdio, command: "./provider-tool",
        startupTimeoutMs: 5000, requestTimeoutMs: 5000)
      configuration.mcp.servers = [server]
      let review = try GatewayProviderReview(
        server: server, configuration: f.database.configurationState())
      let owner = try GatewayPermissionOwner(
        context: .init(caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "owner"),
        validate: {})
      let view = try f.runtime.service.view(owner: owner)
      _ = try f.runtime.service.approveProvider(
        review, permissions: .newPrincipal, fullAccess: false, owner: owner,
        expectedProviderRevision: nil, expectedRevision: view.revision,
        expectedEpoch: #require(view.epoch))
      let source = try GatewayProviderSource.resolve(
        registration: .init(kind: .mcp, id: server.id), configuration: configuration,
        origins: [:], database: f.database)
      let prepared = try await f.runtime.prepareProvider(
        review: source.review, registrationID: server.id, authorization: nil, directory: nil,
        connectionID: nil, source: source)
      let client = Self.client(
        f, prepared: prepared, digest: review.sourceDigest,
        workingDirectory: try #require(executables["other"]))
      do {
        let tools = try await BlockingOperationExecutor(label: "verified-provider-discovery")
          .perform { try client.listTools(server: server, context: .empty) }
        #expect(tools.map(\.name) == ["verified"])
        await client.shutdown()
        try prepared.finishAdmission()
        try await f.runtime.coordinator.stopExecutions([prepared.executionID])
      } catch {
        await client.shutdown()
        try? prepared.finishAdmission()
        try? await f.runtime.coordinator.stopExecutions([prepared.executionID])
        throw error
      }
    }

    private static func client(
      _ f: WorktreeServiceFixture, prepared: PreparedExecutionContext, digest: String,
      workingDirectory: URL? = nil
    ) -> MCPProxyClient {
      var host = MCPHostContext(
        runtimeID: UUID(), context: .init(caller: .localMCP, profileID: .localAdmin),
        projectID: "source", rootURL: f.source, readOnly: true,
        processOwnershipRoot: f.root.appendingPathComponent("ownership"))
      host.providerSource = { _ in .init(digest: digest, prepareDiscovery: { prepared }) }
      return MCPProxyClient(
        launcher: f.platform.launcher, workingDirectory: workingDirectory ?? f.root,
        hostContext: host)
    }

    private static func responder(tool: String) -> String {
      #"""
      import json, sys
      for line in sys.stdin:
          message = json.loads(line)
          if "id" not in message: continue
          if message["method"] == "initialize":
              result = {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}}, "serverInfo": {"name": "fixture", "version": "1"}}
          elif message["method"] == "tools/list":
              result = {"tools": [{"name": "TOOL", "inputSchema": {"type": "object"}}]}
          else:
              result = {}
          print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}), flush=True)
      """#.replacingOccurrences(of: "TOOL", with: tool)
    }

    @Test(arguments: [false, true])
    func projectBoundariesAndIndependentDelegatedRevocation(fullAccess: Bool) async throws {
      let f = try WorktreeServiceFixture()
      defer { f.remove() }
      let first = try f.call(.add(name: "provider-a", branch: nil, base: nil))
      let second = try f.call(.add(name: "provider-b", branch: nil, base: nil))
      let projectID = try #require(first.objectValue?["project_id"]?.stringValue)
      let directory = try ProjectPathResolver.canonicalProject(
        URL(fileURLWithPath: #require(first.objectValue?["path"]?.stringValue)))
      let other = try #require(second.objectValue?["path"]?.stringValue)
      let foreign = try f.database.prepareProviderContainer(.package("foreign"))
      let foreignFile = URL(fileURLWithPath: try foreign.sandbox.state.value)
        .appendingPathComponent("secret")
      try Data("foreign state".utf8).write(to: foreignFile)
      let binary = try compileProviderProbe(in: f.root)
      let server = MCPServerConfig(id: "local-provider", transport: .stdio, command: binary.path)
      let owner = try GatewayPermissionOwner(
        context: .init(caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "owner"),
        validate: {})
      let review = try GatewayProviderReview(
        server: server, configuration: f.database.configurationState())
      var permissions = Permissions.newPrincipal
      try permissions.set(.granted(.write), for: .project("source"))
      let view = try f.runtime.service.view(owner: owner)
      let approval = try f.runtime.service.approveProvider(
        review, permissions: permissions, fullAccess: fullAccess, owner: owner,
        expectedProviderRevision: nil, expectedRevision: view.revision,
        expectedEpoch: #require(view.epoch))
      let currentReview = try GatewayProviderReview(
        server: server, configuration: f.database.configurationState())
      let clients = [Principal.client("a"), .client("b")]
      var prepared: [PreparedExecutionContext] = []
      var processes: [ManagedLineProcess] = []
      do {
        for client in clients {
          let proof = try f.runtime.store.transactionWithDatabase { _, ledger in
            var grants = permissions
            try grants.set(.granted(.all), for: .mcpServer(server.id))
            try ledger.setPermissions(grants, for: client, expectedRevision: ledger.revision)
            if fullAccess {
              var environment = ledger.environment
              environment.modes[client] = ledger.consent(for: client, mode: .fullAccess(.standing))
              try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
            }
            let result = try ledger.authorize(
              invocation: .init(
                principal: client, tool: "probe", projectID: projectID,
                argumentsDigest: UUID().uuidString),
              requirements: .init(
                actions: [
                  .init(requirement: .init(.mcpServer(server.id), .all)),
                  .init(requirement: .init(.project("source"), .write), scope: .project("source")),
                ], paths: [.init(path: .init(directory.path), operation: .write)],
                mode: fullAccess ? .fullAccess(.standing) : .sandbox,
                sandboxProjectID: "source"), now: Date())
            guard case .allowed(let authorization) = result else {
              Issue.record("Caller preparation failed: \(result)")
              throw PermissionModelError.invalidAuthorization
            }
            return authorization
          }
          let execution = try await f.runtime.prepareProvider(
            review: currentReview, registrationID: server.id, authorization: proof,
            directory: directory, connectionID: nil)
          prepared.append(execution)
          let process = try execution.withValue {
            try ManagedLineProcess(
              launcher: f.platform.launcher,
              configuration: .init(
                executable: binary.path,
                arguments: [
                  other, f.source.path, f.root.appendingPathComponent("host/state.sqlite").path,
                  foreignFile.path, fullAccess ? "full" : "sandbox",
                ],
                workingDirectory: directory))
          }
          processes.append(process)
          var lines = process.inboundLines.makeAsyncIterator()
          #expect(try await lines.next() == "boundaries verified")
          try execution.finishAdmission()
        }
        #expect(prepared[0].executionID != prepared[1].executionID)
        if case .sandbox(let a) = prepared[0].mode,
          case .sandbox(let b) = prepared[1].mode
        {
          #expect(a.homeDirectory == b.homeDirectory)
          #expect(a.temporaryDirectory != b.temporaryDirectory)
        } else {
          #expect(fullAccess)
          for (execution, process) in zip(prepared, processes) {
            guard case .fullAccess = execution.mode else {
              Issue.record("Provider Full access mode was lost")
              continue
            }
            #expect(await process.snapshot().supervisorProcessID == nil)
          }
        }
        try f.runtime.store.transactionWithDatabase { _, ledger in
          _ = try ledger.setPermission(
            .notGranted, for: .mcpServer(server.id), principal: clients[0],
            expectedRevision: ledger.revision)
        }
        try await f.runtime.coordinator.reconcile()
        #expect(await processes[0].snapshot().hasExited)
        #expect(!(await processes[1].snapshot().hasExited))
        let latest = try f.runtime.service.view(owner: owner)
        _ = try f.runtime.service.revokeProvider(
          approval.identity, owner: owner,
          expectedProviderRevision: approval.revision, expectedRevision: latest.revision)
        try await f.runtime.coordinator.reconcile()
        #expect(await processes[1].snapshot().hasExited)
      } catch {
        for process in processes { await process.close() }
        try? await f.runtime.coordinator.stopExecutions(Set(prepared.map(\.executionID)))
        throw error
      }
      for process in processes { await process.close() }
      try await f.runtime.coordinator.stopExecutions(Set(prepared.map(\.executionID)))
    }
  }

  private func compileProviderProbe(in directory: URL) throws -> URL {
    let source = directory.appendingPathComponent("provider-probe.c")
    let binary = directory.appendingPathComponent("provider-probe")
    try #"""
    #include <fcntl.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <unistd.h>
    int main(int argc, char **argv) {
      if (argc != 6) return 1;
      int full = strcmp(argv[5], "full") == 0;
      int fd = open("own-write", O_CREAT | O_WRONLY, 0600);
      if (fd < 0) return 2;
      close(fd);
      char path[4096];
      for (int i = 1; i <= 2; i++) {
        snprintf(path, sizeof(path), "%s/forbidden-write", argv[i]);
        fd = open(path, O_CREAT | O_WRONLY, 0600);
        if ((fd >= 0) != full) return 3;
        if (fd >= 0) close(fd);
      }
      fd = open(argv[3], O_RDONLY);
      if ((fd >= 0) != full) return 4;
      if (fd >= 0) close(fd);
      fd = open(argv[4], O_RDWR);
      if ((fd >= 0) != full) return 6;
      if (fd >= 0) { if (write(fd, "unconfined", 10) != 10) return 7; close(fd); }
      snprintf(path, sizeof(path), "%s/state", getenv("HOME"));
      fd = open(path, O_CREAT | O_WRONLY, 0600);
      if (fd < 0) return 5;
      close(fd);
      puts("boundaries verified"); fflush(stdout);
      for (;;) pause();
    }
    """#.write(to: source, atomically: true, encoding: .utf8)
    let compiler = Process()
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
    compiler.arguments = ["-Wall", "-Werror", source.path, "-o", binary.path]
    compiler.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": directory.path]
    try compiler.run()
    compiler.waitUntilExit()
    try #require(compiler.terminationStatus == 0)
    return binary
  }
#endif
