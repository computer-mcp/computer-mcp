import Foundation

package enum ExecutionEnvironmentError: Error, Equatable, CustomStringConvertible {
  case invalidConfiguration(String)
  case unavailable(String)
  case launchFailed(String)

  package var description: String {
    switch self {
    case .invalidConfiguration(let reason), .unavailable(let reason), .launchFailed(let reason):
      return reason
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
  package let administrativeDirectory: SandboxPath
  package let privateObjects: SandboxPath
  package let sharedObjects: SandboxPath

  /// The host creates and verifies a detached HEAD before launching. Branch publication is host-owned.
  package init(
    sharedDirectory: SandboxPath, administrativeDirectory: SandboxPath,
    privateObjects: SandboxPath, sharedObjects: SandboxPath
  ) throws {
    guard sharedDirectory.contains(sharedObjects), !sharedDirectory.contains(privateObjects),
      administrativeDirectory != sharedDirectory,
      !privateObjects.contains(sharedDirectory), !administrativeDirectory.contains(sharedDirectory)
    else {
      throw ExecutionEnvironmentError.invalidConfiguration(
        "Git requires an isolated object store and administration directory")
    }
    self.sharedDirectory = sharedDirectory
    self.administrativeDirectory = administrativeDirectory
    self.privateObjects = privateObjects
    self.sharedObjects = sharedObjects
  }
}

package struct SandboxSystemServices: Sendable, Equatable {
  package var screenCapture: Bool
  package var accessibility: Bool
  package var appleEvents: Bool

  package init(screenCapture: Bool = false, accessibility: Bool = false, appleEvents: Bool = false)
  {
    self.screenCapture = screenCapture
    self.accessibility = accessibility
    self.appleEvents = appleEvents
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
  package let readableRoots: [SandboxPath]
  package let deniedReadRegions: [SandboxReadRegion]
  package let forbiddenReads: [SandboxPath]
  package let listableAncestors: [SandboxPath]
  package let git: SandboxGitConfiguration?
  package let proxy: SandboxProxyPorts?
  package let services: SandboxSystemServices

  package init(
    readOnly: Bool = false, hostNetwork: Bool = false,
    worktree: SandboxPath, temporaryDirectory: SandboxPath, homeDirectory: SandboxPath,
    cacheDirectory: SandboxPath, readableRoots: [SandboxPath],
    deniedReadRegions: [SandboxReadRegion] = [], forbiddenReads: [SandboxPath] = [],
    listableAncestors: [SandboxPath] = [], git: SandboxGitConfiguration? = nil,
    proxy: SandboxProxyPorts? = nil, services: SandboxSystemServices = .init()
  ) throws {
    guard !hostNetwork || (readOnly && proxy == nil) else {
      throw ExecutionEnvironmentError.invalidConfiguration(
        "Host network diagnostics require read-only execution without a proxy")
    }
    let writable =
      readOnly
      ? [temporaryDirectory] : [worktree, temporaryDirectory, homeDirectory, cacheDirectory]
    guard
      !readOnly
        || (temporaryDirectory.contains(homeDirectory)
          && temporaryDirectory.contains(cacheDirectory) && git == nil)
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
    self.readableRoots = readableRoots
    self.deniedReadRegions = deniedReadRegions
    self.forbiddenReads = forbiddenReads
    self.listableAncestors = listableAncestors
    self.git = git
    self.proxy = proxy
    self.services = services
  }

  package var writableDirectories: [SandboxPath] {
    readOnly ? [temporaryDirectory] : [worktree, temporaryDirectory, homeDirectory, cacheDirectory]
  }
}
