import Darwin
import Foundation
import Security

package enum GatewaySocketConnectionOrigin: String, Codable, Equatable, Sendable {
  case localMCP = "local-mcp"
  case localCLI = "local-cli"
  case secureTunnel = "secure-tunnel"
}

package struct GatewaySocketConnectionIdentity: Codable, Equatable, Sendable {
  package var connectionID: String
  package var origin: GatewaySocketConnectionOrigin
  package var tunnelInstanceID: String?
  package var tunnelProfileID: String?

  package init(
    connectionID: String = UUID().uuidString,
    origin: GatewaySocketConnectionOrigin,
    tunnelInstanceID: String? = nil,
    tunnelProfileID: String? = nil
  ) {
    self.connectionID = connectionID
    self.origin = origin
    self.tunnelInstanceID = tunnelInstanceID
    self.tunnelProfileID = tunnelProfileID
  }

  package var caller: GatewayCallerKind {
    switch origin {
    case .localMCP:
      .localMCP
    case .localCLI:
      .localCLI
    case .secureTunnel:
      .secureTunnel
    }
  }

  package var transportTrace: GatewayTransportTrace {
    GatewayTransportTrace(
      transport: "gateway_socket",
      socketConnectionID: connectionID,
      tunnelInstanceID: tunnelInstanceID,
      tunnelProfileID: tunnelProfileID
    )
  }
}

package enum GatewaySocketClientIdentity: Equatable, Sendable {
  case localMCP
  case localCLI
  case secureTunnel(
    credentialFile: URL,
    tunnelInstanceID: String,
    tunnelProfileID: String
  )
}

package enum GatewaySocketCredentialStore {
  package static func create(at url: URL, fileManager: FileManager = .default) throws {
    let parent = url.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: parent,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
    )
    try fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))],
      ofItemAtPath: parent.path
    )

    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw GatewaySocketError.credentialUnavailable(
        "Could not generate the local Tunnel bridge credential."
      )
    }
    let token = Data(bytes).base64EncodedString()
    try Data((token + "\n").utf8).write(to: url, options: .atomic)
    try fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o600))],
      ofItemAtPath: url.path
    )
    _ = try read(at: url, expectedUserID: getuid())
  }

  package static func read(at url: URL, expectedUserID: uid_t = getuid()) throws -> Data {
    let status = try GatewaySocketSecurity.fileStatus(at: url.path)
    guard GatewaySocketSecurity.fileType(status.st_mode) == S_IFREG else {
      throw GatewaySocketError.credentialUnavailable(
        "The Tunnel bridge credential is not a regular file."
      )
    }
    guard status.st_uid == expectedUserID else {
      throw GatewaySocketError.socketUserMismatch(
        expected: expectedUserID,
        actual: status.st_uid
      )
    }
    guard status.st_mode & 0o077 == 0 else {
      throw GatewaySocketError.credentialUnavailable(
        "The Tunnel bridge credential must not grant group or other permissions."
      )
    }
    let token = try String(contentsOf: url, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: token), data.count == 32 else {
      throw GatewaySocketError.credentialUnavailable(
        "The Tunnel bridge credential is invalid."
      )
    }
    return data
  }

  package static func remove(at url: URL, fileManager: FileManager = .default) {
    guard let status = try? GatewaySocketSecurity.fileStatus(at: url.path),
      GatewaySocketSecurity.fileType(status.st_mode) == S_IFREG,
      status.st_uid == getuid()
    else {
      return
    }
    try? fileManager.removeItem(at: url)
  }
}

struct GatewaySocketHandshake: Codable, Equatable, Sendable {
  static let protocolName = "computer-mcp-gateway-socket"
  static let schemaVersion = 1

  var protocolName = Self.protocolName
  var schemaVersion = Self.schemaVersion
  var origin: GatewaySocketConnectionOrigin
  var credential: String?
  var tunnelInstanceID: String?
  var tunnelProfileID: String?

  enum CodingKeys: String, CodingKey {
    case protocolName = "protocol"
    case schemaVersion = "schema_version"
    case origin
    case credential
    case tunnelInstanceID = "tunnel_instance_id"
    case tunnelProfileID = "tunnel_profile_id"
  }
}

struct GatewaySocketHandshakeResolution: Sendable {
  var identity: GatewaySocketConnectionIdentity
  var forwardFrame: Data?
}

enum GatewaySocketAuthenticator {
  static func clientHandshake(
    identity: GatewaySocketClientIdentity,
    expectedUserID: uid_t
  ) throws -> Data {
    let handshake: GatewaySocketHandshake
    switch identity {
    case .localMCP:
      handshake = GatewaySocketHandshake(origin: .localMCP)
    case .localCLI:
      handshake = GatewaySocketHandshake(origin: .localCLI)
    case .secureTunnel(let credentialFile, let tunnelInstanceID, let tunnelProfileID):
      let credential = try GatewaySocketCredentialStore.read(
        at: credentialFile,
        expectedUserID: expectedUserID
      )
      handshake = GatewaySocketHandshake(
        origin: .secureTunnel,
        credential: credential.base64EncodedString(),
        tunnelInstanceID: tunnelInstanceID,
        tunnelProfileID: tunnelProfileID
      )
    }
    return try JSONEncoder().encode(handshake)
  }

  static func resolve(
    firstFrame: Data,
    expectedCredentialFile: URL?,
    expectedUserID: uid_t
  ) throws -> GatewaySocketHandshakeResolution {
    guard
      let handshake = try? JSONDecoder().decode(
        GatewaySocketHandshake.self,
        from: firstFrame
      ),
      handshake.protocolName == GatewaySocketHandshake.protocolName
    else {
      return GatewaySocketHandshakeResolution(
        identity: GatewaySocketConnectionIdentity(origin: .localMCP),
        forwardFrame: firstFrame
      )
    }
    guard handshake.schemaVersion == GatewaySocketHandshake.schemaVersion else {
      throw GatewaySocketError.authenticationFailed(
        "Unsupported local socket handshake version."
      )
    }

    switch handshake.origin {
    case .localMCP, .localCLI:
      guard handshake.credential == nil,
        handshake.tunnelInstanceID == nil,
        handshake.tunnelProfileID == nil
      else {
        throw GatewaySocketError.authenticationFailed(
          "A local handshake cannot include Tunnel credentials."
        )
      }
      return GatewaySocketHandshakeResolution(
        identity: GatewaySocketConnectionIdentity(origin: handshake.origin),
        forwardFrame: nil
      )

    case .secureTunnel:
      guard let expectedCredentialFile else {
        throw GatewaySocketError.authenticationFailed(
          "Secure Tunnel socket authentication is not enabled."
        )
      }
      guard let encodedCredential = handshake.credential,
        let presentedCredential = Data(base64Encoded: encodedCredential),
        let tunnelInstanceID = nonEmpty(handshake.tunnelInstanceID),
        let tunnelProfileID = nonEmpty(handshake.tunnelProfileID)
      else {
        throw GatewaySocketError.authenticationFailed(
          "The Secure Tunnel handshake is incomplete."
        )
      }
      let expectedCredential = try GatewaySocketCredentialStore.read(
        at: expectedCredentialFile,
        expectedUserID: expectedUserID
      )
      guard constantTimeEqual(presentedCredential, expectedCredential) else {
        throw GatewaySocketError.authenticationFailed(
          "The Secure Tunnel bridge credential is invalid."
        )
      }
      return GatewaySocketHandshakeResolution(
        identity: GatewaySocketConnectionIdentity(
          origin: .secureTunnel,
          tunnelInstanceID: tunnelInstanceID,
          tunnelProfileID: tunnelProfileID
        ),
        forwardFrame: nil
      )
    }
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !value.contains("\0")
    else {
      return nil
    }
    return value
  }

  private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else {
      return false
    }
    return lhs.withUnsafeBytes { (left: UnsafeRawBufferPointer) in
      rhs.withUnsafeBytes { (right: UnsafeRawBufferPointer) in
        var difference: UInt8 = 0
        for index in 0..<lhs.count {
          difference |= left[index] ^ right[index]
        }
        return difference == 0
      }
    }
  }
}

package struct GatewaySocketMCPResponseCorrelation: Equatable, Sendable {
  package let mcpRequestID: String
  package let gatewayRequestID: String

  package init(mcpRequestID: String, gatewayRequestID: String) {
    self.mcpRequestID = mcpRequestID
    self.gatewayRequestID = gatewayRequestID
  }

  package static func parse(_ data: Data) -> GatewaySocketMCPResponseCorrelation? {
    guard let message = try? JSONDecoder().decode(JSONValue.self, from: data),
      let object = message.objectValue,
      let mcpRequestID = requestID(object["id"]),
      let result = object["result"]?.objectValue,
      let gatewayRequestID =
        result["structuredContent"]?.objectValue?["gateway_execution"]?
        .objectValue?["request_id"]?.stringValue
        ?? result["_meta"]?.objectValue?["computer_mcp"]?
        .objectValue?["request_id"]?.stringValue
    else {
      return nil
    }
    return GatewaySocketMCPResponseCorrelation(
      mcpRequestID: mcpRequestID,
      gatewayRequestID: gatewayRequestID
    )
  }

  private static func requestID(_ value: JSONValue?) -> String? {
    switch value {
    case .string(let value):
      return value
    case .number(let value):
      if let integer = JSONValue.number(value).intValue {
        return String(integer)
      }
      guard value.isFinite else {
        return nil
      }
      return String(format: "%.17g", value)
    default:
      return nil
    }
  }
}
