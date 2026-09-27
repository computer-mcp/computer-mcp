import Foundation
import Testing

@testable import ComputerMCP

@Suite
struct GatewayOwnedWorkTests {
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
