import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlugins

@Suite(.nativeIntegration, .serialized, .timeLimit(.minutes(2)))
struct PluginCLIDiscoveryTests {
  @Test(arguments: [false, true])
  func executableTreeUsesDiscoveryAndCallsUseBothAuthorities(fullAccess: Bool) async throws {
    let f = try FixedHostFixture(fullAccess: fullAccess, lifecycle: true)
    try await f.run { f in
      try await f.initializeRepository()
      let made = try await f.call("git.worktree_add", ["name": .string("cli")])
      let madeResult = try #require(
        made.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue)
      let projectID = try #require(madeResult["project_id"]?.stringValue)
      let worktree = try #require(madeResult["path"]?.stringValue)
      let root = f.root.appendingPathComponent("plugin")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      try compileExporter(root: root)
      let owner = try GatewayPermissionOwner(
        context: .init(
          caller: .localApp,
          profileID: .localAdmin, trustedPrincipalID: "cli-owner"), validate: {})
      let service = f.runtime.permissionRuntime.service
      func package(_ version: String) throws -> PluginPackage {
        try """
        id = 'exporter'
        name = 'Discovery exporter'
        version = '1.0.0'
        plugin_api = 1
        \(fullAccess ? "[sandbox]\nfull_access = true\npurpose = 'Run the fixture native command'" : "")
        [[permissions]]
        id = 'project'
        access = 'write'
        purpose = 'Run the fixture command'
        [[cli]]
        id = 'native'
        executable = { path = 'exporter' }
        tree = { kind = 'introspection', args = ['schema', '\(version)', '\(f.project.path)/forbidden-exporter-write'] }
        """.write(
          to: root.appendingPathComponent(PluginManifest.filename), atomically: true,
          encoding: .utf8)
        return try PluginPackage.load(at: root)
      }
      func approve(_ package: PluginPackage, write: Bool) throws {
        let view = try service.view(owner: owner)
        var permissions = Permissions.newPrincipal
        try permissions.set(write ? .granted(.write) : .notGranted, for: .project("fixture"))
        _ = try service.approveProvider(
          .init(package: package, configuration: f.database.configurationState()),
          permissions: permissions, fullAccess: fullAccess, owner: owner,
          expectedProviderRevision: view.providers.first { $0.identity == .package("exporter") }?
            .revision,
          expectedRevision: view.revision, expectedEpoch: #require(view.epoch))
      }
      func runtime(_ package: PluginPackage) throws -> GatewayRuntime {
        let plugin = try PluginResolver.resolve(
          package: package,
          source: .init(kind: .development, root: root),
          settings: .init(enabled: true, cli: ["native": .init(registrationID: "exporter")]),
          hostVersion: PluginVersion("1.0.29"), architecture: "arm64")
        try #require(plugin.diagnostics.isEmpty)
        return try GatewayRuntime(
          configuration: f.configuration,
          context: .init(
            caller: .localMCP, profileID: .chatGPTOperate,
            projectID: projectID, trustedPrincipalID: "fixed-client"),
          database: f.database, registeredProjects: f.database.projects(),
          platform: f.platform, plugins: [plugin])
      }
      let first = try package("first")
      try approve(first, write: false)
      let gateway = try runtime(first)
      do {
        let catalog = try gateway.listTools(context: .empty)
        let tool = try #require(
          catalog.first {
            $0.meta?.objectValue?["cli"]?.objectValue?["registration"] == .string("exporter")
          }, "\(catalog.compactMap { $0.meta?.objectValue?["discovery_errors"] })")
        #expect(
          tool.meta?.objectValue?["cli"]?.objectValue?["executable_version"] == .string("first"))
        #expect(
          !FileManager.default.fileExists(atPath: f.project.path + "/forbidden-exporter-write"))
        let container = try f.database.prepareProviderContainer(.package("exporter"))
        let marker = URL(fileURLWithPath: try container.sandbox.home.value).appendingPathComponent(
          "discoveries")
        let before = try Data(contentsOf: marker)
        try await gateway.refreshTools(context: .empty)
        #expect(try Data(contentsOf: marker) == before)
        let executable = root.appendingPathComponent("exporter")
        let held = root.appendingPathComponent("exporter-held")
        try FileManager.default.moveItem(at: executable, to: held)
        try await gateway.refreshTools(context: .empty)
        #expect(try !gateway.listTools(context: .empty).contains { $0.name == tool.name })
        try FileManager.default.moveItem(at: held, to: executable)
        try await gateway.refreshTools(context: .empty)
        let restored = try gateway.listTools(context: .empty)
        #expect(restored.contains { $0.name == tool.name })
        #expect(
          !restored.contains {
            $0.meta?.objectValue?["discovery_errors"]?.objectValue?["exporter"] != nil
          })
        let restoredDiscoveries = try Data(contentsOf: marker)
        #expect(restoredDiscoveries.count > before.count)
        try FileManager.default.moveItem(at: executable, to: held)
        try FileManager.default.copyItem(at: held, to: executable)
        try await gateway.refreshTools(context: .empty)
        #expect(try Data(contentsOf: marker).count > restoredDiscoveries.count)
        let denied = try await gateway.callToolForMCPAsync(
          name: tool.name, arguments: .object([:]), context: .empty)
        #expect(String(describing: denied).contains("permission.required"), "\(denied)")
        var profile = try #require(f.database.profiles().first { $0.id == .chatGPTOperate })
        try profile.permissions.set(.granted(.use), for: .plugin("exporter"))
        try f.database.saveProfile(profile)
        try approve(first, write: false)
        let providerDenied = try await gateway.callToolForMCPAsync(
          name: tool.name, arguments: .object([:]), context: .empty)
        #expect(
          String(describing: providerDenied).contains("permission.required"), "\(providerDenied)")
        #expect(String(describing: providerDenied).contains("exporter"))
        try approve(first, write: true)
        let called = try await gateway.callToolForMCPAsync(
          name: tool.name, arguments: .object([:]), context: .empty)
        #expect(called.objectValue?["isError"] != .bool(true), "\(called)")
        #expect(FileManager.default.fileExists(atPath: worktree + "/created-by-cli"))
        _ = try package("second")
        try await gateway.refreshTools(context: .empty)
        #expect(try !gateway.listTools(context: .empty).contains { $0.name == tool.name })
        #expect(
          try gateway.listTools(context: .empty).contains {
            $0.meta?.objectValue?["discovery_errors"]?.objectValue?["exporter"] != nil
          })
      } catch {
        await gateway.shutdown()
        throw error
      }
      await gateway.shutdown()
      for version in ["second", "fail"] {
        let updated = try package(version)
        try approve(updated, write: true)
        let next = try runtime(updated)
        let tools = try next.listTools(context: .empty)
        let typed = tools.filter {
          $0.meta?.objectValue?["cli"]?.objectValue?["registration"] == .string("exporter")
        }
        if version == "fail" {
          let container = try f.database.prepareProviderContainer(.package("exporter"))
          let marker = URL(fileURLWithPath: try container.sandbox.home.value)
            .appendingPathComponent("discoveries")
          let failedDiscoveries = try Data(contentsOf: marker)
          try await next.refreshTools(context: .empty)
          #expect(try Data(contentsOf: marker) == failedDiscoveries)
          #expect(typed.isEmpty)
          #expect(
            tools.contains {
              $0.meta?.objectValue?["discovery_errors"]?.objectValue?["exporter"] != nil
            })
        } else {
          #expect(
            typed.first?.meta?.objectValue?["cli"]?.objectValue?["executable_version"]
              == .string(version))
        }
        await next.shutdown()
      }
    }
  }
}

private func compileExporter(root: URL) throws {
  let source = root.appendingPathComponent("exporter.c")
  try #"""
  #include <fcntl.h>
  #include <stdio.h>
  #include <stdlib.h>
  #include <string.h>
  #include <unistd.h>
  #include <sys/stat.h>
  int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "call") == 0) {
      int fd = open("created-by-cli", O_CREAT | O_WRONLY, 0600);
      if (fd < 0) return 1;
      close(fd); puts("invoked"); return 0;
    }
    if (argc != 4 || strcmp(argv[1], "schema")) return 2;
    int fd = open(argv[3], O_CREAT | O_WRONLY, 0600);
    if (fd >= 0) { close(fd); return 3; }
    char cwd[4096], home[4096];
    struct stat current, scratch;
    if (!getcwd(cwd, sizeof(cwd)) || !getenv("TMPDIR") ||
        stat(cwd, &current) || stat(getenv("TMPDIR"), &scratch) ||
        current.st_dev != scratch.st_dev || current.st_ino != scratch.st_ino) return 4;
    fd = open("scratch-write", O_CREAT | O_WRONLY, 0600);
    if (fd < 0) return 5;
    close(fd);
    snprintf(home, sizeof(home), "%s/discoveries", getenv("HOME"));
    fd = open(home, O_CREAT | O_WRONLY | O_APPEND, 0600);
    if (fd < 0) return 6;
    if (write(fd, "x", 1) != 1) return 7;
    close(fd);
    if (!strcmp(argv[2], "fail")) return 8;
    printf("{\"format_version\":1,\"source\":\"fixture\",\"executable_version\":\"%s\",\"coverage\":\"complete\",\"omissions\":[],\"commands\":[{\"id\":\"run\",\"path\":[],\"description\":\"Run fixture\",\"executable\":true,\"parameters\":[],\"argv\":[{\"kind\":\"literal\",\"value\":\"call\"}],\"stdout\":\"text\"}]}\n", argv[2]);
    return 0;
  }
  """#.write(to: source, atomically: true, encoding: .utf8)
  let compiler = Process()
  compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
  compiler.arguments = [
    "-Wall", "-Werror", source.path, "-o", root.appendingPathComponent("exporter").path,
  ]
  try compiler.run()
  compiler.waitUntilExit()
  try #require(compiler.terminationStatus == 0)
}
