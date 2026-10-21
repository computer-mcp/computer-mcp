import Foundation
import Testing

package struct ArchiveFixture: Sendable {
  package struct Entry: Encodable {
    package var name: String
    package var content = "payload"
    package var kind = "file"
    package var mode = 0o644

    package init(
      name: String, content: String = "payload", kind: String = "file", mode: Int = 0o644
    ) {
      self.name = name
      self.content = content
      self.kind = kind
      self.mode = mode
    }
  }

  package let root: URL
  package var output: URL { root.appendingPathComponent("staging") }

  package init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "plugin-archive-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
  }

  package func remove() { try? FileManager.default.removeItem(at: root) }

  package func mode(_ path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(
      atPath: output.appendingPathComponent(path).path)
    return try #require(attributes[.posixPermissions] as? NSNumber).intValue
  }

  package func archive(_ entries: [Entry], format: String = "tar") throws -> URL {
    let input = root.appendingPathComponent("entries-\(UUID().uuidString).json")
    let archive = root.appendingPathComponent("archive-\(UUID().uuidString).data")
    try JSONEncoder().encode(entries).write(to: input)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "-c", Self.script, input.path, archive.path, format]
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
