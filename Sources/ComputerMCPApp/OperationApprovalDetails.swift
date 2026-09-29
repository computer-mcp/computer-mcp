import ComputerMCP
import Foundation

struct OperationApprovalDetails {
  struct Field: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
  }

  let title: String
  let fields: [Field]?

  init(ticket: OperationTicket) {
    title = ticket.reviewTitle ?? AppLocalization.string("Operation request")
    guard let summary = ticket.reviewSummary,
      let value = try? JSONDecoder().decode(JSONValue.self, from: Data(summary.utf8)),
      case .object = value
    else {
      fields = nil
      return
    }
    fields = Self.fields(value, path: "", label: "")
  }

  private static func fields(_ value: JSONValue, path: String, label: String) -> [Field] {
    switch value {
    case .object(let object) where !object.isEmpty:
      return object.sorted { $0.key < $1.key }.flatMap { key, item in
        let component = key.replacingOccurrences(of: "~", with: "~0")
          .replacingOccurrences(of: "/", with: "~1")
        return fields(
          item, path: path + "/" + component,
          label: label.isEmpty ? key : label + " › " + key)
      }
    case .array(let array) where !array.isEmpty:
      return array.enumerated().flatMap { index, item in
        fields(item, path: path + "/\(index)", label: label + " [\(index + 1)]")
      }
    default:
      return [Field(id: path, label: label, value: text(value))]
    }
  }

  private static func text(_ value: JSONValue) -> String {
    switch value {
    case .string(let string): string.isEmpty ? AppLocalization.string("Empty text") : string
    case .integer(let integer): String(integer)
    case .number(let number): String(number)
    case .bool(let bool): AppLocalization.string(bool ? "Yes" : "No")
    case .null: AppLocalization.string("Not set")
    case .array: AppLocalization.string("Empty list")
    case .object: AppLocalization.string("No fields")
    }
  }
}
