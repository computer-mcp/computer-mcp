import AppKit
import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPPlatformDarwin
import ComputerMCPTestSupport
import ComputerMCPToolKit
import CoreText
import Foundation
import PDFKit
import Testing

@testable import ComputerMCPToolsStructured

@Suite(.nativeIntegration, .serialized)
final class StructuredMediaToolProviderTests {
  @Test
  func testImageInfoReadsMechanicalImageMetadata() throws {
    let directory = try temporaryDirectory()
    let images = directory.appendingPathComponent("Images")
    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    let imageURL = images.appendingPathComponent("tile.png")
    let representation = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 2,
        pixelsHigh: 3,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ))
    let imageData = try #require(representation.representation(using: .png, properties: [:]))
    try imageData.write(to: imageURL)

    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["image.info"]),
          projectDirectory: directory
        ), mediaInspector: DarwinMediaInspector()))

    let result = try provider.callTool(
      .init(
        name: "image.info",
        arguments: .object([
          "path": .string("Images/tile.png"),
          "include_properties": .bool(true),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operation"]) == (.string("image.info")))
    #expect((payload.objectValue?["project_relative_path"]) == (.string("Images/tile.png")))
    #expect((payload.objectValue?["mime_type"]) == (.string("image/png")))
    #expect((payload.objectValue?["frame_count"]) == (.number(1)))
    #expect((payload.objectValue?["pixel_width"]) == (.number(2)))
    #expect((payload.objectValue?["pixel_height"]) == (.number(3)))
    #expect((payload.objectValue?["has_alpha"]) == (.bool(true)))
    #expect((payload.objectValue?["properties_included"]) == (.bool(true)))
    #expect((payload.objectValue?["properties"]?.objectValue) != nil)
  }

  @Test
  func testImageInfoRejectsInvalidTargets() throws {
    let directory = try temporaryDirectory()
    try "not an image".write(
      to: directory.appendingPathComponent("notes.txt"),
      atomically: true,
      encoding: .utf8
    )
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["image.info"]),
          projectDirectory: directory
        ), mediaInspector: DarwinMediaInspector()))

    expectThrows(
      try provider.callTool(
        .init(
          name: "image.info",
          arguments: .object(["path": .string("notes.txt")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Unable to read image metadata"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "image.info",
          arguments: .object(["path": .string(".")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }
  }

  @Test
  func testPDFInfoReadsMechanicalDocumentMetadata() throws {
    let directory = try temporaryDirectory()
    let docs = directory.appendingPathComponent("Docs")
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    let pdfURL = docs.appendingPathComponent("report.pdf")
    let document = PDFDocument()
    document.insert(PDFPage(), at: 0)
    document.insert(PDFPage(), at: 1)
    document.documentAttributes = [
      PDFDocumentAttribute.titleAttribute: "Demo Report",
      PDFDocumentAttribute.authorAttribute: "Codex",
    ]
    #expect(document.write(to: pdfURL))

    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["pdf.info"]),
          projectDirectory: directory
        ), mediaInspector: DarwinMediaInspector()))

    let result = try provider.callTool(
      .init(
        name: "pdf.info",
        arguments: .object([
          "path": .string("Docs/report.pdf"),
          "max_pages": .number(1),
          "include_attributes": .bool(true),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let page = try #require(payload.objectValue?["pages"]?.arrayValue?.first?.objectValue)
    let boxes = try #require(page["boxes"]?.objectValue)
    let media = try #require(boxes["media"]?.objectValue)

    #expect((payload.objectValue?["operation"]) == (.string("pdf.info")))
    #expect((payload.objectValue?["project_relative_path"]) == (.string("Docs/report.pdf")))
    #expect((payload.objectValue?["page_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_page_count"]) == (.number(1)))
    #expect((payload.objectValue?["pages_truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["is_encrypted"]) == (.bool(false)))
    #expect((payload.objectValue?["allows_copying"]) == (.bool(true)))
    #expect((payload.objectValue?["attributes_included"]) == (.bool(true)))
    #expect((payload.objectValue?["attributes"]?.objectValue?["Title"]) == (.string("Demo Report")))
    #expect((page["number"]) == (.number(1)))
    #expect((media["width"]) == (.number(612)))
    #expect((media["height"]) == (.number(792)))
  }

  @Test
  func testPDFInfoRejectsInvalidTargets() throws {
    let directory = try temporaryDirectory()
    try "not a pdf".write(
      to: directory.appendingPathComponent("notes.txt"),
      atomically: true,
      encoding: .utf8
    )
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["pdf.info"]),
          projectDirectory: directory
        ), mediaInspector: DarwinMediaInspector()))

    expectThrows(
      try provider.callTool(
        .init(
          name: "pdf.info",
          arguments: .object(["path": .string("notes.txt")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Unable to read PDF metadata"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "pdf.info",
          arguments: .object(["path": .string(".")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }
  }

  @Test
  func testPDFTextExtractsSearchableTextWithBounds() throws {
    let directory = try temporaryDirectory()
    let docs = directory.appendingPathComponent("Docs")
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    let pdfURL = docs.appendingPathComponent("report.pdf")
    try writeTextPDF(
      pages: [
        "Alpha PDF page one. This page has searchable text.",
        "Beta PDF page two. More searchable text lives here.",
      ],
      to: pdfURL
    )
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["pdf.text"]),
          projectDirectory: directory
        ), mediaInspector: DarwinMediaInspector()))

    let firstPageResult = try provider.callTool(
      .init(
        name: "pdf.text",
        arguments: .object([
          "path": .string("Docs/report.pdf"),
          "max_pages": .number(1),
          "max_characters": .number(1_000),
        ]), context: .empty
      ))
    let firstPagePayload = try decodeTextPayload(firstPageResult)
    let firstPage = try #require(firstPagePayload.objectValue?["pages"]?.arrayValue?.first)
      .objectValue

    #expect((firstPagePayload.objectValue?["operation"]) == (.string("pdf.text")))
    #expect(
      (firstPagePayload.objectValue?["project_relative_path"]) == (.string("Docs/report.pdf")))
    #expect((firstPagePayload.objectValue?["page_count"]) == (.number(2)))
    #expect((firstPagePayload.objectValue?["returned_page_count"]) == (.number(1)))
    #expect((firstPagePayload.objectValue?["page_range_truncated"]) == (.bool(true)))
    #expect((firstPagePayload.objectValue?["text_truncated"]) == (.bool(false)))
    #expect((firstPagePayload.objectValue?["truncated"]) == (.bool(true)))
    #expect((firstPage?["number"]) == (.number(1)))
    #expect(firstPage?["text"]?.stringValue?.contains("Alpha PDF page one") == true)
    #expect((firstPage?["text_truncated"]) == (.bool(false)))

    let truncatedResult = try provider.callTool(
      .init(
        name: "pdf.text",
        arguments: .object([
          "path": .string("Docs/report.pdf"),
          "start_page": .number(2),
          "max_pages": .number(1),
          "max_characters": .number(8),
        ]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    let truncatedPage = try #require(truncatedPayload.objectValue?["pages"]?.arrayValue?.first)
      .objectValue

    #expect((truncatedPayload.objectValue?["start_page"]) == (.number(2)))
    #expect((truncatedPayload.objectValue?["returned_page_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["page_range_truncated"]) == (.bool(false)))
    #expect((truncatedPayload.objectValue?["text_truncated"]) == (.bool(true)))
    #expect((truncatedPayload.objectValue?["truncated"]) == (.bool(true)))
    #expect((truncatedPayload.objectValue?["total_extracted_character_count"]) == (.number(8)))
    #expect((truncatedPage?["number"]) == (.number(2)))
    #expect((truncatedPage?["extracted_character_count"]) == (.number(8)))
    #expect((truncatedPage?["text_truncated"]) == (.bool(true)))
  }

  @Test
  func testPDFTextRejectsInvalidTargetsAndBounds() throws {
    let directory = try temporaryDirectory()
    try "not a pdf".write(
      to: directory.appendingPathComponent("notes.txt"),
      atomically: true,
      encoding: .utf8
    )
    let pdfURL = directory.appendingPathComponent("blank.pdf")
    try writeTextPDF(pages: ["Only page"], to: pdfURL)
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["pdf.text"]),
          projectDirectory: directory
        ), mediaInspector: DarwinMediaInspector()))

    expectThrows(
      try provider.callTool(
        .init(
          name: "pdf.text",
          arguments: .object(["path": .string("notes.txt")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Unable to read PDF text"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "pdf.text",
          arguments: .object(["path": .string(".")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "pdf.text",
          arguments: .object([
            "path": .string("blank.pdf"),
            "start_page": .number(2),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("start_page exceeds PDF page_count"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "pdf.text",
          arguments: .object([
            "path": .string("blank.pdf"),
            "max_characters": .number(0),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_characters"))
    }
  }

  @Test
  func testMediaInfoReadsMechanicalAudioMetadata() throws {
    let directory = try temporaryDirectory()
    let media = directory.appendingPathComponent("Media")
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    let audioURL = media.appendingPathComponent("tone.wav")
    try testWAVData(sampleRate: 8_000, sampleCount: 4_000).write(to: audioURL)

    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["media.info"]),
          projectDirectory: directory
        ), mediaInspector: DarwinMediaInspector()))

    let result = try provider.callTool(
      .init(
        name: "media.info",
        arguments: .object([
          "path": .string("Media/tone.wav"),
          "max_tracks": .number(5),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let track = try #require(payload.objectValue?["tracks"]?.arrayValue?.first?.objectValue)

    #expect((payload.objectValue?["operation"]) == (.string("media.info")))
    #expect((payload.objectValue?["project_relative_path"]) == (.string("Media/tone.wav")))
    #expect((payload.objectValue?["extension"]) == (.string("wav")))
    #expect((payload.objectValue?["track_count"]) == (.number(1)))
    #expect((payload.objectValue?["returned_track_count"]) == (.number(1)))
    #expect((payload.objectValue?["tracks_truncated"]) == (.bool(false)))
    #expect((payload.objectValue?["media_types"]) == (.array([.string("audio")])))
    #expect((payload.objectValue?["is_playable"]) == (.bool(true)))
    #expect((payload.objectValue?["has_protected_content"]) == (.bool(false)))
    #expect((track["media_type"]) == (.string("audio")))
    #expect((track["codec_types"]?.arrayValue?.first) == (.string("lpcm")))
    #expect((try #require(payload.objectValue?["duration_seconds"]?.numberValue)) > (0))
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testMediaInfoRejectsInvalidTargets() throws {
    let directory = try temporaryDirectory()
    try "not media".write(
      to: directory.appendingPathComponent("notes.txt"),
      atomically: true,
      encoding: .utf8
    )
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["media.info"]),
          projectDirectory: directory
        ), mediaInspector: DarwinMediaInspector()))

    expectThrows(
      try provider.callTool(
        .init(
          name: "media.info",
          arguments: .object(["path": .string("notes.txt")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Unable to read media metadata"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "media.info",
          arguments: .object(["path": .string(".")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }
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
  private func writeTextPDF(pages: [String], to url: URL) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let consumer = CGDataConsumer(url: url as CFURL),
      let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else {
      throw NSError(
        domain: "ComputerMCPTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Unable to create PDF context."])
    }

    for text in pages {
      context.beginPDFPage(nil)
      context.saveGState()
      context.textMatrix = .identity
      context.translateBy(x: 0, y: mediaBox.height)
      context.scaleBy(x: 1, y: -1)

      let attributed = NSAttributedString(
        string: text,
        attributes: [
          .font: NSFont.systemFont(ofSize: 14),
          .foregroundColor: NSColor.black,
        ]
      )
      let framesetter = CTFramesetterCreateWithAttributedString(attributed)
      let path = CGMutablePath()
      path.addRect(CGRect(x: 72, y: 72, width: mediaBox.width - 144, height: mediaBox.height - 144))
      let frame = CTFramesetterCreateFrame(
        framesetter,
        CFRange(location: 0, length: attributed.length),
        path,
        nil
      )
      CTFrameDraw(frame, context)
      context.restoreGState()
      context.endPDFPage()
    }

    context.closePDF()
  }

  private func testWAVData(sampleRate: UInt32, sampleCount: UInt32) -> Data {
    let channels: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let blockAlign = channels * bitsPerSample / 8
    let byteRate = sampleRate * UInt32(blockAlign)
    let dataSize = sampleCount * UInt32(blockAlign)
    let chunkSize = UInt32(36) + dataSize
    var data = Data()
    data.append(contentsOf: "RIFF".utf8)
    appendLittleEndian(chunkSize, to: &data)
    data.append(contentsOf: "WAVE".utf8)
    data.append(contentsOf: "fmt ".utf8)
    appendLittleEndian(UInt32(16), to: &data)
    appendLittleEndian(UInt16(1), to: &data)
    appendLittleEndian(channels, to: &data)
    appendLittleEndian(sampleRate, to: &data)
    appendLittleEndian(byteRate, to: &data)
    appendLittleEndian(blockAlign, to: &data)
    appendLittleEndian(bitsPerSample, to: &data)
    data.append(contentsOf: "data".utf8)
    appendLittleEndian(dataSize, to: &data)
    data.append(Data(repeating: 0, count: Int(dataSize)))
    return data
  }

  private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { buffer in
      data.append(contentsOf: buffer)
    }
  }
}
