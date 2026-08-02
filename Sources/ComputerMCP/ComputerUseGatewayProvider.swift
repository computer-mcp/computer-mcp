import Foundation

internal enum ComputerUseGatewayProviderError: Error, Equatable, Sendable {
  case unknownTool(String)
  case invalidArguments(String)
  case asyncToolRequired(String)
  case service(ComputerUseError)

  internal var code: String {
    switch self {
    case .unknownTool:
      "computer_use.unknown_tool"
    case .invalidArguments:
      "computer_use.invalid_arguments"
    case .asyncToolRequired:
      "computer_use.async_tool_required"
    case .service(let error):
      error.code
    }
  }
}

extension ComputerUseGatewayProviderError: LocalizedError {
  internal var errorDescription: String? {
    let detail: String
    switch self {
    case .unknownTool(let name):
      detail = "Unknown Computer Use tool: \(name)"
    case .invalidArguments(let message):
      detail = message
    case .asyncToolRequired(let name):
      detail = "Tool \(name) must be called through the asynchronous MCP runtime."
    case .service(let error):
      detail = error.localizedDescription
    }
    return "\(code): \(detail)"
  }
}

internal struct ComputerUseGatewayProvider: GatewayToolProvider, Sendable {
  internal let id = "computer-use"

  private let service: ComputerUseService
  private let tools: [MCPTool]

  internal init(service: ComputerUseService = ComputerUseService()) {
    self.service = service
    self.tools = Self.makeTools()
  }

  internal func listTools() throws -> [MCPTool] {
    tools
  }

  internal func capability(for tool: MCPTool) -> CapabilityDescriptor {
    let readOnly = Self.readOnlyTools.contains(tool.name)
    return CapabilityDescriptor(
      id: tool.name,
      risk: readOnly ? .readOnly : .externalWrite,
      workspaceRequirement: .none,
      localOnly: false,
      usesNetwork: false,
      tccServices: Self.tccServices(for: tool.name)
    )
  }

  internal func callTool(name: String, arguments: JSONValue?) throws -> JSONValue {
    guard name != "computer.screenshot" else {
      throw ComputerUseGatewayProviderError.asyncToolRequired(name)
    }
    return try executeSync(name: name, arguments: arguments)
  }

  internal func callToolAsync(name: String, arguments: JSONValue?) async throws -> JSONValue {
    if name == "computer.screenshot" {
      do {
        let input = try decode(ScreenshotArguments.self, arguments)
        let screenshot = try await service.captureScreenshot(input.request)
        return try screenshotResult(screenshot)
      } catch let error as ComputerUseGatewayProviderError {
        throw error
      } catch let error as ComputerUseError {
        throw ComputerUseGatewayProviderError.service(error)
      } catch let error as DecodingError {
        throw ComputerUseGatewayProviderError.invalidArguments(
          Self.decodingMessage(error)
        )
      } catch {
        throw ComputerUseGatewayProviderError.invalidArguments(error.localizedDescription)
      }
    }
    return try executeSync(name: name, arguments: arguments)
  }

  private func executeSync(name: String, arguments: JSONValue?) throws -> JSONValue {
    do {
      let result: JSONValue
      switch name {
      case "computer.permissions":
        _ = try decode(EmptyArguments.self, arguments)
        result = try encode(service.permissionSnapshot())

      case "computer.displays":
        _ = try decode(EmptyArguments.self, arguments)
        result = try encode(service.observeDisplays())

      case "computer.windows":
        let input = try decode(WindowArguments.self, arguments)
        result = try encode(service.observeWindows(input.query))

      case "computer.pointer.position":
        _ = try decode(EmptyArguments.self, arguments)
        result = try encode(service.observePointer())

      case "computer.pointer.move":
        let input = try decode(PointerMoveArguments.self, arguments)
        result = actionValue(
          try service.movePointer(
            to: input.point,
            verification: try input.verification?.value(),
            verificationPolicy: input.verificationPolicy?.value
              ?? ComputerUseVerificationPolicy()
          )
        )

      case "computer.pointer.click":
        let input = try decode(PointerClickArguments.self, arguments)
        result = actionValue(
          try service.clickPointer(
            button: input.button,
            at: input.point,
            clickCount: input.clickCount ?? 1,
            verification: try input.verification?.value(),
            verificationPolicy: input.verificationPolicy?.value
              ?? ComputerUseVerificationPolicy()
          )
        )

      case "computer.keyboard.key":
        let input = try decode(KeyboardKeyArguments.self, arguments)
        result = actionValue(
          try service.pressKey(
            keyCode: input.keyCode,
            modifiers: Set(input.modifiers ?? []),
            repeatCount: input.repeatCount ?? 1,
            verification: try input.verification?.value(),
            verificationPolicy: input.verificationPolicy?.value
              ?? ComputerUseVerificationPolicy()
          )
        )

      case "computer.keyboard.text":
        let input = try decode(KeyboardTextArguments.self, arguments)
        result = actionValue(
          try service.typeText(
            input.text,
            verification: try input.verification?.value(),
            verificationPolicy: input.verificationPolicy?.value
              ?? ComputerUseVerificationPolicy()
          )
        )

      case "computer.scroll":
        let input = try decode(ScrollArguments.self, arguments)
        result = actionValue(
          try service.scroll(
            deltaX: input.deltaX,
            deltaY: input.deltaY,
            unit: input.unit ?? .pixel,
            at: input.point,
            verification: try input.verification?.value(),
            verificationPolicy: input.verificationPolicy?.value
              ?? ComputerUseVerificationPolicy()
          )
        )

      case "computer.accessibility.query":
        let input = try decode(AccessibilityQueryArguments.self, arguments)
        result = .array(try service.queryAccessibility(input.query).map(accessibilityValue))

      case "computer.accessibility.action":
        let input = try decode(AccessibilityActionArguments.self, arguments)
        result = actionValue(
          try service.performAccessibilityAction(
            input.action,
            on: input.reference,
            verification: try input.verification?.value(),
            verificationPolicy: input.verificationPolicy?.value
              ?? ComputerUseVerificationPolicy()
          )
        )

      case "computer.verify":
        let input = try decode(VerifyArguments.self, arguments)
        result = verificationResultValue(
          try service.verify(
            input.verification.value(),
            policy: input.policy?.value ?? ComputerUseVerificationPolicy()
          )
        )

      case "computer.screenshot":
        throw ComputerUseGatewayProviderError.asyncToolRequired(name)

      default:
        throw ComputerUseGatewayProviderError.unknownTool(name)
      }
      return try resultEnvelope(result)
    } catch let error as ComputerUseGatewayProviderError {
      throw error
    } catch let error as ComputerUseError {
      throw ComputerUseGatewayProviderError.service(error)
    } catch let error as DecodingError {
      throw ComputerUseGatewayProviderError.invalidArguments(
        Self.decodingMessage(error)
      )
    } catch {
      throw ComputerUseGatewayProviderError.invalidArguments(error.localizedDescription)
    }
  }

  private func decode<Value: Decodable>(
    _ type: Value.Type,
    _ arguments: JSONValue?
  ) throws -> Value {
    let encoder = JSONEncoder()
    let data = try encoder.encode(arguments ?? .object([:]))
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .custom { codingPath in
      let raw = codingPath.last?.stringValue ?? ""
      let parts = raw.split(separator: "_").map(String.init)
      guard let first = parts.first else {
        return ComputerUseCodingKey(raw)
      }
      let converted =
        first
        + parts.dropFirst().map { part in
          part.caseInsensitiveCompare("id") == .orderedSame
            ? "ID"
            : part.prefix(1).uppercased() + part.dropFirst()
        }.joined()
      return ComputerUseCodingKey(converted)
    }
    return try decoder.decode(Value.self, from: data)
  }

  private func encode<Value: Encodable>(_ value: Value) throws -> JSONValue {
    let encoder = CanonicalJSONCoding.encoder()
    encoder.outputFormatting = [.sortedKeys]
    return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
  }

  private func resultEnvelope(_ result: JSONValue) throws -> JSONValue {
    let data = try JSONEncoder().encode(result)
    return .object([
      "content": .array([
        .object([
          "type": .string("text"),
          "text": .string(String(decoding: data, as: UTF8.self)),
        ])
      ]),
      "structuredContent": .object(["result": result]),
      "isError": .bool(false),
    ])
  }

  private func screenshotResult(
    _ screenshot: ComputerUseScreenshotObservation
  ) throws -> JSONValue {
    let result = try encode(screenshot)
    var metadata = result.objectValue ?? [:]
    metadata.removeValue(forKey: "png_base64")
    let metadataData = try JSONEncoder().encode(JSONValue.object(metadata))
    return .object([
      "content": .array([
        .object([
          "type": .string("text"),
          "text": .string(String(decoding: metadataData, as: UTF8.self)),
        ]),
        .object([
          "type": .string("image"),
          "data": .string(screenshot.pngBase64),
          "mimeType": .string(screenshot.mimeType),
        ]),
      ]),
      "structuredContent": .object(["result": result]),
      "isError": .bool(false),
    ])
  }

  private func actionValue(_ result: ComputerUseActionResult) -> JSONValue {
    .object([
      "action": .string(result.action.rawValue),
      "verification": result.verification.map(verificationResultValue) ?? .null,
    ])
  }

  private func verificationResultValue(
    _ result: ComputerUseVerificationResult
  ) -> JSONValue {
    .object([
      "attempts": .number(Double(result.attempts)),
      "observation": verificationObservationValue(result.observation),
    ])
  }

  private func verificationObservationValue(
    _ observation: ComputerUseVerificationObservation
  ) -> JSONValue {
    switch observation {
    case .pointerPosition(let point):
      return .object([
        "type": .string("pointer-position"),
        "point": pointValue(point),
      ])
    case .accessibilityAttribute(let value):
      return .object([
        "type": .string("accessibility-attribute"),
        "value": accessibilityValue(value),
      ])
    case .accessibilityElementCount(let count):
      return .object([
        "type": .string("accessibility-element-count"),
        "count": .number(Double(count)),
      ])
    case .frontmostApplication(let application):
      return .object([
        "type": .string("frontmost-application"),
        "application": application.map(applicationValue) ?? .null,
      ])
    }
  }

  private func accessibilityValue(
    _ observation: ComputerUseAccessibilityObservation
  ) -> JSONValue {
    .object([
      "reference": referenceValue(observation.reference),
      "role": observation.role.map(JSONValue.string) ?? .null,
      "subrole": observation.subrole.map(JSONValue.string) ?? .null,
      "title": observation.title.map(JSONValue.string) ?? .null,
      "value": observation.value.map(accessibilityValue) ?? .null,
      "description": observation.elementDescription.map(JSONValue.string) ?? .null,
      "identifier": observation.identifier.map(JSONValue.string) ?? .null,
      "enabled": observation.enabled.map(JSONValue.bool) ?? .null,
      "focused": observation.focused.map(JSONValue.bool) ?? .null,
      "frame": observation.frame.map(rectValue) ?? .null,
      "supported_actions": .array(observation.supportedActions.map(JSONValue.string)),
    ])
  }

  private func accessibilityValue(_ value: ComputerUseAccessibilityValue) -> JSONValue {
    switch value {
    case .string(let value):
      .string(value)
    case .bool(let value):
      .bool(value)
    case .number(let value):
      .number(value)
    case .null:
      .null
    }
  }

  private func pointValue(_ point: ComputerUsePoint) -> JSONValue {
    .object([
      "x": .number(point.x),
      "y": .number(point.y),
    ])
  }

  private func rectValue(_ rect: ComputerUseRect) -> JSONValue {
    .object([
      "origin": pointValue(rect.origin),
      "size": .object([
        "width": .number(rect.size.width),
        "height": .number(rect.size.height),
      ]),
    ])
  }

  private func referenceValue(_ reference: ComputerUseAccessibilityReference) -> JSONValue {
    .object([
      "process_id": .number(Double(reference.processID)),
      "child_path": .array(reference.childPath.map { .number(Double($0)) }),
    ])
  }

  private func applicationValue(
    _ application: ComputerUseApplicationObservation
  ) -> JSONValue {
    .object([
      "process_id": .number(Double(application.processID)),
      "bundle_identifier": application.bundleIdentifier.map(JSONValue.string) ?? .null,
      "localized_name": application.localizedName.map(JSONValue.string) ?? .null,
    ])
  }
}

extension ComputerUseGatewayProvider {
  fileprivate static let readOnlyTools: Set<String> = [
    "computer.permissions",
    "computer.displays",
    "computer.screenshot",
    "computer.windows",
    "computer.pointer.position",
    "computer.accessibility.query",
    "computer.verify",
  ]

  fileprivate static func tccServices(for name: String) -> [String] {
    if name == "computer.screenshot" || name == "computer.windows" {
      return ["screen-recording"]
    }
    if name == "computer.pointer.position" {
      return []
    }
    if name.hasPrefix("computer.pointer.") || name.hasPrefix("computer.keyboard.")
      || name == "computer.scroll" || name.hasPrefix("computer.accessibility.")
    {
      return ["accessibility"]
    }
    if name == "computer.verify" {
      return ["accessibility"]
    }
    return []
  }

  fileprivate static func makeTools() -> [MCPTool] {
    [
      tool(
        name: "computer.permissions",
        description:
          "Read current Accessibility and Screen Recording permission status. Never prompts.",
        input: objectSchema(),
        result: permissionSchema,
        readOnly: true
      ),
      tool(
        name: "computer.displays",
        description: "List active display geometry and pixel metadata without capturing pixels.",
        input: objectSchema(),
        result: arraySchema(displaySchema),
        readOnly: true
      ),
      tool(
        name: "computer.screenshot",
        description:
          "Capture a bounded PNG of one display or window. Requires existing Screen Recording "
          + "permission and never prompts for it.",
        input: screenshotInputSchema,
        result: screenshotSchema,
        readOnly: true
      ),
      tool(
        name: "computer.windows",
        description:
          "List filtered, bounded window metadata. Prefer owner, title, process, layer, or alpha "
          + "filters instead of requesting a large unfiltered result. Requires existing Screen "
          + "Recording permission and never prompts for it.",
        input: windowInputSchema,
        result: arraySchema(windowSchema),
        readOnly: true
      ),
      tool(
        name: "computer.pointer.position",
        description:
          "Read the current macOS pointer position without moving it or requesting permissions.",
        input: objectSchema(),
        result: pointSchema,
        readOnly: true
      ),
      tool(
        name: "computer.pointer.move",
        description: "Move the macOS pointer to an absolute display coordinate.",
        input: pointerMoveInputSchema,
        result: actionResultSchema,
        readOnly: false,
        idempotent: true
      ),
      tool(
        name: "computer.pointer.click",
        description: "Click a pointer button at a bounded coordinate or current pointer location.",
        input: pointerClickInputSchema,
        result: actionResultSchema,
        readOnly: false
      ),
      tool(
        name: "computer.keyboard.key",
        description: "Press a macOS virtual key code with explicit modifiers and repeat count.",
        input: keyboardKeyInputSchema,
        result: actionResultSchema,
        readOnly: false
      ),
      tool(
        name: "computer.keyboard.text",
        description: "Type bounded Unicode text through the macOS input event system.",
        input: keyboardTextInputSchema,
        result: actionResultSchema,
        readOnly: false
      ),
      tool(
        name: "computer.scroll",
        description: "Post a bounded two-axis line or pixel scroll event.",
        input: scrollInputSchema,
        result: actionResultSchema,
        readOnly: false
      ),
      tool(
        name: "computer.accessibility.query",
        description:
          "Query a bounded Accessibility element tree for one process and return stable "
          + "element references.",
        input: accessibilityQuerySchema,
        result: arraySchema(accessibilityObservationSchema),
        readOnly: true
      ),
      tool(
        name: "computer.accessibility.action",
        description:
          "Perform one standard Accessibility action on a previously returned reference.",
        input: accessibilityActionInputSchema,
        result: actionResultSchema,
        readOnly: false
      ),
      tool(
        name: "computer.verify",
        description:
          "Poll a bounded mechanical postcondition without performing an input action.",
        input: verifyInputSchema,
        result: verificationResultSchema,
        readOnly: true
      ),
    ]
  }

  private static func tool(
    name: String,
    description: String,
    input: JSONValue,
    result: JSONValue,
    readOnly: Bool,
    idempotent: Bool? = nil
  ) -> MCPTool {
    MCPTool(
      name: name,
      description: description,
      inputSchema: input,
      outputSchema: resultEnvelopeSchema(result),
      annotations: MCPToolAnnotations(
        readOnlyHint: readOnly,
        destructiveHint: false,
        idempotentHint: idempotent ?? (readOnly ? true : false),
        openWorldHint: false
      )
    )
  }

  private static func decodingMessage(_ error: DecodingError) -> String {
    switch error {
    case .keyNotFound(let key, _):
      return "Missing required argument: \(key.stringValue)"
    case .typeMismatch(_, let context), .valueNotFound(_, let context):
      return "Invalid argument at \(codingPath(context.codingPath)): \(context.debugDescription)"
    case .dataCorrupted(let context):
      return "Invalid argument at \(codingPath(context.codingPath)): \(context.debugDescription)"
    @unknown default:
      return "Arguments do not match the declared input schema."
    }
  }

  private static func codingPath(_ path: [any CodingKey]) -> String {
    path.map(\.stringValue).joined(separator: ".")
  }
}

private struct ComputerUseCodingKey: CodingKey {
  var stringValue: String
  var intValue: Int?

  init(_ stringValue: String) {
    self.stringValue = stringValue
    self.intValue = nil
  }

  init?(stringValue: String) {
    self.init(stringValue)
  }

  init?(intValue: Int) {
    self.stringValue = String(intValue)
    self.intValue = intValue
  }
}

private struct EmptyArguments: Decodable {}

private struct ScreenshotArguments: Decodable {
  var target: ComputerUseScreenshotTarget?
  var displayID: UInt32?
  var windowID: UInt32?
  var maxWidth: Int?
  var maxHeight: Int?
  var maxBytes: Int?
  var showsCursor: Bool?

  var request: ComputerUseScreenshotRequest {
    ComputerUseScreenshotRequest(
      target: target ?? .display,
      displayID: displayID,
      windowID: windowID,
      maxWidth: maxWidth ?? 2_560,
      maxHeight: maxHeight ?? 1_600,
      maxBytes: maxBytes ?? 8 * 1_024 * 1_024,
      showsCursor: showsCursor ?? true
    )
  }
}

private struct WindowArguments: Decodable {
  var onScreenOnly: Bool?
  var excludeDesktopElements: Bool?
  var maxResults: Int?
  var ownerProcessID: Int32?
  var ownerNameContains: String?
  var titleContains: String?
  var layer: Int?
  var minimumAlpha: Double?
  var caseSensitive: Bool?

  var query: ComputerUseWindowQuery {
    ComputerUseWindowQuery(
      onScreenOnly: onScreenOnly ?? true,
      excludeDesktopElements: excludeDesktopElements ?? true,
      maxResults: maxResults ?? 10,
      ownerProcessID: ownerProcessID,
      ownerNameContains: ownerNameContains,
      titleContains: titleContains,
      layer: layer,
      minimumAlpha: minimumAlpha,
      caseSensitive: caseSensitive ?? false
    )
  }
}

private struct PointerMoveArguments: Decodable {
  var point: ComputerUsePoint
  var verification: VerificationArguments?
  var verificationPolicy: VerificationPolicyArguments?
}

private struct PointerClickArguments: Decodable {
  var button: ComputerUsePointerButton
  var point: ComputerUsePoint?
  var clickCount: Int?
  var verification: VerificationArguments?
  var verificationPolicy: VerificationPolicyArguments?
}

private struct KeyboardKeyArguments: Decodable {
  var keyCode: UInt16
  var modifiers: [ComputerUseKeyModifier]?
  var repeatCount: Int?
  var verification: VerificationArguments?
  var verificationPolicy: VerificationPolicyArguments?
}

private struct KeyboardTextArguments: Decodable {
  var text: String
  var verification: VerificationArguments?
  var verificationPolicy: VerificationPolicyArguments?
}

private struct ScrollArguments: Decodable {
  var deltaX: Int32
  var deltaY: Int32
  var unit: ComputerUseScrollUnit?
  var point: ComputerUsePoint?
  var verification: VerificationArguments?
  var verificationPolicy: VerificationPolicyArguments?
}

private struct AccessibilityQueryArguments: Decodable {
  var processID: Int32
  var role: String?
  var titleContains: String?
  var identifier: String?
  var valueContains: String?
  var enabled: Bool?
  var focused: Bool?
  var caseSensitive: Bool?
  var maxDepth: Int?
  var maxResults: Int?
  var maxScannedElements: Int?

  var query: ComputerUseAccessibilityQuery {
    ComputerUseAccessibilityQuery(
      processID: processID,
      role: role,
      titleContains: titleContains,
      identifier: identifier,
      valueContains: valueContains,
      enabled: enabled,
      focused: focused,
      caseSensitive: caseSensitive ?? false,
      maxDepth: maxDepth ?? 12,
      maxResults: maxResults ?? 100,
      maxScannedElements: maxScannedElements ?? 5_000
    )
  }
}

private struct AccessibilityActionArguments: Decodable {
  var action: ComputerUseAccessibilityAction
  var reference: ComputerUseAccessibilityReference
  var verification: VerificationArguments?
  var verificationPolicy: VerificationPolicyArguments?
}

private struct VerifyArguments: Decodable {
  var verification: VerificationArguments
  var policy: VerificationPolicyArguments?
}

private struct VerificationPolicyArguments: Decodable {
  var timeoutMilliseconds: Int?
  var pollIntervalMilliseconds: Int?

  var value: ComputerUseVerificationPolicy {
    ComputerUseVerificationPolicy(
      timeoutMilliseconds: timeoutMilliseconds ?? 1_000,
      pollIntervalMilliseconds: pollIntervalMilliseconds ?? 50
    )
  }
}

private struct VerificationArguments: Decodable {
  var type: String
  var point: ComputerUsePoint?
  var tolerance: Double?
  var reference: ComputerUseAccessibilityReference?
  var attribute: ComputerUseAccessibilityAttribute?
  var expected: JSONValue?
  var query: AccessibilityQueryArguments?
  var minimum: Int?
  var processID: Int32?
  var bundleIdentifier: String?

  func value() throws -> ComputerUseVerification {
    switch type {
    case "pointer-position":
      guard let point else {
        throw ComputerUseGatewayProviderError.invalidArguments(
          "verification.point is required for pointer-position"
        )
      }
      return .pointerPosition(expected: point, tolerance: tolerance ?? 1)

    case "accessibility-attribute":
      guard let reference, let attribute, let expected else {
        throw ComputerUseGatewayProviderError.invalidArguments(
          "verification.reference, attribute, and expected are required"
        )
      }
      return .accessibilityAttribute(
        reference: reference,
        attribute: attribute,
        expected: try Self.accessibilityValue(expected)
      )

    case "accessibility-element-count":
      guard let query, let minimum else {
        throw ComputerUseGatewayProviderError.invalidArguments(
          "verification.query and minimum are required"
        )
      }
      return .accessibilityElementCount(query: query.query, minimum: minimum)

    case "frontmost-application":
      return .frontmostApplication(
        processID: processID,
        bundleIdentifier: bundleIdentifier
      )

    default:
      throw ComputerUseGatewayProviderError.invalidArguments(
        "verification.type must be pointer-position, accessibility-attribute, "
          + "accessibility-element-count, or frontmost-application"
      )
    }
  }

  private static func accessibilityValue(
    _ value: JSONValue
  ) throws -> ComputerUseAccessibilityValue {
    switch value {
    case .string(let value):
      return .string(value)
    case .bool(let value):
      return .bool(value)
    case .number(let value):
      return .number(value)
    case .null:
      return .null
    case .array, .object:
      throw ComputerUseGatewayProviderError.invalidArguments(
        "verification.expected must be a string, number, boolean, or null"
      )
    }
  }
}

extension ComputerUseGatewayProvider {
  fileprivate static func objectSchema(
    _ properties: [String: JSONValue] = [:],
    required: [String] = []
  ) -> JSONValue {
    var value: [String: JSONValue] = [
      "type": .string("object"),
      "properties": .object(properties),
      "additionalProperties": .bool(false),
    ]
    if !required.isEmpty {
      value["required"] = .array(required.map(JSONValue.string))
    }
    return .object(value)
  }

  fileprivate static func arraySchema(_ items: JSONValue) -> JSONValue {
    .object([
      "type": .string("array"),
      "items": items,
    ])
  }

  fileprivate static func stringSchema(
    _ description: String,
    enum values: [String]? = nil,
    minLength: Int? = nil,
    maxLength: Int? = nil
  ) -> JSONValue {
    var schema: [String: JSONValue] = [
      "type": .string("string"),
      "description": .string(description),
    ]
    if let values {
      schema["enum"] = .array(values.map(JSONValue.string))
    }
    if let minLength {
      schema["minLength"] = .number(Double(minLength))
    }
    if let maxLength {
      schema["maxLength"] = .number(Double(maxLength))
    }
    return .object(schema)
  }

  fileprivate static func integerSchema(
    _ description: String,
    minimum: Int? = nil,
    maximum: Int? = nil
  ) -> JSONValue {
    var schema: [String: JSONValue] = [
      "type": .string("integer"),
      "description": .string(description),
    ]
    if let minimum { schema["minimum"] = .number(Double(minimum)) }
    if let maximum { schema["maximum"] = .number(Double(maximum)) }
    return .object(schema)
  }

  fileprivate static func numberSchema(
    _ description: String,
    minimum: Double? = nil,
    maximum: Double? = nil
  ) -> JSONValue {
    var schema: [String: JSONValue] = [
      "type": .string("number"),
      "description": .string(description),
    ]
    if let minimum { schema["minimum"] = .number(minimum) }
    if let maximum { schema["maximum"] = .number(maximum) }
    return .object(schema)
  }

  fileprivate static func boolSchema(_ description: String) -> JSONValue {
    .object([
      "type": .string("boolean"),
      "description": .string(description),
    ])
  }

  fileprivate static func nullable(_ schema: JSONValue) -> JSONValue {
    .object([
      "anyOf": .array([
        schema,
        .object(["type": .string("null")]),
      ])
    ])
  }

  fileprivate static func resultEnvelopeSchema(_ result: JSONValue) -> JSONValue {
    objectSchema(["result": result], required: ["result"])
  }

  fileprivate static let pointSchema = objectSchema(
    [
      "x": numberSchema("Absolute horizontal coordinate in display points."),
      "y": numberSchema("Absolute vertical coordinate in display points."),
    ],
    required: ["x", "y"]
  )

  fileprivate static let sizeSchema = objectSchema(
    [
      "width": numberSchema("Width."),
      "height": numberSchema("Height."),
    ],
    required: ["width", "height"]
  )

  fileprivate static let rectSchema = objectSchema(
    [
      "origin": pointSchema,
      "size": sizeSchema,
    ],
    required: ["origin", "size"]
  )

  fileprivate static let referenceSchema = objectSchema(
    [
      "process_id": integerSchema("Positive process identifier.", minimum: 1),
      "child_path": arraySchema(
        integerSchema("Zero-based child index.", minimum: 0)
      ),
    ],
    required: ["process_id", "child_path"]
  )

  fileprivate static let verificationPolicySchema = objectSchema([
    "timeout_milliseconds": integerSchema(
      "Maximum polling duration.", minimum: 0, maximum: 5_000),
    "poll_interval_milliseconds": integerSchema(
      "Polling interval.", minimum: 1, maximum: 1_000),
  ])

  fileprivate static let accessibilityQueryProperties: [String: JSONValue] = [
    "process_id": integerSchema("Positive process identifier.", minimum: 1),
    "role": stringSchema("Exact AXRole value."),
    "title_contains": stringSchema("Required title substring."),
    "identifier": stringSchema("Exact AXIdentifier value."),
    "value_contains": stringSchema("Required textual value substring."),
    "enabled": boolSchema("Match enabled state."),
    "focused": boolSchema("Match focused state."),
    "case_sensitive": boolSchema("Use case-sensitive substring matching."),
    "max_depth": integerSchema("Maximum AX tree depth.", minimum: 0, maximum: 25),
    "max_results": integerSchema("Maximum matches.", minimum: 1, maximum: 200),
    "max_scanned_elements": integerSchema(
      "Maximum scanned elements.", minimum: 1, maximum: 20_000),
  ]

  fileprivate static let accessibilityQuerySchema = objectSchema(
    accessibilityQueryProperties,
    required: ["process_id"]
  )

  fileprivate static let verificationSchema = objectSchema(
    [
      "type": stringSchema(
        "Mechanical condition kind.",
        enum: [
          "pointer-position",
          "accessibility-attribute",
          "accessibility-element-count",
          "frontmost-application",
        ]
      ),
      "point": pointSchema,
      "tolerance": numberSchema("Pointer distance tolerance in points."),
      "reference": referenceSchema,
      "attribute": stringSchema(
        "Accessibility attribute.",
        enum: ComputerUseAccessibilityAttribute.allCases.map(\.rawValue)
      ),
      "expected": .object([
        "description": .string("Expected primitive Accessibility value."),
        "type": .array([
          .string("string"),
          .string("number"),
          .string("boolean"),
          .string("null"),
        ]),
      ]),
      "query": accessibilityQuerySchema,
      "minimum": integerSchema("Minimum matching element count.", minimum: 1),
      "process_id": integerSchema("Expected frontmost process id.", minimum: 1),
      "bundle_identifier": stringSchema("Expected frontmost bundle identifier."),
    ],
    required: ["type"]
  )

  fileprivate static let actionBaseProperties: [String: JSONValue] = [
    "verification": verificationSchema,
    "verification_policy": verificationPolicySchema,
  ]

  fileprivate static let permissionSchema = objectSchema(
    [
      "accessibility": stringSchema(
        "Accessibility permission status.", enum: ["granted", "not-granted"]),
      "screen_recording": stringSchema(
        "Screen Recording permission status.", enum: ["granted", "not-granted"]),
    ],
    required: ["accessibility", "screen_recording"]
  )

  fileprivate static let displaySchema = objectSchema(
    [
      "id": integerSchema("CoreGraphics display identifier.", minimum: 0),
      "bounds": rectSchema,
      "pixel_width": integerSchema("Pixel width.", minimum: 1),
      "pixel_height": integerSchema("Pixel height.", minimum: 1),
      "scale_factor": numberSchema("Backing pixel scale."),
      "rotation_degrees": numberSchema("Clockwise rotation in degrees."),
      "physical_size_millimeters": sizeSchema,
      "is_main": boolSchema("Whether this is the main display."),
    ],
    required: [
      "id", "bounds", "pixel_width", "pixel_height", "scale_factor", "rotation_degrees",
      "physical_size_millimeters", "is_main",
    ]
  )

  fileprivate static let screenshotInputSchema = objectSchema([
    "target": stringSchema("Capture target.", enum: ["display", "window"]),
    "display_id": integerSchema("Display id; omitted to use the main display.", minimum: 0),
    "window_id": integerSchema("Required window id for a window target.", minimum: 0),
    "max_width": integerSchema(
      "Maximum PNG pixel width.",
      minimum: ComputerUseService.minimumScreenshotDimension,
      maximum: ComputerUseService.maximumScreenshotDimension
    ),
    "max_height": integerSchema(
      "Maximum PNG pixel height.",
      minimum: ComputerUseService.minimumScreenshotDimension,
      maximum: ComputerUseService.maximumScreenshotDimension
    ),
    "max_bytes": integerSchema(
      "Maximum PNG byte count.",
      minimum: ComputerUseService.minimumScreenshotBytes,
      maximum: ComputerUseService.maximumScreenshotBytes
    ),
    "shows_cursor": boolSchema("Whether to include the pointer cursor."),
  ])

  fileprivate static let screenshotSchema = objectSchema(
    [
      "target": stringSchema("Captured source type.", enum: ["display", "window"]),
      "source_id": integerSchema("Captured display or window id.", minimum: 0),
      "width": integerSchema("PNG pixel width.", minimum: 1),
      "height": integerSchema("PNG pixel height.", minimum: 1),
      "byte_count": integerSchema("PNG byte count.", minimum: 1),
      "mime_type": stringSchema("Always image/png.", enum: ["image/png"]),
      "png_base64": stringSchema("Base64-encoded PNG bytes."),
    ],
    required: [
      "target", "source_id", "width", "height", "byte_count", "mime_type", "png_base64",
    ]
  )

  fileprivate static let windowInputSchema = objectSchema([
    "on_screen_only": boolSchema("Return only on-screen windows."),
    "exclude_desktop_elements": boolSchema("Exclude desktop background elements."),
    "max_results": integerSchema("Maximum matching windows.", minimum: 1, maximum: 200),
    "owner_process_id": integerSchema(
      "Return windows owned by this process identifier.",
      minimum: 0,
      maximum: Int(Int32.max)
    ),
    "owner_name_contains": stringSchema(
      "Return windows whose owner application name contains this substring.",
      minLength: 1,
      maxLength: 1_024
    ),
    "title_contains": stringSchema(
      "Return windows whose title contains this substring.",
      minLength: 1,
      maxLength: 1_024
    ),
    "layer": integerSchema("Return windows on this CoreGraphics layer."),
    "minimum_alpha": numberSchema(
      "Return windows with alpha greater than or equal to this value.",
      minimum: 0,
      maximum: 1
    ),
    "case_sensitive": boolSchema(
      "Use case-sensitive owner and title substring matching. Defaults to false."
    ),
  ])

  fileprivate static let windowSchema = objectSchema(
    [
      "id": integerSchema("CoreGraphics window identifier.", minimum: 0),
      "owner_process_id": integerSchema("Owning process identifier.", minimum: 0),
      "owner_name": nullable(stringSchema("Owning application name.")),
      "title": nullable(stringSchema("Window title.")),
      "bounds": rectSchema,
      "layer": integerSchema("Window layer."),
      "alpha": numberSchema("Window alpha."),
      "is_on_screen": boolSchema("Whether the window is currently on screen."),
      "memory_bytes": nullable(integerSchema("Backing memory bytes.", minimum: 0)),
      "sharing_state": nullable(integerSchema("CoreGraphics sharing state.", minimum: 0)),
    ],
    required: [
      "id", "owner_process_id", "owner_name", "title", "bounds", "layer", "alpha",
      "is_on_screen", "memory_bytes", "sharing_state",
    ]
  )

  fileprivate static let pointerMoveInputSchema = objectSchema(
    actionBaseProperties.merging(["point": pointSchema], uniquingKeysWith: { _, new in new }),
    required: ["point"]
  )

  fileprivate static let pointerClickInputSchema = objectSchema(
    actionBaseProperties.merging(
      [
        "button": stringSchema("Pointer button.", enum: ["left", "right", "center"]),
        "point": pointSchema,
        "click_count": integerSchema("Click count.", minimum: 1, maximum: 3),
      ],
      uniquingKeysWith: { _, new in new }
    ),
    required: ["button"]
  )

  fileprivate static let keyboardKeyInputSchema = objectSchema(
    actionBaseProperties.merging(
      [
        "key_code": integerSchema("macOS virtual key code.", minimum: 0, maximum: 127),
        "modifiers": arraySchema(
          stringSchema(
            "Key modifier.",
            enum: ["command", "control", "option", "shift", "function"]
          )
        ),
        "repeat_count": integerSchema("Repeat count.", minimum: 1, maximum: 100),
      ],
      uniquingKeysWith: { _, new in new }
    ),
    required: ["key_code"]
  )

  fileprivate static let keyboardTextInputSchema = objectSchema(
    actionBaseProperties.merging(
      [
        "text": .object([
          "type": .string("string"),
          "description": .string("Non-empty Unicode text, at most 4096 UTF-16 code units."),
          "minLength": .number(1),
        ])
      ],
      uniquingKeysWith: { _, new in new }
    ),
    required: ["text"]
  )

  fileprivate static let scrollInputSchema = objectSchema(
    actionBaseProperties.merging(
      [
        "delta_x": integerSchema(
          "Horizontal scroll delta.", minimum: -10_000, maximum: 10_000),
        "delta_y": integerSchema(
          "Vertical scroll delta.", minimum: -10_000, maximum: 10_000),
        "unit": stringSchema("Scroll unit.", enum: ["line", "pixel"]),
        "point": pointSchema,
      ],
      uniquingKeysWith: { _, new in new }
    ),
    required: ["delta_x", "delta_y"]
  )

  fileprivate static let accessibilityActionInputSchema = objectSchema(
    actionBaseProperties.merging(
      [
        "action": stringSchema(
          "Standard Accessibility action.",
          enum: ComputerUseAccessibilityAction.allCases.map(\.rawValue)
        ),
        "reference": referenceSchema,
      ],
      uniquingKeysWith: { _, new in new }
    ),
    required: ["action", "reference"]
  )

  fileprivate static let accessibilityPrimitiveSchema: JSONValue = .object([
    "type": .array([
      .string("string"),
      .string("number"),
      .string("boolean"),
      .string("null"),
    ])
  ])

  fileprivate static let accessibilityObservationSchema = objectSchema(
    [
      "reference": referenceSchema,
      "role": nullable(stringSchema("AXRole.")),
      "subrole": nullable(stringSchema("AXSubrole.")),
      "title": nullable(stringSchema("AXTitle.")),
      "value": accessibilityPrimitiveSchema,
      "description": nullable(stringSchema("AXDescription.")),
      "identifier": nullable(stringSchema("AXIdentifier.")),
      "enabled": nullable(boolSchema("AXEnabled.")),
      "focused": nullable(boolSchema("AXFocused.")),
      "frame": nullable(rectSchema),
      "supported_actions": arraySchema(stringSchema("Supported AX action.")),
    ],
    required: [
      "reference", "role", "subrole", "title", "value", "description", "identifier",
      "enabled", "focused", "frame", "supported_actions",
    ]
  )

  fileprivate static let verificationObservationSchema: JSONValue = .object([
    "oneOf": .array([
      objectSchema(
        [
          "type": stringSchema("Observation kind.", enum: ["pointer-position"]),
          "point": pointSchema,
        ],
        required: ["type", "point"]
      ),
      objectSchema(
        [
          "type": stringSchema(
            "Observation kind.", enum: ["accessibility-attribute"]),
          "value": accessibilityPrimitiveSchema,
        ],
        required: ["type", "value"]
      ),
      objectSchema(
        [
          "type": stringSchema(
            "Observation kind.", enum: ["accessibility-element-count"]),
          "count": integerSchema("Matching element count.", minimum: 0),
        ],
        required: ["type", "count"]
      ),
      objectSchema(
        [
          "type": stringSchema("Observation kind.", enum: ["frontmost-application"]),
          "application": nullable(
            objectSchema(
              [
                "process_id": integerSchema("Process identifier.", minimum: 1),
                "bundle_identifier": nullable(stringSchema("Bundle identifier.")),
                "localized_name": nullable(stringSchema("Localized application name.")),
              ],
              required: ["process_id", "bundle_identifier", "localized_name"]
            )
          ),
        ],
        required: ["type", "application"]
      ),
    ])
  ])

  fileprivate static let verificationResultSchema = objectSchema(
    [
      "attempts": integerSchema("Observation attempts.", minimum: 1),
      "observation": verificationObservationSchema,
    ],
    required: ["attempts", "observation"]
  )

  fileprivate static let actionResultSchema = objectSchema(
    [
      "action": stringSchema(
        "Executed generic action.",
        enum: [
          "pointer.move",
          "pointer.click",
          "keyboard.key",
          "keyboard.text",
          "scroll",
          "accessibility.action",
        ]
      ),
      "verification": nullable(verificationResultSchema),
    ],
    required: ["action", "verification"]
  )

  fileprivate static let verifyInputSchema = objectSchema(
    [
      "verification": verificationSchema,
      "policy": verificationPolicySchema,
    ],
    required: ["verification"]
  )
}
