import AppKit
import SwiftUI

final class ComputerMCPApplicationDelegate: NSObject, NSApplicationDelegate {
  weak var model: ComputerMCPAppModel?
  private var isPreparingToTerminate = false

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model else {
      return .terminateNow
    }
    guard !isPreparingToTerminate else {
      return .terminateLater
    }
    isPreparingToTerminate = true
    Task {
      await model.prepareForTermination()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}

@main
@MainActor
struct ComputerMCPApp: App {
  @NSApplicationDelegateAdaptor(ComputerMCPApplicationDelegate.self)
  private var applicationDelegate

  @StateObject private var model: ComputerMCPAppModel

  init() {
    let controlPlane: any AppControlPlane
    do {
      controlPlane = try LiveAppControlPlane()
    } catch {
      controlPlane = UnavailableControlPlane(
        reason: AppLocalization.formatted(
          "Computer MCP could not initialize: %@",
          AppLocalization.errorDescription(error)
        )
      )
    }
    _model = StateObject(
      wrappedValue: ComputerMCPAppModel(controlPlane: controlPlane)
    )
  }

  init(controlPlane: any AppControlPlane) {
    _model = StateObject(
      wrappedValue: ComputerMCPAppModel(controlPlane: controlPlane)
    )
  }

  var body: some Scene {
    WindowGroup("Computer MCP", id: "control-center") {
      AppShellView()
        .environmentObject(model)
        .task {
          applicationDelegate.model = model
          model.start()
        }
        .frame(minWidth: 980, minHeight: 640)
    }
    .defaultSize(width: 1120, height: 760)
    .windowResizability(.contentMinSize)
    .commands {
      CommandGroup(after: .appInfo) {
        Button("Show Welcome") {
          model.showWelcome()
        }
      }
    }

    MenuBarExtra {
      MenuBarStatusView()
        .environmentObject(model)
    } label: {
      Label("Computer MCP", systemImage: model.menuBarSystemImage)
        .labelStyle(.titleAndIcon)
    }
    .menuBarExtraStyle(.menu)
  }
}

private struct MenuBarStatusView: View {
  @Environment(\.openWindow) private var openWindow
  @EnvironmentObject private var model: ComputerMCPAppModel

  var body: some View {
    AppLocalization.verbatimText(
      AppLocalization.formatted(
        "Computer MCP: %@",
        model.menuBarStatusText
      )
    )

    Divider()

    Button {
      openWindow(id: "control-center")
      NSApplication.shared.activate(ignoringOtherApps: true)
    } label: {
      Label("Open Computer MCP", systemImage: "macwindow")
    }

    Button {
      model.refreshAll()
    } label: {
      Label("Refresh", systemImage: "arrow.clockwise")
    }

    Divider()

    if model.currentServiceState == .running {
      Button {
        model.stopGateway()
      } label: {
        Label("Stop Gateway", systemImage: "stop.fill")
      }
      .disabled(model.isActionRunning("gateway.stop"))
    } else {
      Button {
        model.startGateway()
      } label: {
        Label("Start Gateway", systemImage: "play.fill")
      }
      .disabled(model.isActionRunning("gateway.start"))
    }

    Divider()

    Button("Quit Computer MCP") {
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
  }
}
