import ComputerMCPCore
import Foundation

package struct FileInfo {
  package var path: String
  package var projectRelativePath: String
  package var type: String
  package var size: Int64?
  package var createdAt: Date?
  package var modifiedAt: Date?
  package var isReadable: Bool
  package var isWritable: Bool
  package var isExecutable: Bool
  package var isSymlink: Bool
  package var symlinkDestination: String?

  package var json: JSONValue {
    .object([
      "path": .string(path),
      "project_relative_path": .string(projectRelativePath),
      "type": .string(type),
      "size_bytes": size.map { .integer(Int64($0)) } ?? .null,
      "created_at": createdAt.map { .string(iso8601String($0)) } ?? .null,
      "modified_at": modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "is_readable": .bool(isReadable),
      "is_writable": .bool(isWritable),
      "is_executable": .bool(isExecutable),
      "is_symlink": .bool(isSymlink),
      "symlink_destination": symlinkDestination.map(JSONValue.string) ?? .null,
    ])
  }
}
