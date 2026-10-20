import ComputerMCPCore
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

struct FileHelpersTests {
  @Test
  func boundedReadsAndExistingSizesKeepInclusiveLimits() throws {
    let temporary = try ScopedTemporaryDirectory()
    let file = temporary.url.appendingPathComponent("data")
    let data = Data([0, 1, 2, 255])
    try data.write(to: file)
    #expect(try readBoundedFileData(url: file, path: "data", maxBytes: 4) == data)
    #expect(throws: GatewayToolError.invalidArguments("File exceeds max_bytes: data")) {
      try readBoundedFileData(url: file, path: "data", maxBytes: 3)
    }
    #expect(try existingFileSizeBytes(url: file, existed: true) == 4)
    #expect(try existingFileSizeBytes(url: file, existed: false) == 0)
    #expect(throws: GatewayToolError.invalidArguments("Path is not a directory: data")) {
      try requireDirectory(file, originalPath: "data")
    }
    #expect(throws: GatewayToolError.invalidArguments("Directory does not exist: missing")) {
      try requireDirectory(temporary.url.appendingPathComponent("missing"), originalPath: "missing")
    }
    try requireDirectory(temporary.url, originalPath: ".")
  }

  @Test
  func directorySortingFiltersHiddenNamesBeforeNaturalSorting() throws {
    let temporary = try ScopedTemporaryDirectory()
    for name in ["file10", ".hidden", "file2"] {
      try Data().write(to: temporary.url.appendingPathComponent(name))
    }
    #expect(
      try sortedDirectoryChildren(temporary.url, includeHidden: false).map(\.lastPathComponent)
        == ["file2", "file10"])
    #expect(try sortedDirectoryChildren(temporary.url, includeHidden: true).count == 3)
  }

  @Test(arguments: ["contains", "prefix", "suffix", "exact"])
  func filenameMatchingKeepsCaseAndModeSemantics(mode: String) throws {
    let mode = try fileNameMatchMode(mode)
    #expect(fileName("Name.SWIFT", matches: "name.swift", mode: mode, caseSensitive: false))
    #expect(!fileName("Name.SWIFT", matches: "name.swift", mode: mode, caseSensitive: true))
    #expect(
      fileName("value", matches: "", mode: mode, caseSensitive: true)
        == (mode == .prefix || mode == .suffix))
  }

  @Test
  func fileTypesAndUTF8PreviewsKeepUnknownAndGraphemeBoundaries() throws {
    #expect(fileType(nil) == "unknown")
    #expect(fileType("file") == "unknown")
    #expect(fileType(FileAttributeType.typeRegular) == "file")
    #expect(fileType(FileAttributeType.typeSymbolicLink) == "symlink")
    #expect(fileType(FileAttributeType.typeSocket) == "socket")
    #expect(
      throws: GatewayToolError.invalidArguments(
        "match must be one of: contains, prefix, suffix, exact.")
    ) {
      try fileNameMatchMode("glob")
    }
    let text = "e\u{301}🙂x"
    #expect(utf8Preview(text, maxBytes: 2).text == "")
    #expect(utf8Preview(text, maxBytes: 3).text == "e\u{301}")
    #expect(utf8Preview(text, maxBytes: 7).text == "e\u{301}🙂")
    #expect(utf8Preview(text, maxBytes: 7).truncated)
    #expect(!utf8Preview(text, maxBytes: 8).truncated)
  }

  @Test
  func outlinesFilterFencesAndImportsWithoutChangingLineNumbers() {
    let markdown = "# Title\n```swift\n# Hidden\n```\n## Detail\n####### Invalid\n#NoSpace"
    let headings = outlineItems(in: markdown, language: "markdown", includeImports: false)
    #expect(headings.map(\.name) == ["Title", "Detail"])
    #expect(headings.map(\.line) == [1, 5])
    #expect(headings.map(\.level) == [1, 2])
    #expect(markdownHeading("# ", lineNumber: 1) == nil)
    let swift = "import Foundation\npublic struct Thing<T> {\n  func work(value: Int) {}"
    #expect(
      outlineItems(in: swift, language: "swift", includeImports: false).map(\.name) == [
        "Thing", "work",
      ])
    #expect(
      outlineItems(in: swift, language: "swift", includeImports: true).first?.kind == "import")
    #expect(outlineLanguage(for: URL(fileURLWithPath: "README.MD")) == "markdown")
    #expect(outlineLanguage(for: URL(fileURLWithPath: "Makefile")) == "make")
    #expect(outlineLanguage(for: URL(fileURLWithPath: "unknown.data")) == nil)
    #expect(headings.first?.json.objectValue?["kind"] == .string("heading"))
  }

  @Test
  func volumeProjectionKeepsNullableFieldsAndPathFallback() throws {
    let temporary = try ScopedTemporaryDirectory()
    let url = temporary.url.appendingPathComponent("missing/volume")
    let info = try #require(volumeInfo(url: url, keys: Set(volumeResourceKeys())).objectValue)
    #expect(info["path"] == .string(url.path))
    #expect(info["name"] == .string("volume"))
    #expect(info["total_capacity_bytes"] == .null)
    #expect(info["available_capacity_for_important_usage_bytes"] == .null)
    #expect(info["available_capacity_for_opportunistic_usage_bytes"] == .null)
    #expect(info["supports_file_cloning"] == .null)
    #expect(info.count == 24)
  }
}
