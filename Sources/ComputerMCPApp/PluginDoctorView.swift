import ComputerMCP
import SwiftUI

struct PluginDoctorView: View {
  @ObservedObject var model: PluginDoctorModel
  @Environment(\.dismiss) private var dismiss
  @State private var checkRequest = 0

  var body: some View {
    let report = model.report
    VStack(spacing: 0) {
      Form {
        Section {
          LabeledContent {
            Text(model.pluginID)
          } label: {
            Text("Plugin", bundle: AppLocalization.resourceBundle)
          }
          Text(
            "Checks include disabled contributions. Nothing is enabled, executed or installed.",
            bundle: AppLocalization.resourceBundle
          ).foregroundStyle(.secondary)
          if let report {
            Text(verbatim: AppLocalization.string(report.enabled ? "Enabled" : "Disabled"))
            LabeledContent {
              Text(String(report.revision))
            } label: {
              Text("Revision", bundle: AppLocalization.resourceBundle)
            }
            LabeledContent {
              Text(DateFormatter.computerMCPDateTime.string(from: report.checkedAt))
            } label: {
              Text("Checked at", bundle: AppLocalization.resourceBundle)
            }
            Text(
              verbatim: AppLocalization.string(
                report.status == .failed ? "Some package checks failed" : "Package checks finished")
            )
            Text(
              "File checks do not confirm a working integration.",
              bundle: AppLocalization.resourceBundle
            )
            .foregroundStyle(.secondary)
          }
        } header: {
          Text("Check package", bundle: AppLocalization.resourceBundle)
        }
        if let report {
          if !report.dependencies.isEmpty {
            Section {
              ForEach(report.dependencies) { dependency in
                VStack(alignment: .leading, spacing: 4) {
                  Text(dependency.id).font(.headline)
                  Text(bindingLabel(dependency.resolutionSource)).foregroundStyle(.secondary)
                  if let executable = dependency.executable {
                    Text(executable).textSelection(.enabled)
                  }
                  Text(dependency.declaration.instructions).textSelection(.enabled)
                }
              }
            } header: {
              Text("External executables", bundle: AppLocalization.resourceBundle)
            }
          }
          ForEach(report.checks) { check in
            Section {
              HStack {
                Image(
                  systemName: check.status == .passed
                    ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .accessibilityHidden(true)
                Text(statusLabel(check.status)).font(.headline)
              }
              Text(AppLocalization.string(check.message)).textSelection(.enabled)
              if let component = check.componentID { Text(component).font(.caption) }
              if let dependency = check.dependencyID {
                LabeledContent {
                  Text(dependency)
                } label: {
                  Text("Dependency ID", bundle: AppLocalization.resourceBundle)
                }
              }
              if let inspection = check.inspection {
                Text(inspection.path ?? inspection.executable).textSelection(.enabled)
                ForEach(Array(inspection.interpreters.enumerated()), id: \.offset) {
                  _, interpreter in
                  Text(interpreter.path ?? interpreter.executable).font(.caption).textSelection(
                    .enabled)
                }
              }
              if let directory = check.workingDirectory {
                LabeledContent {
                  Text(directory).textSelection(.enabled)
                } label: {
                  Text("Working directory", bundle: AppLocalization.resourceBundle)
                }
              }
            } header: {
              Text(checkTitle(check.kind))
            }
          }
          Section {
            ForEach(report.notChecked, id: \.self) { item in
              Text(uncheckedTitle(item))
            }
            Text(
              "File checks do not confirm a working integration.",
              bundle: AppLocalization.resourceBundle
            )
            .foregroundStyle(.secondary)
          } header: {
            Text("Not checked", bundle: AppLocalization.resourceBundle)
          }
        }
      }
      .formStyle(.grouped)
      if let errorMessage = model.errorMessage {
        Text(errorMessage).foregroundStyle(.red).textSelection(.enabled).padding(12)
      }
      Divider()
      HStack {
        if model.isChecking { ProgressView().controlSize(.small) }
        Button {
          checkRequest += 1
        } label: {
          Text("Check again", bundle: AppLocalization.resourceBundle)
        }
        .disabled(model.isChecking)
        Spacer()
        Button {
          dismiss()
        } label: {
          Text("Done", bundle: AppLocalization.resourceBundle)
        }
        .keyboardShortcut(.cancelAction)
      }.padding(16)
    }
    .frame(width: 640, height: 620)
    .task(id: checkRequest) { await model.check() }
    .onDisappear { model.cancel() }
  }

  private func statusLabel(_ status: PluginCheckStatus) -> String {
    switch status {
    case .passed: AppLocalization.string("Passed")
    case .failed: AppLocalization.string("Failed")
    case .unverified: AppLocalization.string("Not verified")
    }
  }

  private func checkTitle(_ kind: PluginDoctorCheck.Kind) -> String {
    switch kind {
    case .source: AppLocalization.string("Source")
    case .compatibility: AppLocalization.string("Host compatibility")
    case .executable: AppLocalization.string("Executable")
    case .resources: AppLocalization.string("Skills")
    }
  }

  private func uncheckedTitle(_ value: String) -> String {
    switch value {
    case "runtime_version": AppLocalization.string("Runtime version")
    case "binary_compatibility": AppLocalization.string("Binary compatibility")
    case "connection": AppLocalization.string("Connections")
    case "system_permissions": AppLocalization.string("System permissions")
    default: value
    }
  }

  private func bindingLabel(_ value: String) -> String {
    switch value {
    case "host_override": AppLocalization.string("Host binding")
    case "path": AppLocalization.string("Found in host PATH")
    case "application_bundle": AppLocalization.string("Found in installed application")
    case "unresolved": AppLocalization.string("Not resolved")
    default: value
    }
  }
}
