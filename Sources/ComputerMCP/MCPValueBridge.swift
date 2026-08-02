import Foundation
import MCP

extension JSONValue {
  var sdkValue: MCP.Value {
    switch self {
    case .string(let value):
      return .string(value)
    case .number(let value):
      let rounded = value.rounded()
      if rounded.isFinite,
        rounded == value,
        rounded >= Double(Int.min),
        rounded < -Double(Int.min)
      {
        return .int(Int(rounded))
      }
      return .double(value)
    case .bool(let value):
      return .bool(value)
    case .object(let value):
      return .object(value.mapValues(\.sdkValue))
    case .array(let value):
      return .array(value.map(\.sdkValue))
    case .null:
      return .null
    }
  }

  init(sdkValue: MCP.Value) {
    switch sdkValue {
    case .null:
      self = .null
    case .bool(let value):
      self = .bool(value)
    case .int(let value):
      self = .number(Double(value))
    case .double(let value):
      self = .number(value)
    case .string(let value):
      self = .string(value)
    case .data:
      self = .string(sdkValue.description)
    case .array(let value):
      self = .array(value.map(JSONValue.init(sdkValue:)))
    case .object(let value):
      self = .object(value.mapValues(JSONValue.init(sdkValue:)))
    }
  }
}

extension MCPTool {
  var sdkTool: MCP.Tool {
    MCP.Tool(
      name: name,
      title: title,
      description: description,
      inputSchema: inputSchema.sdkValue,
      annotations: annotations?.sdkAnnotations ?? nil,
      outputSchema: outputSchema?.sdkValue,
      _meta: meta?.sdkMetadata
    )
  }
}

extension MCPToolAnnotations {
  var sdkAnnotations: MCP.Tool.Annotations {
    MCP.Tool.Annotations(
      readOnlyHint: readOnlyHint,
      destructiveHint: destructiveHint,
      idempotentHint: idempotentHint,
      openWorldHint: openWorldHint
    )
  }
}

extension JSONValue {
  var sdkMetadata: MCP.Metadata? {
    guard let object = objectValue else {
      return nil
    }
    return MCP.Metadata(additionalFields: object.mapValues(\.sdkValue))
  }
}

extension JSONValue {
  static func sdkToolResult(
    content: [MCP.Tool.Content],
    structuredContent: MCP.Value?,
    isError: Bool?,
    meta: MCP.Metadata?
  ) throws -> JSONValue {
    var object: [String: JSONValue] = [
      "content": .array(try content.map { try JSONValue.encoded($0) }),
      "isError": isError.map(JSONValue.bool) ?? .null,
    ]
    if let structuredContent {
      object["structuredContent"] = JSONValue(sdkValue: structuredContent)
    }
    if let meta {
      object["_meta"] = .object(meta.fields.mapValues(JSONValue.init(sdkValue:)))
    }
    return .object(object)
  }

  func sdkCallToolResult() throws -> MCP.CallTool.Result {
    guard let object = objectValue else {
      return MCP.CallTool.Result(
        content: [.text(text: encodedText(), annotations: nil, _meta: nil)]
      )
    }

    let isError = object["isError"]?.boolValue
    let structuredContent = object["structuredContent"]?.sdkValue
    let meta = object["_meta"]?.sdkMetadata
    let content = object["content"]?.arrayValue?.compactMap { value -> MCP.Tool.Content? in
      guard let item = value.objectValue,
        item["type"]?.stringValue == "text",
        let text = item["text"]?.stringValue
      else {
        return nil
      }
      return .text(text: text, annotations: nil, _meta: nil)
    }

    if let content, !content.isEmpty {
      return MCP.CallTool.Result(
        content: content,
        structuredContent: structuredContent,
        isError: isError,
        _meta: meta
      )
    }

    return MCP.CallTool.Result(
      content: [.text(text: encodedText(), annotations: nil, _meta: nil)],
      structuredContent: structuredContent,
      isError: isError,
      _meta: meta
    )
  }

  private func encodedText() -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(self) else {
      return "\(self)"
    }
    return String(decoding: data, as: UTF8.self)
  }
}
