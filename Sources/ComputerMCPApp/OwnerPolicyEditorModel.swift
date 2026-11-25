import ComputerMCPControlPlane
import ComputerMCPGateway
import SwiftUI

@MainActor
final class OwnerPolicyEditorModel: ObservableObject {
  enum Issue {
    case parser(String)
    case operation(String)
  }

  let target: PrivacyOwnerPolicyTarget
  @Published private(set) var editor: OwnerPolicyEditor?
  @Published private(set) var issue: Issue?
  @Published private(set) var currentReview: OwnerPolicyEditor?
  @Published private(set) var busy = false
  @Published private(set) var isStale = false

  private let privacy: PrivacySecurityModel
  private var service: OwnerPolicyEditorService?

  init(target: PrivacyOwnerPolicyTarget, privacy: PrivacySecurityModel) {
    self.target = target
    self.privacy = privacy
  }

  var draft: String {
    get { editor?.draft ?? "" }
    set {
      guard canEditDraft else { return }
      editor?.draft = newValue
      if case .parser = issue { issue = nil }
    }
  }

  var canEditDraft: Bool { editor?.canEdit == true && !busy }
  var canSave: Bool { canEditDraft && editor?.isDirty == true && !isStale }
  var canClear: Bool {
    guard canEditDraft, !isStale, let source = editor?.reviewed.ownerSource else { return false }
    return source.revision != "absent"
  }

  func load() async {
    guard editor == nil, !busy else { return }
    busy = true
    defer { busy = false }
    do {
      let service = try await privacy.ownerPolicyEditorService()
      editor = try await service.load(target.id)
      self.service = service
      issue = nil
    } catch {
      issue = .operation(AppLocalization.errorDescription(error))
    }
  }

  func reload() async {
    guard !busy else { return }
    guard let editor, let service else {
      await load()
      return
    }
    busy = true
    defer { busy = false }
    do {
      self.editor = try await service.reload(editor, preservingDraft: false)
      currentReview = nil
      isStale = false
      issue = nil
      await privacy.refresh()
    } catch {
      issue = .operation(AppLocalization.errorDescription(error))
    }
  }

  func reviewCurrent() async {
    guard isStale, !busy, let editor, let service else { return }
    busy = true
    defer { busy = false }
    do {
      currentReview = try await service.reload(editor, preservingDraft: true)
      issue = nil
    } catch {
      issue = .operation(AppLocalization.errorDescription(error))
    }
  }

  func acceptReview(keepingDraft: Bool) {
    guard !busy, var reviewed = currentReview else { return }
    if keepingDraft {
      reviewed.draft = draft
    } else {
      reviewed.draft = reviewed.savedText ?? ""
    }
    editor = reviewed
    currentReview = nil
    isStale = false
    issue = nil
  }

  func revert() {
    draft = editor?.savedText ?? ""
  }

  func save() async {
    guard canSave else { return }
    await commit(clearing: false)
  }

  func clear() async {
    guard canClear else { return }
    await commit(clearing: true)
  }

  private func commit(clearing: Bool) async {
    guard let editor, let service else { return }
    busy = true
    defer { busy = false }
    issue = nil
    if !clearing {
      do { try await service.parse(editor.draft) } catch {
        issue = .parser(String(String(describing: error).prefix(300)))
        return
      }
    }
    do {
      self.editor =
        if clearing { try await service.clear(editor) } else { try await service.save(editor) }
      await privacy.refresh()
    } catch GatewayPermissionError.revisionConflict {
      isStale = true
    } catch {
      issue = .operation(AppLocalization.errorDescription(error))
    }
  }
}
