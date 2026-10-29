#if os(macOS)
  import ComputerMCPDarwinTestSupport
  @testable import ComputerMCPPermissions
  import ComputerMCPPlatform
  import ComputerMCPPlatformPOSIX
  import ComputerMCPProcess
  import ComputerMCPSandbox
  import ComputerMCPTestSupport
  import Darwin
  import Foundation
  import Testing

  @Suite(.nativeIntegration, .serialized, .timeLimit(.minutes(1)))
  struct ProviderChannelDarwinTests {
    @Test func exactChannelTransferOwnershipVendorClosureAndRestart() async throws {
      let directory = try ScopedTemporaryDirectory()
      let root = try SandboxPath(ProjectPathResolver.canonicalProject(directory.url).path)
      let ambient = Pipe()
      let ambientFD = fcntl(ambient.fileHandleForWriting.fileDescriptor, F_DUPFD, 128)
      try #require(ambientFD >= 128)
      defer { Darwin.close(ambientFD) }
      let launcher = testExecutionLauncher()
      let binary = try compileProbe(in: directory.url)
      for generation in 1...2 {
        let authority = try ChannelProbeAuthority()
        let environment = try ExecutionEnvironment(
          searchPath: [.init("/usr/bin"), .init("/bin")], home: root, temporary: root, cache: root)
        let sandbox = try SandboxConfiguration(
          readOnly: true, worktree: root, temporaryDirectory: root, homeDirectory: root,
          cacheDirectory: root, readableRoots: launcher.hostSystemReadPaths,
          listableAncestors: [.init("/")])
        let pair = try ProviderHostServiceChannel.make(metadata: "{\"generation\":\(generation)}")
        defer {
          try? pair.host.close()
          pair.channel.close()
        }
        let prepared = try PreparedExecutionContext(
          authority: authority, mode: .sandbox(sandbox), environment: environment,
          limits: ChannelProbeAuthority.limits, provider: authority.binding
        ).withHostServiceChannel(pair.channel)
        let diagnostics = directory.url.appendingPathComponent("probe-\(generation).stderr")
        for destination: Int32 in [3, 4, 9] {
          #expect(throws: ManagedLineProcessError.self) {
            try prepared.withValue {
              try ManagedLineProcess(
                launcher: launcher,
                configuration: .init(
                  executable: binary.path, workingDirectory: directory.url,
                  inheritedDescriptors: [destination: ambient.fileHandleForWriting]))
            }
          }
        }
        #expect(authority.starts == 0)
        let process = try prepared.withValue {
          try ManagedLineProcess(
            launcher: launcher,
            configuration: .init(
              executable: binary.path, arguments: [String(generation), diagnostics.path],
              environment: ["COMPUTER_MCP_HOST_FD": "9"], workingDirectory: directory.url))
        }
        do {
          var lines = process.inboundLines.makeAsyncIterator()
          let next = try await lines.next()
          if next == nil {
            await process.close()
            print("D7 probe exited: \(await process.snapshot())")
            if let data = try? Data(contentsOf: diagnostics) {
              print(String(decoding: data.prefix(8192), as: UTF8.self))
            }
          }
          let ready = try #require(next)
          let member = try #require(authority.member)
          #expect(ready == "ready \(member.processID)")
          #expect(member.identity != 0)
          #expect(authority.bootstrapVerified)
          #expect(fcntl(pair.host.fileDescriptor, F_GETFD) & FD_CLOEXEC != 0)
          let message = try readChannel(pair.host)
          #expect(String(decoding: message, as: UTF8.self) == "generation-\(generation)\n")
          try pair.host.write(contentsOf: Data("ack-\(generation)\n".utf8))
          #expect(try await lines.next() == "verified")
          if generation == 1 {
            let original = try #require(authority.ownership)
            let recovery = try original.recoveryState()
            let recovered = try await testExecutionLauncher().recover(recovery)
            _ = try await recovered.cancel()
            #expect(try await recovered.members().isEmpty)
          }
          await process.close()
          #expect(await process.snapshot().hasExited)
          #expect(try readChannel(pair.host).isEmpty)
          #expect(kill(member.processID, 0) == -1 && errno == ESRCH)
          #expect(authority.starts == 1)
          print(
            "D7 generation \(generation): pid=\(member.processID), identity=\(member.identity), bootstrap verified, exact FD3 bidirectional transfer, vendor exec closure, ambient FD rejection, cleanup confirmed"
          )
        } catch {
          await process.close()
          throw error
        }
      }
    }
  }

  private func readChannel(_ handle: FileHandle) throws -> Data {
    var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
    try #require(poll(&descriptor, 1, 2000) == 1)
    var bytes = [UInt8](repeating: 0, count: 128)
    let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
    try #require(count >= 0)
    return Data(bytes.prefix(count))
  }

  private func compileProbe(in directory: URL) throws -> URL {
    let source = directory.appendingPathComponent("channel-probe.c")
    let binary = directory.appendingPathComponent("channel-probe")
    try #"""
    #include <errno.h>
    #include <fcntl.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <sys/socket.h>
    #include <sys/resource.h>
    #include <sys/wait.h>
    #include <unistd.h>
    #define CHECK(expression) do { if (!(expression)) { \
      fprintf(stderr, "line %d: %s errno=%d\n", __LINE__, #expression, errno); return 1; \
    } } while (0)
    int main(int argc, char **argv) {
      CHECK(argc >= 2);
      if (argc == 3) {
        struct rlimit bound = {8192, 8192}; CHECK(setrlimit(RLIMIT_FSIZE, &bound) == 0);
        CHECK(freopen(argv[2], "w", stderr));
      }
      int vendor = !strcmp(argv[1], "vendor");
      // Check the inherited descriptor set before creating the vendor process.
      for (int fd = vendor ? 3 : 4; fd < getdtablesize(); fd++) {
        CHECK(fcntl(fd, F_GETFD) == -1 && errno == EBADF);
      }
      if (vendor) return 0;
      CHECK(getenv("COMPUTER_MCP_HOST_FD") && !strcmp(getenv("COMPUTER_MCP_HOST_FD"), "3"));
      char metadata[64];
      snprintf(metadata, sizeof(metadata), "{\"generation\":%s}", argv[1]);
      CHECK(getenv("COMPUTER_MCP_HOST_CONTEXT") && !strcmp(getenv("COMPUTER_MCP_HOST_CONTEXT"), metadata));
      struct sockaddr address; socklen_t size = sizeof(address);
      CHECK(getpeername(3, &address, &size) == 0 && address.sa_family == AF_UNIX);
      int type = 0; size = sizeof(type);
      CHECK(getsockopt(3, SOL_SOCKET, SO_TYPE, &type, &size) == 0 && type == SOCK_STREAM);
      int flags = fcntl(3, F_GETFD);
      CHECK(flags >= 0 && fcntl(3, F_SETFD, flags | FD_CLOEXEC) == 0);
      CHECK(fcntl(3, F_GETFD) & FD_CLOEXEC);
      pid_t child = fork(); CHECK(child >= 0);
      if (!child) { execl(argv[0], argv[0], "vendor", NULL); _exit(127); }
      int status;
      CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
      char message[64];
      int count = snprintf(message, sizeof(message), "generation-%s\n", argv[1]);
      CHECK(write(3, message, count) == count);
      printf("ready %d\n", getpid()); fflush(stdout);
      count = snprintf(message, sizeof(message), "ack-%s\n", argv[1]);
      char reply[64];
      CHECK(read(3, reply, sizeof(reply)) == count && !memcmp(message, reply, count));
      puts("verified"); fflush(stdout);
      char input; while (read(0, &input, 1) > 0) {}
      return 0;
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

  private final class ChannelProbeAuthority: ExecutionAuthorizing, @unchecked Sendable {
    static let limits = EffectiveExecutionLimits(
      timeMilliseconds: nil, outputBytes: 4096, memoryBytes: nil, retentionSeconds: 60,
      retainedOutputBytes: 4096, sources: [:])
    let executionID = UUID()
    let binding: ProviderExecutionBinding
    var authorizationIDs: Set<UUID> { binding.authorizationIDs }
    private let lock = NSLock()
    private var storedMember: ExecutionMember?
    private var storedOwnership: (any ExecutionOwnership)?
    private var count = 0
    private var verified = false
    var bootstrapVerified: Bool { lock.withLock { verified } }
    var member: ExecutionMember? { lock.withLock { storedMember } }
    var ownership: (any ExecutionOwnership)? { lock.withLock { storedOwnership } }
    var starts: Int { lock.withLock { count } }

    init() throws {
      var ledger = PermissionLedger()
      let identity = PluginIdentity.package("channel-probe")
      let decision = try ledger.authorize(
        invocation: .init(
          principal: .plugin(identity), tool: "discover", projectID: nil, argumentsDigest: "probe"),
        requirements: .init(), now: Date())
      guard case .allowed(let proof) = decision else {
        throw PermissionModelError.invalidAuthorization
      }
      binding = try .init(
        identity: identity, registrationID: "channel-probe",
        sourceDigest: String(repeating: "a", count: 64), providerAuthorization: proof,
        delegatingAuthorization: nil)
    }

    func reserveChild(_ id: UUID) {}
    func bindChild(_ id: UUID, ownership: any ExecutionOwnership) {
      lock.withLock { storedOwnership = ownership }
      ownership.beforeStart { [self] member in
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(member.processID, &path, UInt32(path.count))
        let bootstrap =
          length > 0
          && String(
            decoding: path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self
          ).hasSuffix("computer-mcp-execution-bootstrap")
        lock.withLock {
          verified = bootstrap
          storedMember = member
          count += 1
        }
      }
    }
    func launchFailed(_ id: UUID) {}
    func finishAdmission() {}
    func access(_ executionID: UUID, operation: ExecutionOperation) -> EffectiveExecutionLimits {
      Self.limits
    }
  }
#endif
