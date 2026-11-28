import Foundation

/// Checkout safety shared by host Git adapters. Attribute checks include the live
/// checkout and both immutable trees, so incoming attributes cannot enable a filter.
package enum HostGitCheckout {
  package static func requireNoFilters(
    revisions: [String], run: ([String], Data) throws -> Data
  ) throws {
    var paths = Set<Data>()
    for revision in revisions {
      let output = try run(["ls-tree", "-rz", "--name-only", revision], Data())
      paths.formUnion(output.split(separator: 0).map { Data($0) })
    }
    guard !paths.isEmpty else { return }
    var input = Data()
    for path in paths.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
      input.append(path)
      input.append(0)
    }
    for revision in [nil] + revisions.map(Optional.some) {
      let args =
        ["check-attr", "-z"] + (revision.map { ["--source=" + $0] } ?? [])
        + ["--stdin", "filter"]
      let output = try run(args, input)
      let fields = output.split(separator: 0, omittingEmptySubsequences: false)
      guard fields.last?.isEmpty == true, fields.count == paths.count * 3 + 1 else {
        throw WorktreeError.unsafeConfiguration("Cannot verify checkout filter attributes.")
      }
      for index in stride(from: 2, to: fields.count - 1, by: 3) {
        guard fields[index] == Data("unspecified".utf8) || fields[index] == Data("unset".utf8)
        else {
          throw WorktreeError.unsafeConfiguration(
            "Host checkout refuses attributes assigning a filter.")
        }
      }
    }
  }
}
