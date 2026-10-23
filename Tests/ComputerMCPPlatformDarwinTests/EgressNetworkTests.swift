import ComputerMCPEgress
import ComputerMCPPlatformDarwin
import ComputerMCPProcess
import ComputerMCPSandbox
import Foundation
import NIOCore
import Testing

@Suite struct EgressNetworkTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["COMPUTER_MCP_EGRESS_NETWORK_TESTS"] == "1",
      "Explicit opt-in: public HTTPS, Git, SwiftPM and npm downloads"),
    arguments: [
      "curl-allowed", "git-https", "swift-online-resolve", "npm-view", "socks-allowed",
      "proxy-ipv6",
    ])
  func publicNetworkMatrix(name: String) async throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let observations = NetworkMatrixObservations()
    let proxy = try await EgressProxy.start(
      executionID: name, policy: .init(access: .trusted), routing: DarwinEgressRouting(),
      resolver: NetworkMatrixResolver(observations: observations), limits: .init(),
      onDenial: { observations.record($0) })
    do {
      let ports = try await proxy.sandboxPorts()
      let base = try fixture.configuration(proxy: ports)
      var executable = "/usr/bin/curl"
      var arguments = curlArguments + ["https://github.com"]
      var developerRoots = [SandboxPath]()
      var developerAncestors = [SandboxPath]()
      var searchPath = try ["/usr/bin", "/bin"].map(SandboxPath.init)
      var expectedHost = "github.com"
      switch name {
      case "socks-allowed": arguments += ["--proxy", "socks5h://127.0.0.1:\(ports.socks)"]
      case "proxy-ipv6": arguments += ["--proxy", "http://[::1]:\(ports.http)"]
      case "git-https":
        executable = "/usr/bin/git"
        arguments = [
          "-c", "credential.helper=", "-c", "http.lowSpeedLimit=1", "-c", "http.lowSpeedTime=30",
          "ls-remote", "https://github.com/apple/swift-system.git", "HEAD",
        ]
      case "swift-online-resolve":
        try fixture.write(
          "worktree/Package.swift",
          """
          // swift-tools-version: 6.2
          import PackageDescription
          let package = Package(name: "NetworkFixture", dependencies: [
            .package(url: "https://github.com/apple/swift-system.git", exact: "1.4.2")])
          """)
        #expect(!FileManager.default.fileExists(atPath: base.cacheDirectory.value + "/swiftpm"))
        #expect(!FileManager.default.fileExists(atPath: base.worktree.value + "/.build"))
        executable =
          "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
        arguments = [
          "package", "--disable-sandbox", "--disable-keychain", "--disable-netrc",
          "--cache-path", base.cacheDirectory.value + "/swiftpm",
          "--config-path", base.homeDirectory.value + "/configuration",
          "--security-path", base.homeDirectory.value + "/security", "resolve",
        ]
      case "npm-view":
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
          .map(String.init)
        let npm = try #require(
          directories.map { URL(fileURLWithPath: $0).appendingPathComponent("npm") }
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }),
          "The explicitly enabled npm matrix case requires npm and node on PATH")
        executable = npm.path
        let directory = npm.deletingLastPathComponent()
        developerRoots = [
          try SandboxPath(directory.deletingLastPathComponent().resolvingSymlinksInPath().path)
        ]
        var ancestor = directory.deletingLastPathComponent()
        while ancestor.path != "/" {
          ancestor.deleteLastPathComponent()
          developerAncestors.append(try SandboxPath(ancestor.path))
        }
        searchPath.insert(try SandboxPath(directory.path), at: 0)
        expectedHost = "registry.npmjs.org"
        arguments = [
          "view", "is-number", "version", "--registry=https://registry.npmjs.org",
          "--cache=" + base.cacheDirectory.value + "/npm",
          "--userconfig=" + base.homeDirectory.value + "/npmrc",
          "--globalconfig=" + base.homeDirectory.value + "/globalnpmrc",
          "--ignore-scripts", "--fetch-retries=0", "--fetch-timeout=30000",
          "--update-notifier=false",
        ]
      default: break
      }
      let configuration = try SandboxConfiguration(
        worktree: base.worktree, temporaryDirectory: base.temporaryDirectory,
        homeDirectory: base.homeDirectory, cacheDirectory: base.cacheDirectory,
        readableRoots: base.readableRoots + developerRoots,
        listableAncestors: base.listableAncestors + developerAncestors, proxy: ports)
      let result = try await run(
        executable, arguments, fixture: fixture, configuration: configuration,
        searchPath: searchPath)
      #expect(result.status == 0, "\(name): \(result.output)")
      #expect(observations.hosts.contains(expectedHost), "\(name) must resolve in the host proxy")
      #expect(observations.denials.isEmpty, "\(observations.denials)")
      if name == "swift-online-resolve" {
        #expect(FileManager.default.fileExists(atPath: base.worktree.value + "/Package.resolved"))
      }
      print(
        "network matrix \(name): exit=\(result.status), proxy hosts=\(observations.hosts.sorted())")
      try await proxy.releaseAfterExecutionEnds()
    } catch {
      try? await proxy.releaseAfterExecutionEnds()
      throw error
    }
  }

  @Test(arguments: [
    "curl-denied", "bypass-noproxy", "bypass-ip", "bypass-ipv6", "bypass-pinned-github",
    "bypass-loopback", "bypass-udp", "bypass-udp-proxy-port", "bypass-dns-udp", "bypass-dns-tcp",
    "bypass-system-resolver", "socks-denied", "address-loopback", "address-metadata",
    "address-private", "address-mixed", "socks-metadata", "address-localhost",
    "address-direct-subnet",
  ])
  func deniedNetworkMatrix(name: String) async throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let observations = NetworkMatrixObservations()
    let overrides = [
      "loopback.test": ["127.0.0.1"], "metadata.test": ["169.254.169.254"],
      "private.test": ["10.0.0.1"], "mixed.test": ["1.1.1.1", "127.0.0.1"],
      "direct-subnet.test": ["198.18.0.1"],
    ]
    let proxy = try await EgressProxy.start(
      executionID: name,
      policy: .init(
        access: .custom(hosts: Array(overrides.keys) + ["localhost"], includeTrusted: true)),
      routing: NetworkMatrixRouting(),
      resolver: NetworkMatrixResolver(observations: observations, overrides: overrides),
      limits: .init(),
      onDenial: { observations.record($0) })
    do {
      let ports = try await proxy.sandboxPorts()
      let configuration = try fixture.configuration(proxy: ports)
      var executable = "/usr/bin/curl"
      var arguments = curlArguments
      var host = "example.com"
      var reason: EgressDenial.Reason? = .hostNotAllowed
      let usesSOCKS = name.hasPrefix("socks-")
      if usesSOCKS { arguments += ["--proxy", "socks5h://127.0.0.1:\(ports.socks)"] }
      switch name {
      case "curl-denied", "socks-denied": arguments += ["https://example.com"]
      case "address-localhost":
        host = "localhost"
        reason = .loopback
        arguments += ["https://localhost"]
      case "address-loopback", "address-metadata", "address-private", "address-mixed",
        "socks-metadata", "address-direct-subnet":
        host =
          name.replacingOccurrences(of: "address-", with: "").replacingOccurrences(
            of: "socks-", with: "") + ".test"
        reason = ["loopback.test", "mixed.test"].contains(host) ? .loopback : .localNetworkRequired
        arguments += ["https://" + host]
      case "bypass-noproxy": arguments += ["--noproxy", "*", "https://github.com"]
      case "bypass-ip": arguments += ["--noproxy", "*", "https://1.1.1.1"]
      case "bypass-ipv6": arguments += ["--noproxy", "*", "https://[2606:4700:4700::1111]"]
      case "bypass-pinned-github":
        arguments += [
          "--noproxy", "*", "--resolve", "github.com:443:140.82.112.3", "https://github.com",
        ]
      default:
        executable = try compileNetworkProbe(fixture).path
        switch name {
        case "bypass-loopback": arguments = ["tcp", "127.0.0.1", "9"]
        case "bypass-udp": arguments = ["udp", "1.1.1.1", "443"]
        case "bypass-udp-proxy-port": arguments = ["udp", "127.0.0.1", String(ports.http)]
        case "bypass-dns-udp": arguments = ["udp", "1.1.1.1", "53"]
        case "bypass-dns-tcp": arguments = ["tcp", "1.1.1.1", "53"]
        default: arguments = ["dns"]
        }
      }
      if name.hasPrefix("bypass-") { reason = nil }
      let result = try await run(
        executable, arguments, fixture: fixture, configuration: configuration)
      #expect(result.status != 0, "\(name): \(result.output)")
      if let reason {
        #expect((usesSOCKS ? [97] : [22, 56]).contains(result.status), "\(name): \(result.output)")
        #expect(result.output.contains(host), "\(result.output)")
        if usesSOCKS {
          #expect(result.output.contains("(2)"), "SOCKS ruleset denial: \(result.output)")
        } else {
          #expect(result.output.contains("403"), "\(result.output)")
          #expect(result.output.contains("X-Blocked-Host: \(host)"), "\(result.output)")
        }
        #expect(observations.denials.count == 1)
        let denial = try #require(observations.denials.first)
        #expect(denial.executionID == name)
        #expect(denial.host == host)
        #expect(denial.port == 443)
        #expect(denial.reason == reason)
        #expect(observations.hosts.contains(host) == (reason != .hostNotAllowed))
      } else {
        #expect(observations.denials.isEmpty)
        #expect(observations.hosts.isEmpty, "Direct traffic must not reach any proxy resolver")
        if name == "bypass-system-resolver" {
          #expect(result.output.contains("resolver-denied"), "\(result.output)")
        } else if name == "bypass-noproxy" {
          #expect([6, 7].contains(result.status), "\(result.output)")
        } else {
          #expect(result.output.contains("Operation not permitted"), "\(name): \(result.output)")
        }
      }
      print(
        "network matrix \(name): exit=\(result.status), denial=\(reason?.rawValue ?? "Seatbelt")")
      try await proxy.releaseAfterExecutionEnds()
    } catch {
      try? await proxy.releaseAfterExecutionEnds()
      throw error
    }
  }

  private var curlArguments: [String] {
    [
      "-q", "--fail", "--silent", "--show-error", "--verbose", "--head", "--connect-timeout", "10",
      "--max-time", "30",
    ]
  }

  private func run(
    _ executable: String, _ arguments: [String], fixture: SeatbeltFixture,
    configuration: SandboxConfiguration, searchPath: [SandboxPath]? = nil
  ) async throws -> (status: Int32, output: String) {
    let environment = try ExecutionEnvironment(
      searchPath: searchPath ?? [SandboxPath("/usr/bin"), SandboxPath("/bin")],
      home: configuration.homeDirectory,
      temporary: configuration.temporaryDirectory, cache: configuration.cacheDirectory,
      developerDirectory: .init("/Applications/Xcode.app/Contents/Developer"))
    let log = fixture.root.appendingPathComponent("worktree/network.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let output = try FileHandle(forWritingTo: log)
    defer { try? output.close() }
    let descriptor = output.fileDescriptor
    let launcher = try ExecutionLauncher(
      platform: DarwinExecutionPlatform(bootstrapExecutable: SeatbeltFixture.executionBootstrap))
    let status = try await withThrowingTaskGroup(of: Int32.self) { group in
      group.addTask {
        try await launcher.run(
          executable: SandboxPath(executable), arguments: arguments,
          directory: configuration.worktree,
          environment: environment, mode: .sandbox(configuration), output: descriptor,
          error: descriptor
        ).status
      }
      group.addTask {
        try await Task.sleep(for: .seconds(180))
        throw ExecutionEnvironmentError.unavailable("Network matrix command exceeded 180 seconds")
      }
      defer { group.cancelAll() }
      let result = try await group.next()
      return try #require(result)
    }
    let message = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
      .filter { !$0.lowercased().contains("set-cookie:") }.joined(separator: "\n")
    return (status, message)
  }

  private func compileNetworkProbe(_ fixture: SeatbeltFixture) throws -> URL {
    try fixture.write(
      "worktree/network-probe.c",
      """
      #include <arpa/inet.h>
      #include <errno.h>
      #include <netdb.h>
      #include <stdio.h>
      #include <stdlib.h>
      #include <string.h>
      #include <sys/socket.h>
      #include <unistd.h>
      int main(int argc, char **argv) {
        if (argc == 2 && !strcmp(argv[1], "dns")) {
          struct addrinfo *answer = NULL;
          int result = getaddrinfo("github.com", "443", NULL, &answer);
          if (answer) freeaddrinfo(answer);
          printf("resolver-%s: %s\\n", result ? "denied" : "allowed", gai_strerror(result));
          return result ? 1 : 0;
        }
        if (argc != 4) return 2;
        int udp = !strcmp(argv[1], "udp");
        int fd = socket(AF_INET, udp ? SOCK_DGRAM : SOCK_STREAM, 0);
        if (fd < 0) { perror("socket"); return 1; }
        struct sockaddr_in address = {.sin_len = sizeof(address), .sin_family = AF_INET,
          .sin_port = htons(atoi(argv[3]))};
        inet_pton(AF_INET, argv[2], &address.sin_addr);
        struct timeval timeout = {.tv_sec = 2};
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        int result = udp ? (int)sendto(fd, "probe", 5, 0, (void *)&address, sizeof(address))
                         : connect(fd, (void *)&address, sizeof(address));
        if (result < 0) perror(udp ? "sendto" : "connect");
        close(fd);
        return result < 0 ? 1 : 0;
      }
      """)
    let binary = fixture.root.appendingPathComponent("worktree/network-probe")
    let compiler = Process()
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
    compiler.arguments = [
      fixture.root.appendingPathComponent("worktree/network-probe.c").path, "-o", binary.path,
    ]
    compiler.environment = [
      "PATH": "/usr/bin:/bin", "TMPDIR": try fixture.path("worktree/tmp").value,
    ]
    try compiler.run()
    compiler.waitUntilExit()
    try #require(compiler.terminationStatus == 0)
    return binary
  }
}

private final class NetworkMatrixObservations: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedHosts = Set<String>()
  private var recordedDenials = [EgressDenial]()

  var hosts: Set<String> { lock.withLock { recordedHosts } }
  var denials: [EgressDenial] { lock.withLock { recordedDenials } }
  func resolved(_ host: String) { lock.withLock { _ = recordedHosts.insert(host) } }
  func record(_ denial: EgressDenial) { lock.withLock { recordedDenials.append(denial) } }
}

private struct NetworkMatrixResolver: EgressResolving {
  let observations: NetworkMatrixObservations
  var overrides = [String: [String]]()

  func resolve(host: String, port: UInt16) throws -> [SocketAddress] {
    observations.resolved(host)
    if let addresses = overrides[host] {
      return try addresses.map { try SocketAddress(ipAddress: $0, port: Int(port)) }
    }
    return try SystemEgressResolver().resolve(host: host, port: port)
  }
}

private struct NetworkMatrixRouting: EgressRouting {
  func route(to numericAddress: String) throws -> EgressRoute {
    .init(
      interface: "en0", interfaceIndex: 1, isTunnel: false,
      isDirect: ["10.0.0.1", "198.18.0.1"].contains(numericAddress))
  }

  func observeChanges(_ handler: @escaping @Sendable (EgressRouteEvent) -> Void) throws
    -> any EgressRouteObservation
  {
    Observation()
  }

  private struct Observation: EgressRouteObservation {
    func cancel() {}
  }
}
