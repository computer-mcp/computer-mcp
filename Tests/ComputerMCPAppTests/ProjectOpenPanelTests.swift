import AppKit
import Testing

@testable import ComputerMCPApp

@Suite("Project folder panel")
struct ProjectOpenPanelTests {
  @MainActor
  @Test("Repair explains existing permissions and keeps selection scoped to one folder")
  func repairDirectorySelection() {
    let project = ProjectSummary(
      id: "stable", displayName: "Project", path: "/private/tmp/missing-project",
      health: .missing, activeProfileID: "chatgpt-operate", isEnabled: true,
      isSelected: true, lastResolvedAt: nil)
    let panel = ProjectOpenPanelFactory.make(repairing: project)
    #expect(panel.title == AppLocalization.string("Repair Project"))
    #expect(
      panel.message
        == AppLocalization.formatted(
          "Choose the folder for %@. Existing project permissions will apply to this folder.",
          project.displayName))
    #expect(panel.prompt == AppLocalization.string("Use Folder"))
    #expect(panel.canChooseDirectories && !panel.canChooseFiles && !panel.allowsMultipleSelection)
    #expect(
      panel.directoryURL?.resolvingSymlinksInPath()
        == URL(fileURLWithPath: project.path).deletingLastPathComponent()
        .resolvingSymlinksInPath())
  }

  @MainActor
  @Test("Uses one native directory-only selection")
  func nativeDirectorySelection() {
    let panel = ProjectOpenPanelFactory.make()

    #expect(panel.canChooseDirectories)
    #expect(!panel.canChooseFiles)
    #expect(!panel.allowsMultipleSelection)
    #expect(panel.canCreateDirectories)
    #expect(panel.resolvesAliases)
    #expect(panel.directoryURL == FileManager.default.homeDirectoryForCurrentUser)
  }
}
