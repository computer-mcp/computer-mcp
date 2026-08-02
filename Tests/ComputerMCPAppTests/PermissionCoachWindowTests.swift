import AppKit
import CoreGraphics
import Testing

@testable import ComputerMCPApp

@Suite("Permission coach placement")
struct PermissionCoachWindowTests {
  private let panelSize = CGSize(width: 330, height: 112)
  private let visibleFrame = CGRect(x: 0, y: 0, width: 1_600, height: 900)

  @Test("Places the coach to the right and points back to System Settings")
  func rightPlacement() {
    let placement = PermissionCoachPlacement.resolve(
      targetFrame: CGRect(x: 100, y: 100, width: 700, height: 600),
      visibleFrame: visibleFrame,
      panelSize: panelSize
    )

    #expect(placement.origin == CGPoint(x: 814, y: 344))
    #expect(placement.arrowDirection == .left)
  }

  @Test("Uses the left side when the right side has no room")
  func leftPlacement() {
    let placement = PermissionCoachPlacement.resolve(
      targetFrame: CGRect(x: 900, y: 100, width: 650, height: 600),
      visibleFrame: visibleFrame,
      panelSize: panelSize
    )

    #expect(placement.origin == CGPoint(x: 556, y: 344))
    #expect(placement.arrowDirection == .right)
  }

  @Test("Uses a vertical placement when neither side has room")
  func verticalPlacement() {
    let placement = PermissionCoachPlacement.resolve(
      targetFrame: CGRect(x: 10, y: 100, width: 1_580, height: 500),
      visibleFrame: visibleFrame,
      panelSize: panelSize
    )

    #expect(placement.origin == CGPoint(x: 635, y: 614))
    #expect(placement.arrowDirection == .down)
  }

  @Test("Omits the arrow when System Settings cannot be located")
  func unanchoredFallback() {
    let placement = PermissionCoachPlacement.resolve(
      targetFrame: nil,
      visibleFrame: visibleFrame,
      panelSize: panelSize
    )

    #expect(placement.origin == CGPoint(x: 635, y: 764))
    #expect(placement.arrowDirection == nil)
  }

  @Test("Falls back inside the visible frame when the located window is mostly off-screen")
  func offscreenTargetFallback() {
    let placement = PermissionCoachPlacement.resolve(
      targetFrame: CGRect(x: -900, y: 100, width: 1_000, height: 600),
      visibleFrame: visibleFrame,
      panelSize: panelSize
    )

    #expect(placement.origin == CGPoint(x: 635, y: 764))
    #expect(placement.arrowDirection == nil)
  }

  @Test("Converts Quartz top-left coordinates to AppKit coordinates once across displays")
  func quartzToAppKitCoordinates() {
    let converted = CoreGraphicsSystemSettingsWindowLocator.appKitFrame(
      for: CGRect(x: 1_920, y: 100, width: 1_200, height: 800),
      desktopTop: 1_080
    )

    #expect(converted == CGRect(x: 1_920, y: 180, width: 1_200, height: 800))
  }

  @Test("Screen Recording coach exports the app as a copyable file URL")
  func screenRecordingDragSource() throws {
    let appURL = URL(fileURLWithPath: "/Applications/Computer MCP.app")
    let writer = PermissionCoachDragSource.pasteboardWriter(for: appURL)
    let dragPasteboard = NSPasteboard(name: .drag)

    #expect(writer.writableTypes(for: dragPasteboard).contains(.fileURL))
  }
}
