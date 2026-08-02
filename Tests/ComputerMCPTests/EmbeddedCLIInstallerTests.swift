import Foundation
import Testing

@testable import ComputerMCP

@Suite
final class EmbeddedCLIInstallerTests {
  @Test
  func testInstallsAppEmbeddedCLIAsOwnerLocalSymlinkAndUninstallsIt() throws {
    let temporaryDirectory = try ScopedTemporaryDirectory()
    let appCLI = temporaryDirectory.url
      .appendingPathComponent("Computer MCP.app/Contents/Resources/computer-mcp")
    try FileManager.default.createDirectory(
      at: appCLI.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: appCLI)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o755))],
      ofItemAtPath: appCLI.path
    )
    let destination = temporaryDirectory.url.appendingPathComponent("home/.local/bin/computer-mcp")
    let installer = EmbeddedCLIInstaller(
      environment: ["PATH": destination.deletingLastPathComponent().path]
    )

    #expect((try installer.status(destination: destination).state) == .notInstalled)

    let installed = try installer.install(source: appCLI, destination: destination)
    #expect(installed.state == .installed)
    #expect(installed.target == appCLI.path)
    #expect(installed.destinationDirectoryIsOnPath)
    let directoryAttributes = try FileManager.default.attributesOfItem(
      atPath: destination.deletingLastPathComponent().path
    )
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

    try installer.uninstall(destination: destination)
    #expect((try installer.status(destination: destination).state) == .notInstalled)
  }

  @Test
  func testRefusesToReplaceRegularFileOrNonAppExecutable() throws {
    let temporaryDirectory = try ScopedTemporaryDirectory()
    let destination = temporaryDirectory.url.appendingPathComponent("bin/computer-mcp")
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("occupied".utf8).write(to: destination)
    let installer = EmbeddedCLIInstaller()

    #expect((try installer.status(destination: destination).state) == .occupied)
    expectThrows(
      try installer.install(
        source: URL(fileURLWithPath: "/usr/bin/true"),
        destination: destination,
        replaceInvalidLink: true
      )
    ) { error in
      #expect(
        (error as? EmbeddedCLIInstallerError)
          == .notEmbeddedExecutable("/usr/bin/true")
      )
    }
  }
}
