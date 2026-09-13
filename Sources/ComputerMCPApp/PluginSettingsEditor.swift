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
            Text("Plugin", bundle: AppLocalization.resourceBundle)
          }
          Toggle(isOn: $draft.enabled) { Text("Enabled", bundle: AppLocalization.resourceBundle) }
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
            Toggle(isOn: $component.settings.enabled) {
              Text("CLI enabled", bundle: AppLocalization.resourceBundle)
            }
            TextField(text: optional($component.settings.registrationID)) {
              Text("Registration ID", bundle: AppLocalization.resourceBundle)
            }
            Toggle(isOn: $component.settings.allowAnyArgs) {
              Text("Allow arbitrary raw arguments", bundle: AppLocalization.resourceBundle)
            }
            Text(
              "Only grant raw arguments to a trusted CLI. Structured command trees reject this setting.",
              bundle: AppLocalization.resourceBundle
            )
            .font(.caption).foregroundStyle(.secondary)
          } header: {
            Text(verbatim: component.id)
          }
        }
        ForEach($draft.skills) { $component in
          Section {
            Toggle(isOn: $component.settings.enabled) {
              Text("Skills enabled", bundle: AppLocalization.resourceBundle)
            }
            TextField(text: optional($component.settings.registrationID)) {
              Text("Registration ID", bundle: AppLocalization.resourceBundle)
            }
            Text(
              "Reading skills does not execute scripts or grant tool access.",
              bundle: AppLocalization.resourceBundle
            )
            .font(.caption).foregroundStyle(.secondary)
          } header: {
            Text(verbatim: component.id)
          }
        }
        Section {
          ForEach($draft.dependencies) { $dependency in
            VStack(alignment: .leading, spacing: 8) {
              TextField(text: $dependency.name) {
                Text("Dependency ID", bundle: AppLocalization.resourceBundle)
              }
              TextField(text: $dependency.path) {
                Text("Absolute executable path", bundle: AppLocalization.resourceBundle)
              }
              Button(role: .destructive) {
                draft.dependencies.removeAll { $0.id == dependency.id }
              } label: {
                Text("Remove binding", bundle: AppLocalization.resourceBundle)
              }
            }
          }
          Button {
            draft.dependencies.append(PluginDependencyDraft(name: "", path: ""))
          } label: {
            Text("Add executable binding", bundle: AppLocalization.resourceBundle)
          }
          Text(
            "Bindings select existing executables. Computer MCP does not install or update external dependencies.",
            bundle: AppLocalization.resourceBundle
          )
          .font(.caption).foregroundStyle(.secondary)
        } header: {
          Text("External executables", bundle: AppLocalization.resourceBundle)
        }
      }
      .formStyle(.grouped)
      .disabled(model.isSaving)
      if let error = model.errorMessage {
        Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled).padding(16)
      }
      Divider()
      HStack {
        Text(
          "Changes apply only if the saved configuration has not changed.",
          bundle: AppLocalization.resourceBundle
        )
        .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button {
          dismiss()
        } label: {
          Text("Cancel", bundle: AppLocalization.resourceBundle)
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
          Text("Save", bundle: AppLocalization.resourceBundle)
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
    Toggle(isOn: $draft.settings.enabled) {
      Text("MCP enabled", bundle: AppLocalization.resourceBundle)
    }
    MCPHTTPAuthenticationFields(authentication: $draft.settings.authentication)
    TextField(text: optional($draft.settings.registrationID)) {
      Text("Registration ID", bundle: AppLocalization.resourceBundle)
    }
    Toggle(isOn: $draft.preservesNativeNames) {
      Text("Preserve downstream tool names", bundle: AppLocalization.resourceBundle)
    }
    if !draft.preservesNativeNames {
      TextField(text: optional($draft.settings.prefix)) {
        Text("Tool prefix", bundle: AppLocalization.resourceBundle)
      }
    }
    Toggle(isOn: $draft.settings.hostServices) {
      Text("Allow scoped host services", bundle: AppLocalization.resourceBundle)
    }
    Text(
      "For trusted stdio adapters only. Calls retain this connection's workspace and grants; local approval authority is not delegated.",
      bundle: AppLocalization.resourceBundle
    )
    .font(.caption).foregroundStyle(.secondary)
    Toggle(isOn: $draft.overridesArguments) {
      Text("Override process arguments", bundle: AppLocalization.resourceBundle)
    }
    if draft.overridesArguments {
      ForEach($draft.arguments) { $argument in
        HStack {
          TextField(text: $argument.value, axis: .vertical) {
            Text("Argument", bundle: AppLocalization.resourceBundle)
          }
          Button(role: .destructive) {
            draft.arguments.removeAll { $0.id == argument.id }
          } label: {
            Text("Remove argument", bundle: AppLocalization.resourceBundle)
          }
        }
      }
      Button {
        draft.arguments.append(PluginArgumentDraft(value: ""))
      } label: {
        Text("Add argument", bundle: AppLocalization.resourceBundle)
      }
      Text(
        "Each row is one exact argument. No rows means no arguments. Do not enter secrets.",
        bundle: AppLocalization.resourceBundle
      )
      .font(.caption).foregroundStyle(.secondary)
    } else {
      Text("Uses the package's startup arguments.", bundle: AppLocalization.resourceBundle)
        .font(.caption).foregroundStyle(.secondary)
    }
    Picker(selection: $draft.settings.exposure) {
      Text("Gateway calls", bundle: AppLocalization.resourceBundle).tag(MCPExposure.gateway)
      Text("Reexport tools", bundle: AppLocalization.resourceBundle).tag(MCPExposure.reexport)
    } label: {
      Text("Exposure", bundle: AppLocalization.resourceBundle)
    }
    Picker(selection: $draft.selection) {
      Text("Explicit whitelist", bundle: AppLocalization.resourceBundle).tag(
        PluginToolSelection.whitelist)
      Text("All current and future tools", bundle: AppLocalization.resourceBundle).tag(
        PluginToolSelection.all)
    } label: {
      Text("Allowed tools", bundle: AppLocalization.resourceBundle)
    }
    if draft.selection == .whitelist {
      TextField(text: $draft.toolNames, axis: .vertical) {
        Text("Tool names, one per line", bundle: AppLocalization.resourceBundle)
      }
      .lineLimit(3...8)
      Text("An empty whitelist permits no tools.", bundle: AppLocalization.resourceBundle).font(
        .caption
      ).foregroundStyle(
        .secondary)
    } else {
      Text(
        "All also includes tools added by future server updates.",
        bundle: AppLocalization.resourceBundle
      )
      .font(.caption).foregroundStyle(.secondary)
    }
  }
}

private func optional(_ binding: Binding<String?>) -> Binding<String> {
  Binding(
    get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
}
