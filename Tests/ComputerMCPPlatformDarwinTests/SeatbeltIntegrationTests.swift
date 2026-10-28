import ComputerMCPPlatformDarwin
import ComputerMCPSandbox
import Darwin
import Foundation
import Testing

@Suite struct SeatbeltIntegrationTests {
  @Test func readableSourceCannotBeHardlinkedIntoWritableWorktree() throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    try fixture.write("source/value", "original")
    let base = try fixture.configuration()
    let configuration = try SandboxConfiguration(
      worktree: base.worktree, temporaryDirectory: base.temporaryDirectory,
      homeDirectory: base.homeDirectory, cacheDirectory: base.cacheDirectory,
      readableRoots: base.readableRoots + [fixture.path("source")],
      listableAncestors: base.listableAncestors)
    #expect(try fixture.run("cat source/value > worktree/read", configuration: configuration) == 0)
    #expect(
      try fixture.run(
        "ln source/value worktree/link && echo changed > worktree/link",
        configuration: configuration) != 0)
    #expect(
      try String(contentsOf: fixture.root.appendingPathComponent("source/value"), encoding: .utf8)
        == "original")
  }

  @Test(arguments: [false, true])
  func privateGitRespectsReadOnlyModeAndLiteralPaths(readOnly: Bool) throws {
    let f = try SeatbeltFixture()
    defer { f.remove() }
    let repository = "private-a\"b\\[café]"
    try f.write(repository + "/HEAD", "detached")
    try f.write(repository + "/commondir", "../..")
    try f.write(repository + "/refs/protected", "protected")
    let base = try f.configuration()
    let configuration = try SandboxConfiguration(
      readOnly: readOnly, worktree: base.worktree, temporaryDirectory: base.temporaryDirectory,
      homeDirectory: base.temporaryDirectory, cacheDirectory: base.temporaryDirectory,
      readableRoots: base.readableRoots, listableAncestors: base.listableAncestors,
      git: .init(
        sharedDirectory: f.path("shared"), repository: f.path(repository)))
    for (name, writable) in [
      ("HEAD", true), ("COMMIT_EDITMSG", true), ("next-index-42.lock", true),
      ("next-index-42", true), ("next-index-evil.lock", false), ("commondir", false),
      ("refs/next-index-42.lock", true), ("refs/protected", true),
    ] {
      let command = "printf changed > '" + repository + "/" + name + "'"
      #expect(
        (try f.run(command, configuration: configuration) == 0) == (writable && !readOnly),
        "\(name)")
    }
  }

  @Test func privateStorageCanCreateChildrenWithoutReadingItsParents() throws {
    let f = try SeatbeltFixture()
    defer { f.remove() }
    try f.write("host/executions/owned/seed", "private")
    try f.write("host/executions/secret", "secret")
    let owned = try f.path("host/executions/owned")
    let configuration = try SandboxConfiguration(
      worktree: f.path("worktree"), temporaryDirectory: owned,
      homeDirectory: owned, cacheDirectory: owned, readableRoots: f.systemReads,
      deniedReadRegions: [.init(path: f.path("host"), exceptions: [owned])],
      listableAncestors: f.ancestors)
    #expect(
      try f.run("mkdir -p '" + owned.value + "/cache/nested'", configuration: configuration) == 0)
    #expect(try f.run("ls host/executions", configuration: configuration) != 0)
    #expect(try f.run("cat host/executions/secret", configuration: configuration) != 0)
    #expect(try f.run("echo escaped > host/executions/escape", configuration: configuration) != 0)
  }

  @Test func fixedGitWritesRespectNestedReadOnlyRegions() throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    try fixture.write("worktree/readonly/value", "original")
    try fixture.write("worktree/readonly/reopened/value", "original")
    try fixture.write("shared/refs/main", "original")
    let base = try fixture.configuration()
    let configuration = try SandboxConfiguration(
      worktree: base.worktree, temporaryDirectory: base.temporaryDirectory,
      homeDirectory: base.homeDirectory, cacheDirectory: base.cacheDirectory,
      readableRoots: base.readableRoots,
      deniedWriteRegions: [
        .init(
          path: fixture.path("worktree/readonly"),
          exceptions: [fixture.path("worktree/readonly/reopened")])
      ],
      listableAncestors: base.listableAncestors, hostGitDirectory: fixture.path("shared"))
    for (script, allowed) in [
      ("echo changed > worktree/allowed", true),
      ("echo changed > worktree/readonly/value", false),
      ("echo changed > worktree/readonly/reopened/value", true),
      ("echo changed > shared/refs/main", true),
    ] {
      #expect((try fixture.run(script, configuration: configuration) == 0) == allowed, "\(script)")
    }
    #expect(
      try String(
        contentsOf: fixture.root.appendingPathComponent("worktree/readonly/value"),
        encoding: .utf8) == "original")
  }

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
    try fixture.write("private.git/objects/info/packs", "")
    try fixture.write("private.git/HEAD", "0123456789012345678901234567890123456789\n")
    let git = try SandboxGitConfiguration(
      sharedDirectory: fixture.path("shared"),
      repository: fixture.path("private.git"))
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
      ("mkdir -p private.git/objects; echo object > private.git/objects/new", true),
      ("echo forbidden > private.git/config", false),
      ("echo forbidden > private.git/commondir", false),
      ("echo detached > private.git/HEAD", true),
    ]
    for (script, expected) in cases {
      let result = try fixture.run(script, configuration: configuration)
      #expect((result == 0) == expected, "\(script): exit \(result)")
    }
    #expect(
      try String(contentsOf: fixture.root.appendingPathComponent("shared/config"), encoding: .utf8)
        == "protected")
  }

  @Test func privateGitControlEntriesCannotBeReplaced() throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    for name in [
      "private.git/config", "private.git/HEAD", "private.git/objects/info/packs", "worktree/.git",
    ] {
      try fixture.write(name, "original")
    }
    for name in ["private.git/info", "private.git/hooks", "tmp"] {
      try FileManager.default.createDirectory(
        at: fixture.root.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    let configuration = try SandboxConfiguration(
      worktree: fixture.path("worktree"), temporaryDirectory: fixture.path("tmp"),
      homeDirectory: fixture.path("tmp"), cacheDirectory: fixture.path("tmp"),
      readableRoots: fixture.systemReads, listableAncestors: fixture.ancestors,
      git: .init(sharedDirectory: fixture.path("shared"), repository: fixture.path("private.git")))
    #expect(try fixture.run("echo writable > tmp/positive", configuration: configuration) == 0)
    for entry in [
      "private.git", "private.git/info", "private.git/hooks", "private.git/objects",
      "private.git/objects/info", "worktree",
    ] {
      #expect(try fixture.run("mv " + entry + " tmp/moved", configuration: configuration) != 0)
    }
    for command in [
      "rmdir private.git/info && mv tmp private.git/info",
      "echo planted > private.git/Config", "echo planted > private.git/COMMONDIR",
      "echo planted > private.git/info/Grafts",
      "echo planted > private.git/objects/info/Alternates",
      "echo planted > private.git/unknown", "echo planted > private.git/café",
      "ln private.git/config tmp/config-alias",
      "ln -s ../config private.git/commondir",
      "echo planted > worktree/.git",
    ] { #expect(try fixture.run(command, configuration: configuration) != 0, "\(command)") }
    for name in [
      "HEAD", "objects/info/packs", "objects/info/commit-graph", "index.stash.123.lock",
      "BISECT_HEAD.lock",
    ] {
      #expect(
        try fixture.run("echo state > private.git/" + name, configuration: configuration) == 0)
    }
    #expect(
      try String(
        contentsOf: fixture.root.appendingPathComponent("private.git/config"), encoding: .utf8)
        == "original")
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
  static var executionBootstrap: URL {
    get throws {
      let directory = Bundle.module.bundleURL.deletingLastPathComponent()
      return try #require(
        Array(sequence(first: directory) { $0.deletingLastPathComponent() }.prefix(6))
          .map { $0.appendingPathComponent("computer-mcp-execution-bootstrap") }
          .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }))
    }
  }

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
