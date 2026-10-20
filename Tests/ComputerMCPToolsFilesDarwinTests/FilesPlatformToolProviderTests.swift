import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPPlatformDarwin
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Darwin
import Foundation
import Testing

@testable import ComputerMCPToolsFiles

@Suite(.nativeIntegration, .serialized)
final class FilesPlatformToolProviderTests {
  @Test
  func testFileXattrsListsNamesAndOptionalBoundedValues() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("download.txt")
    try "download".write(to: file, atomically: true, encoding: .utf8)
    try setTestExtendedAttribute(
      file,
      name: "com.showxu.alpha",
      value: Data("hello-world".utf8)
    )
    try setTestExtendedAttribute(
      file,
      name: "com.showxu.empty",
      value: Data()
    )
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.xattrs"]),
          workspaceDirectory: directory
        ), extendedAttributes: DarwinExtendedAttributes(), fileTrasher: DarwinFileTrasher()))

    let listResult = try provider.callTool(
      .init(
        name: "file.xattrs",
        arguments: .object(["path": .string("download.txt")]), context: .empty
      ))
    let listPayload = try decodeTextPayload(listResult)
    let listedAttributes = try #require(listPayload.objectValue?["attributes"]?.arrayValue)
    let listedAlpha = try #require(
      listedAttributes.first { $0.objectValue?["name"] == .string("com.showxu.alpha") }
    )

    #expect((listPayload.objectValue?["workspace_relative_path"]) == (.string("download.txt")))
    #expect((listPayload.objectValue?["include_values"]) == (.bool(false)))
    #expect((listedAlpha.objectValue?["size_bytes"]) == (.number(11)))
    #expect((listedAlpha.objectValue?["value_base64"]) == nil)

    let valueResult = try provider.callTool(
      .init(
        name: "file.xattrs",
        arguments: .object([
          "path": .string("download.txt"),
          "include_values": .bool(true),
          "max_value_bytes": .number(16),
        ]), context: .empty
      ))
    let valuePayload = try decodeTextPayload(valueResult)
    let valueAttributes = try #require(valuePayload.objectValue?["attributes"]?.arrayValue)
    let alpha = try #require(
      valueAttributes.first { $0.objectValue?["name"] == .string("com.showxu.alpha") }
    )
    let empty = try #require(
      valueAttributes.first { $0.objectValue?["name"] == .string("com.showxu.empty") }
    )

    #expect((valuePayload.objectValue?["include_values"]) == (.bool(true)))
    #expect((alpha.objectValue?["value_bytes_read"]) == (.number(11)))
    #expect((alpha.objectValue?["value_truncated"]) == (.bool(false)))
    #expect(
      (alpha.objectValue?["value_base64"])
        == (.string(Data("hello-world".utf8).base64EncodedString())))
    #expect((alpha.objectValue?["value_utf8"]) == (.string("hello-world")))
    #expect((empty.objectValue?["size_bytes"]) == (.number(0)))
    #expect((empty.objectValue?["value_bytes_read"]) == (.number(0)))
    #expect((empty.objectValue?["value_truncated"]) == (.bool(false)))
    #expect((empty.objectValue?["value_base64"]) == (.string("")))
    #expect((empty.objectValue?["value_utf8"]) == (.string("")))

    let limitedResult = try provider.callTool(
      .init(
        name: "file.xattrs",
        arguments: .object([
          "path": .string("download.txt"),
          "include_values": .bool(true),
          "max_value_bytes": .number(5),
        ]), context: .empty
      ))
    let limitedPayload = try decodeTextPayload(limitedResult)
    let limitedAttributes = try #require(limitedPayload.objectValue?["attributes"]?.arrayValue)
    let limitedAlpha = try #require(
      limitedAttributes.first { $0.objectValue?["name"] == .string("com.showxu.alpha") }
    )

    #expect((limitedAlpha.objectValue?["value_bytes_read"]) == (.number(0)))
    #expect((limitedAlpha.objectValue?["value_truncated"]) == (.bool(true)))
    #expect((limitedAlpha.objectValue?["value_base64"]) == (.null))
    #expect((limitedAlpha.objectValue?["value_utf8"]) == (.null))
    #expect(
      (limitedAlpha.objectValue?["value_omitted_reason"])
        == (.string("attribute exceeds max_value_bytes")))
  }

  @Test
  func testFileXattrsRejectsWorkspaceEscapeMissingPathAndBadBounds() throws {
    let directory = try temporaryDirectory()
    try "download".write(
      to: directory.appendingPathComponent("download.txt"),
      atomically: true,
      encoding: .utf8
    )
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.xattrs"]),
          workspaceDirectory: directory
        ), extendedAttributes: DarwinExtendedAttributes(), fileTrasher: DarwinFileTrasher()))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.xattrs",
          arguments: .object(["path": .string("../outside")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.xattrs",
          arguments: .object(["path": .string("missing.txt")]), context: .empty
        ))
    ) { error in
      #expect(!(error.localizedDescription.isEmpty))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.xattrs",
          arguments: .object([
            "path": .string("download.txt"),
            "max_value_bytes": .number(0),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_value_bytes"))
    }
  }

  @Test
  func testFileRemoveXattrRemovesNamedAttribute() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("download.txt")
    try "download".write(to: file, atomically: true, encoding: .utf8)
    try setTestExtendedAttribute(
      file,
      name: "com.showxu.keep",
      value: Data("keep".utf8)
    )
    try setTestExtendedAttribute(
      file,
      name: "com.showxu.metadata:test",
      value: Data("remove".utf8)
    )
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.remove_xattr", "file.xattrs"]),
          workspaceDirectory: directory
        ), extendedAttributes: DarwinExtendedAttributes(), fileTrasher: DarwinFileTrasher()))

    let result = try provider.callTool(
      .init(
        name: "file.remove_xattr",
        arguments: .object([
          "path": .string("download.txt"),
          "name": .string("com.showxu.metadata:test"),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operation"]) == (.string("file.remove_xattr")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("download.txt")))
    #expect((payload.objectValue?["name"]) == (.string("com.showxu.metadata:test")))
    #expect((payload.objectValue?["removed"]) == (.bool(true)))
    #expect(
      (payload.objectValue?["attributes_before"]?.arrayValue?.contains(
        .string("com.showxu.metadata:test"))) == (true))
    #expect(
      (payload.objectValue?["attributes_after"]?.arrayValue?.contains(
        .string("com.showxu.metadata:test"))) == (false))

    let readback = try provider.callTool(
      .init(
        name: "file.xattrs",
        arguments: .object(["path": .string("download.txt")]), context: .empty
      ))
    let readbackPayload = try decodeTextPayload(readback)
    let attributes = try #require(readbackPayload.objectValue?["attributes"]?.arrayValue)
    #expect(
      (attributes.first { $0.objectValue?["name"] == .string("com.showxu.metadata:test") }) == nil)
    #expect((attributes.first { $0.objectValue?["name"] == .string("com.showxu.keep") }) != nil)
  }

  @Test
  func testFileRemoveXattrDryRunDoesNotRemoveAttribute() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("download.txt")
    try "download".write(to: file, atomically: true, encoding: .utf8)
    try setTestExtendedAttribute(
      file,
      name: "com.showxu.metadata:test",
      value: Data("keep".utf8)
    )
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.remove_xattr", "file.xattrs"]),
          workspaceDirectory: directory
        ), extendedAttributes: DarwinExtendedAttributes(), fileTrasher: DarwinFileTrasher()))

    let result = try provider.callTool(
      .init(
        name: "file.remove_xattr",
        arguments: .object([
          "path": .string("download.txt"),
          "name": .string("com.showxu.metadata:test"),
          "dry_run": .bool(true),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["removed"]) == (.bool(false)))
    #expect((payload.objectValue?["would_remove"]) == (.bool(true)))
    #expect(
      (payload.objectValue?["attributes_after"]?.arrayValue?.contains(
        .string("com.showxu.metadata:test"))) == (true))
    #expect(
      (payload.objectValue?["would_attributes_after"]?.arrayValue?.contains(
        .string("com.showxu.metadata:test"))) == (false))

    let readback = try provider.callTool(
      .init(
        name: "file.xattrs",
        arguments: .object(["path": .string("download.txt")]), context: .empty
      ))
    let readbackPayload = try decodeTextPayload(readback)
    let attributes = try #require(readbackPayload.objectValue?["attributes"]?.arrayValue)
    #expect(
      (attributes.first { $0.objectValue?["name"] == .string("com.showxu.metadata:test") }) != nil)
  }

  @Test
  func testFileRemoveXattrRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("download.txt")
    try "download".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.remove_xattr"]),
          workspaceDirectory: directory
        ), extendedAttributes: DarwinExtendedAttributes(), fileTrasher: DarwinFileTrasher()))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.remove_xattr",
          arguments: .object([
            "path": .string("download.txt"),
            "name": .string("com.showxu.missing"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("does not exist"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.remove_xattr",
          arguments: .object([
            "path": .string("download.txt"),
            "name": .string("bad\nname"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("control"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.remove_xattr",
          arguments: .object([
            "path": .string("../outside.txt"),
            "name": .string("com.showxu.alpha"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }
  }

  @Test
  func testFileTrashMovesWorkspacePathToMacOSTrash() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("obsolete.txt")
    try "obsolete".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.trash"]),
          workspaceDirectory: directory
        ), extendedAttributes: DarwinExtendedAttributes(), fileTrasher: DarwinFileTrasher()))

    let result = try provider.callTool(
      .init(
        name: "file.trash",
        arguments: .object(["path": .string("obsolete.txt")]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    defer {
      if let path = payload.objectValue?["trashed_path"]?.stringValue {
        try? FileManager.default.removeItem(atPath: path)
      }
    }
    #expect((payload.objectValue?["operation"]) == (.string("file.trash")))
    #expect((payload.objectValue?["source_workspace_relative_path"]) == (.string("obsolete.txt")))
    #expect(!(FileManager.default.fileExists(atPath: file.path)))
    #expect((payload.objectValue?["trashed_path"]) != (.null))
  }

  private var temporaryDirectories: [ScopedTemporaryDirectory] = []

  private func temporaryDirectory() throws -> URL {
    let directory = try ScopedTemporaryDirectory()
    temporaryDirectories.append(directory)
    return directory.url
  }

  private func decodeTextPayload(_ value: JSONValue) throws -> JSONValue {
    let text = try #require(
      value.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  }
  private func setTestExtendedAttribute(_ url: URL, name: String, value: Data) throws {
    let result = value.withUnsafeBytes { buffer -> Int32 in
      url.withUnsafeFileSystemRepresentation { pathPointer -> Int32 in
        guard let pathPointer else {
          errno = EINVAL
          return -1
        }
        return name.withCString { namePointer in
          setxattr(pathPointer, namePointer, buffer.baseAddress, value.count, 0, 0)
        }
      }
    }
    guard result == 0 else {
      throw NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(errno),
        userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]
      )
    }
  }
}
