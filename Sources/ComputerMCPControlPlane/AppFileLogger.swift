import Foundation

package enum AppLogLevel: String, Codable, Sendable {
  case debug
  case info
  case warning
  case error
}

package final class AppFileLogger: @unchecked Sendable {
  package let fileURL: URL

  private let fileManager: FileManager
  private let maxBytes: Int
  private let retainedFiles: Int
  private let lock = NSLock()

  package init(
    directory: URL,
    fileName: String = "computer-mcp.jsonl",
    maxBytes: Int = 1_048_576,
    retainedFiles: Int = 3,
    fileManager: FileManager = .default
  ) throws {
    guard maxBytes >= 4_096 else {
      throw AppFileLoggerError.invalidMaxBytes
    }
    guard retainedFiles >= 1 && retainedFiles <= 10 else {
      throw AppFileLoggerError.invalidRetainedFiles
    }
    self.fileManager = fileManager
    self.maxBytes = maxBytes
    self.retainedFiles = retainedFiles
    self.fileURL = directory.standardizedFileURL.appendingPathComponent(fileName)

    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
    )
    try fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))],
      ofItemAtPath: directory.path
    )
  }

  package func append(
    _ level: AppLogLevel,
    event: String,
    fields: [String: String] = [:]
  ) {
    lock.lock()
    defer { lock.unlock() }

    do {
      let record = AppLogRecord(
        timestamp: Date(),
        level: level,
        event: Self.bounded(event, maxBytes: 256),
        fields: Dictionary(
          uniqueKeysWithValues: fields.sorted(by: { $0.key < $1.key }).map { key, value in
            (
              Self.bounded(key, maxBytes: 128),
              Self.isSensitiveField(key)
                ? "[REDACTED]"
                : Self.bounded(value, maxBytes: 2_048)
            )
          }
        )
      )
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys]
      var data = try encoder.encode(record)
      data.append(0x0A)
      try rotateIfNeeded(incomingBytes: data.count)
      if !fileManager.fileExists(atPath: fileURL.path) {
        _ = fileManager.createFile(
          atPath: fileURL.path,
          contents: nil,
          attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        )
      }
      let handle = try FileHandle(forWritingTo: fileURL)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
      try fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))],
        ofItemAtPath: fileURL.path
      )
    } catch {
      // Logging must never prevent the gateway or App from operating.
    }
  }

  private func rotateIfNeeded(incomingBytes: Int) throws {
    let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
    let currentBytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    guard currentBytes + incomingBytes > maxBytes else {
      return
    }

    let oldest = rotatedURL(index: retainedFiles)
    try? fileManager.removeItem(at: oldest)
    if retainedFiles > 1 {
      for index in stride(from: retainedFiles - 1, through: 1, by: -1) {
        let source = rotatedURL(index: index)
        guard fileManager.fileExists(atPath: source.path) else {
          continue
        }
        try fileManager.moveItem(at: source, to: rotatedURL(index: index + 1))
      }
    }
    if fileManager.fileExists(atPath: fileURL.path) {
      try fileManager.moveItem(at: fileURL, to: rotatedURL(index: 1))
    }
  }

  private func rotatedURL(index: Int) -> URL {
    URL(fileURLWithPath: fileURL.path + ".\(index)")
  }

  private static func isSensitiveField(_ key: String) -> Bool {
    let normalized = key.lowercased()
    return ["authorization", "credential", "key", "password", "secret", "token"]
      .contains { normalized.contains($0) }
  }

  private static func bounded(_ value: String, maxBytes: Int) -> String {
    guard value.utf8.count > maxBytes else {
      return value
    }
    var index = value.startIndex
    var bytes = 0
    while index < value.endIndex {
      let next = value.index(after: index)
      let characterBytes = value[index..<next].utf8.count
      guard bytes + characterBytes <= maxBytes else {
        break
      }
      bytes += characterBytes
      index = next
    }
    return String(value[..<index])
  }
}

package enum AppFileLoggerError: Error, Equatable, Sendable {
  case invalidMaxBytes
  case invalidRetainedFiles
}

private struct AppLogRecord: Codable {
  var timestamp: Date
  var level: AppLogLevel
  var event: String
  var fields: [String: String]
}
