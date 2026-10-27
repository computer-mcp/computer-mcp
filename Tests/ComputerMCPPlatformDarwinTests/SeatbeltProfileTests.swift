import ComputerMCPPlatformDarwin
import ComputerMCPSandbox
import Foundation
import Testing

@Suite struct SeatbeltProfileTests {
  @Test func denyDefaultAndProcessRules() throws {
    let profile = SeatbeltProfile.generate(try configuration())
    for rule in [
      "(version 1)", "(deny default)", "(allow process-exec)", "(allow process-fork)",
      "(allow process-info* (target same-sandbox))", "(allow signal (target same-sandbox))",
      "(allow sysctl-read (sysctl-name \"hw.ncpu\"))",
      "(allow file-write-data (literal \"/dev/null\"))",
      "(allow file-read* (literal \"/dev/null\"))",
    ] {
      #expect(profile.contains(rule))
    }
    #expect(!profile.contains("network-"))
    #expect(!profile.contains("mach-lookup"))
  }

  @Test func nullDevicePlumbingRespectsExplicitReadExclusions() throws {
    let root = try SandboxPath("/test")
    let profile = SeatbeltProfile.generate(
      try SandboxConfiguration(
        worktree: root, temporaryDirectory: root, homeDirectory: root, cacheDirectory: root,
        readableRoots: [root], forbiddenReads: [.init("/dev/null")]))
    #expect(
      profile.contains(
        "(allow file-read* (require-all (literal \"/dev/null\") (require-not (subpath \"/dev/null\"))))"
      ))
    #expect(!profile.contains("(allow file-read* (subpath \"/dev\"))"))
  }

  @Test func pathEscapingAndReadExceptions() throws {
    let root = try SandboxPath("/private/test/quote\"back\\[x]")
    let profile = SeatbeltProfile.generate(
      try SandboxConfiguration(
        worktree: root,
        temporaryDirectory: root, homeDirectory: root, cacheDirectory: root,
        readableRoots: [.init("/")],
        deniedReadRegions: [
          .init(path: .init("/Users"), exceptions: [.init("/Users/example/project")])
        ],
        forbiddenReads: [.init("/Users/example/project/secret")],
        listableAncestors: [.init("/Users/example")]))
    #expect(profile.contains("quote\\\"back\\\\[x]"))
    #expect(
      profile.contains(
        "(require-not (require-all (subpath \"/Users\") (require-not (subpath \"/Users/example/project\"))))"
      ))
    #expect(profile.contains("(require-not (subpath \"/Users/example/project/secret\"))"))
    #expect(profile.contains("(vnode-type DIRECTORY)"))
  }

  @Test func gitRules() throws {
    let git = try SandboxGitConfiguration(
      sharedDirectory: .init("/repo/.git"),
      administrativeDirectory: .init("/repo/.git/worktrees/task"),
      privateObjects: .init("/test/objects"), sharedObjects: .init("/repo/.git/objects"))
    let profile = SeatbeltProfile.generate(try configuration(git: git))
    #expect(profile.contains("(require-not (subpath \"/repo/.git\"))"))
    #expect(profile.contains("(allow file-write* (subpath \"/test/objects\"))"))
    #expect(profile.contains("(allow file-write* (literal \"/repo/.git/worktrees/task/HEAD\"))"))
    #expect(!profile.contains("(allow file-write* (subpath \"/repo/.git\"))"))
  }

  @Test func networkAndServiceRules() throws {
    let profile = SeatbeltProfile.generate(
      try configuration(
        proxy: .init(http: 41001, socks: 41002),
        services: .init(screenCapture: true, accessibility: true)))
    #expect(profile.contains("(remote tcp \"localhost:41001\")"))
    #expect(profile.contains("(remote tcp \"localhost:41002\")"))
    #expect(!profile.contains("network-bind"))
    #expect(!profile.contains("network-inbound"))
    #expect(profile.contains("com.apple.replayd"))
    #expect(profile.contains("com.apple.axserver"))
  }

  @Test(arguments: 0..<4)
  func systemServicesAreIndependent(mask: Int) throws {
    let profile = SeatbeltProfile.generate(
      try configuration(
        services: .init(screenCapture: mask & 1 != 0, accessibility: mask & 2 != 0)))
    for service in ["com.apple.windowserver.active", "com.apple.replayd", "com.apple.tccd.system"] {
      #expect(profile.contains("(global-name \"\(service)\")") == (mask & 1 != 0))
    }
    #expect(
      profile.contains(
        "(allow iokit-open-user-client (iokit-user-client-class \"IOSurfaceRootUserClient\"))")
        == (mask & 1 != 0))
    #expect(
      profile.contains("(allow mach-lookup (local-name \"com.apple.axserver\"))")
        == (mask & 2 != 0))
    #expect(!profile.contains("(global-name \"com.apple.axserver\")"))
    #expect(!profile.contains("com.apple.axregistrar"))
    #expect(!profile.contains("appleevent-send"))
    #expect(!profile.contains("com.apple.coreservices.appleevents"))
  }

  private func configuration(
    git: SandboxGitConfiguration? = nil, proxy: SandboxProxyPorts? = nil,
    services: SandboxSystemServices = .init()
  ) throws -> SandboxConfiguration {
    let root = try SandboxPath("/test")
    return try SandboxConfiguration(
      worktree: root, temporaryDirectory: root,
      homeDirectory: root, cacheDirectory: root, readableRoots: [], git: git, proxy: proxy,
      services: services)
  }
}
