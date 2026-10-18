import ComputerMCP
import SwiftUI

struct ProfilePermissionsEditor: View {
  @StateObject var model: ProfilePermissionsModel
  var didSave: () -> Void = {}
  @Environment(\.dismiss) private var dismiss
  @State private var search = ""
  @State private var confirmSave = false

  var body: some View {
    VStack(spacing: 0) {
      if let draft = model.draft {
        Form {
          Section {
            LabeledContent {
              Text(verbatim: AppLocalization.string(draft.grant.id.displayName))
            } label: {
              Text("Connection permissions", bundle: AppLocalization.resourceBundle)
            }
            Picker(selection: binding(\.mode, default: .readOnly)) {
              Text("Observe", bundle: AppLocalization.resourceBundle).tag(
                GatewayPermissionMode.readOnly)
              Text("Control — Restricted Access", bundle: AppLocalization.resourceBundle)
                .tag(GatewayPermissionMode.workspaceOperations)
            } label: {
              Text("Access", bundle: AppLocalization.resourceBundle)
            }
            .accessibilityIdentifier("profile.permissions.mode")
            Text(
              "These permissions apply to every client using this connection profile. Full Access is approved separately for a connected client.",
              bundle: AppLocalization.resourceBundle
            ).foregroundStyle(.secondary)
            Text(
              "A client's current session can impose a lower access level.",
              bundle: AppLocalization.resourceBundle
            ).font(.caption).foregroundStyle(.secondary)
            if draft.replacesBroadGrants {
              Text(
                "Saving replaces broad access with the projects, capabilities, and integrations selected below. New projects and integrations require selection.",
                bundle: AppLocalization.resourceBundle
              ).foregroundStyle(.secondary)
            }
          }
          Section {
            TextField(text: $search) {
              Text("Search capabilities", bundle: AppLocalization.resourceBundle)
            }.accessibilityIdentifier("profile.permissions.search")
            ScrollView {
              LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(visibleCapabilities(draft)) { capability in
                  capabilityRow(capability, draft: draft)
                }
                if visibleCapabilities(draft).isEmpty {
                  Text("No matching capabilities.", bundle: AppLocalization.resourceBundle)
                    .foregroundStyle(.secondary)
                }
              }.padding(.vertical, 4)
            }.frame(height: 200)
          } header: {
            Text("Capabilities", bundle: AppLocalization.resourceBundle)
          }
          Section {
            ForEach(GatewayCallerKind.permissionChoices, id: \.self) { caller in
              Toggle(isOn: selection(caller, in: \.allowedCallers)) {
                Text(verbatim: AppLocalization.string(caller.permissionLabel))
              }
              .accessibilityIdentifier("profile.permissions.caller.\(caller.rawValue)")
              .disabled(draft.grant.id == .localAdmin && caller.isRemote)
            }
          } header: {
            Text("Allow connections from", bundle: AppLocalization.resourceBundle)
          }
          Section {
            if draft.options.workspaces.isEmpty {
              Text(
                "Register a workspace to select it here.", bundle: AppLocalization.resourceBundle)
            }
            ForEach(draft.options.workspaces, id: \.id) { workspace in
              Toggle(isOn: selection(workspace.id, in: \.workspaceIDs)) {
                VStack(alignment: .leading, spacing: 3) {
                  Text(verbatim: workspace.displayName)
                  Text(verbatim: workspace.rootPath).font(.caption).foregroundStyle(.secondary)
                }
              }.accessibilityIdentifier("profile.permissions.workspace.\(workspace.id)")
            }
          } header: {
            Text("Projects", bundle: AppLocalization.resourceBundle)
          }
          Section {
            if draft.options.integrations.isEmpty {
              Text("No integrations are registered.", bundle: AppLocalization.resourceBundle)
            }
            ForEach(draft.options.integrations) { integration in
              Toggle(
                isOn: Binding(
                  get: { model.draft?.grant.mcpServerIDs.contains(integration.id) == true },
                  set: { model.draft?.selectIntegration(integration.id, selected: $0) }
                )
              ) {
                HStack {
                  Text(verbatim: integration.title)
                  if !integration.isEnabled {
                    Text("Disabled", bundle: AppLocalization.resourceBundle).foregroundStyle(
                      .secondary)
                  }
                }
              }.accessibilityIdentifier("profile.permissions.integration.\(integration.id)")
            }
            Text(
              "An integration includes its current and future host-allowed tools. Observe permits reading only. Restricted Access never permits arbitrary execution.",
              bundle: AppLocalization.resourceBundle
            ).font(.caption).foregroundStyle(.secondary)
          } header: {
            Text("Integrations", bundle: AppLocalization.resourceBundle)
          }
          DisclosureGroup {
            Picker(selection: binding(\.confirmationPolicy, default: .riskBased)) {
              ForEach(GatewayConfirmationPolicy.allCases, id: \.self) { policy in
                Text(verbatim: AppLocalization.string(policy.permissionLabel)).tag(policy)
              }
            } label: {
              Text("Confirmation policy", bundle: AppLocalization.resourceBundle)
            }
            Text(verbatim: draft.grant.capabilityIDs.sorted().joined(separator: "\n"))
              .font(.caption.monospaced()).textSelection(.enabled)
            let unavailable = draft.grant.capabilityIDs.subtracting(
              draft.options.capabilities.map(\.id))
            if !unavailable.isEmpty {
              Text(
                "Some saved capabilities are currently unavailable. They remain selected until you remove them.",
                bundle: AppLocalization.resourceBundle
              ).font(.caption).foregroundStyle(.secondary)
              ForEach(unavailable.sorted(), id: \.self) { id in
                Toggle(isOn: selection(id, in: \.capabilityIDs)) { Text(verbatim: id) }
              }
            }
            ForEach(
              draft.grant.mcpServerIDs.subtracting(draft.options.integrations.map(\.id)).sorted(),
              id: \.self
            ) { id in
              Toggle(isOn: selection(id, in: \.mcpServerIDs)) { Text(verbatim: id) }
            }
            ForEach(
              draft.grant.workspaceIDs.subtracting(draft.options.workspaces.map(\.id)).sorted(),
              id: \.self
            ) { id in
              Toggle(isOn: selection(id, in: \.workspaceIDs)) { Text(verbatim: id) }
            }
          } label: {
            Text("Advanced permissions", bundle: AppLocalization.resourceBundle)
          }
        }
        .formStyle(.grouped).disabled(model.isSaving)
      } else if model.isLoading {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        Button {
          Task { await model.load() }
        } label: {
          Text("Retry", bundle: AppLocalization.resourceBundle)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      if let error = model.errorMessage {
        Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled).padding()
        Text(
          "Close and reopen to review current permission choices.",
          bundle: AppLocalization.resourceBundle
        )
        .font(.caption).foregroundStyle(.secondary).padding(.bottom)
      }
      Divider()
      HStack {
        Button {
          dismiss()
        } label: {
          Text("Cancel", bundle: AppLocalization.resourceBundle)
        }.keyboardShortcut(.cancelAction)
        Spacer()
        if model.isSaving { ProgressView().controlSize(.small) }
        Button {
          confirmSave = true
        } label: {
          Text("Save", bundle: AppLocalization.resourceBundle)
        }.keyboardShortcut(.defaultAction)
          .disabled(model.draft == nil || model.isLoading)
          .accessibilityIdentifier("profile.permissions.save")
      }.padding().disabled(model.isSaving)
    }
    .frame(width: 640, height: 720)
    .interactiveDismissDisabled(model.isSaving)
    .task { await model.load() }
    .confirmationDialog("Apply permission changes?", isPresented: $confirmSave) {
      Button(role: .destructive) {
        Task {
          if await model.save() {
            didSave()
            dismiss()
          }
        }
      } label: {
        Text("Apply", bundle: AppLocalization.resourceBundle)
      }
    } message: {
      Text(
        "All clients using this profile receive the selected permissions on their next request. Full Access approvals and pending confirmations become invalid. Already started work is not stopped.",
        bundle: AppLocalization.resourceBundle)
    }
  }

  private func visibleCapabilities(_ draft: ProfilePermissionsDraft)
    -> [ProfilePermissionCapability]
  {
    draft.options.capabilities.filter {
      search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
        || $0.summary.localizedCaseInsensitiveContains(search)
    }
  }

  private func capabilityRow(
    _ capability: ProfilePermissionCapability, draft: ProfilePermissionsDraft
  )
    -> some View
  {
    let integrated =
      capability.descriptor.mcpReference.map {
        draft.grant.mcpServerIDs.contains($0.serverID)
      } ?? false
    return Toggle(
      isOn: Binding(
        get: { integrated || model.draft?.grant.capabilityIDs.contains(capability.id) == true },
        set: { selected in
          if selected {
            model.draft?.grant.capabilityIDs.insert(capability.id)
          } else {
            model.draft?.grant.capabilityIDs.remove(capability.id)
          }
        }
      )
    ) {
      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text(verbatim: capability.title).font(.body.weight(.medium))
          Text(verbatim: AppLocalization.string(capability.descriptor.risk.permissionLabel))
            .font(.caption).foregroundStyle(.secondary)
        }
        Text(verbatim: capability.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
    }
    .disabled(integrated || !draft.grant.permitsRisk(capability.descriptor.risk))
    .help(capability.summary)
    .accessibilityIdentifier("profile.permissions.capability.\(capability.id)")
  }

  private func binding<Value>(_ key: WritableKeyPath<ProfileGrant, Value>, default fallback: Value)
    -> Binding<Value>
  {
    Binding(
      get: { model.draft?.grant[keyPath: key] ?? fallback },
      set: { model.draft?.grant[keyPath: key] = $0 })
  }

  private func selection<Value: Hashable>(
    _ value: Value, in key: WritableKeyPath<ProfileGrant, Set<Value>>
  )
    -> Binding<Bool>
  {
    Binding(
      get: { model.draft?.grant[keyPath: key].contains(value) == true },
      set: { selected in
        if selected {
          model.draft?.grant[keyPath: key].insert(value)
        } else {
          model.draft?.grant[keyPath: key].remove(value)
        }
      })
  }
}

extension GatewayCallerKind {
  static let permissionChoices: [Self] = [
    .localMCP, .secureTunnel, .cloudflareTunnel, .localApp, .localCLI,
  ]
  var permissionLabel: String {
    switch self {
    case .localApp: "Local App"
    case .localCLI: "Local CLI"
    case .localMCP: "Local MCP clients"
    case .secureTunnel: "Secure Tunnel"
    case .cloudflareTunnel: "Cloudflare Tunnel"
    }
  }
}

extension GatewayConfirmationPolicy {
  var permissionLabel: String {
    switch self {
    case .riskBased: "Confirm risky actions"
    case .allWrites: "Confirm all writes"
    case .never: "No confirmation"
    }
  }
}

extension CapabilityRisk {
  var permissionLabel: String {
    switch self {
    case .readOnly: "Read only"
    case .workspaceWrite: "Changes project files"
    case .externalWrite: "Affects other apps or services"
    case .destructive: "May delete data"
    case .fullShell: "Arbitrary execution"
    }
  }
}
