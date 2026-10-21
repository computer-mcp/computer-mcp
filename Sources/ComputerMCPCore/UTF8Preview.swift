import Foundation

/// Returns a prefix within the UTF-8 byte limit without splitting a grapheme cluster.
package func utf8Preview(_ value: String, maxBytes: Int) -> (text: String, truncated: Bool) {
  let data = Data(value.utf8)
  guard data.count > maxBytes else {
    return (value, false)
  }

  var index = value.startIndex
  var byteCount = 0
  while index < value.endIndex {
    let next = value.index(after: index)
    let characterByteCount = value[index..<next].utf8.count
    guard byteCount + characterByteCount <= maxBytes else {
      break
    }
    byteCount += characterByteCount
    index = next
  }

  return (String(value[..<index]), true)
}
