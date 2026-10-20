import ComputerMCPCore

package enum StructuredPathSegment {
  case key(String)
  case index(Int)

  package var json: JSONValue {
    switch self {
    case .key(let key):
      return .string(key)
    case .index(let index):
      return .integer(Int64(index))
    }
  }
}
