import Foundation
import Testing

package struct ArchiveFixture: Sendable {
  package static var extractionExecutables: [String: String] {
    var executables = ["tar": "tar"]
    #if !canImport(Darwin)
      if let executable = try? testExecutable("bsdtar") { executables["bsdtar"] = executable }
    #endif
    return executables
  }

  package static var zipExtractionAvailable: Bool {
    #if canImport(Darwin)
      true
    #else
      extractionExecutables["bsdtar"] != nil
    #endif
  }

  package struct Entry: Encodable {
    package var name: String
    package var content = "payload"
    package var kind = "file"
    package var mode = 0o644
    package var modificationSeconds: Int64?
    package var modificationNanoseconds: Int

    package init(
      name: String, content: String = "payload", kind: String = "file", mode: Int = 0o644,
      modificationSeconds: Int64? = nil, modificationNanoseconds: Int = 0
    ) {
      self.name = name
      self.content = content
      self.kind = kind
      self.mode = mode
      self.modificationSeconds = modificationSeconds
      self.modificationNanoseconds = modificationNanoseconds
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
    import io, json, signal, stat, struct, sys, tarfile, time, zipfile, warnings
    signal.alarm(10)
    warnings.simplefilter('ignore', UserWarning)
    with open(sys.argv[1], encoding='utf-8') as f: entries = json.load(f)
    fmt = sys.argv[3]
    if fmt.startswith('zip'):
      with zipfile.ZipFile(sys.argv[2], 'w') as archive:
        for e in entries:
          info = zipfile.ZipInfo(e['name'])
          if 'modificationSeconds' in e:
            seconds = e['modificationSeconds']
            info.date_time = time.localtime(seconds)[:6]
            if fmt != 'zip-dos':
              info.extra = struct.pack('<HHBI', 0x5455, 5, 1, seconds)
          info.create_system = 0 if fmt == 'zip-dos' else 3
          info.external_attr = 0x20 if fmt == 'zip-dos' else (e['mode'] | (stat.S_IFDIR if e['kind'] == 'directory' else stat.S_IFREG)) << 16
          info.compress_type = zipfile.ZIP_STORED if fmt == 'zip-stored' else zipfile.ZIP_DEFLATED
          archive.writestr(info, b'' if e['kind'] == 'directory' else e['content'].encode())
      if fmt == 'zip-reordered':
        with open(sys.argv[2], 'rb') as f: data = f.read()
        end = data.rindex(b'PK\x05\x06')
        offset = struct.unpack_from('<I', data, end + 16)[0]
        cursor, records = offset, []
        while cursor < end:
          assert data[cursor:cursor + 4] == b'PK\x01\x02'
          size = 46 + sum(struct.unpack_from('<HHH', data, cursor + 28))
          records.append(data[cursor:cursor + size])
          cursor += size
        assert cursor == end
        with open(sys.argv[2], 'wb') as f:
          f.write(data[:offset] + b''.join(reversed(records)) + data[end:])
    else:
      with tarfile.open(sys.argv[2], 'w:gz' if fmt == 'tar.gz' else 'w', format=tarfile.PAX_FORMAT) as archive:
        for e in entries:
          info = tarfile.TarInfo(e['name'])
          info.mode = e['mode']
          if 'modificationSeconds' in e:
            info.mtime = e['modificationSeconds']
            info.pax_headers['mtime'] = f"{info.mtime}.{e['modificationNanoseconds']:09d}"
          content = e['content'].encode()
          if e['kind'] == 'file':
            info.size = len(content)
            archive.addfile(info, io.BytesIO(content))
          elif e['kind'] == 'sparse':
            # GNU sparse extents occupy whole tar blocks, except the final extent.
            info.size = 1024
            info.pax_headers.update({'GNU.sparse.size': '2048', 'GNU.sparse.numblocks': '2',
              'GNU.sparse.name': e['name'], 'GNU.sparse.map': '0,512,1536,512'})
            archive.addfile(info, io.BytesIO(b'x' + bytes(1022) + b'x'))
          elif e['kind'] == 'sparse-tail':
            info.size = 512
            info.pax_headers.update({'GNU.sparse.size': '1024', 'GNU.sparse.numblocks': '2',
              'GNU.sparse.name': e['name'], 'GNU.sparse.map': '0,512,1024,0'})
            archive.addfile(info, io.BytesIO(b'x' + bytes(511)))
          else:
            info.type = {'directory': tarfile.DIRTYPE, 'symlink': tarfile.SYMTYPE,
              'hardlink': tarfile.LNKTYPE, 'fifo': tarfile.FIFOTYPE,
              'character': tarfile.CHRTYPE, 'sparse': tarfile.GNUTYPE_SPARSE}[e['kind']]
            if e['kind'] in ['symlink', 'hardlink']: info.linkname = '../outside'
            archive.addfile(info)
    """#
}
