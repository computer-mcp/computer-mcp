import ComputerMCPGateway
import SwiftUI

@MainActor
struct WorktreeStorageView: View {
  @Environment(\.locale) private var locale
  @Environment(\.localizationResources) private var resources
  @ObservedObject var model: WorktreeRecoveryModel
  let project: ProjectSummary?

  @State private var selected: Set<RetainedRecoverySelection> = []
  @State private var confirmation: RecoveryConfirmation?

  private var l: PrivacyText { .init(locale: locale, resources: resources) }

  private var inventory: ProjectWorktreeInventory? {
    guard let project else { return nil }
    return model.projectInventory(id: project.id, registeredAt: project.registeredAt)
  }

  private var stores: [RecoveryStoreView] {
    project == nil ? (model.stores ?? []) : model.stores(for: inventory)
  }

  private var selectable: Set<RetainedRecoverySelection> {
    Set(
      stores.flatMap { store in
        records(in: store).filter { model.canSelect($0, in: store) }.map {
          RetainedRecoverySelection(store: RecoveryStoreIdentity(store), record: $0)
        }
      })
  }

  var body: some View {
    Form {
      if let issue = model.authorityIssue {
        Section {
          notice("exclamationmark.shield.fill", issue.key, details: issue.details)
        }
      }
      if project != nil { worktreesSection }
      retainedSection
      storageSection
    }
    .formStyle(.grouped)
    .navigationTitle(project?.displayName ?? l("commits.standalone.title"))
    .accessibilityIdentifier(project == nil ? "recovery.inventory" : "project.worktrees.inventory")
    .onChange(of: selectable) { _, choices in selected.formIntersection(choices) }
    .onChange(of: model.epoch) { _, _ in
      selected.removeAll()
      confirmation = nil
    }
    .sheet(item: $confirmation) { confirmation in
      RecoveryConfirmationSheet(model: model, confirmation: confirmation)
    }
    .alert(item: $model.issue) { issue in
      Alert(
        title: Text(verbatim: l(issue.key)),
        message: issue.details.map { Text(verbatim: l($0)) },
        dismissButton: .default(Text(verbatim: l("OK"))))
    }
  }

  private var worktreesSection: some View {
    Section {
      if let issue = model.inventoryIssue {
        notice("exclamationmark.triangle.fill", issue.key, details: issue.details)
      } else if model.inventory == nil {
        ProgressView().controlSize(.small)
      } else if inventory?.isInventoryAvailable != true {
        notice("exclamationmark.triangle.fill", "worktree.inventory.unavailable")
      }
      if let inventory {
        let rows = model.worktrees(for: inventory)
        if rows.isEmpty, inventory.isInventoryAvailable {
          notice(
            "arrow.triangle.branch", "worktree.empty.title", details: l("worktree.empty.message"))
        }
        ForEach(rows) { row in
          worktreeRow(row)
        }
        ForEach(model.removals.filter { $0.review.target.source == inventory.source }) {
          removalRow($0)
        }
      }
    } header: {
      sectionHeader("worktree.section.title", id: "worktree.refresh")
    }
  }

  private func worktreeRow(_ row: RecoveryWorktreeRow) -> some View {
    HStack(alignment: .top, spacing: 12) {
      PrivacySymbol(name: worktreeSymbol(row.state))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(verbatim: row.name).font(.body.weight(.medium))
          Text(verbatim: l(worktreeStatus(row.state)))
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
        }
        if let path = row.path { pathText(path) }
        if let dirty = row.dirty {
          Label(
            l(dirty ? "worktree.status.uncommitted" : "worktree.status.clean"),
            systemImage: dirty ? "pencil.circle.fill" : "checkmark.circle"
          )
          .font(.caption)
          .foregroundStyle(dirty ? Color.orange : Color.secondary)
        }
      }
      .accessibilityElement(children: .combine)
      Spacer(minLength: 8)
      if let target = row.target,
        !model.removals.contains(where: {
          $0.review.target.worktreeID == target.worktreeID && $0.canResume
        })
      {
        Button(l("worktree.action.remove")) {
          Task {
            if let (review, epoch) = await model.reviewRemoval(target) {
              confirmation = .worktree(review, epoch)
            }
          }
        }
        .accessibilityIdentifier("worktree.remove.\(target.worktreeID.uuidString)")
        .controlSize(.small)
        .disabled(!model.canChange || model.inventoryIssue != nil)
      }
    }
    .padding(.vertical, 2)
  }

  private func removalRow(_ removal: WorktreeRecoveryModel.Removal) -> some View {
    let title: String
    let details: String?
    let symbol: String
    if model.activeOperationID == removal.id {
      title = "operation.kind.removing_worktree"
      details = removal.review.branch
      symbol = "clock.arrow.circlepath"
    } else {
      switch removal.outcome {
      case .removed(let result):
        title = "worktree.removal.verified"
        details =
          result.terminationWarnings.isEmpty
          ? l("worktree.writers.drained") : result.terminationWarnings.joined(separator: "\n")
        symbol =
          result.terminationWarnings.isEmpty
          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
      case .refused:
        title = "worktree.removal.refused"
        details = removal.issue.map { l($0.key) }
        symbol = "exclamationmark.triangle.fill"
      default:
        title = removal.issue?.key ?? "worktree.removal.pending"
        details = removal.issue?.details ?? removal.review.branch
        symbol = "exclamationmark.triangle.fill"
      }
    }
    return HStack {
      notice(symbol, title, details: details)
      Spacer()
      if removal.canResume, model.activeOperationID != removal.id {
        Button(l("common.resume")) { Task { await model.retryRemoval(removal) } }
          .disabled(!model.canChange || removal.epoch != model.epoch)
          .accessibilityIdentifier("worktree.removal.resume")
      }
    }
  }

  private var retainedSection: some View {
    Section {
      ForEach(recoveryOperations(for: .release)) { operation in
        recoveryOperationRow(operation)
      }
      if let issue = model.storesIssue {
        notice("exclamationmark.triangle.fill", issue.key, details: issue.details)
      } else if model.stores == nil {
        ProgressView().controlSize(.small)
      } else if !stores.contains(where: { !records(in: $0).isEmpty }) {
        notice("clock.arrow.circlepath", "commits.empty.title", details: l("commits.empty.message"))
      }

      ForEach(stores.filter { !records(in: $0).isEmpty }, id: \.key) { store in
        let identity = RecoveryStoreIdentity(store)
        if project == nil || stores.count > 1 {
          storeLabel(store)
        }
        selectionToolbar(identity)
        ForEach(records(in: store), id: \.id) { record in
          retainedRow(record, store: store, identity: identity)
        }
      }
    } header: {
      sectionHeader("commits.section.title", id: "recovery.retained.refresh")
    } footer: {
      if project == nil {
        Text(verbatim: l("commits.standalone.footer"))
      }
    }
  }

  private func selectionToolbar(_ store: RecoveryStoreIdentity) -> some View {
    let choices = selected.filter { $0.store == store }
    let candidates = selectable.filter { $0.store == store }
    return HStack(spacing: 8) {
      AppLocalization.verbatimText(
        choices.isEmpty
          ? l("commits.selection.none")
          : l.format("commits.selection.count", Int64(choices.count))
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      if choices.count < candidates.count {
        Button(l("common.select_all")) { selected.formUnion(candidates) }
          .buttonStyle(.link)
          .accessibilityIdentifier("recovery.selection.all.\(store.key)")
      }
      if !choices.isEmpty {
        Button(l("common.clear_selection")) { selected.subtract(choices) }
          .buttonStyle(.link)
          .accessibilityIdentifier("recovery.selection.clear.\(store.key)")
      }
      Spacer()
      Button(l("commits.action.review")) {
        Task {
          if let (review, epoch) = await model.reviewRelease(choices) {
            confirmation = .recovery(.release(review), epoch)
          }
        }
      }
      .accessibilityIdentifier("recovery.release.selected.\(store.key)")
      .disabled(choices.isEmpty)
    }
    .controlSize(.small)
    .disabled(!model.canChange || model.storesIssue != nil)
  }

  private func retainedRow(
    _ record: RecoveryRecordView, store: RecoveryStoreView, identity: RecoveryStoreIdentity
  ) -> some View {
    let choice = RetainedRecoverySelection(store: identity, record: record)
    let isSelected = Binding(
      get: { selected.contains(choice) },
      set: { enabled in
        if enabled { selected.insert(choice) } else { selected.remove(choice) }
      })
    return Toggle(isOn: isSelected) {
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: l("recovery.object.\(record.objectType.rawValue)")).font(
          .body.weight(.medium))
        pathText(record.oid)
        let branch = String(record.owner.branch.dropFirst("refs/heads/".count))
        Label(l.format("recovery.last_branch", branch), systemImage: "arrow.triangle.branch")
          .font(.caption)
          .foregroundStyle(.secondary)
        if project == nil {
          if let source = model.inventory?.first(where: { $0.source == record.owner.source }),
            let name = source.projectName
          {
            Text(verbatim: name).font(.caption).foregroundStyle(.secondary)
          } else if model.inventory != nil, model.inventoryIssue == nil {
            Text(verbatim: l("commits.tag.project_removed")).font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        if record.state != .retained {
          Text(verbatim: l("recovery.record_pending")).font(.caption)
            .foregroundStyle(.secondary)
        } else if !model.canSelect(record, in: store) {
          Text(verbatim: l("recovery.record_in_use")).font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .toggleStyle(.checkbox)
    .disabled(!model.canChange || model.storesIssue != nil || !model.canSelect(record, in: store))
    .accessibilityIdentifier("recovery.record.\(record.id.uuidString)")
  }

  private var storageSection: some View {
    Section {
      Text(verbatim: l("storage.description"))
        .foregroundStyle(.secondary)
      ForEach(stores, id: \.key) { store in
        let identity = RecoveryStoreIdentity(store)
        let measured = recoveryOperations(for: .maintenance).filter {
          RecoveryStoreIdentity($0.review.handle) == identity
        }
        if project == nil || stores.count > 1 { storeLabel(store) }
        ForEach(measured) { operation in
          recoveryOperationRow(operation)
        }
        Button(l("storage.action.reclaim")) {
          Task {
            if let (review, epoch) = await model.prepareMaintenance(identity) {
              confirmation = .recovery(.maintenance(review), epoch)
            }
          }
        }
        .accessibilityIdentifier("recovery.storage.reclaim.\(store.key)")
        .disabled(!model.canChange || model.storesIssue != nil || store.activeOperation != nil)
      }
    } header: {
      Text(verbatim: l("storage.section.title"))
    }
  }

  private func recoveryOperations(for action: RecoveryOperationHandle.Action)
    -> [WorktreeRecoveryModel.Operation]
  {
    let storeIDs = Set(stores.map(RecoveryStoreIdentity.init))
    return model.operations.filter {
      $0.review.handle.action == action
        && storeIDs.contains(RecoveryStoreIdentity($0.review.handle))
    }
  }

  private func recoveryOperationRow(_ operation: WorktreeRecoveryModel.Operation) -> some View {
    let title: String
    let details: String?
    let symbol: String
    let running = model.activeOperationID == operation.id
    if running {
      title =
        operation.review.handle.action == .release
        ? "operation.kind.releasing_commits" : "operation.kind.reclaiming_storage"
      details = nil
      symbol = "clock.arrow.circlepath"
    } else if let issue = operation.issue {
      title = issue.key
      details = issue.details
      symbol = "exclamationmark.triangle.fill"
    } else {
      switch operation.status?.outcome {
      case .released:
        let count: Int
        if case .release(let review) = operation.review {
          count = review.records.count
        } else {
          count = 0
        }
        title = l.format("recovery.release_completed", Int64(count))
        let gates = operation.status?.gates ?? []
        if gates.contains(where: { $0.cleanup == .identityChanged }) {
          details = l("recovery.gate_identity_changed")
        } else if gates.contains(where: { $0.cleanup == .pending }) {
          details = l("recovery.gate_pending")
        } else {
          details = l("recovery.release_completed_detail")
        }
        symbol = "checkmark.circle.fill"
      case .measured(let allocation):
        let date =
          operation.measuredAt?.formatted(.dateTime.month().day().hour().minute().locale(locale))
          ?? "—"
        title =
          allocation.reclaimedBytes == 0
          ? l.format("storage.result.none_reclaimed", date)
          : l.format(
            "storage.result.measured",
            allocation.reclaimedBytes.formatted(.byteCount(style: .file).locale(locale)), date)
        details = l.format(
          "storage.allocation",
          allocation.baselineBytes.formatted(.byteCount(style: .file).locale(locale)),
          allocation.finalBytes.formatted(.byteCount(style: .file).locale(locale)))
        symbol = "checkmark.circle.fill"
      case .stale:
        title = "recovery.review_changed"
        details = nil
        symbol = "exclamationmark.triangle.fill"
      case .busy(let reason), .deferred(let reason):
        title = "storage.reclamation_deferred"
        details = l(reason)
        symbol = "exclamationmark.triangle.fill"
      case .recoveryRequired(let reason):
        title = "recovery.requires_attention"
        details = l(reason)
        symbol = "exclamationmark.triangle.fill"
      case .pending, nil:
        title = "recovery.operation_interrupted"
        details = nil
        symbol = "exclamationmark.triangle.fill"
      }
    }
    return HStack {
      notice(symbol, title, details: details)
      Spacer()
      if running {
        ProgressView().controlSize(.small).accessibilityLabel(Text(verbatim: l(title)))
      } else if operation.canResume {
        Button(l("common.resume")) { Task { await model.retry(operation) } }
          .accessibilityIdentifier("recovery.operation.resume.\(operation.id.uuidString)")
          .disabled(!model.canChange || (operation.epoch.map { $0 != model.epoch } ?? false))
      }
    }
  }

  private func records(in store: RecoveryStoreView) -> [RecoveryRecordView] {
    guard project != nil else { return store.records }
    guard let source = inventory?.source else { return [] }
    return store.records.filter { $0.owner.source == source }
  }

  private func sectionHeader(_ key: String, id: String) -> some View {
    HStack {
      Text(verbatim: l(key))
      Spacer()
      Button {
        Task { await model.refresh() }
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.borderless)
      .help(l("common.refresh"))
      .accessibilityLabel(l("common.refresh") + " " + l(key))
      .accessibilityIdentifier(id)
      .disabled(model.isWorking)
    }
  }

  private func storeLabel(_ store: RecoveryStoreView) -> some View {
    Label {
      pathText(store.repository.sourcePath)
    } icon: {
      PrivacySymbol(name: "internaldrive")
        .accessibilityHidden(true)
    }
  }

  private func pathText(_ value: String) -> some View {
    Text(verbatim: value)
      .font(.caption.monospaced())
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .truncationMode(.middle)
      .textSelection(.enabled)
      .help(value)
  }

  private func notice(_ symbol: String, _ key: String, details: String? = nil) -> some View {
    Label {
      VStack(alignment: .leading, spacing: 3) {
        Text(verbatim: l(key))
        if let details {
          Text(verbatim: details)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    } icon: {
      PrivacySymbol(name: symbol)
        .accessibilityHidden(true)
    }
  }

  private func worktreeStatus(_ state: RecoveryWorktreeRow.State) -> String {
    switch state {
    case .active: "worktree.state.managed"
    case .removed: "worktree.state.removed"
    case .foreign: "worktree.state.external"
    case .unavailable: "worktree.state.unavailable"
    }
  }

  private func worktreeSymbol(_ state: RecoveryWorktreeRow.State) -> String {
    switch state {
    case .active: "folder.badge.gearshape"
    case .removed: "folder.badge.minus"
    case .foreign: "arrow.up.forward.square"
    case .unavailable: "exclamationmark.triangle.fill"
    }
  }
}

@MainActor
struct WorktreeRecoveryPrivacyLink: View {
  @Environment(\.locale) private var locale
  @Environment(\.localizationResources) private var resources
  @ObservedObject var model: WorktreeRecoveryModel

  var body: some View {
    let l = PrivacyText(locale: locale, resources: resources)
    NavigationLink(value: PrivacyRoute.recovery) {
      Label {
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: l("entry.privacy.row_title"))
          Text(verbatim: l("entry.privacy.row_subtitle"))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } icon: {
        PrivacySymbol(name: "clock.arrow.circlepath").accessibilityHidden(true)
      }
    }
    .badge(model.retainedCount)
    .accessibilityIdentifier("privacy.recovery.storage")
  }
}

enum RecoveryConfirmation: Identifiable {
  case worktree(ManagedWorktreeRemovalReview, UUID)
  case recovery(RecoveryOperationReview, UUID)

  var id: UUID {
    switch self {
    case .worktree(let review, _): review.operationID
    case .recovery(let review, _): review.handle.id
    }
  }
}

@MainActor
struct RecoveryConfirmationSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale
  @Environment(\.localizationResources) private var resources
  @ObservedObject var model: WorktreeRecoveryModel
  let confirmation: RecoveryConfirmation
  @State private var confirmsDiscard = false

  private var l: PrivacyText { .init(locale: locale, resources: resources) }

  var body: some View {
    switch confirmation {
    case .worktree(let review, let epoch):
      worktree(review, epoch: epoch)
    case .recovery(let operation, let epoch):
      switch operation {
      case .release(let review):
        sheet(
          l.format("commits.dialog.release.title", Int64(review.records.count)),
          message: l("recovery.release_review_detail"),
          button: "commits.dialog.release.confirm"
        ) {
          submit(operation, epoch: epoch)
        } content: {
          identityRows {
            LabeledContent(l("recovery.store_identity")) { identifier(review.handle.storeKey) }
            LabeledContent(
              l("recovery.store_generation"), value: review.handle.generation.uuidString)
            ForEach(review.records, id: \.id) { record in
              VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: l("recovery.object.\(record.objectType.rawValue)"))
                identifier(record.oid)
                identifier(record.id.uuidString)
                Text(verbatim: record.owner.source.root).font(.caption)
                Text(verbatim: record.owner.branch).font(.caption)
              }
              .accessibilityElement(children: .combine)
            }
          }
        }
      case .maintenance(let review):
        sheet(
          l("storage.dialog.reclaim.title"),
          message: l("storage.dialog.reclaim.message"),
          button: "storage.dialog.reclaim.confirm"
        ) {
          submit(operation, epoch: epoch)
        } content: {
          identityRows {
            LabeledContent(l("recovery.store_identity")) { identifier(review.handle.storeKey) }
            LabeledContent(
              l("recovery.store_generation"), value: review.handle.generation.uuidString)
            LabeledContent(
              l("storage.review.allocated"),
              value: review.baselineBytes.formatted(.byteCount(style: .file).locale(locale)))
            if let hash = review.packHash {
              LabeledContent(l("storage.review.pack")) { identifier(hash) }
            }
          }
        }
      }
    }
  }

  private func worktree(_ review: ManagedWorktreeRemovalReview, epoch: UUID) -> some View {
    sheet(
      l.format("worktree.dialog.remove.title", review.branch),
      message: l("worktree.removal.review_detail"),
      button: review.hasUncommittedChanges
        ? "worktree.action.review_discard" : "worktree.dialog.remove.confirm",
      needsDiscard: review.hasUncommittedChanges
    ) {
      if review.hasUncommittedChanges {
        confirmsDiscard = true
      } else {
        dismiss()
        Task { await model.confirmRemoval(review, discard: false, epoch: epoch) }
      }
    } content: {
      identityRows {
        Text(verbatim: review.path).textSelection(.enabled)
        LabeledContent(l("worktree.review.head")) { identifier(review.head) }
        if review.hasUncommittedChanges {
          Label(l("worktree.status.uncommitted"), systemImage: "exclamationmark.triangle.fill")
            .symbolRenderingMode(.multicolor)
        }
      }
    }
    .confirmationDialog(
      l.format("worktree.dialog.discard.title", review.branch), isPresented: $confirmsDiscard,
      titleVisibility: .visible
    ) {
      Button(l("worktree.dialog.discard_remove.confirm"), role: .destructive) {
        dismiss()
        Task { await model.confirmRemoval(review, discard: true, epoch: epoch) }
      }
      .accessibilityIdentifier("worktree.discard.confirm")
      Button(l("common.cancel"), role: .cancel) {}
    } message: {
      Text(verbatim: l("worktree.dialog.discard_remove.message") + "\n" + review.path)
    }
  }

  private func sheet<Content: View>(
    _ title: String, message: String, button: String, needsDiscard: Bool = false,
    action: @escaping () -> Void, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(verbatim: title).font(.headline)
      Text(verbatim: message).fixedSize(horizontal: false, vertical: true)
      content()
      HStack {
        Spacer()
        Button(l("common.cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(l(button), role: needsDiscard ? nil : .destructive, action: action)
          .accessibilityIdentifier("recovery.review.confirm")
          .disabled(!model.canChange)
      }
    }
    .padding(20)
    .frame(width: 540)
  }

  private func identityRows<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 9, content: content)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }
    .defaultScrollAnchor(.top)
    .frame(minHeight: 80, idealHeight: 180, maxHeight: 280)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
  }

  private func identifier(_ value: String) -> some View {
    Text(verbatim: value).font(.caption.monospaced()).textSelection(.enabled)
  }

  private func submit(_ operation: RecoveryOperationReview, epoch: UUID) {
    dismiss()
    Task { await model.confirm(operation, epoch: epoch) }
  }
}
