import Crypto
import Foundation

/// Canonical profile encoding sorts set-valued arrays. Profile dictionaries are
/// converted to sorted entries by their owner before reaching this encoder.
enum ProfileDigest {
  static func ordered(_ value: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try! encoder.encode(value), as: UTF8.self)
  }

  static func canonical(_ value: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try! encoder.encode(value)
    let object = try! JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    func normalized(_ value: Any) -> Any {
      if let values = value as? [Any] {
        return values.map { value in
          let normalizedValue = normalized(value)
          return (value: normalizedValue, key: serialized(normalizedValue))
        }.sorted { $0.key < $1.key }.map(\.value)
      }
      if let values = value as? [String: Any] { return values.mapValues(normalized) }
      return value
    }
    func serialized(_ value: Any) -> String {
      String(
        decoding: try! JSONSerialization.data(
          withJSONObject: value,
          options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
    }
    return serialized(normalized(object))
  }

  /// SHA-256 of the input's UTF-8 bytes as 64 lowercase hexadecimal characters.
  static func hash(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
