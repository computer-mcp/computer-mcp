import Foundation

struct WorktreePackedRefs {
  private struct Line {
    let range: Range<Int>
    let ref: Data?
  }

  private let data: Data
  private let lines: [Line]
  private let values: [Data: String]

  init(_ data: Data, format: WorktreeObjectFormat) throws {
    self.data = data
    if data.isEmpty {
      lines = []
      values = [:]
      return
    }
    guard data.count <= WorktreeSourceMetadata.maximumBytes, data.last == 10
    else { throw sourceMetadataChanged() }
    var lines: [Line] = []
    var refs: [Data: String] = [:]
    var peelable: Data?
    var preceding: Data?
    var sorted = false
    func oid(_ bytes: Data) throws -> String {
      guard let text = String(data: bytes, encoding: .utf8),
        format.contains(text), bytes.contains(where: { $0 != 48 })
      else { throw sourceMetadataChanged() }
      return text
    }
    var start = data.startIndex
    while start != data.endIndex {
      try Task.checkCancellation()
      guard let newline = data[start...].firstIndex(of: 10) else { throw sourceMetadataChanged() }
      let line = data[start..<newline]
      let range = start..<(newline + 1)
      if line.first == 35 {
        guard !line.contains(0), !line.contains(13) else { throw sourceMetadataChanged() }
        let header = Data("# pack-refs with: ".utf8)
        if start == data.startIndex, line.starts(with: header) {
          sorted = line.dropFirst(header.count).split(separator: 32).contains(Data("sorted".utf8))
        }
        peelable = nil
        lines.append(Line(range: range, ref: nil))
      } else if line.first == 94 {
        guard let ref = peelable else { throw sourceMetadataChanged() }
        _ = try oid(Data(line.dropFirst()))
        peelable = nil
        lines.append(Line(range: range, ref: ref))
      } else {
        guard let space = line.firstIndex(of: 32) else { throw sourceMetadataChanged() }
        let value = try oid(Data(line[..<space]))
        let ref = Data(line[(space + 1)...])
        guard Self.validRef(ref), refs.updateValue(value, forKey: ref) == nil,
          !sorted || preceding.map({ $0.lexicographicallyPrecedes(ref) }) ?? true
        else { throw sourceMetadataChanged() }
        preceding = ref
        peelable = ref
        lines.append(Line(range: range, ref: ref))
      }
      start = newline + 1
    }
    self.lines = lines
    values = refs
  }

  func oid(for ref: String) -> String? {
    values[Data(ref.utf8)]
  }

  func removing(_ ref: String) -> Data {
    let ref = Data(ref.utf8)
    var result = Data()
    for line in lines where line.ref != ref { result.append(data[line.range]) }
    return result
  }

  private static func validRef(_ ref: Data) -> Bool {
    let forbidden = Data("~^:?*[\\".utf8)
    guard ref.starts(with: Data("refs/".utf8)), ref.last != 46,
      !ref.contains(where: { $0 <= 32 || $0 == 127 || forbidden.contains($0) })
    else { return false }
    for (a, b) in zip(ref, ref.dropFirst()) where (a == 46 && b == 46) || (a == 64 && b == 123) {
      return false
    }
    let lock = Data(".lock".utf8)
    return ref.split(separator: 47, omittingEmptySubsequences: false).allSatisfy {
      !$0.isEmpty && $0.first != 46 && !$0.suffix(lock.count).elementsEqual(lock)
    }
  }
}

extension WorktreeSourceMetadata {
  struct DirectRef {
    let oid: String?
    let loose: File?
    let packed: File?
    let packedRefs: WorktreePackedRefs
  }

  func direct(_ ref: String) throws -> DirectRef {
    try Self.requireBranch(ref)
    let loose = try read(ref, limit: 1024)
    let packed = try read("packed-refs")
    let packedRefs = try WorktreePackedRefs(packed?.contents ?? Data(), format: format)
    let oid: String?
    if let loose {
      let bytes = loose.contents
      guard bytes.last == 10, let text = String(data: bytes.dropLast(), encoding: .utf8),
        validOID(text)
      else { throw sourceMetadataChanged() }
      oid = text
    } else {
      oid = packedRefs.oid(for: ref)
    }
    return DirectRef(oid: oid, loose: loose, packed: packed, packedRefs: packedRefs)
  }
}

extension WorktreeRepository {
  func sourceMetadata() throws -> WorktreeSourceMetadata {
    try identity.verify()
    let result = try command(["config", "--get", "core.sharedRepository"], accepting: [0, 1])
    let value: String?
    if result.exitCode == 1 {
      value = nil
    } else {
      guard let text = String(data: result.output, encoding: .utf8), text.last == "\n",
        !text.dropLast().contains("\n")
      else { throw sourceMetadataChanged() }
      value = String(text.dropLast())
    }
    let common = try WorktreeDirectory(URL(fileURLWithPath: identity.common.path))
    guard common.identity == identity.common else { throw sourceMetadataChanged() }
    return WorktreeSourceMetadata(
      common: common, format: identity.format, permissions: try .init(value), io: io)
  }
}
