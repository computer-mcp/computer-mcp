import Foundation
import Testing

@testable import ComputerMCPWorktrees

struct WorktreePackBoundsTests {
  @Test func defaultsAndPublishedCeilings() throws {
    let limits = WorktreePromotionLimits()
    #expect(limits.inputBytes == 512 * 1024 * 1024)
    #expect(limits.inflatedBytes == 2 * 1024 * 1024 * 1024)
    #expect(limits.objectBytes == 128 * 1024 * 1024)
    #expect(limits.objectCount == 250_000)
    #expect(limits.duration == .seconds(120))
    for (format, pack, index, staging) in [
      (WorktreeObjectFormat.sha1, 2_454_438_411, 9_001_072, 10_954_502_972),
      (.sha256, 2_454_438_423, 12_001_096, 10_975_503_188),
    ] {
      let maximum = try WorktreePackBounds.maximum(format: format)
      #expect(maximum.packBytes == pack)
      #expect(maximum.indexBytes == index)
      #expect(try WorktreePackBounds.stagingMaximum(format: format) == staging)
    }
  }

  @Test func integerBoundariesAndOverflow() throws {
    for (size, compressed, header) in [
      (0, 13, 1), (1, 16, 1), (7, 22, 1), (8, 23, 1), (15, 31, 1),
      (16, 32, 2), (63, 85, 2), (64, 86, 2), (127, 158, 2),
      (128, 159, 2), (2047, 2348, 2), (2048, 2349, 3),
    ] {
      #expect(try WorktreePackBounds.compression(size) == compressed)
      #expect(try WorktreePackBounds.header(size) == header)
    }
    #expect(try WorktreePackBounds.header(128 * 1024 * 1024) == 5)
    #expect(throws: WorktreeError.self) { try WorktreePackBounds.header(-1) }
    #expect(throws: WorktreeError.self) { try WorktreePackBounds.compression(-1) }
    #expect(throws: WorktreeError.self) { try WorktreePackBounds.compression(Int.max) }
    #expect(throws: WorktreeError.self) { try WorktreePackBounds.sum(Int.max, 1) }
    #expect(throws: WorktreeError.self) { try WorktreePackBounds.sum(-1) }
  }

  @Test(arguments: [WorktreeObjectFormat.sha1, .sha256])
  func manifestBoundsAndInvalidEntries(format: WorktreeObjectFormat) throws {
    let oid = String(repeating: "1", count: format.hexCount)
    let width = format.hexCount / 2
    let empty = try WorktreePackBounds.manifest(.init(entries: [:]), format: format)
    #expect(empty.packBytes == 12 + width)
    #expect(empty.indexBytes == 1032 + 2 * width)
    let manifest = WorktreeObjectManifest(entries: [oid: .init(type: .blob, size: 16)])
    let bounds = try WorktreePackBounds.manifest(manifest, format: format)
    #expect(bounds.packBytes == 12 + width + 2 + 32)
    #expect(bounds.indexBytes == 1032 + width + 16 + 2 * width)
    for (key, size) in [
      (oid, -1), (oid, 128 * 1024 * 1024 + 1),
      (String(repeating: "0", count: format.hexCount), 1), ("bad", 1),
    ] {
      let invalid = WorktreeObjectManifest(entries: [key: .init(type: .blob, size: size)])
      #expect(throws: WorktreeError.self) {
        try WorktreePackBounds.manifest(invalid, format: format)
      }
    }
  }
}
