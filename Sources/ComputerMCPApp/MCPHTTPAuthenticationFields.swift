import ComputerMCP
import SwiftUI

struct MCPHTTPAuthenticationFields: View {
  @Binding var authentication: MCPHTTPAuthentication?
  var endpoint = ""
  var account = ""

  var body: some View {
    Toggle(
      AppLocalization.string("HTTP bearer authentication"),
      isOn: Binding(
        get: { authentication != nil },
        set: { authentication = $0 ? .init(endpoint: endpoint, keychainAccount: account) : nil }))
    if authentication != nil {
      TextField(
        AppLocalization.string("Credential endpoint"),
        text: Binding(
          get: { authentication?.endpoint ?? "" }, set: { authentication?.endpoint = $0 }))
      TextField(
        AppLocalization.string("Keychain account"),
        text: Binding(
          get: { authentication?.keychainAccount ?? "" },
          set: { authentication?.keychainAccount = $0 }))
      Text(
        "HTTP only. Bind the exact server URL and save these settings, then use Manage credential to store the token. An endpoint change requires a new binding; redirects are rejected.",
        bundle: AppLocalization.resourceBundle
      )
      .font(.caption).foregroundStyle(.secondary)
    }
  }
}
