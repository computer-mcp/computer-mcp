import Darwin
import Foundation
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct PluginArchiveExtractorTests {
  @Test(arguments: ["tar", "tar.gz", "zip", "zip-stored"])
  func extractsRealArchivesAndLoadsTheCombinedPackageWithoutExecutingIt(format: String) throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let manifest = PluginManifestTests.combined.replacingOccurrences(
      of: "dependency = 'vendor'", with: "path = 'bin/helper'")
    let source = try fixture.archive(
      [
        .init(name: PluginManifest.filename, content: manifest),
        .init(name: "bin/helper", content: "#!/bin/sh\ntouch executed\n", mode: 0o6755),
        .init(name: "skills/说明 文档.md", content: "你好\n"),
        .init(name: "skills/", kind: "directory"),
        .init(name: "empty", content: ""),
      ], format: format)
    let result = try PluginArchiveExtractor().extract(source, toNewDirectory: fixture.output)
    #expect(result.entries == 5)
    #expect(result.bytes == manifest.utf8.count + 25 + "你好\n".utf8.count)
    let package = try PluginPackage.load(at: result.root)
    #expect(package.manifest.mcp.count == 1)
    #expect(package.manifest.cli.count == 1)
    #expect(package.manifest.skills.count == 1)
    #expect(
      !FileManager.default.fileExists(atPath: result.root.appendingPathComponent("executed").path))
    #expect(try fixture.mode("bin/helper") == 0o700)
    #expect(try fixture.mode("empty") == 0o600)
    #expect(try fixture.mode("skills") == 0o700)
    #expect(try Data(contentsOf: result.root.appendingPathComponent("empty")).isEmpty)
    #expect(
      try String(
        contentsOf: result.root.appendingPathComponent("skills/说明 文档.md"),
        encoding: .utf8) == "你好\n")
  }

  @Test(arguments: [
    "../escape", "/absolute", "a/../../escape", "a//b", "a/./b", "a\\b", "C:drive",
    "a\nb", "a\tb", ".", "a/" + String(repeating: "b", count: 256),
  ])
  func unsafePathsRejectTheWholeArchiveAndReclaimPartialFiles(path: String) throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let source = try fixture.archive([.init(name: "safe"), .init(name: path)])
    #expect(throws: PluginArchiveError.unsafePath) {
      try PluginArchiveExtractor().extract(source, toNewDirectory: fixture.output)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
    #expect(
      !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("escape").path))
    #expect(FileManager.default.fileExists(atPath: source.path))
  }

  @Test(arguments: ["symlink", "hardlink", "fifo", "character", "sparse"])
  func rejectsLinksDevicesAndSparseFiles(kind: String) throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let source = try fixture.archive([.init(name: "safe"), .init(name: "unsafe", kind: kind)])
    #expect(throws: PluginArchiveError.unsupportedEntry) {
      try PluginArchiveExtractor().extract(source, toNewDirectory: fixture.output)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
  }

  @Test
  func rejectsDirectoryHeadersWithFilePayload() throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let source = try fixture.archive([.init(name: "directory/", content: "not-directory-data")])
    #expect(throws: PluginArchiveError.invalidArchive) {
      try PluginArchiveExtractor().extract(source, toNewDirectory: fixture.output)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
  }

  @Test(arguments: [
    ["file", "file"], ["File", "file"], ["café", "cafe\u{301}"],
    ["Parent/one", "parent/two"], ["straße/one", "STRASSE/two"],
    ["parent/file", "parent"], ["parent", "parent/file"],
  ])
  func rejectsDuplicateCaseUnicodeAndFileDirectoryCollisions(names: [String]) throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let source = try fixture.archive(names.map { .init(name: $0) })
    #expect(throws: PluginArchiveError.conflictingPath) {
      try PluginArchiveExtractor().extract(source, toNewDirectory: fixture.output)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
  }

  @Test
  func permitsTarDotRootAndImplicitParentsButNotDuplicateDirectoryHeaders() throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let source = try fixture.archive([
      .init(name: "./", kind: "directory"), .init(name: "./parent/file"),
      .init(name: "./parent/", kind: "directory"),
    ])
    #expect(
      try PluginArchiveExtractor().extract(source, toNewDirectory: fixture.output).entries == 3)
    let duplicate = try fixture.archive([
      .init(name: "directory/", kind: "directory"), .init(name: "directory/", kind: "directory"),
    ])
    #expect(throws: PluginArchiveError.conflictingPath) {
      try PluginArchiveExtractor().extract(
        duplicate, toNewDirectory: fixture.root.appendingPathComponent("second"))
    }
  }

  @Test(arguments: ["archive", "file", "total", "entries", "path", "depth"])
  func enforcesLimitsIncludingCompressedExpansion(limit: String) throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let source = try fixture.archive(
      [
        .init(name: "parent/one", content: String(repeating: "x", count: 1_024)),
        .init(name: "parent/two", content: String(repeating: "x", count: 1_024)),
      ], format: "tar.gz")
    var limits = PluginArchiveLimits()
    switch limit {
    case "archive": limits.archiveBytes = 1
    case "file": limits.fileBytes = 1_023
    case "total": limits.expandedBytes = 2_047
    case "entries": limits.entries = 1
    case "path": limits.pathBytes = 2
    default: limits.pathDepth = 1
    }
    #expect(throws: PluginArchiveError.self) {
      try PluginArchiveExtractor(limits: limits).extract(source, toNewDirectory: fixture.output)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
  }

  @Test
  func cancellationAfterWritingDataRemovesOnlyThisStagingDirectory() throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let sibling = fixture.root.appendingPathComponent("unrelated")
    try Data("user-owned".utf8).write(to: sibling)
    let source = try fixture.archive([
      .init(name: "large", content: String(repeating: "x", count: 150_000))
    ])
    var checks = 0
    #expect(throws: CancellationError.self) {
      try PluginArchiveExtractor().extract(source, toNewDirectory: fixture.output) {
        checks += 1
        if checks == 4 { throw CancellationError() }
      }
    }
    #expect(checks == 4)
    #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
    #expect(try Data(contentsOf: sibling) == Data("user-owned".utf8))
  }

  @Test
  func neverOverwritesAnExistingDestinationOrFollowsAnInputSymlink() throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let source = try fixture.archive([.init(name: "file")])
    try Data("keep".utf8).write(to: fixture.output)
    #expect(throws: PluginArchiveError.conflictingPath) {
      try PluginArchiveExtractor().extract(source, toNewDirectory: fixture.output)
    }
    #expect(try Data(contentsOf: fixture.output) == Data("keep".utf8))
    let link = fixture.root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    #expect(throws: PluginArchiveError.invalidInput) {
      try PluginArchiveExtractor().extract(
        link, toNewDirectory: fixture.root.appendingPathComponent("new"))
    }
    #expect(throws: PluginArchiveError.invalidInput) {
      try PluginArchiveExtractor().extract(fixture.root, toNewDirectory: fixture.output)
    }
  }

  @Test(arguments: ["invalid", "truncated", "crc", "encrypted", "empty"])
  func corruptAndEncryptedArchivesNeverProduceSuccessfulOutput(corruption: String) throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let source = try fixture.archive(
      corruption == "empty" ? [] : [.init(name: "file", content: "unique-payload")],
      format: "zip-stored")
    var data = try Data(contentsOf: source)
    switch corruption {
    case "invalid": data = Data("not-an-archive".utf8)
    case "truncated": data = Data(data.prefix(35))
    case "crc":
      let range = try #require(data.range(of: Data("unique-payload".utf8)))
      data[range.lowerBound] = 0
    case "encrypted":
      // Set the standard encrypted bit in both the local and central headers.
      data[6] |= 1
      let range = try #require(data.range(of: Data([0x50, 0x4b, 0x01, 0x02])))
      data[range.lowerBound + 8] |= 1
    default: break
    }
    try data.write(to: source)
    #expect(throws: PluginArchiveError.self) {
      try PluginArchiveExtractor().extract(source, toNewDirectory: fixture.output)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
  }

  @Test
  func rejectsUnsafeStagingParentAndInvalidLimitsWithoutCreatingFiles() throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let source = try fixture.archive([.init(name: "file")])
    var limits = PluginArchiveLimits()
    limits.entries = 0
    #expect(throws: PluginArchiveError.invalidInput) {
      try PluginArchiveExtractor(limits: limits).extract(source, toNewDirectory: fixture.output)
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o777], ofItemAtPath: fixture.root.path)
    #expect(throws: PluginArchiveError.invalidInput) {
      try PluginArchiveExtractor().extract(source, toNewDirectory: fixture.output)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
  }

  @Test
  func cleanupUnlinksInjectedSymlinksWithoutTouchingTheirTargets() throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let target = fixture.root.appendingPathComponent("user-file")
    try Data("keep".utf8).write(to: target)
    let directory = try PluginArchiveDirectory(at: fixture.output)
    try FileManager.default.createSymbolicLink(
      at: directory.url.appendingPathComponent("link"),
      withDestinationURL: target)
    try directory.discard()
    #expect(try Data(contentsOf: target) == Data("keep".utf8))
    #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
  }

  @Test
  func cleanupRefusesAReplacedDirectoryName() throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let directory = try PluginArchiveDirectory(at: fixture.output)
    try FileManager.default.moveItem(
      at: fixture.output, to: fixture.root.appendingPathComponent("moved"))
    try FileManager.default.createDirectory(at: fixture.output, withIntermediateDirectories: false)
    #expect(throws: PluginArchiveError.fileSystemFailure) { try directory.discard() }
    #expect(FileManager.default.fileExists(atPath: fixture.output.path))
  }
}

struct ArchiveFixture: Sendable {
  struct Entry: Encodable {
    var name: String
    var content = "payload"
    var kind = "file"
    var mode = 0o644
  }

  let root: URL
  var output: URL { root.appendingPathComponent("staging") }

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "plugin-archive-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  func mode(_ path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(
      atPath: output.appendingPathComponent(path).path)
    return try #require(attributes[.posixPermissions] as? NSNumber).intValue
  }

  func archive(_ entries: [Entry], format: String = "tar") throws -> URL {
    let input = root.appendingPathComponent("entries-\(UUID().uuidString).json")
    let archive = root.appendingPathComponent("archive-\(UUID().uuidString).data")
    try JSONEncoder().encode(entries).write(to: input)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", Self.script, input.path, archive.path, format]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "Archive fixture generator failed")
    return archive
  }

  private static let script = #"""
    import io, json, signal, stat, sys, tarfile, zipfile, warnings
    signal.alarm(10)
    warnings.simplefilter('ignore', UserWarning)
    with open(sys.argv[1], encoding='utf-8') as f: entries = json.load(f)
    fmt = sys.argv[3]
    if fmt.startswith('zip'):
      with zipfile.ZipFile(sys.argv[2], 'w') as archive:
        for e in entries:
          info = zipfile.ZipInfo(e['name'])
          info.create_system = 3
          info.external_attr = (e['mode'] | (stat.S_IFDIR if e['kind'] == 'directory' else stat.S_IFREG)) << 16
          info.compress_type = zipfile.ZIP_STORED if fmt == 'zip-stored' else zipfile.ZIP_DEFLATED
          archive.writestr(info, b'' if e['kind'] == 'directory' else e['content'].encode())
    else:
      with tarfile.open(sys.argv[2], 'w:gz' if fmt == 'tar.gz' else 'w', format=tarfile.PAX_FORMAT) as archive:
        for e in entries:
          info = tarfile.TarInfo(e['name'])
          info.mode = e['mode']
          content = e['content'].encode()
          if e['kind'] == 'file':
            info.size = len(content)
            archive.addfile(info, io.BytesIO(content))
          elif e['kind'] == 'sparse':
            info.size = 2
            info.pax_headers = {'GNU.sparse.map': '0,1,1023,1', 'GNU.sparse.size': '1024',
              'GNU.sparse.numblocks': '2', 'GNU.sparse.name': e['name']}
            archive.addfile(info, io.BytesIO(b'xx'))
          else:
            info.type = {'directory': tarfile.DIRTYPE, 'symlink': tarfile.SYMTYPE,
              'hardlink': tarfile.LNKTYPE, 'fifo': tarfile.FIFOTYPE,
              'character': tarfile.CHRTYPE, 'sparse': tarfile.GNUTYPE_SPARSE}[e['kind']]
            if e['kind'] in ['symlink', 'hardlink']: info.linkname = '../outside'
            archive.addfile(info)
    """#
}
