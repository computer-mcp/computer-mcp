import Foundation
import Testing

@testable import ComputerMCP

@Suite
final class AppFileLoggerTests {
  @Test
  func testWritesJSONLinesWithRestrictedPermissionsAndRedactsSensitiveFields() throws {
    let directory = try ScopedTemporaryDirectory()
    let logger = try AppFileLogger(directory: directory.url)

    logger.append(
      .info,
      event: "tunnel.started",
      fields: [
        "profile_id": "chatgpt",
        "api_key": "must-not-appear",
        "authorization_header": "must-not-appear",
      ]
    )

    let data = try Data(contentsOf: logger.fileURL)
    let text = String(decoding: data, as: UTF8.self)
    let object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let fields = try #require(object["fields"] as? [String: String])
    let attributes = try FileManager.default.attributesOfItem(atPath: logger.fileURL.path)

    #expect((object["event"] as? String) == ("tunnel.started"))
    #expect((fields["profile_id"]) == ("chatgpt"))
    #expect((fields["api_key"]) == ("[REDACTED]"))
    #expect((fields["authorization_header"]) == ("[REDACTED]"))
    #expect(!(text.contains("must-not-appear")))
    #expect(((attributes[.posixPermissions] as? NSNumber)?.intValue) == (0o600))
  }

  @Test
  func testRotatesBoundedFiles() throws {
    let directory = try ScopedTemporaryDirectory()
    let logger = try AppFileLogger(
      directory: directory.url,
      maxBytes: 4_096,
      retainedFiles: 2
    )

    for index in 0..<20 {
      logger.append(
        .info,
        event: "rotation.test",
        fields: [
          "index": "\(index)",
          "value": String(repeating: "x", count: 512),
        ]
      )
    }

    #expect(FileManager.default.fileExists(atPath: logger.fileURL.path))
    #expect(FileManager.default.fileExists(atPath: logger.fileURL.path + ".1"))
    #expect(FileManager.default.fileExists(atPath: logger.fileURL.path + ".2"))
    #expect(!(FileManager.default.fileExists(atPath: logger.fileURL.path + ".3")))
  }
}
