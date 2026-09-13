import ComputerMCP
import SwiftUI

struct PluginSettingsEditor: View {
  @ObservedObject var model: PluginManagementModel
  @Environment(\.dismiss) private var dismiss
  @State private var draft: PluginSettingsDraft

  init(model: PluginManagementModel, initial: PluginSettingsDraft) {
    self.model = model
    _draft = State(initialValue: initial)
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section {
          LabeledContent {
            Text(verbatim: draft.id)
          } label: {
            Text("Plugin", bundle: .module)
          }
          Toggle(isOn: $draft.enabled) { Text("Enabled", bundle: .module) }
        }
        ForEach($draft.mcp) { $component in
          Section {
            PluginMCPSettingsFields(draft: $component)
          } header: {
            Text(verbatim: component.id)
          }
        }
        ForEach($draft.cli) { $component in
          Section {
            Toggle(isOn: $component.settings.enabled) { Text("CLI enabled", bundle: .module) }
            TextField(text: optional($component.settings.registrationID)) {
              Text("Registration ID", bundle: .module)
            }
            Toggle(isOn: $component.settings.allowAnyArgs) {
              Text("Allow arbitrary raw arguments", bundle: .module)
            }
            Text(
              "Only grant raw arguments to a trusted CLI. Structured command trees reject this setting.",
              bundle: .module
            )
            .font(.caption).foregroundStyle(.secondary)
          } header: {
            Text(verbatim: component.id)
          }
        }
        ForEach($draft.skills) { $component in
          Section {
            Toggle(isOn: $component.settings.enabled) { Text("Skills enabled", bundle: .module) }
            TextField(text: optional($component.settings.registrationID)) {
              Text("Registration ID", bundle: .module)
            }
            Text("Reading skills does not execute scripts or grant tool access.", bundle: .module)
              .font(.caption).foregroundStyle(.secondary)
          } header: {
            Text(verbatim: component.id)
          }
        }
        Section {
          ForEach($draft.dependencies) { $dependency in
            VStack(alignment: .leading, spacing: 8) {
              TextField(text: $dependency.name) { Text("Dependency ID", bundle: .module) }
              TextField(text: $dependency.path) {
                Text("Absolute executable path", bundle: .module)
              }
              Button(role: .destructive) {
                draft.dependencies.removeAll { $0.id == dependency.id }
              } label: {
                Text("Remove binding", bundle: .module)
              }
            }
          }
          Button {
            draft.dependencies.append(PluginDependencyDraft(name: "", path: ""))
          } label: {
            Text("Add executable binding", bundle: .module)
          }
          Text(
            "Bindings select existing executables. Computer MCP does not install or update external dependencies.",
            bundle: .module
          )
          .font(.caption).foregroundStyle(.secondary)
        } header: {
          Text("External executables", bundle: .module)
        }
      }
      .formStyle(.grouped)
      .disabled(model.isSaving)
      if let error = model.errorMessage {
        Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled).padding(16)
      }
      Divider()
      HStack {
        Text("Changes apply only if the saved configuration has not changed.", bundle: .module)
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button {
          dismiss()
        } label: {
          Text("Cancel", bundle: .module)
        }.keyboardShortcut(.cancelAction)
        Button {
          Task {
            do {
              let settings = try draft.settings()
              if await model.apply(
                .settings(pluginID: draft.id, settings), expectedRevision: draft.revision)
              {
                dismiss()
              }
            } catch { model.report(error) }
          }
        } label: {
          Text("Save", bundle: .module)
        }
        .keyboardShortcut(.defaultAction)
      }
      .padding(16)
      .disabled(model.isSaving)
    }
    .frame(minWidth: 600, idealWidth: 640, minHeight: 480, idealHeight: 680)
    .interactiveDismissDisabled(model.isSaving)
  }
}

private struct PluginMCPSettingsFields: View {
  @Binding var draft: PluginMCPDraft

  var body: some View {
    Toggle(isOn: $draft.settings.enabled) { Text("MCP enabled", bundle: .module) }
    MCPHTTPAuthenticationFields(authentication: $draft.settings.authentication)
    TextField(text: optional($draft.settings.registrationID)) {
      Text("Registration ID", bundle: .module)
    }
    Toggle(isOn: $draft.preservesNativeNames) {
      Text("Preserve downstream tool names", bundle: .module)
    }
    if !draft.preservesNativeNames {
      TextField(text: optional($draft.settings.prefix)) { Text("Tool prefix", bundle: .module) }
    }
    Toggle(isOn: $draft.settings.hostServices) {
      Text("Allow scoped host services", bundle: .module)
    }
    Text(
      "For trusted stdio adapters only. Calls retain this connection's workspace and grants; local approval authority is not delegated.",
      bundle: .module
    )
    .font(.caption).foregroundStyle(.secondary)
    Toggle(isOn: $draft.overridesArguments) { Text("Override process arguments", bundle: .module) }
    if draft.overridesArguments {
      ForEach($draft.arguments) { $argument in
        HStack {
          TextField(text: $argument.value, axis: .vertical) { Text("Argument", bundle: .module) }
          Button(role: .destructive) {
            draft.arguments.removeAll { $0.id == argument.id }
          } label: {
            Text("Remove argument", bundle: .module)
          }
        }
      }
      Button {
        draft.arguments.append(PluginArgumentDraft(value: ""))
      } label: {
        Text("Add argument", bundle: .module)
      }
      Text(
        "Each row is one exact argument. No rows means no arguments. Do not enter secrets.",
        bundle: .module
      )
      .font(.caption).foregroundStyle(.secondary)
    } else {
      Text("Uses the package's startup arguments.", bundle: .module)
        .font(.caption).foregroundStyle(.secondary)
    }
    Picker(selection: $draft.settings.exposure) {
      Text("Gateway calls", bundle: .module).tag(MCPExposure.gateway)
      Text("Reexport tools", bundle: .module).tag(MCPExposure.reexport)
    } label: {
      Text("Exposure", bundle: .module)
    }
    Picker(selection: $draft.selection) {
      Text("Explicit whitelist", bundle: .module).tag(PluginToolSelection.whitelist)
      Text("All current and future tools", bundle: .module).tag(PluginToolSelection.all)
    } label: {
      Text("Allowed tools", bundle: .module)
    }
    if draft.selection == .whitelist {
      TextField(text: $draft.toolNames, axis: .vertical) {
        Text("Tool names, one per line", bundle: .module)
      }
      .lineLimit(3...8)
      Text("An empty whitelist permits no tools.", bundle: .module).font(.caption).foregroundStyle(
        .secondary)
    } else {
      Text("All also includes tools added by future server updates.", bundle: .module)
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}

private func optional(_ binding: Binding<String?>) -> Binding<String> {
  Binding(
    get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
}
