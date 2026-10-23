import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPToolsStructured

struct StructuredToolProviderContractTests {
  @Test
  func enablementAndDomainDispatch() throws {
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: .fixture(builtin: .init(enabled: ["json.read", "skills.list"]))))
    #expect(provider.id == "structured")
    #expect(try provider.definitions().map(\.tool.name) == ["json.read"])
    #expect(throws: GatewayToolError.disabled("json.write is disabled by configuration.")) {
      try provider.callTool(.init(name: "json.write", arguments: nil, context: .empty))
    }
    #expect(throws: GatewayToolError.unknownTool("skills.list")) {
      try provider.callTool(.init(name: "skills.list", arguments: nil, context: .empty))
    }
  }

  @Test
  func asynchronousDispatchPreservesStructuredResult() async throws {
    let directory = try ScopedTemporaryDirectory()
    try Data(#"{"count":9007199254740993}"#.utf8).write(
      to: directory.url.appendingPathComponent("value.json"))
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: .init(enabled: ["json.read"]), projectDirectory: directory.url)))
    let invocation = ToolInvocation(
      name: "json.read", arguments: .object(["path": .string("value.json")]), context: .empty)
    #expect(try await provider.callToolAsync(invocation) == provider.callTool(invocation))
  }

  @Test(arguments: ["image.info", "pdf.info", "pdf.text", "media.info"])
  func mediaUsesInjectedInspector(name: String) throws {
    let directory = try ScopedTemporaryDirectory()
    let file = directory.url.appendingPathComponent("asset.dat")
    try Data([1, 2, 3]).write(to: file)
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: .init(enabled: [name]), projectDirectory: directory.url),
        mediaInspector: InspectionStub(expectedURL: file)))
    let options: [String: JSONValue]
    switch name {
    case "image.info":
      options = ["include_properties": .bool(true), "max_property_depth": .integer(4)]
    case "pdf.info":
      options = [
        "max_pages": .integer(3), "include_page_boxes": .bool(false),
        "include_attributes": .bool(false),
      ]
    case "pdf.text":
      options = [
        "start_page": .integer(2), "max_pages": .integer(3), "max_characters": .integer(42),
      ]
    default:
      options = ["max_tracks": .integer(3), "load_timeout_ms": .integer(250)]
    }
    let result = try provider.callTool(
      .init(
        name: name, arguments: .object(options.merging(["path": .string("asset.dat")]) { $1 }),
        context: .empty))
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    #expect(payload.objectValue?["operation"] == .string(name))
    #expect(payload.objectValue?["path"] == .string(file.path))
    #expect(payload.objectValue?["project_relative_path"] == .string("asset.dat"))
    #expect(payload.objectValue?["size_bytes"] == .integer(3))
    #expect(payload.objectValue?["inspected"] == .string(name))
    if name == "media.info" {
      #expect(payload.objectValue?["extension"] == .string("dat"))
    }
    expectThrows(
      try provider.callTool(
        .init(name: name, arguments: .object(["path": .string("../outside")]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }
  }
}

private struct InspectionStub: MediaInspector {
  let expectedURL: URL

  func imageInfo(at url: URL, includeProperties: Bool, maxPropertyDepth: Int) throws
    -> [String: JSONValue]?
  {
    #expect(url == expectedURL)
    #expect(includeProperties)
    #expect(maxPropertyDepth == 4)
    return ["inspected": .string("image.info")]
  }

  func pdfInfo(at url: URL, maxPages: Int, includePageBoxes: Bool, includeAttributes: Bool) throws
    -> [String: JSONValue]?
  {
    #expect(url == expectedURL)
    #expect(maxPages == 3)
    #expect(!includePageBoxes)
    #expect(!includeAttributes)
    return ["inspected": .string("pdf.info")]
  }

  func pdfText(at url: URL, startPage: Int, maxPages: Int, maxCharacters: Int) throws
    -> [String: JSONValue]?
  {
    #expect(url == expectedURL)
    #expect(startPage == 2)
    #expect(maxPages == 3)
    #expect(maxCharacters == 42)
    return ["inspected": .string("pdf.text")]
  }

  func mediaInfo(at url: URL, maxTracks: Int, loadTimeoutMS: Int) throws -> [String: JSONValue] {
    #expect(url == expectedURL)
    #expect(maxTracks == 3)
    #expect(loadTimeoutMS == 250)
    return ["inspected": .string("media.info")]
  }
}
