import ComputerMCPPlatformDarwin
import ComputerMCPSandbox
import Darwin
import Foundation
import Testing

@Suite struct SeatbeltIntegrationTests {
  @Test func filesystemBoundaries() throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    try fixture.write("outside", "outside")
    try fixture.write("denied/secret", "secret")
    try fixture.write("denied/reopened/visible", "visible")
    try fixture.write("denied/reopened/credentials", "secret")
    try fixture.write("siblings/secret", "secret")
    try fixture.write("shared/config", "protected")
    try fixture.write("shared/objects/existing", "object")
    try fixture.write("shared/refs/heads/main", "ref")
    try fixture.write("shared/worktrees/task/HEAD", "0123456789012345678901234567890123456789\n")
    let git = try SandboxGitConfiguration(
      sharedDirectory: fixture.path("shared"),
      administrativeDirectory: fixture.path("shared/worktrees/task"),
      privateObjects: fixture.path("worktree/objects"),
      sharedObjects: fixture.path("shared/objects"))
    let configuration = try fixture.configuration(git: git)
    let cases: [(String, Bool)] = [
      ("echo yes > worktree/file", true),
      ("echo no > outside", false),
      ("cat denied/secret", false),
      ("cat denied/reopened/visible", true),
      ("cat denied/reopened/credentials", false),
      ("ls siblings", true),
      ("cat siblings/secret", false),
      ("echo no > shared/config", false),
      ("echo no > shared/objects/existing", false),
      ("echo no > shared/refs/heads/main", false),
      ("cat shared/objects/existing", true),
      ("echo object > worktree/objects/new", true),
      ("echo detached > shared/worktrees/task/HEAD", true),
    ]
    for (script, expected) in cases {
      let result = try fixture.run(script, configuration: configuration)
      #expect((result == 0) == expected, "\(script): exit \(result)")
    }
    #expect(
      try String(contentsOf: fixture.root.appendingPathComponent("shared/config"), encoding: .utf8)
        == "protected")
  }

  @Test func escapedPathsAreLiteral() throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let unusual = "worktree/a\"b\\[c]"
    try fixture.write(unusual + "/file", "visible")
    let path = try fixture.path(unusual)
    let configuration = try SandboxConfiguration(
      worktree: path, temporaryDirectory: path,
      homeDirectory: path, cacheDirectory: path, readableRoots: fixture.systemReads,
      listableAncestors: fixture.ancestors)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    process.arguments = [
      "-p", SeatbeltProfile.generate(configuration), "/bin/cat", path.value + "/file",
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }

  @Test func offlineNativeBuild() throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    try fixture.write(
      "worktree/Package.swift",
      """
      // swift-tools-version: 6.2
      import PackageDescription
      let package = Package(name: "SandboxFixture", dependencies: [.package(path: "Local")], targets: [
        .executableTarget(name: "SandboxFixture", dependencies: [.product(name: "Local", package: "Local")])])
      """)
    try fixture.write("worktree/Sources/SandboxFixture/main.swift", "import Local\nprint(answer)\n")
    try fixture.write(
      "worktree/Local/Package.swift",
      """
      // swift-tools-version: 6.2
      import PackageDescription
      let package = Package(name: "Local", products: [.library(name: "Local", targets: ["Local"])], targets: [.target(name: "Local")])
      """)
    try fixture.write("worktree/Local/Sources/Local/Value.swift", "public let answer = 42\n")
    let configuration = try fixture.configuration()
    let environment = try ExecutionEnvironment(
      searchPath: [.init("/usr/bin"), .init("/bin")],
      home: configuration.homeDirectory, temporary: configuration.temporaryDirectory,
      cache: configuration.cacheDirectory,
      developerDirectory: .init("/Applications/Xcode.app/Contents/Developer"))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    process.arguments =
      [
        "-p", SeatbeltProfile.generate(configuration),
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift",
      ] + environment.swiftBuildArguments()
      + [
        "--sdk",
        "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
      ]
    process.currentDirectoryURL = URL(fileURLWithPath: configuration.worktree.value)
    process.environment = try environment.variables(sandbox: configuration)
    let log = fixture.root.appendingPathComponent("build.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let handle = try FileHandle(forWritingTo: log)
    defer { try? handle.close() }
    process.standardOutput = handle
    process.standardError = handle
    try process.run()
    process.waitUntilExit()
    let buildLog = try String(contentsOf: log, encoding: .utf8)
    #expect(process.terminationStatus == 0, "\(buildLog)")
    #expect(
      FileManager.default.fileExists(
        atPath: configuration.worktree.value + "/.build/debug/SandboxFixture"))
  }
}

struct SeatbeltFixture {
  let root: URL

  init() throws {
    let canonical = realpath(FileManager.default.temporaryDirectory.path, nil)!
    defer { free(canonical) }
    root = URL(fileURLWithPath: String(cString: canonical)).appendingPathComponent(
      "seatbelt-" + UUID().uuidString)
    for directory in [
      "worktree/tmp", "worktree/home", "worktree/cache", "worktree/objects", "siblings",
    ] {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
    }
  }

  func path(_ relative: String) throws -> SandboxPath {
    try SandboxPath(root.appendingPathComponent(relative).path)
  }
  func write(_ relative: String, _ value: String) throws {
    let file = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try value.write(to: file, atomically: true, encoding: .utf8)
  }
  func remove() { try? FileManager.default.removeItem(at: root) }

  var systemReads: [SandboxPath] {
    get throws {
      try [
        "/usr", "/bin", "/sbin", "/System", "/dev", "/private/etc", "/Applications",
        "/Library/Developer",
        "/Library/Apple", "/Library/Preferences/com.apple.dt.Xcode.plist", "/private/var/select",
      ].map(SandboxPath.init)
    }
  }
  var ancestors: [SandboxPath] {
    get throws {
      var result = [SandboxPath]()
      var current = root
      while current.path != "/" {
        result.append(try SandboxPath(current.path))
        current.deleteLastPathComponent()
      }
      return result + [
        try SandboxPath("/"), try SandboxPath("/private/var"), try SandboxPath("/Library"),
      ]
    }
  }
  func configuration(git: SandboxGitConfiguration? = nil, proxy: SandboxProxyPorts? = nil) throws
    -> SandboxConfiguration
  {
    try SandboxConfiguration(
      worktree: path("worktree"), temporaryDirectory: path("worktree/tmp"),
      homeDirectory: path("worktree/home"), cacheDirectory: path("worktree/cache"),
      readableRoots: systemReads + [path("denied")],
      deniedReadRegions: [.init(path: path("denied"), exceptions: [path("denied/reopened")])],
      forbiddenReads: [path("denied/reopened/credentials")],
      listableAncestors: ancestors + [path("siblings")], git: git, proxy: proxy)
  }
  func run(_ script: String, configuration: SandboxConfiguration) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    process.arguments = ["-p", SeatbeltProfile.generate(configuration), "/bin/sh", "-c", script]
    process.currentDirectoryURL = root
    process.environment = [
      "PATH": "/usr/bin:/bin", "HOME": configuration.homeDirectory.value,
      "TMPDIR": configuration.temporaryDirectory.value,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }
}
