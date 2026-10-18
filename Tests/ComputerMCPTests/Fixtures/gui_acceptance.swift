import AppKit
import Foundation

/// A disposable target for read/action/verify acceptance; writes only its explicit receipt file.
@MainActor
private final class FixtureDelegate: NSObject, NSApplicationDelegate {
  private let receipt: URL
  private var window: NSWindow?
  private var count = 0
  private let label = NSTextField(labelWithString: "Count 0")

  init(receipt: URL) { self.receipt = receipt }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let window = NSWindow(
      contentRect: NSRect(x: 120, y: 120, width: 380, height: 160),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Computer MCP isolated GUI verification"
    window.isReleasedWhenClosed = false
    label.setAccessibilityIdentifier("fixture-counter")
    let button = NSButton(title: "Increment once", target: self, action: #selector(increment))
    button.setAccessibilityIdentifier("fixture-increment")
    let close = NSButton(title: "Close fixture", target: self, action: #selector(closeFixture))
    close.setAccessibilityIdentifier("fixture-close")
    let stack = NSStackView(views: [label, button, close])
    stack.orientation = .vertical
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    window.contentView?.addSubview(stack)
    if let content = window.contentView {
      NSLayoutConstraint.activate([
        stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
        stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
      ])
    }
    self.window = window
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    save(running: true)
    // A failed driver cannot leave an unattended test window running indefinitely.
    Task {
      try? await Task.sleep(for: .seconds(120))
      closeFixture()
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  func applicationWillTerminate(_ notification: Notification) { save(running: false) }

  @objc private func increment() {
    count += 1
    label.stringValue = "Count \(count)"
    save(running: true)
  }

  @objc private func closeFixture() { NSApp.terminate(nil) }

  private func save(running: Bool) {
    do {
      try JSONSerialization.data(
        withJSONObject: [
          "pid": ProcessInfo.processInfo.processIdentifier, "count": count, "running": running,
          "bundle_identifier": Bundle.main.bundleIdentifier ?? "",
        ], options: [.sortedKeys]
      ).write(to: receipt, options: .atomic)
    } catch {
      NSApp.terminate(nil)
    }
  }
}

@main
@MainActor
private struct GUIAcceptanceApp {
  static func main() {
    guard CommandLine.arguments.count == 2, CommandLine.arguments[1].hasPrefix("/") else { return }
    let delegate = FixtureDelegate(receipt: URL(fileURLWithPath: CommandLine.arguments[1]))
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
  }
}
