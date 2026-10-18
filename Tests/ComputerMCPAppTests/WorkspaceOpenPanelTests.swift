import AppKit
import Testing

@testable import ComputerMCPApp

@Suite("Workspace folder panel")
struct WorkspaceOpenPanelTests {
  @MainActor
  @Test("Repair explains existing permissions and keeps selection scoped to one folder")
  func repairDirectorySelection() {
    let workspace = WorkspaceSummary(
      id: "stable", displayName: "Project", path: "/private/tmp/missing-project",
      health: .missing, activeProfileID: "chatgpt-operate", isEnabled: true,
      isSelected: true, lastResolvedAt: nil)
    let panel = WorkspaceOpenPanelFactory.make(repairing: workspace)
    #expect(panel.title == AppLocalization.string("Repair Workspace"))
    #expect(
      panel.message
        == AppLocalization.formatted(
          "Choose the folder for %@. Existing workspace permissions will apply to this folder.",
          workspace.displayName))
    #expect(panel.prompt == AppLocalization.string("Use Folder"))
    #expect(panel.canChooseDirectories && !panel.canChooseFiles && !panel.allowsMultipleSelection)
    #expect(
      panel.directoryURL?.resolvingSymlinksInPath()
        == URL(fileURLWithPath: workspace.path).deletingLastPathComponent()
        .resolvingSymlinksInPath())
  }

  @MainActor
  @Test("Uses one native directory-only selection")
  func nativeDirectorySelection() {
    let panel = WorkspaceOpenPanelFactory.make()

    #expect(panel.canChooseDirectories)
    #expect(!panel.canChooseFiles)
    #expect(!panel.allowsMultipleSelection)
    #expect(panel.canCreateDirectories)
    #expect(panel.resolvesAliases)
    #expect(panel.directoryURL == FileManager.default.homeDirectoryForCurrentUser)
  }
}
