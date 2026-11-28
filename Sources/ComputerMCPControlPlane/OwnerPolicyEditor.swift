import ComputerMCPGateway
import ComputerMCPPermissions
import Foundation

/// A draft and the authority reviewed for its next write.
package struct OwnerPolicyEditor: Sendable {
  package private(set) var reviewed: GatewayOwnerPolicySnapshot
  package var draft: String
  package private(set) var savedText: String?
  /// A successful write invalidates the reviewed revision and limits until reload.
  package private(set) var requiresReload = false

  package var isDirty: Bool { !draft.utf8.elementsEqual((savedText ?? "").utf8) }
  package var canEdit: Bool { reviewed.canEdit && !requiresReload }

  fileprivate init(reviewed: GatewayOwnerPolicySnapshot) {
    self.reviewed = reviewed
    savedText = reviewed.savedText
    draft = reviewed.savedText ?? ""
  }

  fileprivate mutating func recordCommit(_ text: String?) {
    savedText = text
    draft = text ?? ""
    requiresReload = true
  }
}

/// Local owner operations for the Privacy & Security editor, backed by the live gateway.
package actor OwnerPolicyEditorService {
  private let control: PermissionControlService

  package init(control: PermissionControlService) {
    self.control = control
  }

  package func load(_ target: GatewayOwnerPolicyTarget) throws -> OwnerPolicyEditor {
    try .init(reviewed: control.ownerPolicySnapshot(for: target))
  }

  package func reload(
    _ editor: OwnerPolicyEditor, preservingDraft: Bool
  ) throws -> OwnerPolicyEditor {
    var fresh = try load(editor.reviewed.target)
    if preservingDraft { fresh.draft = editor.draft }
    return fresh
  }

  package func parse(_ draft: String) throws {
    try control.validateOwnerPolicy(Data(draft.utf8))
  }

  package func save(_ editor: OwnerPolicyEditor) throws -> OwnerPolicyEditor {
    try commit(editor.draft, to: editor)
  }

  package func clear(_ editor: OwnerPolicyEditor) throws -> OwnerPolicyEditor {
    try commit(nil, to: editor)
  }

  private func commit(_ text: String?, to editor: OwnerPolicyEditor) throws -> OwnerPolicyEditor {
    guard !editor.requiresReload else { throw GatewayPermissionError.revisionConflict }
    guard editor.reviewed.canEdit, let epoch = editor.reviewed.epoch else {
      throw PermissionModelError.authoritySuspended
    }
    try control.writeOwnerPolicy(
      text.map { Data($0.utf8) }, target: editor.reviewed.target,
      revision: editor.reviewed.revision,
      epoch: epoch)
    var committed = editor
    // An unavailable readback must not turn a committed write into a reported failure.
    committed.recordCommit(text)
    return committed
  }
}

extension AppControlPlaneService {
  package func ownerPolicyEditorService() throws -> OwnerPolicyEditorService {
    try OwnerPolicyEditorService(control: requirePermissionControl())
  }
}
