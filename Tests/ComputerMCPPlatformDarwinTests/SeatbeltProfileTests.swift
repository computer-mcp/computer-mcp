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
    ] {
      #expect(profile.contains(rule))
    }
    #expect(!profile.contains("network-"))
    #expect(!profile.contains("mach-lookup"))
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
        services: .init(screenCapture: true, accessibility: true, appleEvents: true)))
    #expect(profile.contains("(remote tcp \"localhost:41001\")"))
    #expect(profile.contains("(remote tcp \"localhost:41002\")"))
    #expect(!profile.contains("network-bind"))
    #expect(!profile.contains("network-inbound"))
    #expect(profile.contains("com.apple.replayd"))
    #expect(profile.contains("com.apple.axserver"))
    #expect(profile.contains("(allow appleevent-send)"))
  }

  @Test(arguments: 0..<8)
  func appleEventsRequireTheirServiceSwitch(mask: Int) throws {
    let enabled = mask & 4 != 0
    let profile = SeatbeltProfile.generate(
      try configuration(
        services: .init(
          screenCapture: mask & 1 != 0, accessibility: mask & 2 != 0, appleEvents: enabled)))
    #expect(profile.contains("appleevent-send") == enabled)
    #expect(profile.contains("com.apple.coreservices.appleevents") == enabled)
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
