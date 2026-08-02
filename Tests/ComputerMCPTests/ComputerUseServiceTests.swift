import Foundation
import Testing

@testable import ComputerMCP

@Suite

final class ComputerUseServiceTests {
  @Test
  func testPermissionSnapshotOnlyReadsCurrentStatus() {
    let adapter = FakeComputerUseAdapter(
      permissions: [
        .accessibility: .granted,
        .screenRecording: .notGranted,
      ]
    )
    let service = ComputerUseService(adapter: adapter)

    #expect(
      (service.permissionSnapshot())
        == (ComputerUsePermissionSnapshot(
          accessibility: .granted,
          screenRecording: .notGranted
        )))
    #expect(
      (adapter.calls)
        == ([
          .permissionStatus(.accessibility),
          .permissionStatus(.screenRecording),
        ]))
  }

  @Test
  func testDeniedAccessibilityFailsClosedBeforePointerAction() {
    let adapter = FakeComputerUseAdapter(permissions: [.accessibility: .notGranted])
    let service = ComputerUseService(adapter: adapter)

    expectThrows(
      try service.movePointer(to: ComputerUsePoint(x: 100, y: 100))
    ) { error in
      #expect((error as? ComputerUseError) == (.permissionRequired(.accessibility)))
    }
    #expect((adapter.calls) == ([.permissionStatus(.accessibility)]))
  }

  @Test
  func testDeniedScreenRecordingFailsClosedBeforeWindowObservation() {
    let adapter = FakeComputerUseAdapter(permissions: [.screenRecording: .notGranted])
    let service = ComputerUseService(adapter: adapter)

    expectThrows(try service.observeWindows()) { error in
      #expect((error as? ComputerUseError) == (.permissionRequired(.screenRecording)))
    }
    #expect((adapter.calls) == ([.permissionStatus(.screenRecording)]))
  }

  @Test
  func testDisplayObservationDoesNotRequireTCCPermission() throws {
    let adapter = FakeComputerUseAdapter(permissions: [:])
    let service = ComputerUseService(adapter: adapter)

    #expect((try service.observeDisplays()) == ([FakeComputerUseAdapter.display]))
    #expect((adapter.calls) == ([.observeDisplays]))
  }

  @Test
  func testAllowedWindowObservationUsesBoundedQuery() throws {
    let adapter = FakeComputerUseAdapter(permissions: [.screenRecording: .granted])
    let service = ComputerUseService(adapter: adapter)
    let query = ComputerUseWindowQuery(
      onScreenOnly: false,
      excludeDesktopElements: false,
      maxResults: 25
    )

    #expect((try service.observeWindows(query)) == ([FakeComputerUseAdapter.window]))
    #expect(
      (adapter.calls)
        == ([
          .permissionStatus(.screenRecording),
          .observeWindows(query),
        ]))
  }

  @Test
  func testInvalidWindowQueryDoesNotTouchAdapter() {
    let adapter = FakeComputerUseAdapter(permissions: [.screenRecording: .granted])
    let service = ComputerUseService(adapter: adapter)

    expectThrows(
      try service.observeWindows(ComputerUseWindowQuery(maxResults: 0))
    ) { error in
      assertInvalidArgument(error, field: "max_results")
    }
    #expect((adapter.calls) == ([]))
  }

  @Test
  func testWindowObservationAppliesMechanicalFiltersBeforeBoundingResults() throws {
    let adapter = FakeComputerUseAdapter(permissions: [.screenRecording: .granted])
    let safariWindow = ComputerUseWindowObservation(
      id: 11,
      ownerProcessID: 43,
      ownerName: "Safari",
      title: "Computer MCP",
      bounds: ComputerUseRect(x: 20, y: 20, width: 600, height: 500),
      layer: 0,
      alpha: 1,
      isOnScreen: true
    )
    adapter.windows = [FakeComputerUseAdapter.window, safariWindow]
    let service = ComputerUseService(adapter: adapter)
    let query = ComputerUseWindowQuery(
      maxResults: 1,
      ownerNameContains: "saf",
      titleContains: "mcp",
      layer: 0,
      minimumAlpha: 0.5
    )

    #expect((try service.observeWindows(query)) == ([safariWindow]))
    #expect(
      (adapter.calls)
        == ([
          .permissionStatus(.screenRecording),
          .observeWindows(query),
        ]))
  }

  @Test
  func testInvalidWindowFiltersDoNotTouchAdapter() {
    let adapter = FakeComputerUseAdapter(permissions: [.screenRecording: .granted])
    let service = ComputerUseService(adapter: adapter)

    expectThrows(
      try service.observeWindows(
        ComputerUseWindowQuery(ownerNameContains: "")
      )
    ) { error in
      assertInvalidArgument(error, field: "owner_name_contains")
    }
    expectThrows(
      try service.observeWindows(
        ComputerUseWindowQuery(minimumAlpha: 2)
      )
    ) { error in
      assertInvalidArgument(error, field: "minimum_alpha")
    }
    #expect((adapter.calls) == ([]))
  }

  @Test
  func testDeniedScreenRecordingFailsClosedBeforeScreenshotCapture() async {
    let adapter = FakeComputerUseAdapter(permissions: [.screenRecording: .notGranted])
    let service = ComputerUseService(adapter: adapter)

    do {
      _ = try await service.captureScreenshot()
      Issue.record("Expected screenshot permission failure.")
    } catch {
      #expect((error as? ComputerUseError) == (.permissionRequired(.screenRecording)))
    }
    #expect((adapter.calls) == ([.permissionStatus(.screenRecording)]))
  }

  @Test
  func testScreenshotRequestIsValidatedBeforePermissionCheck() async {
    let adapter = FakeComputerUseAdapter(permissions: [.screenRecording: .granted])
    let service = ComputerUseService(adapter: adapter)

    do {
      _ = try await service.captureScreenshot(
        ComputerUseScreenshotRequest(target: .window, windowID: nil)
      )
      Issue.record("Expected screenshot request validation failure.")
    } catch {
      assertInvalidArgument(error, field: "window_id")
    }
    #expect((adapter.calls) == ([]))
  }

  @Test
  func testScreenshotReturnsBoundedPNGFromAdapter() async throws {
    let adapter = FakeComputerUseAdapter(permissions: [.screenRecording: .granted])
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
    adapter.capturedImage = ComputerUseCapturedImage(
      target: .window,
      sourceID: 10,
      width: 640,
      height: 480,
      pngData: png
    )
    let service = ComputerUseService(adapter: adapter)
    let request = ComputerUseScreenshotRequest(
      target: .window,
      windowID: 10,
      maxWidth: 1_024,
      maxHeight: 768,
      maxBytes: 64 * 1_024,
      showsCursor: false
    )

    let result = try await service.captureScreenshot(request)

    #expect(
      (result)
        == (ComputerUseScreenshotObservation(
          target: .window,
          sourceID: 10,
          width: 640,
          height: 480,
          byteCount: png.count,
          pngBase64: png.base64EncodedString()
        )))
    #expect(
      (adapter.calls)
        == ([
          .permissionStatus(.screenRecording),
          .captureScreenshot(request),
        ]))
  }

  @Test
  func testScreenshotRejectsAdapterOutputThatExceedsRequestedBytes() async {
    let adapter = FakeComputerUseAdapter(permissions: [.screenRecording: .granted])
    adapter.capturedImage = ComputerUseCapturedImage(
      target: .display,
      sourceID: 1,
      width: 64,
      height: 64,
      pngData: Data(repeating: 0, count: 32 * 1_024 + 1)
    )
    let service = ComputerUseService(adapter: adapter)

    do {
      _ = try await service.captureScreenshot(
        ComputerUseScreenshotRequest(
          maxWidth: 64,
          maxHeight: 64,
          maxBytes: 32 * 1_024
        )
      )
      Issue.record("Expected screenshot byte limit failure.")
    } catch {
      #expect(
        (error as? ComputerUseError)
          == (.screenshotTooLarge(actualBytes: 32 * 1_024 + 1, maximumBytes: 32 * 1_024)))
    }
  }

  @Test
  func testPointerCoordinatesAndClickCountAreBounded() {
    let adapter = FakeComputerUseAdapter(permissions: [.accessibility: .granted])
    let service = ComputerUseService(adapter: adapter)

    expectThrows(
      try service.movePointer(to: ComputerUsePoint(x: .infinity, y: 0))
    ) { error in
      assertInvalidArgument(error, field: "point")
    }
    expectThrows(
      try service.clickPointer(
        button: .left,
        at: ComputerUsePoint(x: 10, y: 10),
        clickCount: 4
      )
    ) { error in
      assertInvalidArgument(error, field: "click_count")
    }
    #expect((adapter.calls) == ([]))
  }

  @Test
  func testPointOutsideActiveDisplaysDoesNotInjectInput() {
    let adapter = FakeComputerUseAdapter(permissions: [.accessibility: .granted])
    let service = ComputerUseService(adapter: adapter)
    let point = ComputerUsePoint(x: 2_000, y: 2_000)

    expectThrows(try service.movePointer(to: point)) { error in
      #expect((error as? ComputerUseError) == (.pointOutsideDisplays(point)))
    }
    #expect(
      (adapter.calls)
        == ([
          .permissionStatus(.accessibility),
          .observeDisplays,
        ]))
  }

  @Test
  func testAllowedPointerMoveCanVerifyObservedPosition() throws {
    let point = ComputerUsePoint(x: 400, y: 300)
    let adapter = FakeComputerUseAdapter(permissions: [.accessibility: .granted])
    adapter.pointerLocationAfterMove = point
    let service = ComputerUseService(adapter: adapter)

    let result = try service.movePointer(
      to: point,
      verification: .pointerPosition(expected: point, tolerance: 0.5),
      verificationPolicy: ComputerUseVerificationPolicy(
        timeoutMilliseconds: 0,
        pollIntervalMilliseconds: 1
      )
    )

    #expect(
      (result)
        == (ComputerUseActionResult(
          action: .pointerMove,
          verification: ComputerUseVerificationResult(
            attempts: 1,
            observation: .pointerPosition(point)
          )
        )))
    #expect(
      (adapter.calls)
        == ([
          .permissionStatus(.accessibility),
          .observeDisplays,
          .movePointer(point),
          .currentPointerLocation,
        ]))
  }

  @Test
  func testFailedVerificationReportsLastMechanicalObservation() {
    let expected = ComputerUsePoint(x: 400, y: 300)
    let actual = ComputerUsePoint(x: 401, y: 305)
    let adapter = FakeComputerUseAdapter(permissions: [.accessibility: .granted])
    adapter.pointerLocationAfterMove = actual
    let service = ComputerUseService(adapter: adapter)

    expectThrows(
      try service.movePointer(
        to: expected,
        verification: .pointerPosition(expected: expected, tolerance: 1),
        verificationPolicy: ComputerUseVerificationPolicy(
          timeoutMilliseconds: 0,
          pollIntervalMilliseconds: 1
        )
      )
    ) { error in
      #expect(
        (error as? ComputerUseError)
          == (.verificationFailed(
            expected: "pointer at (400.0, 300.0) within 1.0 points",
            actual: .pointerPosition(actual),
            attempts: 1
          )))
    }
    #expect((adapter.actionCallCount) == (1))
  }

  @Test
  func testKeyboardAndTextParametersAreBoundedWithoutExecution() {
    let adapter = FakeComputerUseAdapter(permissions: [.accessibility: .granted])
    let service = ComputerUseService(adapter: adapter)

    expectThrows(try service.pressKey(keyCode: 128)) { error in
      assertInvalidArgument(error, field: "key_code")
    }
    expectThrows(try service.pressKey(keyCode: 0, repeatCount: 0)) { error in
      assertInvalidArgument(error, field: "repeat_count")
    }
    expectThrows(try service.typeText("")) { error in
      assertInvalidArgument(error, field: "text")
    }
    expectThrows(try service.typeText(String(repeating: "a", count: 4_097))) {
      error in
      assertInvalidArgument(error, field: "text")
    }
    #expect((adapter.calls) == ([]))
  }

  @Test
  func testScrollParametersAreBoundedWithoutExecution() {
    let adapter = FakeComputerUseAdapter(permissions: [.accessibility: .granted])
    let service = ComputerUseService(adapter: adapter)

    expectThrows(try service.scroll(deltaX: 0, deltaY: 0)) { error in
      assertInvalidArgument(error, field: "delta")
    }
    expectThrows(try service.scroll(deltaX: 10_001, deltaY: 0)) { error in
      assertInvalidArgument(error, field: "delta")
    }
    #expect((adapter.calls) == ([]))
  }

  @Test
  func testAllowedInputActionsForwardTypedValues() throws {
    let point = ComputerUsePoint(x: 50, y: 75)
    let adapter = FakeComputerUseAdapter(permissions: [.accessibility: .granted])
    adapter.pointerLocationAfterMove = point
    let service = ComputerUseService(adapter: adapter)

    _ = try service.clickPointer(button: .right, clickCount: 2)
    _ = try service.pressKey(
      keyCode: 12,
      modifiers: [.command, .shift],
      repeatCount: 2
    )
    _ = try service.typeText("hello")
    _ = try service.scroll(deltaX: -10, deltaY: 20, unit: .line, at: point)

    #expect(
      (adapter.calls)
        == ([
          .permissionStatus(.accessibility),
          .currentPointerLocation,
          .observeDisplays,
          .clickPointer(.right, point, 2),
          .permissionStatus(.accessibility),
          .pressKey(12, [.command, .shift], 2),
          .permissionStatus(.accessibility),
          .typeText("hello"),
          .permissionStatus(.accessibility),
          .observeDisplays,
          .scroll(-10, 20, .line, point),
        ]))
  }

  @Test
  func testAccessibilityQueryValidatesAndChecksPermissionBeforeAdapter() {
    let invalidAdapter = FakeComputerUseAdapter(permissions: [.accessibility: .granted])
    let invalidService = ComputerUseService(adapter: invalidAdapter)
    expectThrows(
      try invalidService.queryAccessibility(
        ComputerUseAccessibilityQuery(processID: 0)
      )
    ) { error in
      assertInvalidArgument(error, field: "process_id")
    }
    #expect((invalidAdapter.calls) == ([]))

    let deniedAdapter = FakeComputerUseAdapter(permissions: [.accessibility: .notGranted])
    let deniedService = ComputerUseService(adapter: deniedAdapter)
    expectThrows(
      try deniedService.queryAccessibility(
        ComputerUseAccessibilityQuery(processID: 42)
      )
    ) { error in
      #expect((error as? ComputerUseError) == (.permissionRequired(.accessibility)))
    }
    #expect((deniedAdapter.calls) == ([.permissionStatus(.accessibility)]))
  }

  @Test
  func testAllowedAccessibilityQueryReturnsAdapterObservations() throws {
    let adapter = FakeComputerUseAdapter(permissions: [.accessibility: .granted])
    let reference = ComputerUseAccessibilityReference(processID: 42, childPath: [1])
    let observation = ComputerUseAccessibilityObservation(
      reference: reference,
      role: "AXButton",
      title: "Continue",
      enabled: true,
      supportedActions: ["AXPress"]
    )
    adapter.accessibilityResults = [observation]
    let service = ComputerUseService(adapter: adapter)
    let query = ComputerUseAccessibilityQuery(
      processID: 42,
      role: "AXButton",
      titleContains: "Continue"
    )

    #expect((try service.queryAccessibility(query)) == ([observation]))
    #expect(
      (adapter.calls)
        == ([
          .permissionStatus(.accessibility),
          .queryAccessibility(query),
        ]))
  }

  @Test
  func testAccessibilityActionCanVerifyTypedAttribute() throws {
    let adapter = FakeComputerUseAdapter(permissions: [.accessibility: .granted])
    let service = ComputerUseService(adapter: adapter)
    let reference = ComputerUseAccessibilityReference(processID: 42, childPath: [0, 2])
    adapter.attributeValue = .bool(true)

    let result = try service.performAccessibilityAction(
      .press,
      on: reference,
      verification: .accessibilityAttribute(
        reference: reference,
        attribute: .enabled,
        expected: .bool(true)
      ),
      verificationPolicy: ComputerUseVerificationPolicy(
        timeoutMilliseconds: 0,
        pollIntervalMilliseconds: 1
      )
    )

    #expect((result.action) == (.accessibilityAction))
    #expect(
      (result.verification)
        == (ComputerUseVerificationResult(
          attempts: 1,
          observation: .accessibilityAttribute(.bool(true))
        )))
    #expect(
      (adapter.calls)
        == ([
          .permissionStatus(.accessibility),
          .performAccessibilityAction(.press, reference),
          .accessibilityAttribute(reference, .enabled),
        ]))
  }

  private func assertInvalidArgument(
    _ error: Error,
    field: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard
      let computerUseError = error as? ComputerUseError,
      case .invalidArgument(let actualField, _) = computerUseError
    else {
      Issue.record("Expected invalid argument, got \(error)")
      return
    }
    #expect((actualField) == (field))
  }
}

private final class FakeComputerUseAdapter: ComputerUseAdapter, @unchecked Sendable {
  enum Call: Equatable {
    case permissionStatus(ComputerUsePermission)
    case observeDisplays
    case observeWindows(ComputerUseWindowQuery)
    case captureScreenshot(ComputerUseScreenshotRequest)
    case currentPointerLocation
    case movePointer(ComputerUsePoint)
    case clickPointer(ComputerUsePointerButton, ComputerUsePoint, Int)
    case pressKey(UInt16, Set<ComputerUseKeyModifier>, Int)
    case typeText(String)
    case scroll(Int32, Int32, ComputerUseScrollUnit, ComputerUsePoint?)
    case queryAccessibility(ComputerUseAccessibilityQuery)
    case accessibilityAttribute(
      ComputerUseAccessibilityReference,
      ComputerUseAccessibilityAttribute
    )
    case performAccessibilityAction(
      ComputerUseAccessibilityAction,
      ComputerUseAccessibilityReference
    )
    case frontmostApplication
  }

  static let display = ComputerUseDisplayObservation(
    id: 1,
    bounds: ComputerUseRect(x: 0, y: 0, width: 1_000, height: 800),
    pixelWidth: 2_000,
    pixelHeight: 1_600,
    scaleFactor: 2,
    rotationDegrees: 0,
    physicalSizeMillimeters: ComputerUseSize(width: 300, height: 200),
    isMain: true
  )

  static let window = ComputerUseWindowObservation(
    id: 10,
    ownerProcessID: 42,
    ownerName: "Fixture",
    title: "Fixture Window",
    bounds: ComputerUseRect(x: 10, y: 10, width: 500, height: 400),
    layer: 0,
    alpha: 1,
    isOnScreen: true
  )

  private let permissions: [ComputerUsePermission: ComputerUsePermissionStatus]
  var calls: [Call] = []
  var windows = [FakeComputerUseAdapter.window]
  var pointerLocationAfterMove = ComputerUsePoint(x: 0, y: 0)
  var attributeValue: ComputerUseAccessibilityValue = .null
  var accessibilityResults: [ComputerUseAccessibilityObservation] = []
  var application: ComputerUseApplicationObservation?
  var capturedImage = ComputerUseCapturedImage(
    target: .display,
    sourceID: 1,
    width: 64,
    height: 64,
    pngData: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
  )

  var actionCallCount: Int {
    calls.filter {
      switch $0 {
      case .movePointer, .clickPointer, .pressKey, .typeText, .scroll,
        .performAccessibilityAction:
        true
      default:
        false
      }
    }.count
  }

  init(permissions: [ComputerUsePermission: ComputerUsePermissionStatus]) {
    self.permissions = permissions
  }

  func permissionStatus(_ permission: ComputerUsePermission) -> ComputerUsePermissionStatus {
    calls.append(.permissionStatus(permission))
    return permissions[permission] ?? .notGranted
  }

  func observeDisplays() throws -> [ComputerUseDisplayObservation] {
    calls.append(.observeDisplays)
    return [Self.display]
  }

  func observeWindows(
    _ query: ComputerUseWindowQuery
  ) throws -> [ComputerUseWindowObservation] {
    calls.append(.observeWindows(query))
    return windows
  }

  func captureScreenshot(
    _ request: ComputerUseScreenshotRequest
  ) async throws -> ComputerUseCapturedImage {
    calls.append(.captureScreenshot(request))
    return capturedImage
  }

  func currentPointerLocation() throws -> ComputerUsePoint {
    calls.append(.currentPointerLocation)
    return pointerLocationAfterMove
  }

  func movePointer(to point: ComputerUsePoint) throws {
    calls.append(.movePointer(point))
  }

  func clickPointer(
    button: ComputerUsePointerButton,
    at point: ComputerUsePoint,
    clickCount: Int
  ) throws {
    calls.append(.clickPointer(button, point, clickCount))
  }

  func pressKey(
    keyCode: UInt16,
    modifiers: Set<ComputerUseKeyModifier>,
    repeatCount: Int
  ) throws {
    calls.append(.pressKey(keyCode, modifiers, repeatCount))
  }

  func typeText(_ text: String) throws {
    calls.append(.typeText(text))
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
    calls.append(.queryAccessibility(query))
    return accessibilityResults
  }

  func accessibilityAttribute(
    of reference: ComputerUseAccessibilityReference,
    attribute: ComputerUseAccessibilityAttribute
  ) throws -> ComputerUseAccessibilityValue {
    calls.append(.accessibilityAttribute(reference, attribute))
    return attributeValue
  }

  func performAccessibilityAction(
    _ action: ComputerUseAccessibilityAction,
    on reference: ComputerUseAccessibilityReference
  ) throws {
    calls.append(.performAccessibilityAction(action, reference))
  }

  func frontmostApplication() -> ComputerUseApplicationObservation? {
    calls.append(.frontmostApplication)
    return application
  }
}
