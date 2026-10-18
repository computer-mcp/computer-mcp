import Foundation

enum ValidationJSONCoding {
  static func encode<T: Encodable>(
    _ value: T,
    prettyPrinted: Bool = true,
    dateEncodingStrategy: JSONEncoder.DateEncodingStrategy? = nil
  ) throws -> Data {
    let encoder = CanonicalJSONCoding.encoder(
      outputFormatting:
        prettyPrinted
        ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        : [.sortedKeys, .withoutEscapingSlashes]
    )
    if let dateEncodingStrategy {
      encoder.dateEncodingStrategy = dateEncodingStrategy
    }
    return try encoder.encode(value)
  }

  static func decode<T: Decodable>(
    _ type: T.Type,
    from data: Data,
    dateDecodingStrategy: JSONDecoder.DateDecodingStrategy? = nil
  ) throws -> T {
    let decoder = CanonicalJSONCoding.decoder()
    if let dateDecodingStrategy {
      decoder.dateDecodingStrategy = dateDecodingStrategy
    }
    return try decoder.decode(type, from: data)
  }

  static func requireExactShape<T: Encodable>(
    _ value: T,
    input: Data,
    artifact: String,
    dateEncodingStrategy: JSONEncoder.DateEncodingStrategy? = nil
  ) throws {
    let canonical = try encode(
      value,
      prettyPrinted: false,
      dateEncodingStrategy: dateEncodingStrategy
    )
    let decoder = JSONDecoder()
    let inputValue = try decoder.decode(JSONValue.self, from: input)
    let canonicalValue = try decoder.decode(JSONValue.self, from: canonical)
    guard inputValue == canonicalValue else {
      throw ValidationArtifactError.noncanonicalShape(artifact: artifact)
    }
  }

}

public enum ValidationArtifactError: Error, LocalizedError, Equatable, Sendable {
  case noncanonicalShape(artifact: String)
  case unsupportedSchema(artifact: String, expected: Int, actual: Int)

  public var errorDescription: String? {
    switch self {
    case .noncanonicalShape(let artifact):
      return "\(artifact) contains unknown fields or values outside its current schema."
    case .unsupportedSchema(let artifact, let expected, let actual):
      return "\(artifact) requires schema_version \(expected); found \(actual)."
    }
  }
}
