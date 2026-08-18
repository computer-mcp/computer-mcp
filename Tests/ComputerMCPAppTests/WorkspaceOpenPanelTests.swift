import AppKit
import Testing

@testable import ComputerMCPApp

@Suite("Workspace folder panel")
struct WorkspaceOpenPanelTests {
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
