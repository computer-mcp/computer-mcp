import Foundation
import Testing

func expectThrows<T>(
  _ expression: @autoclosure () throws -> T,
  _ message: String? = nil,
  _ errorHandler: (any Error) -> Void = { _ in }
) {
  do {
    _ = try expression()
    Issue.record(Comment(rawValue: message ?? "Expected expression to throw."))
  } catch {
    errorHandler(error)
  }
}

func expectNoThrow<T>(
  _ expression: @autoclosure () throws -> T,
  _ message: String? = nil
) {
  do {
    _ = try expression()
  } catch {
    Issue.record(Comment(rawValue: message ?? "Expected expression not to throw: \(error)"))
  }
}

func expectThrowsAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  _ message: String? = nil,
  _ errorHandler: (any Error) -> Void = { _ in }
) async {
  do {
    _ = try await expression()
    Issue.record(Comment(rawValue: message ?? "Expected expression to throw."))
  } catch {
    errorHandler(error)
  }
}

final class ScopedTemporaryDirectory {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}
