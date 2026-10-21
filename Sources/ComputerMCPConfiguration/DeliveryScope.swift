import Foundation

package struct DeliveryConfig: Codable, Equatable, Sendable {
  package var scopes: [DeliveryScope]

  package init(scopes: [DeliveryScope] = []) { self.scopes = scopes }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    scopes = try container.decodeIfPresent([DeliveryScope].self, forKey: .scopes) ?? []
  }

  private enum CodingKeys: String, CodingKey { case scopes }

  func validate(workspaces: [WorkspaceManifestConfig]) throws {
    var ids = Set<String>()
    for scope in scopes {
      guard ids.insert(scope.id).inserted else {
        throw ConfigurationError.invalid("Duplicate delivery scope id: \(scope.id)")
      }
      guard workspaces.contains(where: { $0.id == scope.workspace }) else {
        throw ConfigurationError.invalid(
          "delivery.scopes.workspace references unknown workspace '\(scope.workspace)'.")
      }
      try scope.validate()
    }
  }
}

/// A host-declared repository and path boundary, selected by workspace identity.
package struct DeliveryScope: Codable, Equatable, Sendable {
  package enum Mode: String, Codable, Sendable {
    case land
    case commitOnly = "commit-only"
  }

  package var id: String
  package var workspace: String
  package var repository: String
  package var paths: [String]
  package var defaultBranch: String
  package var worktreeRoot: String
  package var sparse: Bool
  package var mode: Mode

  package init(
    id: String, workspace: String, repository: String = ".", paths: [String],
    defaultBranch: String, worktreeRoot: String = ".claude/worktrees", sparse: Bool = false,
    mode: Mode = .land
  ) {
    self.id = id
    self.workspace = workspace
    self.repository = repository
    self.paths = paths
    self.defaultBranch = defaultBranch
    self.worktreeRoot = worktreeRoot
    self.sparse = sparse
    self.mode = mode
  }

  private enum CodingKeys: String, CodingKey {
    case id, workspace, repository, paths, sparse, mode
    case defaultBranch = "default_branch"
    case worktreeRoot = "worktree_root"
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    workspace = try container.decode(String.self, forKey: .workspace)
    repository = try container.decodeIfPresent(String.self, forKey: .repository) ?? "."
    paths = try container.decode([String].self, forKey: .paths)
    defaultBranch = try container.decode(String.self, forKey: .defaultBranch)
    worktreeRoot =
      try container.decodeIfPresent(String.self, forKey: .worktreeRoot) ?? ".claude/worktrees"
    sparse = try container.decodeIfPresent(Bool.self, forKey: .sparse) ?? false
    mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .land
  }

  func validate() throws {
    guard id.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]*$", options: .regularExpression) != nil else {
      throw ConfigurationError.invalid("delivery.scopes.id must be an identifier.")
    }
    guard Self.normalizedPath(repository, allowRoot: true) != nil,
      Self.normalizedPath(worktreeRoot) != nil
    else {
      throw ConfigurationError.invalid(
        "delivery repository and worktree_root must be relative paths inside the repository.")
    }
    guard !paths.isEmpty, paths.allSatisfy({ Self.globExpression($0) != nil }) else {
      throw ConfigurationError.invalid(
        "delivery.scopes.paths must contain valid relative globs using * and **.")
    }
    let invalidRef =
      defaultBranch.isEmpty || defaultBranch.hasPrefix("-")
      || defaultBranch.hasPrefix("/") || defaultBranch.hasSuffix("/")
      || defaultBranch.hasSuffix(".")
      || defaultBranch.contains("..") || defaultBranch.contains("@{") || defaultBranch == "@"
      || defaultBranch.contains("//")
      || defaultBranch.unicodeScalars.contains(where: {
        $0.value <= 32 || $0.value == 127 || "~^:?*[\\".unicodeScalars.contains($0)
      })
      || defaultBranch.split(separator: "/").contains(where: {
        $0.hasPrefix(".") || $0.hasSuffix(".lock")
      })
    guard !invalidRef else {
      throw ConfigurationError.invalid(
        "delivery.scopes.default_branch must be a valid branch name.")
    }
  }

  /// Reject traversal before normalization; callers also check filesystem symlinks.
  package static func normalizedPath(_ path: String, allowRoot: Bool = false) -> String? {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
      !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    else { return nil }
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    guard !components.contains(".."), !components.contains(where: { $0.lowercased() == ".git" })
    else { return nil }
    let normalized = components.filter { $0 != "." }.joined(separator: "/")
    return normalized.isEmpty ? (allowRoot ? "." : nil) : normalized
  }

  package func contains(path: String) -> Bool {
    paths.contains { pattern in
      guard let expression = Self.globExpression(pattern) else { return false }
      return path.range(of: expression, options: .regularExpression) != nil
    }
  }

  private static func globExpression(_ pattern: String) -> String? {
    guard normalizedPath(pattern) == pattern,
      !pattern.contains(where: { "?[]{}".contains($0) }), !pattern.contains("***")
    else { return nil }
    var result = "^"
    var index = pattern.startIndex
    while index < pattern.endIndex {
      let character = pattern[index]
      index = pattern.index(after: index)
      if character != "*" {
        result += NSRegularExpression.escapedPattern(for: String(character))
      } else if index < pattern.endIndex && pattern[index] == "*" {
        index = pattern.index(after: index)
        if index < pattern.endIndex && pattern[index] == "/" {
          index = pattern.index(after: index)
          result += "(?:.*/)?"
        } else {
          result += ".*"
        }
      } else {
        result += "[^/]*"
      }
    }
    return result + "$"
  }
}
