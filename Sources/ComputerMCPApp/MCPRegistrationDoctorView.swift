import ComputerMCP
import SwiftUI

struct MCPRegistrationDoctorView: View {
  let registrationID: String
  @ObservedObject var model: MCPRegistrationModel
  @EnvironmentObject private var appModel: ComputerMCPAppModel
  @Environment(\.dismiss) private var dismiss
  @State private var workspaceID = ""
  @State private var pendingRecovery: MCPProcessReceiptStatus?
  @State private var showsRecovery = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Check connection", bundle: AppLocalization.resourceBundle).font(.title2.bold())
      Text(verbatim: registrationID).font(.headline)
      Text(
        "Starts only this enabled MCP to check its connection and catalog. No tools are called, dependencies installed or grants changed.",
        bundle: AppLocalization.resourceBundle)
      if case .loaded(let workspaces) = appModel.workspaces, !workspaces.isEmpty {
        Picker(AppLocalization.string("Workspace"), selection: $workspaceID) {
          Text("Choose a workspace", bundle: AppLocalization.resourceBundle).tag("")
          ForEach(workspaces) { workspace in
            Text(verbatim: workspace.displayName).tag(workspace.id)
          }
        }.disabled(model.isBusy)
      } else {
        Text(
          "Register a workspace before checking a connection.",
          bundle: AppLocalization.resourceBundle)
        Button(AppLocalization.string("Refresh")) { appModel.refresh(.workspaces) }
      }
      if let report = model.doctorReport,
        report.registrationID == registrationID && report.workspaceID == workspaceID
      {
        Divider()
        Text(verbatim: AppLocalization.string(report.message)).textSelection(.enabled)
        LabeledContent(AppLocalization.string("Checked at")) {
          Text(verbatim: DateFormatter.computerMCPDateTime.string(from: report.checkedAt))
        }
        if let version = report.serverVersion {
          LabeledContent(AppLocalization.string("Server version")) { Text(verbatim: version) }
        }
        if let code = report.errorCode { Text(verbatim: code).font(.caption) }
        if let inspection = report.executableInspection {
          Text(verbatim: inspection.path ?? inspection.executable).textSelection(.enabled)
        }
        if let receipts = report.processReceipts, !receipts.isEmpty {
          ScrollView {
            VStack(alignment: .leading, spacing: 8) {
              ForEach(receipts) { receipt in
                Text(verbatim: receipt.id).font(.caption).textSelection(.enabled)
                Text(verbatim: processStateLabel(receipt.state)).font(.caption).foregroundStyle(
                  .secondary)
                if receipt.recoverable {
                  Button(AppLocalization.string("Recover released record")) {
                    pendingRecovery = receipt
                    showsRecovery = true
                  }.disabled(model.isBusy)
                }
              }
            }
          }.frame(maxHeight: 160)
          Text(
            "Recovery requires released process locks and confirmed host authorization cleanup. Damaged or unconfirmed records remain blocked.",
            bundle: AppLocalization.resourceBundle
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        Text(
          "Not verified: tool execution, remote profile permissions, system permissions and persistent host services.",
          bundle: AppLocalization.resourceBundle
        ).foregroundStyle(.secondary)
      }
      if model.processRecovered {
        Text(
          "Process record recovered. Check the connection again when ready; no process was started.",
          bundle: AppLocalization.resourceBundle)
      }
      if let error = model.errorMessage {
        Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled)
      }
      HStack {
        if model.isBusy { ProgressView().controlSize(.small) }
        Spacer()
        Button(AppLocalization.string("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
          .disabled(model.isBusy)
        Button(AppLocalization.string("Check connection")) {
          Task { await model.checkConnection(id: registrationID, workspaceID: workspaceID) }
        }.disabled(workspaceID.isEmpty || model.isBusy)
      }
    }
    .padding(24).frame(width: 560)
    .task {
      model.clearConnectionReport()
      appModel.refresh(.workspaces)
    }
    .onChange(of: workspaceID) { _, _ in model.clearConnectionReport() }
    .interactiveDismissDisabled(model.isBusy)
    .alert(
      AppLocalization.string("Recover released record"), isPresented: $showsRecovery,
      presenting: pendingRecovery
    ) { receipt in
      Button(AppLocalization.string("Recover released record"), role: .destructive) {
        Task {
          await model.recoverProcess(id: registrationID, workspaceID: workspaceID, receipt: receipt)
        }
      }
      Button(AppLocalization.string("Cancel"), role: .cancel) {}
    } message: { receipt in
      Text(
        verbatim: receipt.id + "\n"
          + AppLocalization.string(
            "Only this reviewed record will be retired. No process or downstream action will be started."
          ))
    }
  }

  private func processStateLabel(_ state: String) -> String {
    let key =
      switch state {
      case "running": "Host session is active"
      case "stopped": "Process has stopped"
      case "cleanup_pending": "Waiting for process cleanup"
      case "cleanup_failed": "Process cleanup needs recovery"
      case "host_cleanup_unconfirmed": "Host authorization cleanup is unconfirmed"
      default: "Process record is damaged"
      }
    return AppLocalization.string(key)
  }
}
