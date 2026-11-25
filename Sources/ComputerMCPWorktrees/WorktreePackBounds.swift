import Foundation

struct WorktreePackBounds: Codable, Equatable {
  let packBytes: Int
  let indexBytes: Int

  static func compression(_ size: Int) throws -> Int {
    try sum(size, sum(size, 7) / 8, sum(size, 63) / 64, 13)
  }

  static func header(_ size: Int) throws -> Int {
    guard size >= 0 else { throw invalidBound() }
    var remaining = size >> 4
    var bytes = 1
    while remaining != 0 {
      bytes = try sum(bytes, 1)
      remaining >>= 7
    }
    return bytes
  }

  static func manifest(_ manifest: WorktreeObjectManifest, format: WorktreeObjectFormat) throws
    -> Self
  {
    let limits = WorktreePromotionLimits()
    let width = format.hexCount / 2
    guard manifest.entries.count <= limits.objectCount else { throw invalidBound() }
    var pack = try sum(12, width)
    var inflated = 0
    for (oid, entry) in manifest.entries {
      guard format.contains(oid), oid.utf8.contains(where: { $0 != 48 }),
        entry.size >= 0, entry.size <= limits.objectBytes
      else { throw invalidBound() }
      inflated = try sum(inflated, entry.size)
      guard inflated <= limits.inflatedBytes else { throw invalidBound() }
      pack = try sum(pack, header(entry.size), compression(entry.size))
    }
    return Self(packBytes: pack, indexBytes: try index(manifest.entries.count, width: width))
  }

  static func maximum(format: WorktreeObjectFormat) throws -> Self {
    let limits = WorktreePromotionLimits()
    let width = format.hexCount / 2
    let count = limits.objectCount
    let inflated = limits.inflatedBytes
    return try Self(
      packBytes: sum(
        12, width, inflated, sum(inflated, multiply(7, count)) / 8,
        sum(inflated, multiply(63, count)) / 64, multiply(18, count)),
      indexBytes: index(count, width: width))
  }

  static let metadataLimit = 128 * 1024 * 1024

  static func stagingMaximum(format: WorktreeObjectFormat) throws -> Int {
    let maximum = try maximum(format: format)
    return try sum(
      WorktreePromotionLimits().inputBytes, multiply(4, maximum.packBytes),
      multiply(7, maximum.indexBytes), multiply(4, metadataLimit))
  }

  private static func index(_ count: Int, width: Int) throws -> Int {
    try sum(8, 1024, multiply(count, sum(width, 16)), multiply(2, width))
  }

  static func sum(_ terms: Int...) throws -> Int {
    try terms.reduce(0) { total, term in
      let (result, overflow) = total.addingReportingOverflow(term)
      guard term >= 0, !overflow else { throw invalidBound() }
      return result
    }
  }

  private static func multiply(_ lhs: Int, _ rhs: Int) throws -> Int {
    let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
    guard lhs >= 0, rhs >= 0, !overflow else { throw invalidBound() }
    return result
  }

  private static func invalidBound() -> WorktreeError {
    .invalidRequest("Invalid or excessive recovery pack bound.")
  }
}
