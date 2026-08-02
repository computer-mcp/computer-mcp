import SwiftUI

struct AppShellView: View {
  @EnvironmentObject private var model: ComputerMCPAppModel

  var body: some View {
    NavigationSplitView {
      List(AppWorkspace.allCases, selection: $model.selectedWorkspace) { workspace in
        Label(workspace.title, systemImage: workspace.systemImage)
          .tag(workspace)
      }
      .navigationTitle("Computer MCP")
      .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
    } detail: {
      detail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
    .alert(item: $model.presentedError) { error in
      Alert(
        title: Text(error.title),
        message: Text(error.message),
        dismissButton: .default(Text("OK"))
      )
    }
  }

  @ViewBuilder
  private var detail: some View {
    switch model.selectedWorkspace ?? .status {
    case .status:
      StatusView()
    case .workspaces:
      WorkspacesView()
    case .profiles:
      ProfilesView()
    case .providers:
      ProvidersView()
    case .tunnels:
      TunnelsView()
    case .permissions:
      PermissionsView()
    case .audit:
      AuditView()
    case .diagnostics:
      DiagnosticsView()
    }
  }
}
