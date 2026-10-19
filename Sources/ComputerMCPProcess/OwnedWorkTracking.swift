/// Records work that outlives the call that started it, so its owner can drain it.
package protocol OwnedWorkTracking: Sendable {
  /// Records a running shell session until the returned lease finishes.
  func retainShell(workspaceID: String?, sessionID: String) -> any OwnedWorkLease
}

/// A record of running work. Releasing the lease without `finish()` leaves the work
/// reported as uncertain, because losing the reference does not prove the work stopped.
package protocol OwnedWorkLease: Sendable {
  func finish()
}
