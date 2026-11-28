import Foundation

package enum ExecutionEnvironmentError: Error, Equatable, CustomStringConvertible {
  case invalidConfiguration(String)
  case unavailable(String)
  case launchFailed(String)
  case bootstrapFailed(status: Int32, signal: Int32?, reason: String, standardError: String)

  package var description: String {
    switch self {
    case .invalidConfiguration(let reason), .unavailable(let reason), .launchFailed(let reason):
      return reason
    case .bootstrapFailed(let status, let signal, let reason, let standardError):
      return
        "Bootstrap exited with status \(status)\(signal.map { " (signal \($0))" } ?? ""): \(reason)"
        + (standardError.isEmpty ? "" : "; bootstrap stderr: \(standardError)")
    }
  }
}

/// Canonical absolute paths supplied by the host's path resolver, never by a child process.
package struct SandboxPath: Hashable, Sendable {
  package let value: String

  package init(_ value: String) throws {
    guard value.hasPrefix("/"), !value.contains("\0"),
      !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
      value == "/" || !value.hasSuffix("/"),
      value == "/"
        || !value.split(separator: "/", omittingEmptySubsequences: false).dropFirst().contains(
          where: {
            $0.isEmpty || $0 == "." || $0 == ".."
          })
    else {
      throw ExecutionEnvironmentError.invalidConfiguration("Expected a canonical absolute path")
    }
    self.value = value
  }

  package func contains(_ other: SandboxPath) -> Bool {
    value == "/" || other.value == value || other.value.hasPrefix(value + "/")
  }
}

package struct SandboxReadRegion: Sendable, Equatable {
  package let path: SandboxPath
  /// Reopened descendants; explicit forbidden paths still take precedence.
  package let exceptions: [SandboxPath]

  package init(path: SandboxPath, exceptions: [SandboxPath] = []) throws {
    guard exceptions.allSatisfy({ path.contains($0) && $0 != path }) else {
      throw ExecutionEnvironmentError.invalidConfiguration(
        "Read exceptions must lie inside their denied region")
    }
    self.path = path
    self.exceptions = exceptions
  }
}

package struct SandboxGitConfiguration: Sendable, Equatable {
  package let sharedDirectory: SandboxPath
  package let repository: SandboxPath

  package static let immutableFiles = [
    "config", "commondir", "config.worktree", "info/grafts", "shallow",
    "objects/info/alternates", "objects/info/http-alternates",
  ]

  package init(sharedDirectory: SandboxPath, repository: SandboxPath) throws {
    guard !sharedDirectory.contains(repository), !repository.contains(sharedDirectory) else {
      throw ExecutionEnvironmentError.invalidConfiguration(
        "Private Git must be separate from the source repository")
    }
    self.sharedDirectory = sharedDirectory
    self.repository = repository
  }
}

package struct SandboxSystemServices: Sendable, Equatable {
  package var screenCapture: Bool
  package var accessibility: Bool

  package init(screenCapture: Bool = false, accessibility: Bool = false) {
    self.screenCapture = screenCapture
    self.accessibility = accessibility
  }
}

/// A listener lease must remain alive until every process using this profile has ended.
package struct SandboxProxyPorts: Sendable, Equatable {
  package let http: UInt16
  package let socks: UInt16

  package init(http: UInt16, socks: UInt16) throws {
    guard http != 0, socks != 0 else {
      throw ExecutionEnvironmentError.invalidConfiguration(
        "Proxy ports must be bound before creating a sandbox")
    }
    self.http = http
    self.socks = socks
  }
}

package struct SandboxConfiguration: Sendable, Equatable {
  package let readOnly: Bool
  package let hostNetwork: Bool
  package let worktree: SandboxPath
  package let temporaryDirectory: SandboxPath
  package let homeDirectory: SandboxPath
  package let cacheDirectory: SandboxPath
  package let providerContainer: SandboxProviderContainer?
  package let readableRoots: [SandboxPath]
  package let deniedReadRegions: [SandboxReadRegion]
  package let deniedWriteRegions: [SandboxReadRegion]
  package let forbiddenReads: [SandboxPath]
  package let listableAncestors: [SandboxPath]
  package let git: SandboxGitConfiguration?
  /// Only a fixed host Git command may write this verified repository directory.
  package let hostGitDirectory: SandboxPath?
  package let proxy: SandboxProxyPorts?
  package let services: SandboxSystemServices

  package func withProxy(_ ports: SandboxProxyPorts) throws -> Self {
    try Self(
      readOnly: readOnly, hostNetwork: hostNetwork, worktree: worktree,
      temporaryDirectory: temporaryDirectory, homeDirectory: homeDirectory,
      cacheDirectory: cacheDirectory, readableRoots: readableRoots,
      providerContainer: providerContainer, deniedReadRegions: deniedReadRegions,
      deniedWriteRegions: deniedWriteRegions,
      forbiddenReads: forbiddenReads,
      listableAncestors: listableAncestors, git: git, hostGitDirectory: hostGitDirectory,
      proxy: ports, services: services)
  }

  package init(
    readOnly: Bool = false, hostNetwork: Bool = false,
    worktree: SandboxPath, temporaryDirectory: SandboxPath, homeDirectory: SandboxPath,
    cacheDirectory: SandboxPath, readableRoots: [SandboxPath],
    providerContainer: SandboxProviderContainer? = nil,
    deniedReadRegions: [SandboxReadRegion] = [], deniedWriteRegions: [SandboxReadRegion] = [],
    forbiddenReads: [SandboxPath] = [],
    listableAncestors: [SandboxPath] = [], git: SandboxGitConfiguration? = nil,
    hostGitDirectory: SandboxPath? = nil,
    proxy: SandboxProxyPorts? = nil, services: SandboxSystemServices = .init()
  ) throws {
    guard hostGitDirectory == nil || (!readOnly && git == nil) else {
      throw ExecutionEnvironmentError.invalidConfiguration(
        "Host Git writes require a fixed writable helper profile")
    }
    guard !hostNetwork || (readOnly && proxy == nil) else {
      throw ExecutionEnvironmentError.invalidConfiguration(
        "Host network diagnostics require read-only execution without a proxy")
    }
    if let container = providerContainer {
      guard container.home == homeDirectory, container.cache == cacheDirectory,
        !container.root.contains(temporaryDirectory), !temporaryDirectory.contains(container.root),
        readOnly || (!container.root.contains(worktree) && !worktree.contains(container.root))
      else {
        throw ExecutionEnvironmentError.invalidConfiguration(
          "Provider storage overlaps execution locations")
      }
    }
    let writable =
      readOnly
      ? [temporaryDirectory] + [providerContainer?.root].compactMap { $0 }
      : [worktree, temporaryDirectory, homeDirectory, cacheDirectory]
        + [hostGitDirectory, providerContainer?.root].compactMap { $0 }
    guard
      !readOnly
        || ((providerContainer?.home == homeDirectory && providerContainer?.cache == cacheDirectory)
          || (temporaryDirectory.contains(homeDirectory)
            && temporaryDirectory.contains(cacheDirectory)))
    else {
      throw ExecutionEnvironmentError.invalidConfiguration(
        "Read-only executions keep home and caches inside temporary storage")
    }
    let hasForbiddenRoot = writable.contains { path in
      forbiddenReads.contains { $0.contains(path) }
    }
    guard writable.allSatisfy({ $0.value != "/" }), !hasForbiddenRoot else {
      throw ExecutionEnvironmentError.invalidConfiguration(
        "Writable locations intersect a forbidden root")
    }
    self.readOnly = readOnly
    self.hostNetwork = hostNetwork
    self.worktree = worktree
    self.temporaryDirectory = temporaryDirectory
    self.homeDirectory = homeDirectory
    self.cacheDirectory = cacheDirectory
    self.providerContainer = providerContainer
    self.readableRoots = readableRoots
    self.deniedReadRegions = deniedReadRegions
    self.deniedWriteRegions = deniedWriteRegions
    self.forbiddenReads = forbiddenReads
    self.listableAncestors = listableAncestors
    self.git = git
    self.hostGitDirectory = hostGitDirectory
    self.proxy = proxy
    self.services = services
  }

  package var writableDirectories: [SandboxPath] {
    readOnly
      ? [temporaryDirectory] + [providerContainer?.root].compactMap { $0 }
      : [worktree, temporaryDirectory, homeDirectory, cacheDirectory]
        + [hostGitDirectory, providerContainer?.root].compactMap { $0 }
  }
}

/// The storage owner verifies ownership and identity before supplying these locations.
package struct SandboxProviderContainer: Sendable, Equatable {
  package let root: SandboxPath
  package let home: SandboxPath
  package let cache: SandboxPath
  package let state: SandboxPath

  package init(root: SandboxPath, home: SandboxPath, cache: SandboxPath, state: SandboxPath) throws
  {
    let locations = [home, cache, state]
    guard root.value != "/", locations.allSatisfy({ root.contains($0) && root != $0 }),
      locations.allSatisfy({ candidate in
        locations.allSatisfy {
          $0 == candidate || (!$0.contains(candidate) && !candidate.contains($0))
        }
      }), Set(locations).count == 3
    else {
      throw ExecutionEnvironmentError.invalidConfiguration("Invalid provider container locations")
    }
    self.root = root
    self.home = home
    self.cache = cache
    self.state = state
  }
}
