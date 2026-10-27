import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPSandbox
import Foundation
import Testing

@testable import ComputerMCPGateway

struct ExecutionRecoveryJournalTests {
  enum RootSpelling: String, CaseIterable, Sendable {
    case physical, temporary, symlink
  }

  @Test(arguments: RootSpelling.allCases)
  func receiptLifecyclePreservesExactOwnership(rootSpelling: RootSpelling) throws {
    let fixture = try JournalFixture(rootSpelling: rootSpelling)
    defer { fixture.remove() }
    let journal = try ExecutionRecoveryJournal(directory: fixture.directory)
    var expected = fixture.receipt()
    try journal.save(expected)
    try expectReceipt(journal.all(), matching: expected)
    #expect(throws: ExecutionEnvironmentError.unavailable("Execution exit is unconfirmed")) {
      try journal.release(expected.child)
    }
    try expectReceipt(journal.all(), matching: expected)
    try journal.confirm(expected.child)
    expected.completed = true
    try expectReceipt(journal.all(), matching: expected)
    try journal.release(expected.child)
    expected.released = true
    try expectReceipt(journal.all(), matching: expected)
    let reopened = try ExecutionRecoveryJournal(directory: fixture.directory)
    try expectReceipt(reopened.all(), matching: expected)
  }

  @Test(arguments: [false, true])
  func receiptFilenameMustMatchItsChildIdentity(validUUID: Bool) throws {
    let fixture = try JournalFixture(rootSpelling: .temporary)
    defer { fixture.remove() }
    let journal = try ExecutionRecoveryJournal(directory: fixture.directory)
    let receipt = fixture.receipt()
    try journal.save(receipt)
    let name = validUUID ? UUID().uuidString : "invalid-child"
    try FileManager.default.moveItem(
      at: fixture.file(receipt.child),
      to: fixture.directory.appendingPathComponent(name + ".json"))
    #expect(
      throws: ExecutionEnvironmentError.unavailable(
        validUUID ? "Invalid ownership receipt identity" : "Invalid ownership receipt name")
    ) {
      try journal.all()
    }
  }

  @Test
  func releasedReceiptRequiresConfirmedCompletion() throws {
    let fixture = try JournalFixture(rootSpelling: .symlink)
    defer { fixture.remove() }
    let journal = try ExecutionRecoveryJournal(directory: fixture.directory)
    var receipt = fixture.receipt()
    receipt.released = true
    let invalid = try JSONEncoder().encode(receipt)
    try invalid.write(to: fixture.file(receipt.child))
    let error = ExecutionEnvironmentError.unavailable("Invalid ownership receipt identity")
    #expect(throws: error) { try journal.all() }
    #expect(throws: error) { try journal.confirm(receipt.child) }
    #expect(throws: error) { try journal.release(receipt.child) }
    #expect(try Data(contentsOf: fixture.file(receipt.child)) == invalid)
  }

  @Test
  func oversizedReceiptIsRefusedBeforeDecoding() throws {
    let fixture = try JournalFixture(rootSpelling: .physical)
    defer { fixture.remove() }
    let journal = try ExecutionRecoveryJournal(directory: fixture.directory)
    try Data(repeating: 0x20, count: 131_073).write(to: fixture.file(UUID()))
    #expect(throws: ExecutionEnvironmentError.unavailable("Invalid ownership receipt")) {
      try journal.all()
    }
  }

  private func expectReceipt(
    _ receipts: [ExecutionRecoveryJournal.Entry], matching expected: ExecutionRecoveryJournal.Entry
  ) throws {
    try #require(receipts.count == 1)
    let actual = try #require(receipts.first)
    #expect(actual.child == expected.child)
    #expect(actual.execution == expected.execution)
    #expect(actual.owner == expected.owner)
    #expect(actual.boot == expected.boot)
    #expect(actual.recovery.root.processID == expected.recovery.root.processID)
    #expect(actual.recovery.root.identity == expected.recovery.root.identity)
    #expect(actual.recovery.sandboxed == expected.recovery.sandboxed)
    #expect(actual.recovery.backend == expected.recovery.backend)
    #expect(actual.recovery.payload == expected.recovery.payload)
    #expect(actual.completed == expected.completed)
    #expect(actual.released == expected.released)
  }

  private struct JournalFixture {
    let root: URL
    let directory: URL

    init(rootSpelling: RootSpelling) throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let physical = try ProjectPathResolver.canonicalProject(root)
      let selected: URL
      switch rootSpelling {
      case .physical: selected = physical
      case .temporary: selected = root
      case .symlink:
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
        selected = alias
      }
      directory = selected.appendingPathComponent("receipts", isDirectory: true)
    }

    func receipt() -> ExecutionRecoveryJournal.Entry {
      .init(
        child: UUID(), execution: UUID(), owner: UUID(), boot: "fixture-boot",
        recovery: .init(
          root: .init(processID: 42, identity: 123), sandboxed: true,
          backend: "fixture", payload: Data([0x00, 0x7F, 0xFF])))
    }

    func file(_ child: UUID) -> URL {
      directory.appendingPathComponent(child.uuidString + ".json")
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
  }
}
