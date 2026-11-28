import Foundation

extension NetworkAccess {
  /// Applies configuration without borrowing another principal's evidence. Rules
  /// retained in the same collection keep their identity across an owner edit.
  package func updating(to proposed: NetworkAccess) -> NetworkAccess {
    guard configuration != proposed.configuration else { return self }
    var result = proposed.freshDraft()
    if result.fullRule != nil { result.fullRule = fullRule ?? result.fullRule }
    if result.trustedRule != nil { result.trustedRule = trustedRule ?? result.trustedRule }
    result.customRules = Set(
      result.customRules.map { rule in
        customRules.first { $0.host == rule.host } ?? rule
      })
    return result
  }
}

extension PermissionLedger {
  package var pendingRevocations: RevocationResult {
    RevocationResult(executionsToTerminate: pendingExecutionTerminations)
  }
}
