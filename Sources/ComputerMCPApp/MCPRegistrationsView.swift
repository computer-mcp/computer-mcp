import ComputerMCP
import SwiftUI

struct MCPRegistrationsView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var model: MCPRegistrationModel
  let managePlugin: (String) -> Void
  @State private var editor: MCPRegistrationEditorPresentation?
  @State private var checking: MCPRegistrationEntry?
  @State private var credential: MCPRegistrationEntry?

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("MCP Registrations", bundle: .module).font(.title2.bold())
        Spacer()
        Button(AppLocalization.string("Add MCP")) { editor = .new }
          .disabled(model.isBusy || model.preview != nil)
        Button(AppLocalization.string("Refresh")) { Task { await model.reload() } }
        Button(AppLocalization.string("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
      }.padding()
      Divider()
      if let message = model.errorMessage {
        Text(verbatim: message).foregroundStyle(.red).textSelection(.enabled).padding()
      }
      if model.isBusy { ProgressView().padding() }
      List(model.snapshot?.registrations ?? []) { entry in
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(verbatim: entry.id).font(.headline)
            Text(verbatim: AppLocalization.string(entry.server.enabled ? "Enabled" : "Disabled"))
              .foregroundStyle(.secondary)
            Spacer()
            if entry.server.authentication != nil {
              Button(AppLocalization.string("Manage credential")) { credential = entry }
            }
            Button(AppLocalization.string("Check connection")) {
              model.clearConnectionReport()
              checking = entry
            }
            if let origin = entry.origin {
              Button(AppLocalization.string("Plugin settings")) {
                dismiss()
                managePlugin(origin.pluginID)
              }
            } else {
              Button(AppLocalization.string("Edit")) {
                editor = .init(server: entry.server, isNew: false)
              }
              Button {
                Task { _ = await model.review(.enabled(id: entry.id, !entry.server.enabled)) }
              } label: {
                Text(verbatim: AppLocalization.string(entry.server.enabled ? "Disable" : "Enable"))
              }
              Button(AppLocalization.string("Remove"), role: .destructive) {
                Task { _ = await model.review(.remove(id: entry.id)) }
              }
            }
          }
          Text(
            verbatim: entry.origin.map { "\($0.pluginID) · \($0.version)" }
              ?? AppLocalization.string("Manual registration")
          )
          .font(.caption).foregroundStyle(.secondary)
          Text(verbatim: entry.server.command ?? entry.server.url ?? "")
            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          Text(
            verbatim: AppLocalization.string(
              entry.server.allowAnyTool ? "All current and future tools" : "Selected tools only")
          )
          .font(.caption)
        }.padding(.vertical, 6)
      }
      .disabled(model.isBusy || model.preview != nil)
      if let preview = model.preview {
        Divider()
        VStack(alignment: .leading, spacing: 10) {
          Text("Review MCP change", bundle: .module).font(.headline)
          Text(verbatim: preview.id)
          if let after = preview.after {
            Text(
              verbatim: AppLocalization.string(
                after.enabled ? "Registration will be enabled." : "Registration will be disabled."))
            Text(
              verbatim: after.allowAnyTool
                ? AppLocalization.string("All current and future tools")
                : after.allowedTools.joined(separator: ", "))
          } else {
            Text(
              "The registration will be removed. External dependencies are retained.",
              bundle: .module)
          }
          Text(
            "Profile grants are unchanged. A registration cannot grant itself permissions.",
            bundle: .module
          )
          .font(.caption).foregroundStyle(.secondary)
          if preview.transportWillRestart {
            Label(
              AppLocalization.string("Applying this change reconnects the running gateway."),
              systemImage: "exclamationmark.triangle")
            Text(
              "Outstanding calls may have an unknown outcome. Reconnect and inspect before retrying.",
              bundle: .module
            )
            .font(.caption)
          }
          HStack {
            Spacer()
            Button(AppLocalization.string("Cancel")) { model.cancelReview() }
            Button(AppLocalization.string("Apply")) { Task { await model.apply() } }
          }.disabled(model.isBusy)
        }.padding()
      }
    }
    .frame(minWidth: 720, idealWidth: 780, minHeight: 520, idealHeight: 620)
    .task { await model.reload() }
    .sheet(item: $editor) { presentation in
      MCPRegistrationEditor(presentation: presentation, model: model)
    }
    .sheet(item: $checking) { entry in
      MCPRegistrationDoctorView(registrationID: entry.id, model: model)
    }
    .sheet(item: $credential) { entry in
      MCPCredentialView(registrationID: entry.id, model: model)
    }
  }
}

private struct MCPRegistrationEditorPresentation: Identifiable {
  let id = UUID()
  let server: MCPServerConfig
  let isNew: Bool
  static var new: Self {
    .init(server: .init(id: "", transport: .stdio, command: "", enabled: false), isNew: true)
  }
}

private struct MCPRegistrationEditor: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var model: MCPRegistrationModel
  @State private var draft: MCPRegistrationDraft
  @State private var errorMessage: String?
  let isNew: Bool

  init(presentation: MCPRegistrationEditorPresentation, model: MCPRegistrationModel) {
    self.model = model
    isNew = presentation.isNew
    _draft = State(initialValue: MCPRegistrationDraft(server: presentation.server))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(verbatim: AppLocalization.string(isNew ? "Add MCP" : "Edit MCP"))
        .font(.title2.bold()).padding()
      Form {
        TextField(AppLocalization.string("Registration ID"), text: $draft.server.id).disabled(
          !isNew)
        Toggle(AppLocalization.string("Enabled"), isOn: $draft.server.enabled)
        Picker(AppLocalization.string("Transport"), selection: $draft.server.transport) {
          Text("Local process", bundle: .module).tag(MCPTransport.stdio)
          Text("Streamable HTTP", bundle: .module).tag(MCPTransport.streamableHTTP)
          if draft.server.transport == .http { Text(verbatim: "HTTP").tag(MCPTransport.http) }
          if draft.server.transport == .sse { Text(verbatim: "SSE").tag(MCPTransport.sse) }
        }
        if draft.server.transport == .stdio {
          TextField(
            AppLocalization.string("Executable"),
            text: Binding(get: { draft.server.command ?? "" }, set: { draft.server.command = $0 }))
          jsonEditor("Arguments (JSON array)", text: $draft.argumentsJSON)
          TextField(
            AppLocalization.string("Working directory"),
            text: Binding(get: { draft.server.cwd ?? "workspace" }, set: { draft.server.cwd = $0 }))
        } else {
          TextField(
            AppLocalization.string("Server URL"),
            text: Binding(get: { draft.server.url ?? "" }, set: { draft.server.url = $0 }))
          MCPHTTPAuthenticationFields(
            authentication: $draft.server.authentication,
            endpoint: draft.server.url ?? "", account: "mcp.\(draft.server.id)")
        }
        Picker(AppLocalization.string("Tool exposure"), selection: $draft.server.exposure) {
          Text("Gateway calls", bundle: .module).tag(MCPExposure.gateway)
          Text("Reexport tools", bundle: .module).tag(MCPExposure.reexport)
        }
        .onChange(of: draft.server.exposure) { _, exposure in
          if exposure == .reexport && draft.server.prefix == nil {
            draft.server.prefix = draft.server.id
          }
        }
        if draft.server.exposure == .reexport {
          TextField(
            AppLocalization.string("Tool prefix"),
            text: Binding(get: { draft.server.prefix ?? "" }, set: { draft.server.prefix = $0 }))
          Text(
            "An empty prefix preserves original tool names. Conflicts are rejected.",
            bundle: .module
          ).font(.caption)
        }
        Toggle(
          AppLocalization.string("All current and future tools"), isOn: $draft.server.allowAnyTool)
        if !draft.server.allowAnyTool {
          VStack(alignment: .leading) {
            Text("Allowed tool names, one per line", bundle: .module)
            TextEditor(text: $draft.allowedToolsText).font(.system(.body, design: .monospaced))
              .frame(minHeight: 70)
            Text("An empty selection exposes no tools.", bundle: .module).font(.caption)
          }
        }
        DisclosureGroup(AppLocalization.string("Advanced")) {
          jsonEditor("Environment (JSON object)", text: $draft.environmentJSON)
          jsonEditor("Host risk classifications (JSON object)", text: $draft.riskJSON)
          Toggle(AppLocalization.string("Scoped host services"), isOn: $draft.server.hostServices)
            .disabled(draft.server.transport != .stdio)
          Text(
            "External dependencies are user-managed. Host services do not grant local administration.",
            bundle: .module
          ).font(.caption)
        }
      }.formStyle(.grouped)
      if let errorMessage = errorMessage ?? model.errorMessage {
        Text(verbatim: errorMessage).foregroundStyle(.red).padding()
      }
      HStack {
        Spacer()
        Button(AppLocalization.string("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(AppLocalization.string("Review")) {
          Task {
            do {
              let server = try draft.value()
              if await model.review(isNew ? .add(server) : .configure(server)) { dismiss() }
            } catch { errorMessage = AppLocalization.errorDescription(error) }
          }
        }.keyboardShortcut(.defaultAction)
      }.padding().disabled(model.isBusy)
    }.frame(width: 640, height: 710)
  }

  private func jsonEditor(_ title: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading) {
      Text(verbatim: AppLocalization.string(title))
      TextEditor(text: text).font(.system(.body, design: .monospaced)).frame(minHeight: 55)
    }
  }
}
