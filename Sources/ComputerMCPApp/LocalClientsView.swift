import ComputerMCPControlPlane
import SwiftUI

/// Rows for the Home form; registration changes always go through a reviewed plan.
struct LocalClientRows: View {
  @ObservedObject var model: LocalClientsModel

  var body: some View {
    ForEach(RegistrationClient.allCases, id: \.self) { client in
      LocalClientRow(model: model, client: client)
    }
    if let error = model.loadError {
      Label {
        Text(verbatim: error)
      } icon: {
        Image(systemName: "exclamationmark.triangle")
      }
      .foregroundStyle(.orange)
    }
  }
}

private struct LocalClientRow: View {
  @ObservedObject var model: LocalClientsModel
  let client: RegistrationClient

  var body: some View {
    let status = model.status(for: client)
    LabeledContent {
      HStack(spacing: 10) {
        if model.uncertainClients.contains(client) {
          Label {
            Text("Result unknown — refresh to check", bundle: AppLocalization.resourceBundle)
          } icon: {
            Image(systemName: "questionmark.circle").foregroundStyle(.orange)
          }
        } else {
          stateLabel(status?.state)
        }
        if model.busyClient == client {
          ProgressView().controlSize(.small)
        } else if !model.uncertainClients.contains(client),
          let operation = operation(for: status?.state)
        {
          Button {
            Task { await model.beginReview(client, operation: operation) }
          } label: {
            actionTitle(status?.state)
          }
          .disabled(model.callInFlight)
          .accessibilityIdentifier("home.local-client.\(client.rawValue).action")
        }
      }
    } label: {
      AppLocalization.verbatimText(AppLocalization.string(client.displayName))
    }
    .accessibilityIdentifier("home.local-client.\(client.rawValue)")
  }

  @ViewBuilder
  private func stateLabel(_ state: ClientRegistrationState?) -> some View {
    switch state {
    case .registered:
      Label {
        Text("Connected", bundle: AppLocalization.resourceBundle)
      } icon: {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
      }
    case .notRegistered:
      Text("Not connected", bundle: AppLocalization.resourceBundle).foregroundStyle(.secondary)
    case .different:
      Label {
        Text("Different entry", bundle: AppLocalization.resourceBundle)
      } icon: {
        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
      }
    case .unavailable:
      Text("Unavailable", bundle: AppLocalization.resourceBundle).foregroundStyle(.secondary)
        .help(
          Text(
            "Not installed, or its command didn't respond.", bundle: AppLocalization.resourceBundle)
        )
    case .unreadable:
      Label {
        Text("Settings can't be read", bundle: AppLocalization.resourceBundle)
      } icon: {
        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
      }
    case nil:
      Text("Checking…", bundle: AppLocalization.resourceBundle).foregroundStyle(.secondary)
    }
  }

  private func operation(for state: ClientRegistrationState?) -> ClientRegistrationOperation? {
    switch state {
    case .notRegistered, .different: .register
    case .registered: .remove
    case .unavailable, .unreadable, nil: nil
    }
  }

  @ViewBuilder
  private func actionTitle(_ state: ClientRegistrationState?) -> some View {
    switch state {
    case .different: Text("Update…", bundle: AppLocalization.resourceBundle)
    case .registered: Text("Remove…", bundle: AppLocalization.resourceBundle)
    default: Text("Connect…", bundle: AppLocalization.resourceBundle)
    }
  }
}

struct LocalClientReviewSheet: View {
  @ObservedObject var model: LocalClientsModel
  let review: LocalClientReview

  private var plan: ClientRegistrationDisplayPlan { review.plan.display }
  private var name: String { AppLocalization.string(plan.client.displayName) }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      AppLocalization.verbatimText(title)
        .font(.title2.weight(.semibold))
      if let refusal = plan.refusalCode {
        Label {
          AppLocalization.verbatimText(LocalClientsModel.message(for: refusal, client: plan.client))
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
      } else {
        Text(
          "Review exactly what changes. Nothing is written until you confirm.",
          bundle: AppLocalization.resourceBundle
        )
        .foregroundStyle(.secondary)
      }
      GroupBox {
        VStack(alignment: .leading, spacing: 12) {
          ReviewValue(label: Text("Settings file", bundle: AppLocalization.resourceBundle)) {
            Text(verbatim: plan.location.configurationFile)
          }
          if let variable = plan.location.configurationVariable {
            ReviewValue(label: Text("Selected by", bundle: AppLocalization.resourceBundle)) {
              Text(verbatim: variable + "=" + (plan.location.configurationValue ?? ""))
            }
          }
          if let entry = plan.observedEntry {
            ReviewValue(
              label: AppLocalization.verbatimText(
                AppLocalization.formatted("Current “%@” entry", plan.serverName))
            ) {
              Text(verbatim: entry.command ?? entry.urlOrigin ?? "—")
            } detail: {
              AppLocalization.verbatimText(entryDetail(entry))
            }
          }
          if plan.refusalCode == nil {
            if plan.operation == .register {
              ReviewValue(label: Text("New command", bundle: AppLocalization.resourceBundle)) {
                Text(verbatim: commandLine(plan.server))
              }
            }
            let commands = plan.actions.compactMap(\.command)
            if !commands.isEmpty {
              ReviewValue(
                label: AppLocalization.verbatimText(
                  AppLocalization.formatted("Computer MCP runs %@'s own command", name))
              ) {
                Text(verbatim: commands.map(commandLine).joined(separator: "\n"))
              }
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
      }
      if plan.refusalCode == nil {
        ForEach(plan.warnings, id: \.self) { warning in
          Label {
            AppLocalization.verbatimText(AppLocalization.string(warning))
          } icon: {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
          }
          .font(.callout)
        }
        Label {
          AppLocalization.verbatimText(AppLocalization.string(plan.appliesAfter))
        } icon: {
          Image(systemName: "arrow.clockwise.circle")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
      }
      HStack {
        Spacer()
        if plan.refusalCode != nil {
          Button {
            model.cancelReview()
          } label: {
            Text("Close", bundle: AppLocalization.resourceBundle)
          }
          .keyboardShortcut(.defaultAction)
        } else {
          Button {
            model.cancelReview()
          } label: {
            Text("Cancel", bundle: AppLocalization.resourceBundle)
          }
          .keyboardShortcut(.cancelAction)
          confirmButton
        }
      }
    }
    .padding(22)
    .frame(width: 600)
  }

  @ViewBuilder
  private var confirmButton: some View {
    if plan.operation == .remove {
      Button(role: .destructive) {
        Task { await model.confirm(review) }
      } label: {
        Text("Remove", bundle: AppLocalization.resourceBundle)
      }
      .accessibilityIdentifier("local-client.review.confirm")
    } else {
      Button {
        Task { await model.confirm(review) }
      } label: {
        if plan.state == .different {
          Text("Update", bundle: AppLocalization.resourceBundle)
        } else {
          Text("Connect", bundle: AppLocalization.resourceBundle)
        }
      }
      .keyboardShortcut(.defaultAction)
      .accessibilityIdentifier("local-client.review.confirm")
    }
  }

  private var title: String {
    if plan.operation == .remove {
      return AppLocalization.formatted("Remove Computer MCP from %@?", name)
    }
    return plan.state == .different
      ? AppLocalization.formatted("Update Computer MCP in %@?", name)
      : AppLocalization.formatted("Connect %@ to Computer MCP?", name)
  }

  /// Only counts and names are shown; the entry's values can hold credentials.
  private func entryDetail(_ entry: ClientRegistrationEntrySummary) -> String {
    var parts = [AppLocalization.formatted("%@ arguments", String(entry.argumentCount))]
    if !entry.environmentNames.isEmpty {
      parts.append(
        AppLocalization.formatted(
          "Environment: %@", entry.environmentNames.joined(separator: ", ")))
    }
    if !entry.headerNames.isEmpty {
      parts.append(
        AppLocalization.formatted("Headers: %@", entry.headerNames.joined(separator: ", ")))
    }
    return parts.joined(separator: " · ")
  }

  private func commandLine(_ command: ClientRegistrationCommand) -> String {
    ([command.executable] + command.arguments).map(Self.shellToken).joined(separator: " ")
  }

  private static func shellToken(_ value: String) -> String {
    guard !value.isEmpty,
      value.unicodeScalars.allSatisfy({
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/:=")).contains($0)
      })
    else {
      return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    return value
  }
}

/// A label above a selectable monospaced value, for paths and commands too long to align.
private struct ReviewValue<Value: View, Detail: View>: View {
  let label: Text
  @ViewBuilder let value: Value
  @ViewBuilder let detail: Detail

  init(label: Text, @ViewBuilder value: () -> Value, @ViewBuilder detail: () -> Detail) {
    self.label = label
    self.value = value()
    self.detail = detail()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      label.font(.callout).foregroundStyle(.secondary)
      value
        .font(.system(.callout, design: .monospaced))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      detail.font(.caption).foregroundStyle(.secondary)
    }
  }
}

extension ReviewValue where Detail == EmptyView {
  init(label: Text, @ViewBuilder value: () -> Value) {
    self.init(label: label, value: value, detail: { EmptyView() })
  }
}
