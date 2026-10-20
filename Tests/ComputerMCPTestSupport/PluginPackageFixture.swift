import Foundation

package func pluginPackageFixture() throws -> URL {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "plugin-package-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: root.appendingPathComponent("skills"), withIntermediateDirectories: true)
  return root
}
