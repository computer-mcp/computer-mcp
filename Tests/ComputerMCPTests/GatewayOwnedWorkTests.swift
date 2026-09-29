import Foundation
import Testing
import os

@testable import ComputerMCP

@Suite
struct GatewayOwnedWorkTests {
  @Test
  func idleRetirementIsAtomicWithInvocationAdmission() throws {
    for _ in 0..<100 {
      let work = GatewayOwnedWork()
      let outcomes = OSAllocatedUnfairLock(
        initialState: (admitted: Optional<GatewayOwnedWork.Lease>.none, retired: false))
      DispatchQueue.concurrentPerform(iterations: 2) { index in
        if index == 0 {
          let lease = try? work.admitInvocation(workspaceID: "ws", resourceID: "call")
          outcomes.withLock { $0.admitted = lease }
        } else {
          let retired = work.closeAdmissionIfDrained()
          outcomes.withLock { $0.retired = retired }
        }
      }
      let result = outcomes.withLock { $0 }
      #expect((result.admitted != nil) != result.retired)
      result.admitted?.finish()
      #expect(work.closeAdmissionIfDrained())
      #expect(throws: GatewayToolError.self) {
        try work.admitInvocation(workspaceID: "ws", resourceID: "late")
      }
      #expect(work.snapshot.isEmpty)
    }
  }

  @Test
  func backgroundAndUncertainOwnersPreventIdleRetirement() throws {
    let work = GatewayOwnedWork()
    let invocation = try work.admitInvocation(workspaceID: "ws", resourceID: "call")
    let background = work.retain(.mcpResource, workspaceID: "ws", resourceID: "native")
    invocation.finish()
    #expect(!work.closeAdmissionIfDrained())
    background.markUncertain()
    #expect(!work.closeAdmissionIfDrained())
    let recovery = try work.admitInvocation(workspaceID: "ws", resourceID: "recover")
    background.finish()
    #expect(!work.closeAdmissionIfDrained())
    recovery.finish()
    #expect(work.closeAdmissionIfDrained())
  }

  @Test
  func lostObservationKeepsAnUncertainOwner() {
    let work = GatewayOwnedWork()
    let id = work.retain(.mcpRequest, registrationID: "remote", resourceID: "request").id
    #expect(work.snapshot.count == 1)
    #expect(work.snapshot.first?.id == id)
    #expect(work.snapshot.first?.uncertain == true)
  }

  @Test
  func completionAndObservationLossCannotResurrectAnOwner() async {
    let work = GatewayOwnedWork()
    let ownership = work.retain(.invocation, resourceID: "request")
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<20 {
        group.addTask { ownership.finish() }
        group.addTask { ownership.markUncertain() }
        group.addTask { ownership.confirmObservation() }
      }
    }
    #expect(work.snapshot.isEmpty)
  }
}
