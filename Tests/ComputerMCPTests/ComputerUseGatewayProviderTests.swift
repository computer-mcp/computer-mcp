import Foundation
import Testing

@testable import ComputerMCP

@Suite

final class ComputerUseGatewayProviderTests {
  @Test
  func testProviderExposesCompleteStableToolCatalog() throws {
    let provider = ComputerUseGatewayProvider(
      service: ComputerUseService(adapter: ProviderComputerUseAdapter())
    )

    let tools = try provider.listTools()

    #expect(
      (Set(tools.map(\.name)))
        == ([
          "computer.permissions",
          "computer.displays",
          "computer.screenshot",
          "computer.windows",
          "computer.pointer.position",
          "computer.pointer.move",
          "computer.pointer.click",
          "computer.keyboard.key",
          "computer.keyboard.text",
          "computer.scroll",
          "computer.accessibility.query",
          "computer.accessibility.action",
          "computer.verify",
        ]))
    #expect(
      tools.allSatisfy {
        $0.inputSchema.objectValue?["type"] == .string("object")
          && $0.outputSchema?.objectValue?["properties"]?.objectValue?["result"] != nil
          && $0.annotations != nil
      })
  }

  @Test
  func testCapabilitiesHaveNoWorkspaceRequirementAndCorrectRisk() throws {
    let provider = ComputerUseGatewayProvider(
      service: ComputerUseService(adapter: ProviderComputerUseAdapter())
    )
    let tools = try provider.listTools()
    let descriptors = Dictionary(
      uniqueKeysWithValues: tools.map { ($0.name, provider.capability(for: $0)) }
    )

    #expect(descriptors.values.allSatisfy { $0.workspaceRequirement == .none })
    #expect((descriptors["computer.screenshot"]?.risk) == (.readOnly))
    #expect((descriptors["computer.screenshot"]?.tccServices) == (["screen-recording"]))
    #expect((descriptors["computer.pointer.click"]?.risk) == (.externalWrite))
    #expect((descriptors["computer.pointer.click"]?.tccServices) == (["accessibility"]))
    let usesNetwork = descriptors.values.contains(where: \.usesNetwork)
    #expect(!usesNetwork)
  }

  @Test
  func testPermissionToolReturnsStructuredResult() throws {
    let adapter = ProviderComputerUseAdapter(
      permissions: [
        .accessibility: .granted,
        .screenRecording: .notGranted,
      ]
    )
    let provider = ComputerUseGatewayProvider(service: ComputerUseService(adapter: adapter))

    let response = try provider.callTool(name: "computer.permissions", arguments: nil)
    let result = structuredResult(response)

    #expect((result.objectValue?["accessibility"]) == (.string("granted")))
    #expect((result.objectValue?["screen_recording"]) == (.string("not-granted")))
    #expect(
      (adapter.calls)
        == ([
          .permission(.accessibility),
          .permission(.screenRecording),
        ]))
  }

  @Test
  func testScreenshotToolReturnsMCPImageAndStructuredPNG() async throws {
    let adapter = ProviderComputerUseAdapter(
      permissions: [.screenRecording: .granted]
    )
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x42])
    adapter.capture = ComputerUseCapturedImage(
      target: .window,
      sourceID: 88,
      width: 800,
      height: 600,
      pngData: png
    )
    let provider = ComputerUseGatewayProvider(service: ComputerUseService(adapter: adapter))
    let arguments: JSONValue = .object([
      "target": .string("window"),
      "window_id": .number(88),
      "max_width": .number(1_024),
      "max_height": .number(768),
      "max_bytes": .number(64 * 1_024),
      "shows_cursor": .bool(false),
    ])

    let response = try await provider.callToolAsync(
      name: "computer.screenshot",
      arguments: arguments
    )
    let result = structuredResult(response)
    let content = response.objectValue?["content"]?.arrayValue

    #expect((result.objectValue?["source_id"]) == (.number(88)))
    #expect((result.objectValue?["png_base64"]) == (.string(png.base64EncodedString())))
    #expect((content?.count) == (2))
    #expect((content?[1].objectValue?["type"]) == (.string("image")))
    #expect((content?[1].objectValue?["mimeType"]) == (.string("image/png")))
    #expect((content?[1].objectValue?["data"]) == (.string(png.base64EncodedString())))
    #expect(
      (adapter.calls)
        == ([
          .permission(.screenRecording),
          .capture(
            ComputerUseScreenshotRequest(
              target: .window,
              windowID: 88,
              maxWidth: 1_024,
              maxHeight: 768,
              maxBytes: 64 * 1_024,
              showsCursor: false
            )
          ),
        ]))
  }

  @Test
  func testScreenshotPermissionFailureHasStableCodeAndNoCapture() async {
    let adapter = ProviderComputerUseAdapter(
      permissions: [.screenRecording: .notGranted]
    )
    let provider = ComputerUseGatewayProvider(service: ComputerUseService(adapter: adapter))

    do {
      _ = try await provider.callToolAsync(
        name: "computer.screenshot",
        arguments: .object([:])
      )
      Issue.record("Expected screenshot permission failure.")
    } catch {
      guard let providerError = error as? ComputerUseGatewayProviderError else {
        Issue.record("Unexpected error: \(error)")
        return
      }
      #expect((providerError.code) == ("computer_use.permission_required"))
      #expect(providerError.localizedDescription.contains(providerError.code))
    }
    #expect((adapter.calls) == ([.permission(.screenRecording)]))
  }

  @Test
  func testPointerPositionReturnsReadOnlyObservationWithoutTCCPermission() throws {
    let adapter = ProviderComputerUseAdapter()
    adapter.pointer = ComputerUsePoint(x: 125, y: 250)
    let provider = ComputerUseGatewayProvider(service: ComputerUseService(adapter: adapter))

    let response = try provider.callTool(
      name: "computer.pointer.position",
      arguments: .object([:])
    )

    #expect(
      (structuredResult(response))
        == (.object([
          "x": .number(125),
          "y": .number(250),
        ])))
    #expect((adapter.calls) == ([.pointer]))
  }

  @Test
  func testPointerMoveDecodesSchemaAndReturnsActionResult() throws {
    let adapter = ProviderComputerUseAdapter(
      permissions: [.accessibility: .granted]
    )
    let provider = ComputerUseGatewayProvider(service: ComputerUseService(adapter: adapter))
    let point = ComputerUsePoint(x: 125, y: 250)

    let response = try provider.callTool(
      name: "computer.pointer.move",
      arguments: .object([
        "point": .object([
          "x": .number(point.x),
          "y": .number(point.y),
        ])
      ])
    )

    #expect((structuredResult(response).objectValue?["action"]) == (.string("pointer.move")))
    #expect(
      (adapter.calls)
        == ([
          .permission(.accessibility),
          .displays,
          .move(point),
        ]))
  }

  @Test
  func testAccessibilityQueryReturnsFlatPrimitiveValues() throws {
    let adapter = ProviderComputerUseAdapter(
      permissions: [.accessibility: .granted]
    )
    adapter.accessibilityResults = [
      ComputerUseAccessibilityObservation(
        reference: ComputerUseAccessibilityReference(processID: 42, childPath: [0]),
        role: "AXButton",
        title: "Continue",
        value: .bool(true),
        enabled: true,
        supportedActions: ["AXPress"]
      )
    ]
    let provider = ComputerUseGatewayProvider(service: ComputerUseService(adapter: adapter))

    let response = try provider.callTool(
      name: "computer.accessibility.query",
      arguments: .object([
        "process_id": .number(42),
        "role": .string("AXButton"),
      ])
    )
    let observations = structuredResult(response).arrayValue

    #expect((observations?.count) == (1))
    #expect((observations?[0].objectValue?["value"]) == (.bool(true)))
    #expect((observations?[0].objectValue?["supported_actions"]) == (.array([.string("AXPress")])))
  }

  @Test
  func testWindowToolDecodesBoundedMechanicalFilters() throws {
    let adapter = ProviderComputerUseAdapter(
      permissions: [.screenRecording: .granted]
    )
    let provider = ComputerUseGatewayProvider(service: ComputerUseService(adapter: adapter))
    let expectedQuery = ComputerUseWindowQuery(
      onScreenOnly: false,
      excludeDesktopElements: false,
      maxResults: 5,
      ownerProcessID: 1_433,
      ownerNameContains: "Safari",
      titleContains: "ChatGPT",
      layer: 0,
      minimumAlpha: 0.5,
      caseSensitive: true
    )

    _ = try provider.callTool(
      name: "computer.windows",
      arguments: .object([
        "on_screen_only": .bool(false),
        "exclude_desktop_elements": .bool(false),
        "max_results": .number(5),
        "owner_process_id": .number(1_433),
        "owner_name_contains": .string("Safari"),
        "title_contains": .string("ChatGPT"),
        "layer": .number(0),
        "minimum_alpha": .number(0.5),
        "case_sensitive": .bool(true),
      ])
    )

    #expect(
      (adapter.calls)
        == ([
          .permission(.screenRecording),
          .windows(expectedQuery),
        ]))
  }

  @Test
  func testVerifyToolReturnsMechanicalObservation() throws {
    let adapter = ProviderComputerUseAdapter()
    adapter.pointer = ComputerUsePoint(x: 10, y: 20)
    let provider = ComputerUseGatewayProvider(service: ComputerUseService(adapter: adapter))

    let response = try provider.callTool(
      name: "computer.verify",
      arguments: .object([
        "verification": .object([
          "type": .string("pointer-position"),
          "point": .object([
            "x": .number(10),
            "y": .number(20),
          ]),
          "tolerance": .number(0),
        ]),
        "policy": .object([
          "timeout_milliseconds": .number(0),
          "poll_interval_milliseconds": .number(1),
        ]),
      ])
    )
    let result = structuredResult(response)

    #expect((result.objectValue?["attempts"]) == (.number(1)))
    #expect(
      (result.objectValue?["observation"]?.objectValue?["type"]) == (.string("pointer-position")))
    #expect((adapter.calls) == ([.pointer]))
  }

  @Test
  func testInvalidArgumentsHaveStableCodeAndDoNotExecuteAdapter() throws {
    let adapter = ProviderComputerUseAdapter(
      permissions: [.accessibility: .granted]
    )
    let provider = ComputerUseGatewayProvider(service: ComputerUseService(adapter: adapter))

    expectThrows(
      try provider.callTool(
        name: "computer.pointer.click",
        arguments: .object(["button": .string("primary")])
      )
    ) { error in
      guard let providerError = error as? ComputerUseGatewayProviderError else {
        Issue.record("Unexpected error: \(error)")
        return
      }
      #expect((providerError.code) == ("computer_use.invalid_arguments"))
      #expect(providerError.localizedDescription.contains(providerError.code))
    }
    #expect((adapter.calls) == ([]))
  }

  private func structuredResult(
    _ response: JSONValue,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> JSONValue {
    guard
      let value = response.objectValue?["structuredContent"]?.objectValue?["result"]
    else {
      Issue.record("Missing structuredContent.result")
      return .null
    }
    return value
  }
}

private final class ProviderComputerUseAdapter: ComputerUseAdapter, @unchecked Sendable {
  enum Call: Equatable {
    case permission(ComputerUsePermission)
    case displays
    case windows(ComputerUseWindowQuery)
    case capture(ComputerUseScreenshotRequest)
    case pointer
    case move(ComputerUsePoint)
    case click(ComputerUsePointerButton, ComputerUsePoint, Int)
    case key(UInt16, Set<ComputerUseKeyModifier>, Int)
    case text(String)
    case scroll(Int32, Int32, ComputerUseScrollUnit, ComputerUsePoint?)
    case accessibilityQuery(ComputerUseAccessibilityQuery)
    case accessibilityAttribute(
      ComputerUseAccessibilityReference,
      ComputerUseAccessibilityAttribute
    )
    case accessibilityAction(
      ComputerUseAccessibilityAction,
      ComputerUseAccessibilityReference
    )
    case frontmostApplication
  }

  private let permissions: [ComputerUsePermission: ComputerUsePermissionStatus]
  var calls: [Call] = []
  var pointer = ComputerUsePoint(x: 100, y: 100)
  var accessibilityResults: [ComputerUseAccessibilityObservation] = []
  var attribute: ComputerUseAccessibilityValue = .null
  var application: ComputerUseApplicationObservation?
  var capture = ComputerUseCapturedImage(
    target: .display,
    sourceID: 1,
    width: 64,
    height: 64,
    pngData: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
  )

  init(
    permissions: [ComputerUsePermission: ComputerUsePermissionStatus] = [:]
  ) {
    self.permissions = permissions
  }

  func permissionStatus(_ permission: ComputerUsePermission) -> ComputerUsePermissionStatus {
    calls.append(.permission(permission))
    return permissions[permission] ?? .notGranted
  }

  func observeDisplays() throws -> [ComputerUseDisplayObservation] {
    calls.append(.displays)
    return [
      ComputerUseDisplayObservation(
        id: 1,
        bounds: ComputerUseRect(x: 0, y: 0, width: 1_000, height: 800),
        pixelWidth: 2_000,
        pixelHeight: 1_600,
        scaleFactor: 2,
        rotationDegrees: 0,
        physicalSizeMillimeters: ComputerUseSize(width: 300, height: 200),
        isMain: true
      )
    ]
  }

  func observeWindows(
    _ query: ComputerUseWindowQuery
  ) throws -> [ComputerUseWindowObservation] {
    calls.append(.windows(query))
    return []
  }

  func captureScreenshot(
    _ request: ComputerUseScreenshotRequest
  ) async throws -> ComputerUseCapturedImage {
    calls.append(.capture(request))
    return capture
  }

  func currentPointerLocation() throws -> ComputerUsePoint {
    calls.append(.pointer)
    return pointer
  }

  func movePointer(to point: ComputerUsePoint) throws {
    calls.append(.move(point))
  }

  func clickPointer(
    button: ComputerUsePointerButton,
    at point: ComputerUsePoint,
    clickCount: Int
  ) throws {
    calls.append(.click(button, point, clickCount))
  }

  func pressKey(
    keyCode: UInt16,
    modifiers: Set<ComputerUseKeyModifier>,
    repeatCount: Int
  ) throws {
    calls.append(.key(keyCode, modifiers, repeatCount))
  }

  func typeText(_ text: String) throws {
    calls.append(.text(text))
  }

  func scroll(
    deltaX: Int32,
    deltaY: Int32,
    unit: ComputerUseScrollUnit,
    at point: ComputerUsePoint?
  ) throws {
    calls.append(.scroll(deltaX, deltaY, unit, point))
  }

  func queryAccessibility(
    _ query: ComputerUseAccessibilityQuery
  ) throws -> [ComputerUseAccessibilityObservation] {
    calls.append(.accessibilityQuery(query))
    return accessibilityResults
  }

  func accessibilityAttribute(
    of reference: ComputerUseAccessibilityReference,
    attribute: ComputerUseAccessibilityAttribute
  ) throws -> ComputerUseAccessibilityValue {
    calls.append(.accessibilityAttribute(reference, attribute))
    return self.attribute
  }

  func performAccessibilityAction(
    _ action: ComputerUseAccessibilityAction,
    on reference: ComputerUseAccessibilityReference
  ) throws {
    calls.append(.accessibilityAction(action, reference))
  }

  func frontmostApplication() -> ComputerUseApplicationObservation? {
    calls.append(.frontmostApplication)
    return application
  }
}
