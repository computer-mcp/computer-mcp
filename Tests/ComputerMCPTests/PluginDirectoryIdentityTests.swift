import Darwin
import Foundation
import Testing

@testable import ComputerMCP

@Suite(.nativeIntegration)
struct PluginDirectoryIdentityTests {
  @Test
  func durableIdentitySurvivesMountDeviceRenumbering() throws {
    let directory = try PluginArchiveDirectory(
      at: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? directory.discard() }
    let identity = try directory.identity()
    var status = stat()
    try #require(fstat(directory.descriptor, &status) == 0)
    let mountedDevice = status.st_dev
    status.st_dev ^= 1
    #expect(try identity.matches(status, descriptor: directory.descriptor))
    let data = try JSONEncoder().encode(identity)
    let document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(document["volumeUUID"] != nil)
    let legacy = try JSONDecoder().decode(LegacyDirectoryIdentity.self, from: data)
    #expect(legacy.device == mountedDevice && legacy.inode == identity.inode)
    #expect(legacy.url == identity.url && legacy.birthSeconds == identity.birthSeconds)
    #expect(legacy.birthNanoseconds == identity.birthNanoseconds)
    let restored = try JSONDecoder().decode(PluginDirectoryIdentity.self, from: data)
    #expect(restored == identity)
    #expect(try restored.matches(status, descriptor: directory.descriptor))
  }

  @Test(arguments: ["volumeUUID", "inode", "birthSeconds", "birthNanoseconds"])
  func changedDirectoryIdentityIsRejected(field: String) throws {
    let directory = try PluginArchiveDirectory(
      at: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? directory.discard() }
    let identity = try directory.identity()
    var document = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(identity)) as? [String: Any])
    if field == "volumeUUID" {
      document[field] = UUID().uuidString
    } else {
      document[field] = try #require(document[field] as? NSNumber).uint64Value + 1
    }
    let changed = try JSONDecoder().decode(
      PluginDirectoryIdentity.self, from: JSONSerialization.data(withJSONObject: document))
    var status = stat()
    try #require(fstat(directory.descriptor, &status) == 0)
    #expect(try !changed.matches(status, descriptor: directory.descriptor))
  }

  @Test
  func legacyReceiptsRequireTheirRecordedMountBeforeMigration() throws {
    let directory = try PluginArchiveDirectory(
      at: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? directory.discard() }
    let identity = try directory.identity()
    var status = stat()
    try #require(fstat(directory.descriptor, &status) == 0)
    var document = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(identity)) as? [String: Any])
    document.removeValue(forKey: "volumeUUID")
    document["device"] = status.st_dev
    let legacy = try JSONDecoder().decode(
      PluginDirectoryIdentity.self, from: JSONSerialization.data(withJSONObject: document))
    #expect(try legacy.matches(status, descriptor: directory.descriptor))
    status.st_dev ^= 1
    #expect(try !legacy.matches(status, descriptor: directory.descriptor))
    #expect(legacy.mayReferToSameDirectory(as: identity))
    document["volumeUUID"] = identity.volumeUUID?.uuidString
    let durable = try JSONDecoder().decode(
      PluginDirectoryIdentity.self, from: JSONSerialization.data(withJSONObject: document))
    #expect(try durable.matches(status, descriptor: directory.descriptor))
  }
}

private struct LegacyDirectoryIdentity: Decodable {
  let url: URL
  let device: Int32
  let inode: UInt64
  let birthSeconds: Int
  let birthNanoseconds: Int
}
