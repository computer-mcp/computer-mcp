import Foundation

/// Canonical JSON coding for Computer MCP wire and report documents.
///
/// Foundation's built-in snake-case conversion splits plural initialisms such
/// as `IDs` into `i_ds`. This codec preserves recognized initialisms so public
/// keys remain stable and conventional, including `capability_ids`,
/// `http_url`, and `mcp_request_id`.
internal enum CanonicalJSONCoding {
  internal static func encoder(
    outputFormatting: JSONEncoder.OutputFormatting = []
  ) -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = outputFormatting
    encoder.keyEncodingStrategy = .custom { codingPath in
      AnyCodingKey(Self.snakeCase(codingPath.last?.stringValue ?? ""))
    }
    return encoder
  }

  internal static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .custom { codingPath in
      AnyCodingKey(Self.swiftPropertyName(codingPath.last?.stringValue ?? ""))
    }
    return decoder
  }

  internal static func snakeCase(_ propertyName: String) -> String {
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
        if index < characters.count,
          characters[index] == "s",
          index + 1 == characters.count
            || isSeparator(characters[index + 1])
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
        !isSeparator(characters[index]),
        !characters[index].isUppercase
      {
        index += 1
      }
      words.append(String(characters[start..<index]).lowercased())
    }

    return words.filter { !$0.isEmpty }.joined(separator: "_")
  }

  internal static func swiftPropertyName(_ snakeCaseKey: String) -> String {
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
    "URL", "VPN", "XML", "API", "CPU", "UTF", "AX", "CF", "ID", "IP", "OS",
    "AI",
  ]

  private static let swiftInitialisms: [String: String] = [
    "ai": "AI",
    "api": "API",
    "ascii": "ASCII",
    "ax": "AX",
    "cf": "CF",
    "cli": "CLI",
    "cpu": "CPU",
    "csv": "CSV",
    "dmg": "DMG",
    "dns": "DNS",
    "gpt": "GPT",
    "grdb": "GRDB",
    "html": "HTML",
    "http": "HTTP",
    "https": "HTTPS",
    "id": "ID",
    "ids": "IDs",
    "ip": "IP",
    "json": "JSON",
    "mcp": "MCP",
    "os": "OS",
    "pdf": "PDF",
    "pid": "PID",
    "png": "PNG",
    "posix": "POSIX",
    "sha256": "SHA256",
    "sql": "SQL",
    "sqlite": "SQLite",
    "ssh": "SSH",
    "tcp": "TCP",
    "tcc": "TCC",
    "tls": "TLS",
    "toml": "TOML",
    "url": "URL",
    "urls": "URLs",
    "utf": "UTF",
    "utf8": "UTF8",
    "uuid": "UUID",
    "vpn": "VPN",
    "xml": "XML",
    "yaml": "YAML",
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
        return end + 1 == characters.count
          || isSeparator(characters[end + 1])
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

    init(_ stringValue: String) {
      self.stringValue = stringValue
    }

    init?(stringValue: String) {
      self.init(stringValue)
    }

    init?(intValue: Int) {
      return nil
    }
  }
}
