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
        return values.map(normalized).sorted { serialized($0) < serialized($1) }
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

  /// SHA-256, using only Foundation so the persisted digest is platform-independent.
  static func hash(_ value: String) -> String {
    let constants: [UInt32] = [
      0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4,
      0xab1c_5ed5,
      0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7,
      0xc19b_f174,
      0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc,
      0x76f9_88da,
      0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351,
      0x1429_2967,
      0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e,
      0x9272_2c85,
      0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585,
      0x106a_a070,
      0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f,
      0x682e_6ff3,
      0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7,
      0xc671_78f2,
    ]
    var bytes = Array(value.utf8)
    let bitCount = UInt64(bytes.count) * 8
    bytes.append(0x80)
    while bytes.count % 64 != 56 { bytes.append(0) }
    bytes += (0..<8).reversed().map { UInt8(truncatingIfNeeded: bitCount >> ($0 * 8)) }
    var state: [UInt32] = [
      0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
      0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
    ]
    func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
    for offset in stride(from: 0, to: bytes.count, by: 64) {
      var words = [UInt32](repeating: 0, count: 64)
      for i in 0..<16 {
        words[i] = (0..<4).reduce(0) { ($0 << 8) | UInt32(bytes[offset + i * 4 + $1]) }
      }
      for i in 16..<64 {
        let x = words[i - 15]
        let y = words[i - 2]
        words[i] =
          words[i - 16] &+ (rotate(x, 7) ^ rotate(x, 18) ^ (x >> 3))
          &+ words[i - 7] &+ (rotate(y, 17) ^ rotate(y, 19) ^ (y >> 10))
      }
      var a = state[0]
      var b = state[1]
      var c = state[2]
      var d = state[3]
      var e = state[4]
      var f = state[5]
      var g = state[6]
      var h = state[7]
      for i in 0..<64 {
        let first =
          h &+ (rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25))
          &+ ((e & f) ^ (~e & g)) &+ constants[i] &+ words[i]
        let second =
          (rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22))
          &+ ((a & b) ^ (a & c) ^ (b & c))
        h = g
        g = f
        f = e
        e = d &+ first
        d = c
        c = b
        b = a
        a = first &+ second
      }
      for (index, word) in [a, b, c, d, e, f, g, h].enumerated() { state[index] &+= word }
    }
    return state.map { String(format: "%08x", $0) }.joined()
  }
}
