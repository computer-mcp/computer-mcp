import AppKit
import Foundation
import QuartzCore
import SwiftUI
import Testing

@testable import ComputerMCP
@testable import ComputerMCPApp

@Suite
struct PluginSettingsDraftTests {
  @Test
  func argumentEditingPreservesEmptyUnicodeAndNewlineValues() throws {
    let values = ["--codex-executable", "/tmp/My Codex/执行", "", "a\nb", "--", "-1"]
    var draft = PluginMCPDraft(id: "adapter", settings: .init(args: values))
    #expect(draft.overridesArguments && draft.value.args == values)
    let secondID = draft.arguments[1].id
    draft.arguments.removeFirst()
    #expect(draft.arguments[0].id == secondID)
    draft.arguments = []
    #expect(draft.value.args == [])
    draft.overridesArguments = false
    #expect(draft.value.args == nil)
  }

  @Test
  func editingPreservesHostOverridesAndExactRevision() throws {
    let settings = PluginSettings(
      mcp: [
        "native": PluginMCPSettings(
          enabled: false, registrationID: "my-native", exposure: .reexport, prefix: "chosen",
          allowedTools: ["inspect", "工具"],
          toolRisks: ["inspect": .readOnly, "future": .externalWrite])
      ],
      cli: ["command": PluginCLISettings(registrationID: "my-command", allowAnyArgs: true)],
      skills: ["guide": PluginSkillSettings(enabled: false, registrationID: "my-guide")],
      dependencyExecutables: ["vendor": "/tmp/My CLI/工具"])
    let snapshot = try snapshot(revision: 47, settings: settings)
    var draft = PluginSettingsDraft(id: "sample", snapshot: snapshot)
    #expect(draft.revision == 47)
    #expect(try draft.settings() == settings)
    draft.mcp[0].selection = .all
    #expect(try draft.settings().mcp["native"]?.allowAnyTool == true)
    #expect(try draft.settings().mcp["native"]?.allowedTools == [])
    #expect(try draft.settings().mcp["native"]?.toolRisks == settings.mcp["native"]?.toolRisks)
    draft.mcp[0].selection = .whitelist
    draft.mcp[0].toolNames = ""
    #expect(try draft.settings().mcp["native"]?.allowAnyTool == false)
    #expect(try draft.settings().mcp["native"]?.allowedTools == [])
  }

  @Test
  func hostDelegationIsExplicitAndSurvivesDraftEditing() throws {
    var draft = PluginMCPDraft(id: "adapter", settings: PluginMCPSettings())
    #expect(!draft.value.hostServices)
    draft.settings.hostServices = true
    draft.selection = .whitelist
    draft.toolNames = "inspect"
    #expect(draft.value.hostServices && draft.value.allowedTools == ["inspect"])
    let reopened = PluginMCPDraft(id: "adapter", settings: draft.value)
    #expect(reopened.value.hostServices)
    draft.settings.hostServices = false
    #expect(!draft.value.hostServices)
  }

  @Test
  func nativeToolNamingPreservesEmptyDefaultAndCustomPrefixChoices() throws {
    var draft = PluginMCPDraft(id: "adapter", settings: .init(prefix: "custom"))
    draft.preservesNativeNames = true
    #expect(draft.value.prefix == "")
    draft.selection = .all
    let reopened = PluginMCPDraft(id: "adapter", settings: draft.value)
    #expect(reopened.preservesNativeNames && reopened.value.prefix == "")
    draft.preservesNativeNames = false
    #expect(draft.value.prefix == "custom")
    var inherited = PluginMCPDraft(id: "adapter", settings: .init())
    inherited.preservesNativeNames = true
    inherited.preservesNativeNames = false
    #expect(inherited.value.prefix == nil)
  }

  @Test
  func duplicateBindingsAreRejectedWithoutDroppingEitherValue() throws {
    var draft = PluginSettingsDraft(id: "sample", snapshot: try snapshot())
    draft.dependencies = [
      PluginDependencyDraft(name: "vendor", path: "/bin/one"),
      PluginDependencyDraft(name: "vendor", path: "/bin/two"),
    ]
    #expect(throws: AppControlPlaneError.self) { try draft.settings() }
    #expect(draft.dependencies.count == 2)
  }

  @Test
  func multilineToolNamesPreserveIdentityAndOrder() throws {
    var draft = PluginMCPDraft(id: "native", settings: PluginMCPSettings())
    draft.toolNames = "inspect\r\n工具\nname with spaces\n"
    #expect(draft.value.allowedTools == ["inspect", "工具", "name with spaces"])
  }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PluginManagementModelTests {
  @Test
  func bundledPackagesAreVisibleAndEditableWithoutPersistedSettingsOrInstallations() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bundled-ui-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appendingPathComponent("sample")
    try FileManager.default.createDirectory(
      at: package.appendingPathComponent("skills"), withIntermediateDirectories: true)
    try """
    id = 'sample'
    name = 'Bundled Sample'
    version = '1.2.3'
    [[mcp]]
    id = 'native'
    transport = 'http'
    url = 'http://127.0.0.1:1/mcp'
    [[skills]]
    id = 'guide'
    path = 'skills'
    """.write(
      to: package.appendingPathComponent(PluginManifest.filename), atomically: true, encoding: .utf8
    )
    let bundled = BundledPlugins.load(directory: root)
    #expect(bundled.issues.isEmpty && bundled.packages.count == 1)
    let host = try PluginHostSnapshot(state: PluginStoreSnapshot(), bundled: bundled)
    let service = PluginManagementFake(current: host)
    let model = PluginManagementModel(controlPlane: service)
    await model.reload()
    #expect(model.pluginIDs == ["sample"] && model.selectedID == "sample")
    let draft = PluginSettingsDraft(id: "sample", snapshot: host)
    #expect(draft.revision == 0 && !draft.enabled)
    #expect(draft.mcp.map(\.id) == ["native"] && draft.skills.map(\.id) == ["guide"])
    #expect(try draft.settings().mcp["native"] == PluginMCPSettings())
    #expect(host.state.settings.isEmpty && host.state.installations.isEmpty)
    for dark in [false, true] {
      try render(
        PluginsView(model: model).environment(\.colorScheme, dark ? .dark : .light),
        size: NSSize(width: 1000, height: 720),
        appearance: try #require(NSAppearance(named: dark ? .darkAqua : .aqua)),
        name: dark ? "bundled-dark" : "bundled-light")
    }
    #expect(service.changeCount == 0)
  }

  @Test
  func committedCleanupWarningsRemainVisibleWithoutRetryingTheWrite() async throws {
    let service = PluginManagementFake(current: try snapshot())
    let warning = PluginStoreIssue(pluginID: "uninstalled", message: "Recovery requires attention")
    service.resultIssues = [warning]
    let model = PluginManagementModel(controlPlane: service)
    await model.reload()
    #expect(await model.apply(.uninstallArtifact(installationID: "fixture"), expectedRevision: 0))
    #expect(service.changeCount == 1)
    #expect(model.snapshot?.state.revision == 1)
    #expect(model.snapshot?.issues.contains(warning) == true)
    #expect(model.pluginIDs.contains("uninstalled"))
    #expect(model.errorMessage == nil && !model.isSaving)
  }

  @Test
  func recoveryUpdatesDiagnosticsEvenWhenConfigurationRevisionDoesNotChange() async throws {
    let service = PluginManagementFake(
      current: try PluginHostSnapshot(
        state: PluginStoreSnapshot(),
        issues: [.init(pluginID: "orphan", message: "Pending recovery")],
        recoveryError: "Store busy"))
    let model = PluginManagementModel(controlPlane: service)
    await model.reload()
    #expect(model.pluginIDs == ["orphan"])
    #expect(model.snapshot?.recoveryError == "Store busy")
    #expect(await model.apply(.recover, expectedRevision: 0))
    #expect(model.snapshot?.state.revision == 0)
    #expect(model.pluginIDs.isEmpty && model.snapshot?.recoveryError == nil)
  }

  @Test
  func failedRefreshPreservesTheListAndSurfacesAnError() async throws {
    let service = PluginManagementFake(current: try snapshot())
    let model = PluginManagementModel(controlPlane: service)
    await model.reload()
    let before = model.snapshot?.state
    service.onFetch = { throw PluginHostError.connectedClients }
    await model.reload()
    #expect(model.snapshot?.state == before)
    #expect(model.pluginIDs == ["sample"])
    #expect(model.selectedID == "sample")
    #expect(model.errorMessage != nil)
    #expect(!model.isRefreshing)
  }

  @Test
  func staleEditorIsNotSilentlyRebasedOrRetried() async throws {
    let service = PluginManagementFake(current: try snapshot(revision: 1))
    let model = PluginManagementModel(controlPlane: service)
    await model.reload()
    let draft = PluginSettingsDraft(id: "sample", snapshot: try #require(model.snapshot))
    service.current = try snapshot(revision: 2)
    let success = await model.apply(
      .settings(pluginID: draft.id, try draft.settings()), expectedRevision: draft.revision)
    #expect(!success)
    #expect(service.changeCount == 1)
    #expect(service.receivedRevisions == [1])
    #expect(model.snapshot?.state.revision == 2)
    #expect(draft.revision == 1)
    #expect(model.errorMessage != nil)
    #expect(!model.isSaving)
  }

  @Test
  func readStartedBeforeSavingCannotReplaceCommittedState() async throws {
    let original = try snapshot(revision: 0)
    let service = PluginManagementFake(current: original)
    let model = PluginManagementModel(controlPlane: service)
    let started = AsyncStream<Void>.makeStream()
    var continuation: CheckedContinuation<PluginHostSnapshot, any Error>?
    service.onFetch = {
      try await withCheckedThrowingContinuation {
        continuation = $0
        started.continuation.yield(())
      }
    }
    let read = Task { await model.reload() }
    var events = started.stream.makeAsyncIterator()
    await events.next()
    #expect(await model.apply(.enabled(pluginID: "sample", true), expectedRevision: 0))
    continuation?.resume(returning: original)
    await read.value
    #expect(model.snapshot?.state.revision == 1)
    #expect(model.snapshot?.state.settings["sample"]?.enabled == true)
    #expect(!model.isRefreshing)
    started.continuation.finish()
  }

  @Test
  func secondClickDoesNotQueueAnotherMutation() async throws {
    let service = PluginManagementFake(current: try snapshot())
    let model = PluginManagementModel(controlPlane: service)
    let started = AsyncStream<Void>.makeStream()
    var continuation: CheckedContinuation<Void, Never>?
    service.beforeChange = {
      await withCheckedContinuation {
        continuation = $0
        started.continuation.yield(())
      }
    }
    let write = Task { await model.apply(.enabled(pluginID: "sample", true), expectedRevision: 0) }
    var events = started.stream.makeAsyncIterator()
    await events.next()
    #expect(model.isSaving)
    #expect(!(await model.apply(.enabled(pluginID: "sample", false), expectedRevision: 0)))
    continuation?.resume()
    #expect(await write.value)
    #expect(service.changeCount == 1)
    #expect(!model.isSaving)
    started.continuation.finish()
  }

  @Test
  func unavailableControlPlaneDoesNotFabricateEmptySuccess() async {
    let model = PluginManagementModel(controlPlane: UnavailableControlPlane())
    await model.reload()
    #expect(model.snapshot == nil)
    #expect(model.errorMessage != nil)
  }

  @Test
  func pluginManagementIsRoutedToTheConfigurationGroup() {
    #expect(AppWorkspace.plugins.group == .configure)
    #expect(AppWorkspace.allCases.contains(.plugins))
    let capabilities = AppControlCapabilityCatalog.all.filter { $0.id.hasPrefix("plugin.") }
    #expect(capabilities.count == 15)
    #expect(capabilities.allSatisfy { $0.surface == .appAndCLI && $0.localOnly })
  }

  @Test
  func nativePluginViewsRenderWithAnIsolatedFixture() async throws {
    let settings = PluginSettings(
      mcp: [
        "native": PluginMCPSettings(
          exposure: .reexport, allowedTools: ["inspect"],
          args: ["--codex-executable", "/tmp/Plugin render fixture/执行"])
      ],
      cli: ["command": PluginCLISettings()], skills: ["guide": PluginSkillSettings()],
      dependencyExecutables: ["vendor": "/tmp/Plugin render fixture/vendor"])
    var state = try snapshot(settings: settings).state
    state.installations = [
      PluginInstallationRecord(
        id: "fixture", pluginID: "sample", version: try PluginVersion("1.2.3"),
        source: PluginSource(
          kind: .development, root: URL(fileURLWithPath: "/tmp/Plugin render fixture")),
        manifestDigest: String(repeating: "0", count: 64),
        registeredAt: Date(timeIntervalSince1970: 0))
    ]
    state.selectedInstallations = ["sample": "fixture"]
    let host = try PluginHostSnapshot(state: state)
    let service = PluginManagementFake(current: host)
    let model = PluginManagementModel(controlPlane: service)
    await model.reload()
    for dark in [false, true] {
      let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
      try render(
        PluginsView(model: model).environment(\.colorScheme, dark ? .dark : .light),
        size: NSSize(width: 1000, height: 720), appearance: appearance,
        name: dark ? "plugins-dark" : "plugins-light")
      try render(
        PluginSettingsEditor(
          model: model, initial: PluginSettingsDraft(id: "sample", snapshot: host)
        )
        .environment(\.colorScheme, dark ? .dark : .light),
        size: NSSize(width: 640, height: 680), appearance: appearance,
        name: dark ? "settings-dark" : "settings-light")
      try render(
        PluginSettingsEditor(
          model: model, initial: PluginSettingsDraft(id: "sample", snapshot: host)
        )
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.locale, Locale(identifier: "zh-Hans")),
        size: NSSize(width: 640, height: 680), appearance: appearance,
        name: dark ? "settings-zh-dark" : "settings-zh-light")
      try render(
        PluginArchiveInstallView(model: model, revision: host.state.revision)
          .environment(\.colorScheme, dark ? .dark : .light),
        size: NSSize(width: 620, height: 480), appearance: appearance,
        name: dark ? "plugin-install-dark" : "plugin-install-light")
      try render(
        PluginArchiveInstallView(model: model, revision: host.state.revision)
          .environment(\.colorScheme, dark ? .dark : .light)
          .environment(\.locale, Locale(identifier: "zh-Hans")),
        size: NSSize(width: 620, height: 480), appearance: appearance,
        name: dark ? "plugin-install-zh-dark" : "plugin-install-zh-light")
    }
    #expect(service.changeCount == 0)
  }
}

@MainActor
func render<V: View>(
  _ view: V, size: NSSize, appearance: NSAppearance, name: String
) throws {
  _ = NSApplication.shared
  let host = NSHostingView(rootView: view.background(Color(nsColor: .controlBackgroundColor)))
  host.frame = NSRect(origin: .zero, size: size)
  host.appearance = appearance
  let window = NSWindow(
    contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = host
  defer { window.close() }
  host.layoutSubtreeIfNeeded()
  window.display()
  host.displayIfNeeded()
  CATransaction.flush()
  let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
  host.cacheDisplay(in: host.bounds, to: bitmap)
  let png = try #require(bitmap.representation(using: .png, properties: [:]))
  #expect(bitmap.pixelsWide >= Int(size.width))
  #expect(bitmap.pixelsHigh >= Int(size.height))
  if let path = ProcessInfo.processInfo.environment["COMPUTER_MCP_UI_SNAPSHOT_DIR"] {
    try png.write(to: URL(fileURLWithPath: path).appendingPathComponent(name + ".png"))
  }
}

@MainActor
private final class PluginManagementFake: PluginManaging {
  func doctorPlugin(id: String) async throws -> PluginDoctorReport { throw CancellationError() }
  func pluginReleaseArtifacts(repository: String, repositoryID: Int64, tag: String?, page: Int)
    async throws -> GitHubPluginReleaseArtifacts
  { throw PluginCatalogError.networkUnavailable }
  func searchPlugins(query: String, kind: IntegrationKind?, page: Int, refresh: Bool) async throws
    -> PluginCatalogSearchResult
  { throw PluginCatalogError.networkUnavailable }
  var current: PluginHostSnapshot
  var onFetch: (() async throws -> PluginHostSnapshot)?
  var beforeChange: (() async -> Void)?
  var resultIssues: [PluginStoreIssue] = []
  private(set) var changeCount = 0
  private(set) var receivedRevisions: [Int64] = []

  init(current: PluginHostSnapshot) { self.current = current }

  func fetchPlugins() async throws -> PluginHostSnapshot {
    if let onFetch { return try await onFetch() }
    return current
  }

  func changePlugins(_ change: PluginHostChange, expectedRevision: Int64) async throws
    -> PluginHostSnapshot
  {
    changeCount += 1
    receivedRevisions.append(expectedRevision)
    await beforeChange?()
    guard expectedRevision == current.state.revision else {
      throw PluginStoreError.staleRevision(
        expected: expectedRevision, actual: current.state.revision)
    }
    var state = current.state
    if case .enabled(let id, let enabled) = change { state.settings[id]?.enabled = enabled }
    if case .settings(let id, let settings) = change { state.settings[id] = settings }
    if case .recover = change {} else { state.revision += 1 }
    current = try PluginHostSnapshot(state: state, issues: resultIssues)
    return current
  }
}

private func snapshot(revision: Int64 = 0, settings: PluginSettings = PluginSettings()) throws
  -> PluginHostSnapshot
{
  var state = PluginStoreSnapshot()
  state.revision = revision
  state.settings = ["sample": settings]
  return try PluginHostSnapshot(state: state)
}
