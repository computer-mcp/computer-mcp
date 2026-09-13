import SwiftUI

struct MCPCredentialView: View {
  let registrationID: String
  @ObservedObject var model: MCPRegistrationModel
  @Environment(\.dismiss) private var dismiss
  @State private var token = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Manage credential", bundle: AppLocalization.resourceBundle).font(.headline)
      Text(verbatim: registrationID)
      if let status = model.credentialStatus, status.registrationID == registrationID {
        Text(verbatim: status.authentication.endpoint).textSelection(.enabled)
        Text(verbatim: status.authentication.keychainAccount).foregroundStyle(.secondary)
        Text(
          verbatim: AppLocalization.string(
            status.present ? "Credential is stored." : "Credential is missing."))
        SecureField(AppLocalization.string("Bearer token"), text: $token)
        Text(
          "The token is stored only in the host Keychain. New requests read the current value; changing it does not cancel already issued requests.",
          bundle: AppLocalization.resourceBundle
        )
        .font(.caption).foregroundStyle(.secondary)
        HStack {
          Button(AppLocalization.string("Save")) {
            let value = token
            token = ""
            Task { _ = await model.saveCredential(id: registrationID, token: value) }
          }.disabled(token.isEmpty)
          Button(AppLocalization.string("Remove credential"), role: .destructive) {
            token = ""
            Task { _ = await model.saveCredential(id: registrationID, token: nil) }
          }.disabled(!status.present)
        }
      }
      if let error = model.errorMessage { Text(verbatim: error).foregroundStyle(.red) }
      if model.isBusy { ProgressView() }
      HStack {
        Button(AppLocalization.string("Refresh")) {
          Task { await model.loadCredential(id: registrationID) }
        }
        Spacer()
        Button(AppLocalization.string("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
      }
    }
    .padding().frame(width: 540).disabled(model.isBusy)
    .interactiveDismissDisabled(model.isBusy)
    .task { await model.loadCredential(id: registrationID) }
    .onDisappear { token = "" }
  }
}
