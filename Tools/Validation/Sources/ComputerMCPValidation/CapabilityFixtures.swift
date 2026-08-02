import AppKit
import CoreText
import CryptoKit
import Darwin
import Foundation

public struct CapabilityFixtureEntry: Codable, Equatable, Sendable {
  public var path: String
  public var kind: String
  public var byteCount: Int?
  public var contentDigest: String?
  public var fixtureMetadata: [String: String]?

  public init(
    path: String,
    kind: String,
    byteCount: Int? = nil,
    contentDigest: String? = nil,
    fixtureMetadata: [String: String]? = nil
  ) {
    self.path = path
    self.kind = kind
    self.byteCount = byteCount
    self.contentDigest = contentDigest
    self.fixtureMetadata = fixtureMetadata
  }
}

public struct CapabilityFixtureReport: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public var schemaVersion = Self.currentSchemaVersion
  public var generatedAt: String
  public var rootPath: String
  public var entries: [CapabilityFixtureEntry]
  public var contentDigest: String

  public init(
    generatedAt: String,
    rootPath: String,
    entries: [CapabilityFixtureEntry],
    contentDigest: String
  ) {
    self.generatedAt = generatedAt
    self.rootPath = rootPath
    self.entries = entries
    self.contentDigest = contentDigest
  }

  public var entryCount: Int {
    entries.count
  }

  public func encodedJSON() throws -> Data {
    try ValidationJSONCoding.encode(self)
  }

  public static func decodeJSON(_ data: Data) throws -> CapabilityFixtureReport {
    let report = try ValidationJSONCoding.decode(Self.self, from: data)
    guard report.schemaVersion == currentSchemaVersion else {
      throw ValidationArtifactError.unsupportedSchema(
        artifact: "Capability Fixture Report",
        expected: currentSchemaVersion,
        actual: report.schemaVersion
      )
    }
    try ValidationJSONCoding.requireExactShape(
      report,
      input: data,
      artifact: "Capability Fixture Report"
    )
    return report
  }
}

public enum CapabilityFixtureError: Error, LocalizedError, Equatable {
  case destinationExists(String)
  case destinationNotOwned(String)
  case commandFailed(String)
  case fixtureEncodingFailed(String)

  public var errorDescription: String? {
    switch self {
    case .destinationExists(let path):
      return "Fixture destination already exists: \(path). Pass --force to replace it."
    case .destinationNotOwned(let path):
      return
        "Refusing to replace a directory without the Computer MCP Validation owner marker: \(path)"
    case .commandFailed(let message):
      return message
    case .fixtureEncodingFailed(let name):
      return "Could not encode deterministic fixture: \(name)"
    }
  }
}

public struct CapabilityFixtureGenerator {
  private static let markerName = ".computer-mcp-validate-fixture"
  private static let markerContent = """
    {"owner":"computer-mcp-validate","schema_version":1}
    """

  private let fileManager: FileManager
  private let commandRunner: any CommandRunning

  public init(
    fileManager: FileManager = .default,
    commandRunner: any CommandRunning = ProcessCommandRunner()
  ) {
    self.fileManager = fileManager
    self.commandRunner = commandRunner
  }

  public func generate(
    at destination: URL,
    force: Bool = false,
    generatedAt: Date = Date()
  ) throws -> CapabilityFixtureReport {
    let requestedRoot = destination.standardizedFileURL
    try prepare(root: requestedRoot, force: force)
    let root = requestedRoot.resolvingSymlinksInPath()
    try write(
      Self.markerContent,
      to: root.appendingPathComponent(Self.markerName)
    )

    try writeTextFixtures(root: root)
    try writeStructuredFixtures(root: root)
    try writeBinaryFixtures(root: root)
    try writeSkillFixture(root: root)
    try writeFilesystemFixtures(root: root)
    try writeExtendedAttributeFixture(root: root)
    try writeSQLiteFixture(root: root)
    try writeArchiveFixture(root: root)
    try writeGitFixture(root: root)

    let entries = try entries(in: root)
    return CapabilityFixtureReport(
      generatedAt: Self.timestamp(generatedAt),
      rootPath: root.path,
      entries: entries,
      contentDigest: try Self.digest(entries)
    )
  }

  private func prepare(root: URL, force: Bool) throws {
    var isDirectory = ObjCBool(false)
    guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
      try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
      return
    }
    let existingRoot = root.resolvingSymlinksInPath()
    guard force else {
      throw CapabilityFixtureError.destinationExists(existingRoot.path)
    }
    let marker = existingRoot.appendingPathComponent(Self.markerName)
    guard isDirectory.boolValue,
      (try? String(contentsOf: marker, encoding: .utf8)) == Self.markerContent
    else {
      throw CapabilityFixtureError.destinationNotOwned(existingRoot.path)
    }
    try fileManager.removeItem(at: existingRoot)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
  }

  private func writeTextFixtures(root: URL) throws {
    try write(
      """
      # Computer MCP Validation Fixture

      This workspace contains deterministic files for capability testing.

      ## Links

      - [Local guide](Docs/guide.md)
      - [OpenAI](https://openai.com)

      | Capability | Fixture |
      | --- | --- |
      | text | Text/lines.txt |
      | structured | Data/sample.json |
      """,
      to: root.appendingPathComponent("README.md")
    )
    try write(
      """
      alpha
      beta
      gamma
      delta
      epsilon
      """,
      to: root.appendingPathComponent("Text/lines.txt")
    )
    try write(
      """
      # Fixture Guide

      The stable marker is `CMCP-FIXTURE-ALPHA`.

      ## Verification

      Parsers should return bounded structured output.
      """,
      to: root.appendingPathComponent("Docs/guide.md")
    )
    try write(
      """
      import Foundation

      struct FixtureProgram {
        let name = "computer-mcp"
      }

      print("computer-mcp fixture")
      // TODO: fixture marker for workspace.todos
      """,
      to: root.appendingPathComponent("Sources/main.swift")
    )
    try write(
      """
      # Computer MCP Fixture Agent Guide

      Keep fixture operations deterministic and bounded.
      """,
      to: root.appendingPathComponent("AGENTS.md")
    )
    try write(
      """
      // swift-tools-version: 6.2
      import PackageDescription

      let package = Package(
        name: "ComputerMCPFixture",
        targets: [.executableTarget(name: "Fixture", path: "Sources")]
      )
      """,
      to: root.appendingPathComponent("Package.swift")
    )
    try write(
      """
      import Testing

      @Test func fixture() {
        #expect(true)
      }
      """,
      to: root.appendingPathComponent("Tests/FixtureTests.swift")
    )
    try write(
      """
      name: fixture-ci
      on: [push]
      jobs:
        test:
          runs-on: macos-latest
          steps:
            - run: swift test
      """,
      to: root.appendingPathComponent(".github/workflows/ci.yml")
    )
    try write(
      "* @computer-mcp-fixture\n",
      to: root.appendingPathComponent(".github/CODEOWNERS")
    )
    try write(
      "fixture.enabled=true\n",
      to: root.appendingPathComponent("Config/fixture.conf")
    )
    try write(
      "FROM scratch\n",
      to: root.appendingPathComponent("Infrastructure/Dockerfile")
    )
    try write(
      """
      {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "title": "Computer MCP Fixture",
        "type": "object"
      }
      """,
      to: root.appendingPathComponent("Schemas/fixture.schema.json")
    )
    try write(
      "MIT License\n\nComputer MCP deterministic fixture.\n",
      to: root.appendingPathComponent("LICENSE")
    )
    try write(
      "# Security\n\nThis directory contains only generated test data.\n",
      to: root.appendingPathComponent("SECURITY.md")
    )
    try write(
      ".build/\n.fixture-cache/\n",
      to: root.appendingPathComponent(".gitignore")
    )
    try write(
      "{\"version\":1}\n",
      to: root.appendingPathComponent(".swift-format")
    )
    try write(
      """
      #!/bin/sh
      printf 'computer-mcp-fixture\\n'
      """,
      to: root.appendingPathComponent("Scripts/fixture.sh")
    )
    try fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o755))],
      ofItemAtPath: root.appendingPathComponent("Scripts/fixture.sh").path
    )
    try write(
      "COMPUTER_MCP_FIXTURE=enabled\n",
      to: root.appendingPathComponent(".env.example")
    )
    try write(
      "2026-01-01T00:00:00Z fixture ready\n",
      to: root.appendingPathComponent("Logs/sample.log")
    )
    try write(
      "deterministic build output\n",
      to: root.appendingPathComponent("build/fixture-output.txt")
    )
  }

  private func writeStructuredFixtures(root: URL) throws {
    try write(
      """
      {
        "fixture": "computer-mcp",
        "enabled": true,
        "count": 3,
        "items": ["alpha", "beta", "gamma"]
      }
      """,
      to: root.appendingPathComponent("Data/sample.json")
    )
    try write(
      """
      {"id":1,"name":"alpha"}
      {"id":2,"name":"beta"}
      {"id":3,"name":"gamma"}
      """,
      to: root.appendingPathComponent("Data/sample.jsonl")
    )
    try write(
      """
      fixture: computer-mcp
      enabled: true
      items:
        - alpha
        - beta
      """,
      to: root.appendingPathComponent("Data/sample.yaml")
    )
    try write(
      """
      title = "computer-mcp"
      enabled = true

      [limits]
      count = 3
      """,
      to: root.appendingPathComponent("Data/sample.toml")
    )
    try write(
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <fixture name="computer-mcp"><item id="1">alpha</item></fixture>
      """,
      to: root.appendingPathComponent("Data/sample.xml")
    )
    try write(
      """
      id,name,enabled
      1,alpha,true
      2,beta,false
      3,gamma,true
      """,
      to: root.appendingPathComponent("Data/sample.csv")
    )
    let plist: [String: Any] = [
      "fixture": "computer-mcp",
      "enabled": true,
      "items": ["alpha", "beta"],
    ]
    let plistData = try PropertyListSerialization.data(
      fromPropertyList: plist,
      format: .xml,
      options: 0
    )
    try write(plistData, to: root.appendingPathComponent("Data/sample.plist"))
  }

  private func writeBinaryFixtures(root: URL) throws {
    guard
      let png = Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9WlFK1cAAAAASUVORK5CYII="
      )
    else {
      throw CapabilityFixtureError.fixtureEncodingFailed("PNG")
    }
    try write(png, to: root.appendingPathComponent("Artifacts/pixel.png"))
    try write(png, to: root.appendingPathComponent("Assets/pixel.png"))
    try writeTextPDF(
      pages: [
        "Computer MCP fixture PDF page one.",
        "Computer MCP fixture PDF page two.",
      ],
      to: root.appendingPathComponent("Artifacts/report.pdf")
    )
    try write(
      wavData(sampleRate: 8_000, sampleCount: 4_000),
      to: root.appendingPathComponent("Artifacts/silence.wav")
    )
  }

  private func writeSkillFixture(root: URL) throws {
    try write(
      """
      ---
      name: fixture-skill
      description: >-
        Validate folded YAML frontmatter and complete skill-package reading
        through Computer MCP.
      ---

      # Fixture Skill

      Read [the reference](references/details.md) before using the script.
      """,
      to: root.appendingPathComponent("Skills/fixture-skill/SKILL.md")
    )
    try write(
      "# Fixture Reference\n\nStable reference content.\n",
      to: root.appendingPathComponent("Skills/fixture-skill/references/details.md")
    )
    try write(
      "#!/bin/sh\nprintf 'fixture-skill\\n'\n",
      to: root.appendingPathComponent("Skills/fixture-skill/scripts/run.sh")
    )
    try fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o755))],
      ofItemAtPath: root.appendingPathComponent("Skills/fixture-skill/scripts/run.sh").path
    )
  }

  private func writeFilesystemFixtures(root: URL) throws {
    try fileManager.createDirectory(
      at: root.appendingPathComponent("Empty", isDirectory: true),
      withIntermediateDirectories: true
    )
    try write(
      "duplicate-content\n",
      to: root.appendingPathComponent("Duplicates/first.txt")
    )
    try write(
      "duplicate-content\n",
      to: root.appendingPathComponent("Duplicates/second.txt")
    )
    let links = root.appendingPathComponent("Links", isDirectory: true)
    try fileManager.createDirectory(at: links, withIntermediateDirectories: true)
    try fileManager.createSymbolicLink(
      atPath: links.appendingPathComponent("readme.md").path,
      withDestinationPath: "../README.md"
    )
    try fileManager.createSymbolicLink(
      atPath: links.appendingPathComponent("missing").path,
      withDestinationPath: "../missing.txt"
    )
  }

  private func writeExtendedAttributeFixture(root: URL) throws {
    let url = root.appendingPathComponent("Xattrs/tagged.txt")
    let name = "com.showxu.computer-mcp.fixture"
    let value = Data("deterministic-xattr".utf8)
    try write("extended attribute fixture\n", to: url)
    let result = url.withUnsafeFileSystemRepresentation { path in
      value.withUnsafeBytes { bytes in
        setxattr(path, name, bytes.baseAddress, value.count, 0, 0)
      }
    }
    guard result == 0 else {
      throw CapabilityFixtureError.commandFailed(
        "Could not set deterministic fixture xattr: \(String(cString: strerror(errno)))"
      )
    }
  }

  private func writeSQLiteFixture(root: URL) throws {
    let databaseURL = root.appendingPathComponent("Data/sample.sqlite")
    try fileManager.createDirectory(
      at: databaseURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try run(
      executable: "/usr/bin/sqlite3",
      arguments: [
        databaseURL.path,
        "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, enabled INTEGER NOT NULL); INSERT INTO items (id, name, enabled) VALUES (1, 'alpha', 1), (2, 'beta', 0), (3, 'gamma', 1);",
      ],
      workingDirectory: root
    )
  }

  private func writeArchiveFixture(root: URL) throws {
    let source = root.appendingPathComponent("ArchiveSource", isDirectory: true)
    try write("hello from archive\n", to: source.appendingPathComponent("hello.txt"))
    try write(
      "{\"archive\":true}\n",
      to: source.appendingPathComponent("nested/value.json")
    )
    try normalizeArchiveSourceDates(at: source)
    try run(
      executable: "/usr/bin/ditto",
      arguments: [
        "-c", "-k", "--sequesterRsrc", "--keepParent",
        source.path,
        root.appendingPathComponent("Artifacts/sample.zip").path,
      ],
      workingDirectory: root
    )
  }

  private func normalizeArchiveSourceDates(at root: URL) throws {
    let fixedDate = Date(timeIntervalSince1970: 315_532_800)
    let keys: [URLResourceKey] = [.isDirectoryKey]
    guard
      let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: keys,
        options: [],
        errorHandler: { _, _ in false }
      )
    else {
      throw CapabilityFixtureError.fixtureEncodingFailed("archive source")
    }
    var entries = enumerator.compactMap { $0 as? URL }
    entries.append(root)
    for entry in entries {
      try fileManager.setAttributes(
        [.modificationDate: fixedDate],
        ofItemAtPath: entry.path
      )
    }
  }

  private func writeGitFixture(root: URL) throws {
    let repository = root.appendingPathComponent("Repository", isDirectory: true)
    try write(
      "# Fixture Repository\n",
      to: repository.appendingPathComponent("README.md")
    )
    try write(
      "print(\"fixture repository\")\n",
      to: repository.appendingPathComponent("Sources/main.swift")
    )
    try write(
      ".fixture-ignored\n",
      to: repository.appendingPathComponent(".gitignore")
    )
    try run(
      executable: "/usr/bin/git",
      arguments: ["init", "-q", "-b", "main"],
      workingDirectory: repository
    )
    try run(
      executable: "/usr/bin/git",
      arguments: ["config", "user.name", "Computer MCP Fixture"],
      workingDirectory: repository
    )
    try run(
      executable: "/usr/bin/git",
      arguments: ["config", "user.email", "fixture@invalid.example"],
      workingDirectory: repository
    )
    try run(
      executable: "/usr/bin/git",
      arguments: ["add", "."],
      workingDirectory: repository
    )
    try run(
      executable: "/usr/bin/git",
      arguments: ["commit", "-q", "-m", "Initial fixture"],
      workingDirectory: repository
    )
    try run(
      executable: "/usr/bin/git",
      arguments: ["tag", "-a", "v0.1.0", "-m", "Fixture release"],
      workingDirectory: repository
    )
    try run(
      executable: "/usr/bin/git",
      arguments: ["branch", "fixture-base"],
      workingDirectory: repository
    )
    try write(
      "# Fixture Repository\n\nSecond committed revision.\n",
      to: repository.appendingPathComponent("README.md")
    )
    try run(
      executable: "/usr/bin/git",
      arguments: ["add", "README.md"],
      workingDirectory: repository
    )
    try run(
      executable: "/usr/bin/git",
      arguments: ["commit", "-q", "-m", "Second fixture revision"],
      workingDirectory: repository
    )
    try run(
      executable: "/usr/bin/git",
      arguments: ["remote", "add", "origin", repository.path],
      workingDirectory: repository
    )
    try run(
      executable: "/usr/bin/git",
      arguments: ["update-ref", "refs/remotes/origin/main", "HEAD"],
      workingDirectory: repository
    )
    try run(
      executable: "/usr/bin/git",
      arguments: ["branch", "--set-upstream-to=origin/main", "main"],
      workingDirectory: repository
    )
    try write(
      "# Fixture Repository\n\nTemporary stash revision.\n",
      to: repository.appendingPathComponent("README.md")
    )
    try run(
      executable: "/usr/bin/git",
      arguments: ["stash", "push", "-q", "-m", "Fixture stash", "--", "README.md"],
      workingDirectory: repository
    )
    try write(
      "staged fixture\n",
      to: repository.appendingPathComponent("staged.txt")
    )
    try run(
      executable: "/usr/bin/git",
      arguments: ["add", "staged.txt"],
      workingDirectory: repository
    )
    try write(
      "print(\"fixture repository with unstaged change\")\n",
      to: repository.appendingPathComponent("Sources/main.swift")
    )
    try write(
      "ignored fixture\n",
      to: repository.appendingPathComponent(".fixture-ignored")
    )
    try write(
      "untracked fixture\n",
      to: repository.appendingPathComponent("untracked.txt")
    )
  }

  private func writeTextPDF(pages: [String], to url: URL) throws {
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    let fixedDate = Date(timeIntervalSince1970: 0)
    let metadata: [CFString: Any] = [
      kCGPDFContextCreator: "Computer MCP Validation",
      kCGPDFContextTitle: "Deterministic Capability Fixture",
      "CreationDate" as CFString: fixedDate as CFDate,
      "ModDate" as CFString: fixedDate as CFDate,
    ]
    guard let consumer = CGDataConsumer(url: url as CFURL),
      let context = CGContext(
        consumer: consumer,
        mediaBox: &mediaBox,
        metadata as CFDictionary
      )
    else {
      throw CapabilityFixtureError.fixtureEncodingFailed("PDF")
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
      path.addRect(
        CGRect(
          x: 72,
          y: 72,
          width: mediaBox.width - 144,
          height: mediaBox.height - 144
        )
      )
      CTFrameDraw(
        CTFramesetterCreateFrame(
          framesetter,
          CFRange(location: 0, length: attributed.length),
          path,
          nil
        ),
        context
      )
      context.restoreGState()
      context.endPDFPage()
    }
    context.closePDF()
    try normalizePDFMetadata(at: url)
  }

  private func normalizePDFMetadata(at url: URL) throws {
    var bytes = Array(try Data(contentsOf: url))
    let dateSuffix = Array("Z00'00'".utf8)
    let fixedDate = Array("19700101000000Z00'00'".utf8)
    let identifierMarker = Array("/ID [ <".utf8)
    let fixedIdentifier = Array("0123456789abcdef0123456789abcdef".utf8)

    var index = 0
    while index + 2 + fixedDate.count <= bytes.count {
      let hasDatePrefix = bytes[index] == 68 && bytes[index + 1] == 58
      let digits = bytes[(index + 2)..<(index + 16)]
      let suffix = bytes[(index + 16)..<(index + 16 + dateSuffix.count)]
      if hasDatePrefix,
        digits.allSatisfy({ (48...57).contains($0) }),
        suffix.elementsEqual(dateSuffix)
      {
        bytes.replaceSubrange((index + 2)..<(index + 2 + fixedDate.count), with: fixedDate)
        index += 2 + fixedDate.count
      } else {
        index += 1
      }
    }

    guard
      let markerIndex = bytes.indices.first(where: { candidate in
        candidate + identifierMarker.count <= bytes.count
          && bytes[candidate..<(candidate + identifierMarker.count)]
            .elementsEqual(identifierMarker)
      })
    else {
      throw CapabilityFixtureError.fixtureEncodingFailed("PDF identifier")
    }
    let firstIdentifierStart = markerIndex + identifierMarker.count
    guard
      firstIdentifierStart + fixedIdentifier.count <= bytes.count,
      let secondIdentifierOpen = bytes[(firstIdentifierStart + fixedIdentifier.count)...]
        .firstIndex(of: 60),
      secondIdentifierOpen + 1 + fixedIdentifier.count <= bytes.count
    else {
      throw CapabilityFixtureError.fixtureEncodingFailed("PDF identifier")
    }
    bytes.replaceSubrange(
      firstIdentifierStart..<(firstIdentifierStart + fixedIdentifier.count),
      with: fixedIdentifier
    )
    let secondIdentifierStart = secondIdentifierOpen + 1
    bytes.replaceSubrange(
      secondIdentifierStart..<(secondIdentifierStart + fixedIdentifier.count),
      with: fixedIdentifier
    )
    try Data(bytes).write(to: url, options: .atomic)
  }

  private func wavData(sampleRate: UInt32, sampleCount: UInt32) -> Data {
    let channels: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let blockAlign = channels * bitsPerSample / 8
    let byteRate = sampleRate * UInt32(blockAlign)
    let dataSize = sampleCount * UInt32(blockAlign)
    var data = Data()
    data.append(contentsOf: "RIFF".utf8)
    appendLittleEndian(UInt32(36) + dataSize, to: &data)
    data.append(contentsOf: "WAVEfmt ".utf8)
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

  private func appendLittleEndian<T: FixedWidthInteger>(
    _ value: T,
    to data: inout Data
  ) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { buffer in
      data.append(contentsOf: buffer)
    }
  }

  private func run(
    executable: String,
    arguments: [String],
    workingDirectory: URL
  ) throws {
    let result = try commandRunner.run(
      executable: executable,
      arguments: arguments,
      workingDirectory: workingDirectory,
      environment: [:],
      timeoutMilliseconds: 30_000,
      maxOutputBytes: 65_536
    )
    guard result.exitCode == 0, !result.timedOut else {
      let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      throw CapabilityFixtureError.commandFailed(
        detail.isEmpty
          ? "Fixture command failed: \(executable) \(arguments.joined(separator: " "))"
          : detail
      )
    }
  }

  private func write(_ text: String, to url: URL) throws {
    try write(Data(text.utf8), to: url)
  }

  private func write(_ data: Data, to url: URL) throws {
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
  }

  private func entries(in root: URL) throws -> [CapabilityFixtureEntry] {
    guard let enumerator = fileManager.enumerator(atPath: root.path) else {
      return []
    }
    var entries: [CapabilityFixtureEntry] = []
    for case let relative as String in enumerator {
      if relative == Self.markerName {
        continue
      }
      if relative == "Repository/.git" {
        enumerator.skipDescendants()
        continue
      }
      let url = root.appendingPathComponent(relative)
      let values = try url.resourceValues(
        forKeys: [
          .isDirectoryKey,
          .isRegularFileKey,
          .isSymbolicLinkKey,
          .fileSizeKey,
        ]
      )
      let kind: String
      let byteCount: Int?
      let contentDigest: String?
      if values.isSymbolicLink == true {
        kind = "symlink"
        byteCount = nil
        contentDigest = Self.digest(
          Data(try fileManager.destinationOfSymbolicLink(atPath: url.path).utf8)
        )
      } else if values.isDirectory == true {
        kind = "directory"
        byteCount = nil
        contentDigest = nil
      } else {
        kind = "file"
        byteCount = values.fileSize
        contentDigest = Self.digest(try Data(contentsOf: url))
      }
      entries.append(
        CapabilityFixtureEntry(
          path: relative,
          kind: kind,
          byteCount: byteCount,
          contentDigest: contentDigest,
          fixtureMetadata:
            relative == "Xattrs/tagged.txt"
            ? [
              "com.showxu.computer-mcp.fixture": Self.digest(
                Data("deterministic-xattr".utf8)
              )
            ]
            : nil
        )
      )
    }
    return entries.sorted { $0.path < $1.path }
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private static func digest<T: Encodable>(_ value: T) throws -> String {
    let encoder = CanonicalJSONCoding.encoder(
      outputFormatting: [.sortedKeys, .withoutEscapingSlashes]
    )
    return digest(try encoder.encode(value))
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
