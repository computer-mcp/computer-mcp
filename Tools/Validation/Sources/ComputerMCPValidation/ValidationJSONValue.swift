import Foundation

/// Validation-owned JSON representation used at executable and MCP boundaries.
public enum ValidationJSONValue: Codable, Equatable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: ValidationJSONValue])
  case array([ValidationJSONValue])
  case null

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([ValidationJSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: ValidationJSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unsupported JSON value."
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value):
      try container.encode(value)
    case .number(let value):
      guard value.isFinite else {
        throw EncodingError.invalidValue(
          value,
          .init(codingPath: encoder.codingPath, debugDescription: "JSON numbers must be finite.")
        )
      }
      try container.encode(value)
    case .bool(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .null:
      try container.encodeNil()
    }
  }

  public var objectValue: [String: ValidationJSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  public var arrayValue: [ValidationJSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  public var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  public var numberValue: Double? {
    guard case .number(let value) = self else { return nil }
    return value
  }

  public var intValue: Int? {
    guard case .number(let value) = self,
      value.isFinite,
      value.rounded(.towardZero) == value,
      value >= Double(Int.min),
      value <= Double(Int.max)
    else { return nil }
    return Int(value)
  }

  public static func encoded<T: Encodable>(_ value: T) throws -> ValidationJSONValue {
    let data = try ValidationCanonicalJSONCoding.encoder().encode(value)
    return try ValidationCanonicalJSONCoding.decoder().decode(Self.self, from: data)
  }
}

/// Temporary source-compatible spelling while Validation is migrated off production types.
public typealias JSONValue = ValidationJSONValue

public enum ValidationCanonicalJSONCoding {
  public static func encoder(
    outputFormatting: JSONEncoder.OutputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  ) -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = outputFormatting
    encoder.keyEncodingStrategy = .custom { codingPath in
      AnyCodingKey(snakeCase(codingPath.last?.stringValue ?? ""))
    }
    return encoder
  }

  public static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .custom { codingPath in
      AnyCodingKey(swiftPropertyName(codingPath.last?.stringValue ?? ""))
    }
    return decoder
  }

  public static func snakeCase(_ propertyName: String) -> String {
    let characters = Array(propertyName)
    var words: [String] = []
    var index = 0
    while index < characters.count {
      if isSeparator(characters[index]) {
        index += 1
        continue
      }
      if let initialism = matchingInitialism(in: characters, at: index) {
        var word = initialism.lowercased()
        index += initialism.count
        if index < characters.count, characters[index] == "s",
          index + 1 == characters.count || isSeparator(characters[index + 1])
            || characters[index + 1].isUppercase
        {
          word.append("s")
          index += 1
        }
        words.append(word)
        continue
      }
      let start = index
      index += 1
      while index < characters.count,
        !isSeparator(characters[index]), !characters[index].isUppercase
      {
        index += 1
      }
      words.append(String(characters[start..<index]).lowercased())
    }
    return words.filter { !$0.isEmpty }.joined(separator: "_")
  }

  public static func swiftPropertyName(_ snakeCaseKey: String) -> String {
    let components = snakeCaseKey.split(separator: "_").map(String.init)
    guard let first = components.first else { return snakeCaseKey }
    return first
      + components.dropFirst().map { component in
        swiftInitialisms[component]
          ?? component.prefix(1).uppercased() + component.dropFirst()
      }.joined()
  }

  private static let initialisms = [
    "SHA256", "ASCII", "HTTPS", "POSIX", "SQLite", "UUID", "GRDB", "TOML",
    "JSON", "YAML", "HTTP", "HTML", "UTF8", "CLI", "CSV", "DMG", "DNS",
    "GPT", "MCP", "PDF", "PID", "PNG", "SQL", "SSH", "TCP", "TCC", "TLS",
    "URL", "VPN", "XML", "API", "CPU", "UTF", "AX", "CF", "ID", "IP", "OS", "AI",
  ]

  private static let swiftInitialisms: [String: String] = [
    "ai": "AI", "api": "API", "ascii": "ASCII", "ax": "AX", "cf": "CF",
    "cli": "CLI", "cpu": "CPU", "csv": "CSV", "dmg": "DMG", "dns": "DNS",
    "gpt": "GPT", "grdb": "GRDB", "html": "HTML", "http": "HTTP", "https": "HTTPS",
    "id": "ID", "ids": "IDs", "ip": "IP", "json": "JSON", "mcp": "MCP", "os": "OS",
    "pdf": "PDF", "pid": "PID", "png": "PNG", "posix": "POSIX", "sha256": "SHA256",
    "sql": "SQL", "sqlite": "SQLite", "ssh": "SSH", "tcp": "TCP", "tcc": "TCC",
    "tls": "TLS", "toml": "TOML", "url": "URL", "urls": "URLs", "utf": "UTF",
    "utf8": "UTF8", "uuid": "UUID", "vpn": "VPN", "xml": "XML", "yaml": "YAML",
  ]

  private static func matchingInitialism(
    in characters: [Character],
    at index: Int
  ) -> String? {
    initialisms.first { initialism in
      guard index + initialism.count <= characters.count else { return false }
      let candidate = String(characters[index..<(index + initialism.count)])
      guard candidate == initialism else { return false }
      let end = index + initialism.count
      guard end < characters.count else { return true }
      let next = characters[end]
      if next == "s" {
        return end + 1 == characters.count || isSeparator(characters[end + 1])
          || characters[end + 1].isUppercase
      }
      return isSeparator(next) || next.isUppercase
    }
  }

  private static func isSeparator(_ character: Character) -> Bool {
    character == "_" || character == "-" || character == " "
  }

  private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
  }
}

public typealias CanonicalJSONCoding = ValidationCanonicalJSONCoding
