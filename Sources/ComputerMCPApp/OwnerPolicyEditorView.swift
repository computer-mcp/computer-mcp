import ComputerMCPControlPlane
import SwiftUI

struct OwnerPolicyEditorView: View {
  @Environment(\.locale) private var locale
  @Environment(\.localizationResources) private var resources
  private var l: PrivacyText { .init(locale: locale, resources: resources) }

  @StateObject var model: OwnerPolicyEditorModel
  let close: () -> Void
  @State private var confirmation: Confirmation?
  @FocusState private var draftFocused: Bool

  private enum Confirmation {
    case clear, reload, close
  }

  var body: some View {
    NavigationStack {
      Form {
        if let editor = model.editor {
          sourceSection(editor)
          draftSection(editor)
          if !editor.requiresReload {
            OwnerPolicyLimitsView(snapshot: editor.reviewed)
          }
        } else if model.busy {
          ProgressView(l("Loading Owner Policy…"))
        } else if let issue = model.issue {
          Section {
            errorNotice(issue)
            Button(l("Reload")) { Task { await model.reload() } }
              .accessibilityIdentifier("privacy.ownerPolicy.reloadButton")
          }
        }
      }
      .formStyle(.grouped)
      .accessibilityIdentifier("privacy.ownerPolicy.editor")
      .navigationTitle(l.format("Owner Policy for %@", model.target.title))
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(l("Done")) {
            if model.editor?.isDirty == true { confirmation = .close } else { close() }
          }
          .keyboardShortcut(.cancelAction)
          .disabled(model.busy)
          .accessibilityIdentifier("privacy.ownerPolicy.doneButton")
        }
      }
    }
    .frame(minWidth: 600, idealWidth: 660, minHeight: 620, idealHeight: 720)
    .interactiveDismissDisabled(model.busy || model.editor?.isDirty == true)
    .task { await model.load() }
    .confirmationDialog(
      confirmationTitle,
      isPresented: Binding(
        get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
      titleVisibility: .visible, presenting: confirmation
    ) { action in
      Button(l(confirmationAction(action)), role: .destructive) {
        switch action {
        case .clear: Task { await model.clear() }
        case .reload: Task { await model.reload() }
        case .close: close()
        }
      }
      .accessibilityIdentifier("privacy.ownerPolicy.confirmButton")
      Button(l("Cancel"), role: .cancel) {}
    } message: { action in
      if action == .clear {
        Text(
          verbatim: l(
            "Clearing removes this owner's policy. Limits from other sources still apply."))
      }
    }
  }

  private var confirmationTitle: String {
    switch confirmation {
    case .clear: l.format("Clear the saved policy for %@?", model.target.title)
    case .reload: l("Discard unsaved draft changes and reload?")
    case .close: l("Discard unsaved draft changes?")
    case nil: ""
    }
  }

  private func confirmationAction(_ action: Confirmation) -> String {
    switch action {
    case .clear: "Clear Policy"
    case .reload: "Discard and Reload"
    case .close: "Discard"
    }
  }

  private func sourceSection(_ editor: OwnerPolicyEditor) -> some View {
    Section(l("Policy Source")) {
      LabeledContent {
        if editor.requiresReload {
          Text(verbatim: l(editor.savedText == nil ? "Not Set" : "Saved"))
            .foregroundStyle(.secondary)
        } else {
          PolicySourceStatusText(
            state: editor.reviewed.ownerSource.map(LivePrivacySecurityService.source)?.state
              ?? .absent)
        }
      } label: {
        Label {
          Text(verbatim: model.target.title)
        } icon: {
          PrivacySymbol(name: model.target.symbol)
        }
      }
      .accessibilityIdentifier("privacy.ownerPolicy.sourceStatus")

      if editor.requiresReload {
        notice(
          "Reload Required",
          editor.savedText == nil
            ? "Policy cleared. Reload to see the current limits."
            : "Policy saved. Reload to see the current limits.",
          symbol: "arrow.clockwise.circle.fill", color: .accentColor
        )
        .accessibilityIdentifier("privacy.ownerPolicy.reloadRequiredBanner")
      } else {
        if let failure = editor.reviewed.ownerSource?.failure {
          Text(verbatim: l(failure))
            .font(.callout)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
        if !editor.canEdit {
          notice(
            "Read-Only",
            "Confirm the restored permissions in Privacy & Security to edit this policy.",
            symbol: "lock.fill", color: .secondary)
        }
      }

      if model.isStale { staleReview }
      if let issue = model.issue { errorNotice(issue) }
    }
  }

  private var staleReview: some View {
    VStack(alignment: .leading, spacing: 10) {
      notice(
        "Policy Source Changed",
        "Your draft is preserved. Review the current source before saving or clearing.",
        symbol: "exclamationmark.triangle.fill", color: .orange
      )
      .accessibilityIdentifier("privacy.ownerPolicy.staleReviewBanner")
      if let current = model.currentReview {
        Text(verbatim: l("Current Saved Source"))
          .font(.headline)
        if let savedText = current.savedText {
          ScrollView {
            Text(verbatim: savedText)
              .font(.body.monospaced())
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 140)
          .accessibilityIdentifier("privacy.ownerPolicy.currentSourcePreview")
        } else {
          Text(
            verbatim: l(
              current.reviewed.ownerSource?.failure == nil
                ? "No policy is saved for this owner." : "The current saved source can't be read.")
          )
          .foregroundStyle(.secondary)
        }
        HStack {
          Button(l("Replace Draft")) { model.acceptReview(keepingDraft: false) }
            .accessibilityIdentifier("privacy.ownerPolicy.replaceDraftButton")
          Button(l("Keep Draft on Current Revision")) { model.acceptReview(keepingDraft: true) }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("privacy.ownerPolicy.keepDraftButton")
        }
      } else {
        Button(l("Review Current Source")) { Task { await model.reviewCurrent() } }
          .accessibilityIdentifier("privacy.ownerPolicy.reviewCurrentSourceButton")
      }
    }
    .disabled(model.busy)
  }

  private func draftSection(_ editor: OwnerPolicyEditor) -> some View {
    Section(l(editor.canEdit ? "Owner Policy" : "Saved Policy Source")) {
      if editor.canEdit {
        if editor.reviewed.ownerSource?.revision == "absent" || editor.reviewed.ownerSource == nil {
          Text(verbatim: l("Enter a TOML policy to set limits for this owner."))
            .foregroundStyle(.secondary)
        }
        TextEditor(text: Binding(get: { model.draft }, set: { model.draft = $0 }))
          .font(.body.monospaced())
          .frame(minHeight: 180)
          .focused($draftFocused)
          .disabled(!model.canEditDraft)
          .accessibilityLabel(l("Owner policy draft"))
          .accessibilityHint(l("Edit the TOML policy. Press Command-S to save."))
          .accessibilityIdentifier("privacy.ownerPolicy.draft")
      } else {
        Text(verbatim: editor.savedText ?? l("No readable saved policy for this owner."))
          .font(.body.monospaced())
          .textSelection(.enabled)
      }
      HStack(spacing: 10) {
        if editor.canEdit, editor.reviewed.ownerSource?.revision != nil,
          editor.reviewed.ownerSource?.revision != "absent"
        {
          Button(l("Clear Policy…"), role: .destructive) { confirmation = .clear }
            .disabled(!model.canClear)
            .accessibilityIdentifier("privacy.ownerPolicy.clearButton")
        }
        Button(l(editor.requiresReload ? "Reload Now" : "Reload")) {
          if editor.isDirty { confirmation = .reload } else { Task { await model.reload() } }
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(model.busy)
        .accessibilityIdentifier(
          editor.requiresReload
            ? "privacy.ownerPolicy.reloadNowButton" : "privacy.ownerPolicy.reloadButton")
        if model.busy {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel(l("Working…"))
        }
        Spacer(minLength: 8)
        if editor.isDirty {
          Button(l("Revert")) { model.revert() }
            .disabled(!model.canEditDraft)
            .accessibilityIdentifier("privacy.ownerPolicy.revertButton")
        }
        if editor.canEdit {
          Button(l("Save")) {
            Task {
              await model.save()
              if case .parser = model.issue { draftFocused = true }
            }
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut("s", modifiers: .command)
          .disabled(!model.canSave)
          .accessibilityIdentifier("privacy.ownerPolicy.saveButton")
        }
      }
      .buttonStyle(.bordered)
    }
  }

  private func errorNotice(_ issue: OwnerPolicyEditorModel.Issue) -> some View {
    switch issue {
    case .parser(let detail):
      notice("Invalid TOML", detail, symbol: "exclamationmark.triangle.fill", color: .red)
        .accessibilityIdentifier("privacy.ownerPolicy.parseError")
    case .operation(let detail):
      notice("Operation Failed", detail, symbol: "exclamationmark.triangle.fill", color: .red)
        .accessibilityIdentifier("privacy.ownerPolicy.operationError")
    }
  }

  private func notice(_ title: String, _ message: String, symbol: String, color: Color) -> some View
  {
    Label {
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: l(title)).font(.headline)
        Text(verbatim: l(message))
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: symbol)
        .foregroundStyle(color)
        .accessibilityHidden(true)
    }
    .accessibilityElement(children: .combine)
  }
}
