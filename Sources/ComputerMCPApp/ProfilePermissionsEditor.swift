import ComputerMCPControlPlane
import ComputerMCPCore
import ComputerMCPPermissions
import SwiftUI

struct ProfilePermissionsEditor: View {
  @StateObject var model: ProfilePermissionsModel
  var didSave: () -> Void = {}
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      if let draft = model.draft {
        Form {
          Section {
            LabeledContent(
              AppLocalization.string("Profile"),
              value: AppLocalization.string(draft.grant.id.displayName))
            LabeledContent(
              AppLocalization.string("Profile revision"),
              value: String(draft.options.grant.authorizationRevision))
            LabeledContent(
              AppLocalization.string("Permission revision"),
              value: String(draft.options.permissionRevision))
            Text(
              "These permissions apply to every client using this profile. Revoking a permission ends work that uses it.",
              bundle: AppLocalization.resourceBundle
            ).foregroundStyle(.secondary)
            Toggle(
              AppLocalization.string("Full access"),
              isOn: Binding(
                get: { model.draft?.grant.fullAccess ?? false },
                set: { model.draft?.grant.fullAccess = $0 }))
            Text(
              "Full access runs programs outside the sandbox and requires separate consent for a connected client. Host tools still require their permissions.",
              bundle: AppLocalization.resourceBundle
            ).font(.caption).foregroundStyle(.secondary)
          }
          Section(AppLocalization.string("Permissions")) {
            ForEach(principalPermissions, id: \.permission) { item in
              permissionPicker(item.title, permission: item.permission, values: [.access])
            }
          }
          Section(AppLocalization.string("Files and Folders")) {
            ForEach(FolderCategory.allCases, id: \.self) { category in
              permissionPicker(
                category.permissionTitle, permission: .filesAndFolders(category), values: [.read])
            }
          }
          Section(AppLocalization.string("Projects")) {
            permissionPicker("All projects", permission: .project("*"), values: [.read, .write])
            ForEach(draft.projectIDs, id: \.self) { id in
              let project = draft.options.projects.first { $0.id == id }
              VStack(alignment: .leading, spacing: 4) {
                permissionPicker(
                  project?.displayName ?? id, permission: .project(id), values: [.read, .write],
                  localizedTitle: false)
                Text(verbatim: project?.rootPath ?? id).font(.caption).foregroundStyle(.secondary)
                if project == nil { savedEntryLabel }
                networkPicker(id)
              }
            }
            networkPicker("*")
          }
          Section(AppLocalization.string("Plugins")) {
            permissionPicker("All plugins", permission: .plugin("*"), values: [.use])
            ForEach(draft.pluginIDs, id: \.self) { id in
              let plugin = draft.options.plugins.first { $0.id == id }
              permissionPicker(
                plugin?.title ?? id, permission: .plugin(id), values: [.use], localizedTitle: false)
              if plugin == nil { savedEntryLabel }
            }
          }
          Section(AppLocalization.string("MCP servers")) {
            permissionPicker("All MCP servers", permission: .mcpServer("*"), values: [.read, .all])
            ForEach(draft.serverIDs, id: \.self) { id in
              let server = draft.options.integrations.first { $0.id == id }
              permissionPicker(
                server?.title ?? id, permission: .mcpServer(id), values: [.read, .all],
                localizedTitle: false)
              if server == nil { savedEntryLabel }
            }
          }
          if !draft.automationTargets.isEmpty {
            Section(AppLocalization.string("Automation")) {
              ForEach(draft.automationTargets, id: \.self) { target in
                Picker(
                  selection: Binding<String>(
                    get: { model.draft?.grant.automation[target]?.rawValue ?? "inherit" },
                    set: {
                      model.draft?.grant.automation[target] = ProfileGrant.AutomationAccess(
                        rawValue: $0)
                    }
                  )
                ) {
                  Text("Default", bundle: AppLocalization.resourceBundle).tag("inherit")
                  Text("Allow", bundle: AppLocalization.resourceBundle).tag("allow")
                  Text("Deny", bundle: AppLocalization.resourceBundle).tag("deny")
                } label: {
                  Text(verbatim: target)
                }
              }
            }
          }
          Section(AppLocalization.string("Allow connections from")) {
            ForEach(GatewayCallerKind.permissionChoices, id: \.self) { caller in
              Toggle(isOn: callerSelection(caller)) {
                Text(verbatim: AppLocalization.string(caller.permissionLabel))
              }.disabled(draft.grant.id == .localAdmin && caller.isRemote)
            }
          }
        }.formStyle(.grouped).disabled(model.isSaving)
      } else if model.isLoading {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        Button(AppLocalization.string("Retry")) { Task { await model.load() } }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      if let error = model.errorMessage {
        Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled).padding()
        Text(
          "Close and reopen to review current permission choices.",
          bundle: AppLocalization.resourceBundle
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Divider()
      HStack {
        Button(AppLocalization.string("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        if model.isSaving { ProgressView().controlSize(.small) }
        Button(AppLocalization.string("Save")) {
          Task {
            if await model.save() {
              didSave()
              dismiss()
            }
          }
        }.keyboardShortcut(.defaultAction)
          .disabled(model.draft == nil || model.isLoading || model.isSaving)
          .accessibilityIdentifier("profile.permissions.save")
      }.padding().disabled(model.isSaving)
    }
    .frame(width: 640, height: 720)
    .interactiveDismissDisabled(model.isSaving)
    .task { await model.load() }
  }

  private var principalPermissions: [(title: String, permission: Permission)] {
    [
      ("Screen", .screen), ("Desktop control", .desktopControl), ("Local network", .localNetwork),
      ("Machine information", .machineInformation), ("Unified logs", .unifiedLogs),
      ("Skills", .skills),
    ]
  }

  private var savedEntryLabel: some View {
    Text(
      "Saved entry; the object is not currently registered.", bundle: AppLocalization.resourceBundle
    )
    .font(.caption).foregroundStyle(.secondary)
  }

  private func permissionPicker(
    _ title: String, permission: Permission, values: [PermissionValue], localizedTitle: Bool = true
  )
    -> some View
  {
    Picker(
      selection: Binding<String>(
        get: {
          guard let entry = model.draft?.grant.permissions.entries[permission] else {
            return "inherit"
          }
          switch entry {
          case .notGranted: return "ask"
          case .denied: return "deny"
          case .granted(let value): return value.rawValue
          }
        },
        set: { selected in
          guard var draft = model.draft else { return }
          if selected == "inherit" {
            draft.grant.permissions.removeEntry(for: permission)
          } else {
            let state: ComputerMCPPermissions.PermissionState =
              selected == "deny"
              ? .denied
              : selected == "ask" ? .notGranted : .granted(PermissionValue(rawValue: selected)!)
            try? draft.grant.permissions.set(state, for: permission)
          }
          model.draft = draft
        })
    ) {
      Text("Default", bundle: AppLocalization.resourceBundle).tag("inherit")
      Text("Ask", bundle: AppLocalization.resourceBundle).tag("ask")
      ForEach(values, id: \.self) { value in
        Text(verbatim: AppLocalization.string(value.permissionTitle)).tag(value.rawValue)
      }
      Text("Deny", bundle: AppLocalization.resourceBundle).tag("deny")
    } label: {
      Text(verbatim: localizedTitle ? AppLocalization.string(title) : title)
    }
  }

  private func networkPicker(_ id: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Picker(
        selection: Binding<String>(
          get: {
            guard let network = model.draft?.grant.projectNetworks[id] else { return "inherit" }
            switch network.configuration {
            case .none: return "none"
            case .trusted: return "trusted"
            case .full: return "full"
            case .custom: return "custom"
            }
          },
          set: {
            switch $0 {
            case "none": model.draft?.grant.projectNetworks[id] = NetworkAccess.none
            case "trusted": model.draft?.grant.projectNetworks[id] = .trusted
            case "full": model.draft?.grant.projectNetworks[id] = .full
            case "custom":
              model.draft?.customHostText[id] = ""
              model.draft?.grant.projectNetworks[id] = .custom(hosts: [], includesTrusted: false)
            default: model.draft?.grant.projectNetworks[id] = nil
            }
          })
      ) {
        Text("Default", bundle: AppLocalization.resourceBundle).tag("inherit")
        Text("None", bundle: AppLocalization.resourceBundle).tag("none")
        Text("Trusted hosts", bundle: AppLocalization.resourceBundle).tag("trusted")
        Text("Full network", bundle: AppLocalization.resourceBundle).tag("full")
        Text("Custom hosts", bundle: AppLocalization.resourceBundle).tag("custom")
      } label: {
        Text(verbatim: AppLocalization.string(id == "*" ? "Network for all projects" : "Network"))
      }
      if case .custom(let hosts, let includesTrusted)? = model.draft?.grant.projectNetworks[id]?
        .configuration
      {
        TextField(
          AppLocalization.string("Hosts, separated by commas"),
          text: Binding(
            get: { model.draft?.customHostText[id] ?? hosts.sorted().joined(separator: ", ") },
            set: { text in
              model.draft?.customHostText[id] = text
              model.draft?.grant.projectNetworks[id] = .custom(
                hosts: Set(
                  text.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                  }.filter { !$0.isEmpty }),
                includesTrusted: includesTrusted)
            }))
        Toggle(
          AppLocalization.string("Include trusted hosts"),
          isOn: Binding(
            get: { includesTrusted },
            set: {
              model.draft?.grant.projectNetworks[id] = .custom(hosts: hosts, includesTrusted: $0)
            }))
      }
    }
  }

  private func callerSelection(_ caller: GatewayCallerKind) -> Binding<Bool> {
    Binding(
      get: { model.draft?.grant.allowedCallers.contains(caller) == true },
      set: {
        if $0 {
          model.draft?.grant.allowedCallers.insert(caller)
        } else {
          model.draft?.grant.allowedCallers.remove(caller)
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

extension PermissionValue {
  var permissionTitle: String {
    switch self {
    case .access, .use: "Allow"
    case .read: "Read"
    case .write: "Write"
    case .all: "All tools"
    }
  }
}

extension FolderCategory {
  var permissionTitle: String {
    switch self {
    case .desktop: "Desktop"
    case .documents: "Documents"
    case .downloads: "Downloads"
    case .iCloudDrive: "iCloud Drive"
    case .networkVolumes: "Network volumes"
    case .removableVolumes: "Removable volumes"
    }
  }
}
