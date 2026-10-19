import Foundation

/// Host-side location of an interface. Package references are resolved into this same
/// registration shape; dependency ownership remains with the package/host resolver.
package struct CLITreeSource: Codable, Equatable, Sendable {
  package enum Kind: String, Codable, Sendable { case file, introspection, helper }
  package var kind: Kind
  package var path: String?
  package var helper: String?
  package var args: [String]
  /// Derived package containment anchor, never persisted into a user's registration.
  package var packageRoot: URL? = nil

  package init(kind: Kind, path: String? = nil, helper: String? = nil, args: [String] = []) {
    self.kind = kind
    self.path = path
    self.helper = helper
    self.args = args
  }

  private enum CodingKeys: String, CodingKey { case kind, path, helper, args }

  package init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    kind = try c.decode(Kind.self, forKey: .kind)
    path = try c.decodeIfPresent(String.self, forKey: .path)
    helper = try c.decodeIfPresent(String.self, forKey: .helper)
    args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
    try validate()
  }

  package func validate() throws {
    let valid: Bool
    switch kind {
    case .file: valid = path != nil && helper == nil && args.isEmpty
    case .introspection: valid = path == nil && helper == nil && !args.isEmpty
    case .helper: valid = path == nil && helper?.hasPrefix("/") == true
    }
    guard valid,
      [path, helper].compactMap({ $0 }).allSatisfy({ !$0.isEmpty && !$0.contains("\0") }),
      args.count <= 1_024, args.allSatisfy({ !$0.contains("\0") })
    else { throw ConfigurationError.invalid("CLI tree source fields do not match its kind.") }
  }
}
