@preconcurrency import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

internal enum ComputerUsePermission: String, Codable, CaseIterable, Sendable {
  case accessibility
  case screenRecording = "screen-recording"
}

package enum ComputerUsePermissionStatus: String, Codable, Sendable {
  case granted
  case notGranted = "not-granted"
}

package struct ComputerUsePermissionSnapshot: Codable, Equatable, Sendable {
  package var accessibility: ComputerUsePermissionStatus
  package var screenRecording: ComputerUsePermissionStatus

  package init(
    accessibility: ComputerUsePermissionStatus,
    screenRecording: ComputerUsePermissionStatus
  ) {
    self.accessibility = accessibility
    self.screenRecording = screenRecording
  }
}

internal struct ComputerUsePoint: Codable, Equatable, Sendable {
  internal var x: Double
  internal var y: Double

  internal init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }

  fileprivate var cgPoint: CGPoint {
    CGPoint(x: x, y: y)
  }
}

internal struct ComputerUseSize: Codable, Equatable, Sendable {
  internal var width: Double
  internal var height: Double
}

internal struct ComputerUseRect: Codable, Equatable, Sendable {
  internal var origin: ComputerUsePoint
  internal var size: ComputerUseSize

  internal init(origin: ComputerUsePoint, size: ComputerUseSize) {
    self.origin = origin
    self.size = size
  }

  internal init(x: Double, y: Double, width: Double, height: Double) {
    self.init(
      origin: ComputerUsePoint(x: x, y: y),
      size: ComputerUseSize(width: width, height: height)
    )
  }

  internal func contains(_ point: ComputerUsePoint) -> Bool {
    guard size.width > 0, size.height > 0 else {
      return false
    }
    return point.x >= origin.x && point.x < origin.x + size.width
      && point.y >= origin.y && point.y < origin.y + size.height
  }
}

internal struct ComputerUseDisplayObservation: Codable, Equatable, Sendable {
  internal var id: UInt32
  internal var bounds: ComputerUseRect
  internal var pixelWidth: Int
  internal var pixelHeight: Int
  internal var scaleFactor: Double
  internal var rotationDegrees: Double
  internal var physicalSizeMillimeters: ComputerUseSize
  internal var isMain: Bool

}

internal struct ComputerUseWindowQuery: Codable, Equatable, Sendable {
  internal var onScreenOnly: Bool
  internal var excludeDesktopElements: Bool
  internal var maxResults: Int
  internal var ownerProcessID: Int32?
  internal var ownerNameContains: String?
  internal var titleContains: String?
  internal var layer: Int?
  internal var minimumAlpha: Double?
  internal var caseSensitive: Bool

  internal init(
    onScreenOnly: Bool = true,
    excludeDesktopElements: Bool = true,
    maxResults: Int = 10,
    ownerProcessID: Int32? = nil,
    ownerNameContains: String? = nil,
    titleContains: String? = nil,
    layer: Int? = nil,
    minimumAlpha: Double? = nil,
    caseSensitive: Bool = false
  ) {
    self.onScreenOnly = onScreenOnly
    self.excludeDesktopElements = excludeDesktopElements
    self.maxResults = maxResults
    self.ownerProcessID = ownerProcessID
    self.ownerNameContains = ownerNameContains
    self.titleContains = titleContains
    self.layer = layer
    self.minimumAlpha = minimumAlpha
    self.caseSensitive = caseSensitive
  }

  fileprivate func matches(_ window: ComputerUseWindowObservation) -> Bool {
    if let ownerProcessID, window.ownerProcessID != ownerProcessID {
      return false
    }
    if let ownerNameContains,
      !contains(window.ownerName, substring: ownerNameContains)
    {
      return false
    }
    if let titleContains, !contains(window.title, substring: titleContains) {
      return false
    }
    if let layer, window.layer != layer {
      return false
    }
    if let minimumAlpha, window.alpha < minimumAlpha {
      return false
    }
    return true
  }

  private func contains(_ value: String?, substring: String) -> Bool {
    guard let value else { return false }
    if caseSensitive {
      return value.contains(substring)
    }
    return value.range(
      of: substring,
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    ) != nil
  }
}

internal struct ComputerUseWindowObservation: Codable, Equatable, Sendable {
  internal var id: UInt32
  internal var ownerProcessID: Int32
  internal var ownerName: String?
  internal var title: String?
  internal var bounds: ComputerUseRect
  internal var layer: Int
  internal var alpha: Double
  internal var isOnScreen: Bool
  internal var memoryBytes: UInt64?
  internal var sharingState: UInt32?

  internal init(
    id: UInt32,
    ownerProcessID: Int32,
    ownerName: String?,
    title: String?,
    bounds: ComputerUseRect,
    layer: Int,
    alpha: Double,
    isOnScreen: Bool,
    memoryBytes: UInt64? = nil,
    sharingState: UInt32? = nil
  ) {
    self.id = id
    self.ownerProcessID = ownerProcessID
    self.ownerName = ownerName
    self.title = title
    self.bounds = bounds
    self.layer = layer
    self.alpha = alpha
    self.isOnScreen = isOnScreen
    self.memoryBytes = memoryBytes
    self.sharingState = sharingState
  }
}

internal enum ComputerUseScreenshotTarget: String, Codable, Sendable {
  case display
  case window
}

internal struct ComputerUseScreenshotRequest: Codable, Equatable, Sendable {
  internal var target: ComputerUseScreenshotTarget
  internal var displayID: UInt32?
  internal var windowID: UInt32?
  internal var maxWidth: Int
  internal var maxHeight: Int
  internal var maxBytes: Int
  internal var showsCursor: Bool

  internal init(
    target: ComputerUseScreenshotTarget = .display,
    displayID: UInt32? = nil,
    windowID: UInt32? = nil,
    maxWidth: Int = 2_560,
    maxHeight: Int = 1_600,
    maxBytes: Int = 8 * 1_024 * 1_024,
    showsCursor: Bool = true
  ) {
    self.target = target
    self.displayID = displayID
    self.windowID = windowID
    self.maxWidth = maxWidth
    self.maxHeight = maxHeight
    self.maxBytes = maxBytes
    self.showsCursor = showsCursor
  }
}

internal struct ComputerUseCapturedImage: Equatable, Sendable {
  internal var target: ComputerUseScreenshotTarget
  internal var sourceID: UInt32
  internal var width: Int
  internal var height: Int
  internal var pngData: Data

}

internal struct ComputerUseScreenshotObservation: Codable, Equatable, Sendable {
  internal var target: ComputerUseScreenshotTarget
  internal var sourceID: UInt32
  internal var width: Int
  internal var height: Int
  internal var byteCount: Int
  internal var mimeType: String
  internal var pngBase64: String

  internal init(
    target: ComputerUseScreenshotTarget,
    sourceID: UInt32,
    width: Int,
    height: Int,
    byteCount: Int,
    mimeType: String = "image/png",
    pngBase64: String
  ) {
    self.target = target
    self.sourceID = sourceID
    self.width = width
    self.height = height
    self.byteCount = byteCount
    self.mimeType = mimeType
    self.pngBase64 = pngBase64
  }
}

internal enum ComputerUsePointerButton: String, Codable, Sendable {
  case left
  case right
  case center
}

internal enum ComputerUseKeyModifier: String, Codable, Hashable, Sendable {
  case command
  case control
  case option
  case shift
  case function
}

internal enum ComputerUseScrollUnit: String, Codable, Sendable {
  case line
  case pixel
}

internal enum ComputerUseAccessibilityAttribute: String, Codable, CaseIterable, Sendable {
  case role = "AXRole"
  case subrole = "AXSubrole"
  case title = "AXTitle"
  case value = "AXValue"
  case elementDescription = "AXDescription"
  case identifier = "AXIdentifier"
  case enabled = "AXEnabled"
  case focused = "AXFocused"
}

internal enum ComputerUseAccessibilityAction: String, Codable, CaseIterable, Sendable {
  case press = "AXPress"
  case increment = "AXIncrement"
  case decrement = "AXDecrement"
  case confirm = "AXConfirm"
  case cancel = "AXCancel"
  case showMenu = "AXShowMenu"
  case raise = "AXRaise"
  case pick = "AXPick"
}

internal enum ComputerUseAccessibilityValue: Codable, Equatable, Sendable {
  case string(String)
  case bool(Bool)
  case number(Double)
  case null
}

internal struct ComputerUseAccessibilityReference: Codable, Equatable, Hashable, Sendable {
  internal var processID: Int32
  internal var childPath: [Int]
}

internal struct ComputerUseAccessibilityQuery: Codable, Equatable, Sendable {
  internal var processID: Int32
  internal var role: String?
  internal var titleContains: String?
  internal var identifier: String?
  internal var valueContains: String?
  internal var enabled: Bool?
  internal var focused: Bool?
  internal var caseSensitive: Bool
  internal var maxDepth: Int
  internal var maxResults: Int
  internal var maxScannedElements: Int

  internal init(
    processID: Int32,
    role: String? = nil,
    titleContains: String? = nil,
    identifier: String? = nil,
    valueContains: String? = nil,
    enabled: Bool? = nil,
    focused: Bool? = nil,
    caseSensitive: Bool = false,
    maxDepth: Int = 12,
    maxResults: Int = 100,
    maxScannedElements: Int = 5_000
  ) {
    self.processID = processID
    self.role = role
    self.titleContains = titleContains
    self.identifier = identifier
    self.valueContains = valueContains
    self.enabled = enabled
    self.focused = focused
    self.caseSensitive = caseSensitive
    self.maxDepth = maxDepth
    self.maxResults = maxResults
    self.maxScannedElements = maxScannedElements
  }
}

internal struct ComputerUseAccessibilityObservation: Codable, Equatable, Sendable {
  internal var reference: ComputerUseAccessibilityReference
  internal var role: String?
  internal var subrole: String?
  internal var title: String?
  internal var value: ComputerUseAccessibilityValue?
  internal var elementDescription: String?
  internal var identifier: String?
  internal var enabled: Bool?
  internal var focused: Bool?
  internal var frame: ComputerUseRect?
  internal var supportedActions: [String]

  internal init(
    reference: ComputerUseAccessibilityReference,
    role: String? = nil,
    subrole: String? = nil,
    title: String? = nil,
    value: ComputerUseAccessibilityValue? = nil,
    elementDescription: String? = nil,
    identifier: String? = nil,
    enabled: Bool? = nil,
    focused: Bool? = nil,
    frame: ComputerUseRect? = nil,
    supportedActions: [String] = []
  ) {
    self.reference = reference
    self.role = role
    self.subrole = subrole
    self.title = title
    self.value = value
    self.elementDescription = elementDescription
    self.identifier = identifier
    self.enabled = enabled
    self.focused = focused
    self.frame = frame
    self.supportedActions = supportedActions
  }
}

internal struct ComputerUseApplicationObservation: Codable, Equatable, Sendable {
  internal var processID: Int32
  internal var bundleIdentifier: String?
  internal var localizedName: String?
}

internal enum ComputerUseVerification: Codable, Equatable, Sendable {
  case pointerPosition(expected: ComputerUsePoint, tolerance: Double)
  case accessibilityAttribute(
    reference: ComputerUseAccessibilityReference,
    attribute: ComputerUseAccessibilityAttribute,
    expected: ComputerUseAccessibilityValue
  )
  case accessibilityElementCount(query: ComputerUseAccessibilityQuery, minimum: Int)
  case frontmostApplication(processID: Int32?, bundleIdentifier: String?)
}

internal enum ComputerUseVerificationObservation: Codable, Equatable, Sendable {
  case pointerPosition(ComputerUsePoint)
  case accessibilityAttribute(ComputerUseAccessibilityValue)
  case accessibilityElementCount(Int)
  case frontmostApplication(ComputerUseApplicationObservation?)
}

internal struct ComputerUseVerificationPolicy: Codable, Equatable, Sendable {
  internal var timeoutMilliseconds: Int
  internal var pollIntervalMilliseconds: Int

  internal init(timeoutMilliseconds: Int = 1_000, pollIntervalMilliseconds: Int = 50) {
    self.timeoutMilliseconds = timeoutMilliseconds
    self.pollIntervalMilliseconds = pollIntervalMilliseconds
  }
}

internal struct ComputerUseVerificationResult: Codable, Equatable, Sendable {
  internal var attempts: Int
  internal var observation: ComputerUseVerificationObservation
}

internal enum ComputerUseActionKind: String, Codable, Sendable {
  case pointerMove = "pointer.move"
  case pointerClick = "pointer.click"
  case keyboardKey = "keyboard.key"
  case keyboardText = "keyboard.text"
  case scroll
  case accessibilityAction = "accessibility.action"
}

internal struct ComputerUseActionResult: Codable, Equatable, Sendable {
  internal var action: ComputerUseActionKind
  internal var verification: ComputerUseVerificationResult?
}

internal enum ComputerUseError: Error, Equatable, Sendable {
  case permissionRequired(ComputerUsePermission)
  case invalidArgument(field: String, reason: String)
  case noActiveDisplays
  case pointOutsideDisplays(ComputerUsePoint)
  case eventCreationFailed(kind: String)
  case systemCallFailed(operation: String, code: Int32)
  case accessibilityElementUnavailable(ComputerUseAccessibilityReference)
  case screenshotSourceUnavailable(target: ComputerUseScreenshotTarget, id: UInt32?)
  case screenshotEncodingFailed
  case screenshotTooLarge(actualBytes: Int, maximumBytes: Int)
  case verificationFailed(
    expected: String,
    actual: ComputerUseVerificationObservation,
    attempts: Int
  )

  internal var code: String {
    switch self {
    case .permissionRequired:
      "computer_use.permission_required"
    case .invalidArgument:
      "computer_use.invalid_argument"
    case .noActiveDisplays:
      "computer_use.no_active_displays"
    case .pointOutsideDisplays:
      "computer_use.point_outside_displays"
    case .eventCreationFailed:
      "computer_use.event_creation_failed"
    case .systemCallFailed:
      "computer_use.system_call_failed"
    case .accessibilityElementUnavailable:
      "computer_use.accessibility_element_unavailable"
    case .screenshotSourceUnavailable:
      "computer_use.screenshot_source_unavailable"
    case .screenshotEncodingFailed:
      "computer_use.screenshot_encoding_failed"
    case .screenshotTooLarge:
      "computer_use.screenshot_too_large"
    case .verificationFailed:
      "computer_use.verification_failed"
    }
  }
}

extension ComputerUseError: LocalizedError {
  internal var errorDescription: String? {
    switch self {
    case .permissionRequired(let permission):
      "The \(permission.rawValue) permission is not granted. Computer MCP never requests TCC "
        + "permission from a remote tool call; grant it locally in System Settings."
    case .invalidArgument(let field, let reason):
      "Invalid \(field): \(reason)"
    case .noActiveDisplays:
      "No active displays are available."
    case .pointOutsideDisplays(let point):
      "Point (\(point.x), \(point.y)) is outside every active display."
    case .eventCreationFailed(let kind):
      "CoreGraphics could not create the \(kind) input event."
    case .systemCallFailed(let operation, let code):
      "\(operation) failed with system error \(code)."
    case .accessibilityElementUnavailable(let reference):
      "The Accessibility element at PID \(reference.processID), path "
        + "\(reference.childPath) is no longer available."
    case .screenshotSourceUnavailable(let target, let id):
      "The requested \(target.rawValue) screenshot source"
        + (id.map { " with id \($0)" } ?? "") + " is unavailable."
    case .screenshotEncodingFailed:
      "The captured image could not be encoded as PNG."
    case .screenshotTooLarge(let actualBytes, let maximumBytes):
      "The PNG screenshot is \(actualBytes) bytes, exceeding the \(maximumBytes)-byte limit."
    case .verificationFailed(let expected, _, let attempts):
      "Post-action verification failed after \(attempts) attempt(s); expected \(expected)."
    }
  }
}

internal protocol ComputerUseAdapter: Sendable {
  func permissionStatus(_ permission: ComputerUsePermission) -> ComputerUsePermissionStatus
  func observeDisplays() throws -> [ComputerUseDisplayObservation]
  func observeWindows(_ query: ComputerUseWindowQuery) throws
    -> [ComputerUseWindowObservation]
  func captureScreenshot(_ request: ComputerUseScreenshotRequest) async throws
    -> ComputerUseCapturedImage
  func currentPointerLocation() throws -> ComputerUsePoint
  func movePointer(to point: ComputerUsePoint) throws
  func clickPointer(
    button: ComputerUsePointerButton,
    at point: ComputerUsePoint,
    clickCount: Int
  ) throws
  func pressKey(
    keyCode: UInt16,
    modifiers: Set<ComputerUseKeyModifier>,
    repeatCount: Int
  ) throws
  func typeText(_ text: String) throws
  func scroll(
    deltaX: Int32,
    deltaY: Int32,
    unit: ComputerUseScrollUnit,
    at point: ComputerUsePoint?
  ) throws
  func queryAccessibility(_ query: ComputerUseAccessibilityQuery) throws
    -> [ComputerUseAccessibilityObservation]
  func accessibilityAttribute(
    of reference: ComputerUseAccessibilityReference,
    attribute: ComputerUseAccessibilityAttribute
  ) throws -> ComputerUseAccessibilityValue
  func performAccessibilityAction(
    _ action: ComputerUseAccessibilityAction,
    on reference: ComputerUseAccessibilityReference
  ) throws
  func frontmostApplication() -> ComputerUseApplicationObservation?
}

internal struct ComputerUseService: Sendable {
  internal static let minimumScreenshotDimension = 64
  internal static let maximumScreenshotDimension = 4_096
  internal static let minimumScreenshotBytes = 32 * 1_024
  internal static let maximumScreenshotBytes = 8 * 1_024 * 1_024

  private static let maximumTextUTF16Units = 4_096
  private static let maximumKeyCode: UInt16 = 127
  private static let maximumRepeatCount = 100
  private static let maximumScrollMagnitude: Int32 = 10_000

  private let adapter: any ComputerUseAdapter
  private let sleep: @Sendable (TimeInterval) -> Void

  internal init() {
    self.init(adapter: MacOSComputerUseAdapter())
  }

  internal init(adapter: any ComputerUseAdapter) {
    self.adapter = adapter
    self.sleep = { duration in
      Thread.sleep(forTimeInterval: duration)
    }
  }

  init(
    adapter: any ComputerUseAdapter,
    sleep: @escaping @Sendable (TimeInterval) -> Void
  ) {
    self.adapter = adapter
    self.sleep = sleep
  }

  internal func permissionSnapshot() -> ComputerUsePermissionSnapshot {
    ComputerUsePermissionSnapshot(
      accessibility: adapter.permissionStatus(.accessibility),
      screenRecording: adapter.permissionStatus(.screenRecording)
    )
  }

  internal func observeDisplays() throws -> [ComputerUseDisplayObservation] {
    try adapter.observeDisplays()
  }

  internal func observeWindows(
    _ query: ComputerUseWindowQuery = ComputerUseWindowQuery()
  ) throws -> [ComputerUseWindowObservation] {
    try validate(query)
    try requirePermissions([.screenRecording])
    return Array(
      try adapter.observeWindows(query).lazy
        .filter(query.matches)
        .prefix(query.maxResults)
    )
  }

  internal func observePointer() throws -> ComputerUsePoint {
    let point = try adapter.currentPointerLocation()
    try validate(point)
    return point
  }

  internal func captureScreenshot(
    _ request: ComputerUseScreenshotRequest = ComputerUseScreenshotRequest()
  ) async throws -> ComputerUseScreenshotObservation {
    try validate(request)
    try requirePermissions([.screenRecording])
    let capture = try await adapter.captureScreenshot(request)
    guard capture.target == request.target else {
      throw ComputerUseError.screenshotSourceUnavailable(
        target: request.target,
        id: request.target == .display ? request.displayID : request.windowID
      )
    }
    guard capture.width > 0, capture.height > 0,
      capture.width <= request.maxWidth, capture.height <= request.maxHeight
    else {
      throw ComputerUseError.invalidArgument(
        field: "capture.dimensions",
        reason: "adapter output must fit the requested maximum dimensions"
      )
    }
    guard capture.pngData.count <= request.maxBytes else {
      throw ComputerUseError.screenshotTooLarge(
        actualBytes: capture.pngData.count,
        maximumBytes: request.maxBytes
      )
    }
    guard capture.pngData.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    else {
      throw ComputerUseError.screenshotEncodingFailed
    }
    return ComputerUseScreenshotObservation(
      target: capture.target,
      sourceID: capture.sourceID,
      width: capture.width,
      height: capture.height,
      byteCount: capture.pngData.count,
      pngBase64: capture.pngData.base64EncodedString()
    )
  }

  internal func queryAccessibility(
    _ query: ComputerUseAccessibilityQuery
  ) throws -> [ComputerUseAccessibilityObservation] {
    try validate(query)
    try requirePermissions([.accessibility])
    return try adapter.queryAccessibility(query)
  }

  internal func movePointer(
    to point: ComputerUsePoint,
    verification: ComputerUseVerification? = nil,
    verificationPolicy: ComputerUseVerificationPolicy = ComputerUseVerificationPolicy()
  ) throws -> ComputerUseActionResult {
    try validate(point)
    return try performAction(
      kind: .pointerMove,
      requiredPermissions: [.accessibility],
      verification: verification,
      verificationPolicy: verificationPolicy
    ) {
      try validatePointOnActiveDisplay(point)
      try adapter.movePointer(to: point)
    }
  }

  internal func clickPointer(
    button: ComputerUsePointerButton,
    at requestedPoint: ComputerUsePoint? = nil,
    clickCount: Int = 1,
    verification: ComputerUseVerification? = nil,
    verificationPolicy: ComputerUseVerificationPolicy = ComputerUseVerificationPolicy()
  ) throws -> ComputerUseActionResult {
    guard (1...3).contains(clickCount) else {
      throw ComputerUseError.invalidArgument(
        field: "click_count",
        reason: "must be between 1 and 3"
      )
    }
    if let requestedPoint {
      try validate(requestedPoint)
    }

    return try performAction(
      kind: .pointerClick,
      requiredPermissions: [.accessibility],
      verification: verification,
      verificationPolicy: verificationPolicy
    ) {
      let point = try requestedPoint ?? adapter.currentPointerLocation()
      try validatePointOnActiveDisplay(point)
      try adapter.clickPointer(button: button, at: point, clickCount: clickCount)
    }
  }

  internal func pressKey(
    keyCode: UInt16,
    modifiers: Set<ComputerUseKeyModifier> = [],
    repeatCount: Int = 1,
    verification: ComputerUseVerification? = nil,
    verificationPolicy: ComputerUseVerificationPolicy = ComputerUseVerificationPolicy()
  ) throws -> ComputerUseActionResult {
    guard keyCode <= Self.maximumKeyCode else {
      throw ComputerUseError.invalidArgument(
        field: "key_code",
        reason: "must be between 0 and \(Self.maximumKeyCode)"
      )
    }
    guard (1...Self.maximumRepeatCount).contains(repeatCount) else {
      throw ComputerUseError.invalidArgument(
        field: "repeat_count",
        reason: "must be between 1 and \(Self.maximumRepeatCount)"
      )
    }

    return try performAction(
      kind: .keyboardKey,
      requiredPermissions: [.accessibility],
      verification: verification,
      verificationPolicy: verificationPolicy
    ) {
      try adapter.pressKey(
        keyCode: keyCode,
        modifiers: modifiers,
        repeatCount: repeatCount
      )
    }
  }

  internal func typeText(
    _ text: String,
    verification: ComputerUseVerification? = nil,
    verificationPolicy: ComputerUseVerificationPolicy = ComputerUseVerificationPolicy()
  ) throws -> ComputerUseActionResult {
    let utf16Count = text.utf16.count
    guard utf16Count > 0 else {
      throw ComputerUseError.invalidArgument(field: "text", reason: "must not be empty")
    }
    guard utf16Count <= Self.maximumTextUTF16Units else {
      throw ComputerUseError.invalidArgument(
        field: "text",
        reason: "must not exceed \(Self.maximumTextUTF16Units) UTF-16 code units"
      )
    }

    return try performAction(
      kind: .keyboardText,
      requiredPermissions: [.accessibility],
      verification: verification,
      verificationPolicy: verificationPolicy
    ) {
      try adapter.typeText(text)
    }
  }

  internal func scroll(
    deltaX: Int32,
    deltaY: Int32,
    unit: ComputerUseScrollUnit = .pixel,
    at point: ComputerUsePoint? = nil,
    verification: ComputerUseVerification? = nil,
    verificationPolicy: ComputerUseVerificationPolicy = ComputerUseVerificationPolicy()
  ) throws -> ComputerUseActionResult {
    guard deltaX != 0 || deltaY != 0 else {
      throw ComputerUseError.invalidArgument(
        field: "delta",
        reason: "delta_x and delta_y cannot both be zero"
      )
    }
    guard
      magnitude(deltaX) <= Int64(Self.maximumScrollMagnitude),
      magnitude(deltaY) <= Int64(Self.maximumScrollMagnitude)
    else {
      throw ComputerUseError.invalidArgument(
        field: "delta",
        reason: "each axis must be between -\(Self.maximumScrollMagnitude) and "
          + "\(Self.maximumScrollMagnitude)"
      )
    }
    if let point {
      try validate(point)
    }

    return try performAction(
      kind: .scroll,
      requiredPermissions: [.accessibility],
      verification: verification,
      verificationPolicy: verificationPolicy
    ) {
      if let point {
        try validatePointOnActiveDisplay(point)
      }
      try adapter.scroll(deltaX: deltaX, deltaY: deltaY, unit: unit, at: point)
    }
  }

  internal func performAccessibilityAction(
    _ action: ComputerUseAccessibilityAction,
    on reference: ComputerUseAccessibilityReference,
    verification: ComputerUseVerification? = nil,
    verificationPolicy: ComputerUseVerificationPolicy = ComputerUseVerificationPolicy()
  ) throws -> ComputerUseActionResult {
    try validate(reference)
    return try performAction(
      kind: .accessibilityAction,
      requiredPermissions: [.accessibility],
      verification: verification,
      verificationPolicy: verificationPolicy
    ) {
      try adapter.performAccessibilityAction(action, on: reference)
    }
  }

  internal func verify(
    _ verification: ComputerUseVerification,
    policy: ComputerUseVerificationPolicy = ComputerUseVerificationPolicy()
  ) throws -> ComputerUseVerificationResult {
    try validate(policy)
    try validate(verification)
    try requirePermissions(permissionsRequired(for: verification))
    return try pollVerification(verification, policy: policy)
  }

  private func performAction(
    kind: ComputerUseActionKind,
    requiredPermissions: Set<ComputerUsePermission>,
    verification: ComputerUseVerification?,
    verificationPolicy: ComputerUseVerificationPolicy,
    action: () throws -> Void
  ) throws -> ComputerUseActionResult {
    try validate(verificationPolicy)
    if let verification {
      try validate(verification)
    }

    var allPermissions = requiredPermissions
    if let verification {
      allPermissions.formUnion(permissionsRequired(for: verification))
    }
    try requirePermissions(allPermissions)

    try action()
    let verificationResult = try verification.map {
      try pollVerification($0, policy: verificationPolicy)
    }
    return ComputerUseActionResult(action: kind, verification: verificationResult)
  }

  private func pollVerification(
    _ verification: ComputerUseVerification,
    policy: ComputerUseVerificationPolicy
  ) throws -> ComputerUseVerificationResult {
    var attempts = 0
    var elapsedMilliseconds = 0

    while true {
      attempts += 1
      let assessment = try assess(verification)
      if assessment.matches {
        return ComputerUseVerificationResult(
          attempts: attempts,
          observation: assessment.observation
        )
      }
      guard elapsedMilliseconds < policy.timeoutMilliseconds else {
        throw ComputerUseError.verificationFailed(
          expected: expectedDescription(for: verification),
          actual: assessment.observation,
          attempts: attempts
        )
      }

      let remaining = policy.timeoutMilliseconds - elapsedMilliseconds
      let delay = min(policy.pollIntervalMilliseconds, remaining)
      sleep(TimeInterval(delay) / 1_000)
      elapsedMilliseconds += delay
    }
  }

  private func assess(
    _ verification: ComputerUseVerification
  ) throws -> (matches: Bool, observation: ComputerUseVerificationObservation) {
    switch verification {
    case .pointerPosition(let expected, let tolerance):
      let actual = try adapter.currentPointerLocation()
      let deltaX = actual.x - expected.x
      let deltaY = actual.y - expected.y
      return (
        (deltaX * deltaX) + (deltaY * deltaY) <= tolerance * tolerance,
        .pointerPosition(actual)
      )

    case .accessibilityAttribute(let reference, let attribute, let expected):
      let actual = try adapter.accessibilityAttribute(
        of: reference,
        attribute: attribute
      )
      return (actual == expected, .accessibilityAttribute(actual))

    case .accessibilityElementCount(let query, let minimum):
      let count = try adapter.queryAccessibility(query).count
      return (count >= minimum, .accessibilityElementCount(count))

    case .frontmostApplication(let processID, let bundleIdentifier):
      let application = adapter.frontmostApplication()
      let processMatches = processID.map { application?.processID == $0 } ?? true
      let bundleMatches =
        bundleIdentifier.map { application?.bundleIdentifier == $0 } ?? true
      return (
        application != nil && processMatches && bundleMatches,
        .frontmostApplication(application)
      )
    }
  }

  private func permissionsRequired(
    for verification: ComputerUseVerification
  ) -> Set<ComputerUsePermission> {
    switch verification {
    case .accessibilityAttribute, .accessibilityElementCount:
      [.accessibility]
    case .pointerPosition, .frontmostApplication:
      []
    }
  }

  private func requirePermissions(_ permissions: Set<ComputerUsePermission>) throws {
    for permission in permissions.sorted(by: { $0.rawValue < $1.rawValue }) {
      guard adapter.permissionStatus(permission) == .granted else {
        throw ComputerUseError.permissionRequired(permission)
      }
    }
  }

  private func validate(_ point: ComputerUsePoint) throws {
    guard point.x.isFinite, point.y.isFinite else {
      throw ComputerUseError.invalidArgument(
        field: "point",
        reason: "coordinates must be finite"
      )
    }
  }

  private func validatePointOnActiveDisplay(_ point: ComputerUsePoint) throws {
    let displays = try adapter.observeDisplays()
    guard !displays.isEmpty else {
      throw ComputerUseError.noActiveDisplays
    }
    guard displays.contains(where: { $0.bounds.contains(point) }) else {
      throw ComputerUseError.pointOutsideDisplays(point)
    }
  }

  private func validate(_ query: ComputerUseWindowQuery) throws {
    guard (1...200).contains(query.maxResults) else {
      throw ComputerUseError.invalidArgument(
        field: "max_results",
        reason: "must be between 1 and 200"
      )
    }
    if let ownerProcessID = query.ownerProcessID, ownerProcessID < 0 {
      throw ComputerUseError.invalidArgument(
        field: "owner_process_id",
        reason: "must be non-negative"
      )
    }
    try validateWindowSubstring(query.ownerNameContains, field: "owner_name_contains")
    try validateWindowSubstring(query.titleContains, field: "title_contains")
    if let minimumAlpha = query.minimumAlpha,
      !minimumAlpha.isFinite || !(0...1).contains(minimumAlpha)
    {
      throw ComputerUseError.invalidArgument(
        field: "minimum_alpha",
        reason: "must be finite and between 0 and 1"
      )
    }
  }

  private func validateWindowSubstring(_ value: String?, field: String) throws {
    guard let value else { return }
    guard !value.isEmpty, value.utf16.count <= 1_024 else {
      throw ComputerUseError.invalidArgument(
        field: field,
        reason: "must contain between 1 and 1024 UTF-16 code units"
      )
    }
  }

  private func validate(_ request: ComputerUseScreenshotRequest) throws {
    guard
      (Self.minimumScreenshotDimension...Self.maximumScreenshotDimension).contains(
        request.maxWidth
      )
    else {
      throw ComputerUseError.invalidArgument(
        field: "max_width",
        reason:
          "must be between \(Self.minimumScreenshotDimension) and "
          + "\(Self.maximumScreenshotDimension)"
      )
    }
    guard
      (Self.minimumScreenshotDimension...Self.maximumScreenshotDimension).contains(
        request.maxHeight
      )
    else {
      throw ComputerUseError.invalidArgument(
        field: "max_height",
        reason:
          "must be between \(Self.minimumScreenshotDimension) and "
          + "\(Self.maximumScreenshotDimension)"
      )
    }
    guard
      (Self.minimumScreenshotBytes...Self.maximumScreenshotBytes).contains(
        request.maxBytes
      )
    else {
      throw ComputerUseError.invalidArgument(
        field: "max_bytes",
        reason:
          "must be between \(Self.minimumScreenshotBytes) and "
          + "\(Self.maximumScreenshotBytes)"
      )
    }
    switch request.target {
    case .display:
      guard request.windowID == nil else {
        throw ComputerUseError.invalidArgument(
          field: "window_id",
          reason: "must be omitted when target is display"
        )
      }
    case .window:
      guard request.displayID == nil else {
        throw ComputerUseError.invalidArgument(
          field: "display_id",
          reason: "must be omitted when target is window"
        )
      }
      guard request.windowID != nil else {
        throw ComputerUseError.invalidArgument(
          field: "window_id",
          reason: "is required when target is window"
        )
      }
    }
  }

  private func validate(_ query: ComputerUseAccessibilityQuery) throws {
    guard query.processID > 0 else {
      throw ComputerUseError.invalidArgument(
        field: "process_id",
        reason: "must be greater than zero"
      )
    }
    guard (0...25).contains(query.maxDepth) else {
      throw ComputerUseError.invalidArgument(
        field: "max_depth",
        reason: "must be between 0 and 25"
      )
    }
    guard (1...200).contains(query.maxResults) else {
      throw ComputerUseError.invalidArgument(
        field: "max_results",
        reason: "must be between 1 and 200"
      )
    }
    guard (1...20_000).contains(query.maxScannedElements) else {
      throw ComputerUseError.invalidArgument(
        field: "max_scanned_elements",
        reason: "must be between 1 and 20000"
      )
    }
  }

  private func validate(_ reference: ComputerUseAccessibilityReference) throws {
    guard reference.processID > 0 else {
      throw ComputerUseError.invalidArgument(
        field: "reference.process_id",
        reason: "must be greater than zero"
      )
    }
    guard reference.childPath.count <= 25 else {
      throw ComputerUseError.invalidArgument(
        field: "reference.child_path",
        reason: "must not contain more than 25 indexes"
      )
    }
    guard reference.childPath.allSatisfy({ $0 >= 0 }) else {
      throw ComputerUseError.invalidArgument(
        field: "reference.child_path",
        reason: "indexes must be nonnegative"
      )
    }
  }

  private func validate(_ verification: ComputerUseVerification) throws {
    switch verification {
    case .pointerPosition(let point, let tolerance):
      try validate(point)
      guard tolerance.isFinite, (0...100).contains(tolerance) else {
        throw ComputerUseError.invalidArgument(
          field: "verification.tolerance",
          reason: "must be finite and between 0 and 100"
        )
      }
    case .accessibilityAttribute(let reference, _, _):
      try validate(reference)
    case .accessibilityElementCount(let query, let minimum):
      try validate(query)
      guard (1...query.maxResults).contains(minimum) else {
        throw ComputerUseError.invalidArgument(
          field: "verification.minimum",
          reason: "must be between 1 and query.max_results"
        )
      }
    case .frontmostApplication(let processID, let bundleIdentifier):
      if let processID, processID <= 0 {
        throw ComputerUseError.invalidArgument(
          field: "verification.process_id",
          reason: "must be greater than zero"
        )
      }
      if let bundleIdentifier, bundleIdentifier.isEmpty {
        throw ComputerUseError.invalidArgument(
          field: "verification.bundle_identifier",
          reason: "must not be empty"
        )
      }
      guard processID != nil || bundleIdentifier != nil else {
        throw ComputerUseError.invalidArgument(
          field: "verification",
          reason: "frontmost application verification needs a PID or bundle identifier"
        )
      }
    }
  }

  private func validate(_ policy: ComputerUseVerificationPolicy) throws {
    guard (0...5_000).contains(policy.timeoutMilliseconds) else {
      throw ComputerUseError.invalidArgument(
        field: "verification_policy.timeout_milliseconds",
        reason: "must be between 0 and 5000"
      )
    }
    guard (1...1_000).contains(policy.pollIntervalMilliseconds) else {
      throw ComputerUseError.invalidArgument(
        field: "verification_policy.poll_interval_milliseconds",
        reason: "must be between 1 and 1000"
      )
    }
  }

  private func expectedDescription(for verification: ComputerUseVerification) -> String {
    switch verification {
    case .pointerPosition(let expected, let tolerance):
      "pointer at (\(expected.x), \(expected.y)) within \(tolerance) points"
    case .accessibilityAttribute(let reference, let attribute, let expected):
      "\(attribute.rawValue) at PID \(reference.processID), path \(reference.childPath) "
        + "equal to \(expected)"
    case .accessibilityElementCount(_, let minimum):
      "at least \(minimum) matching Accessibility element(s)"
    case .frontmostApplication(let processID, let bundleIdentifier):
      "frontmost application PID \(processID.map(String.init) ?? "*"), bundle "
        + "\(bundleIdentifier ?? "*")"
    }
  }

  private func magnitude(_ value: Int32) -> Int64 {
    abs(Int64(value))
  }
}

internal struct MacOSComputerUseAdapter: ComputerUseAdapter, Sendable {
  internal func permissionStatus(
    _ permission: ComputerUsePermission
  ) -> ComputerUsePermissionStatus {
    switch permission {
    case .accessibility:
      AXIsProcessTrusted() ? .granted : .notGranted
    case .screenRecording:
      CGPreflightScreenCaptureAccess() ? .granted : .notGranted
    }
  }

  internal func observeDisplays() throws -> [ComputerUseDisplayObservation] {
    var count: UInt32 = 0
    let countError = CGGetActiveDisplayList(0, nil, &count)
    guard countError == .success else {
      throw ComputerUseError.systemCallFailed(
        operation: "CGGetActiveDisplayList",
        code: countError.rawValue
      )
    }
    guard count > 0 else {
      return fallbackDisplayObservations()
    }

    var identifiers = [CGDirectDisplayID](repeating: 0, count: Int(count))
    let listError = CGGetActiveDisplayList(count, &identifiers, &count)
    guard listError == .success else {
      throw ComputerUseError.systemCallFailed(
        operation: "CGGetActiveDisplayList",
        code: listError.rawValue
      )
    }

    return identifiers.prefix(Int(count)).map { identifier in
      displayObservation(identifier: identifier)
    }
  }

  private func fallbackDisplayObservations() -> [ComputerUseDisplayObservation] {
    NSScreen.screens.compactMap { screen in
      guard
        let number = screen.deviceDescription[
          NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber
      else {
        return nil
      }
      let identifier = CGDirectDisplayID(number.uint32Value)
      var observation = displayObservation(identifier: identifier)
      if observation.bounds.size.width <= 0 || observation.bounds.size.height <= 0 {
        let frame = screen.frame
        observation.bounds = ComputerUseRect(
          x: frame.origin.x,
          y: frame.origin.y,
          width: frame.width,
          height: frame.height
        )
        observation.scaleFactor = screen.backingScaleFactor
        observation.pixelWidth = Int(frame.width * screen.backingScaleFactor)
        observation.pixelHeight = Int(frame.height * screen.backingScaleFactor)
      }
      return observation
    }
  }

  private func displayObservation(
    identifier: CGDirectDisplayID
  ) -> ComputerUseDisplayObservation {
    let bounds = CGDisplayBounds(identifier)
    let pixelsWide = CGDisplayPixelsWide(identifier)
    let pixelsHigh = CGDisplayPixelsHigh(identifier)
    let physicalSize = CGDisplayScreenSize(identifier)
    let scaleFactor =
      bounds.width > 0 ? Double(pixelsWide) / Double(bounds.width) : 1
    return ComputerUseDisplayObservation(
      id: identifier,
      bounds: ComputerUseRect(
        x: bounds.origin.x,
        y: bounds.origin.y,
        width: bounds.width,
        height: bounds.height
      ),
      pixelWidth: pixelsWide,
      pixelHeight: pixelsHigh,
      scaleFactor: scaleFactor,
      rotationDegrees: CGDisplayRotation(identifier),
      physicalSizeMillimeters: ComputerUseSize(
        width: physicalSize.width,
        height: physicalSize.height
      ),
      isMain: CGDisplayIsMain(identifier) != 0
    )
  }

  internal func observeWindows(
    _ query: ComputerUseWindowQuery
  ) throws -> [ComputerUseWindowObservation] {
    try requirePermission(.screenRecording)

    var options: CGWindowListOption = []
    if query.onScreenOnly {
      options.insert(.optionOnScreenOnly)
    } else {
      options.insert(.optionAll)
    }
    if query.excludeDesktopElements {
      options.insert(.excludeDesktopElements)
    }

    guard
      let dictionaries = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
        as? [[String: Any]]
    else {
      throw ComputerUseError.systemCallFailed(
        operation: "CGWindowListCopyWindowInfo",
        code: -1
      )
    }

    return Array(
      dictionaries.lazy
        .compactMap(windowObservation(from:))
        .filter(query.matches)
        .prefix(query.maxResults)
    )
  }

  internal func captureScreenshot(
    _ request: ComputerUseScreenshotRequest
  ) async throws -> ComputerUseCapturedImage {
    try requirePermission(.screenRecording)
    let content = try await SCShareableContent.excludingDesktopWindows(
      false,
      onScreenWindowsOnly: false
    )

    let filter: SCContentFilter
    let sourceID: UInt32
    let sourceSize: CGSize
    switch request.target {
    case .display:
      let display =
        request.displayID.flatMap { requestedID in
          content.displays.first(where: { $0.displayID == requestedID })
        } ?? content.displays.first(where: { CGDisplayIsMain($0.displayID) != 0 })
      guard let display else {
        throw ComputerUseError.screenshotSourceUnavailable(
          target: .display,
          id: request.displayID
        )
      }
      filter = SCContentFilter(display: display, excludingWindows: [])
      sourceID = display.displayID
      sourceSize = CGSize(width: display.width, height: display.height)

    case .window:
      guard let windowID = request.windowID,
        let window = content.windows.first(where: { $0.windowID == windowID })
      else {
        throw ComputerUseError.screenshotSourceUnavailable(
          target: .window,
          id: request.windowID
        )
      }
      filter = SCContentFilter(desktopIndependentWindow: window)
      sourceID = window.windowID
      sourceSize = window.frame.size
    }

    var targetSize = boundedPixelSize(
      sourceSize: sourceSize,
      maxWidth: request.maxWidth,
      maxHeight: request.maxHeight
    )
    var lastByteCount = 0
    while targetSize.width >= Self.minimumCaptureDimension,
      targetSize.height >= Self.minimumCaptureDimension
    {
      let configuration = SCStreamConfiguration()
      configuration.width = targetSize.width
      configuration.height = targetSize.height
      configuration.showsCursor = request.showsCursor
      let image = try await SCScreenshotManager.captureImage(
        contentFilter: filter,
        configuration: configuration
      )
      let data = try pngData(for: image)
      lastByteCount = data.count
      if data.count <= request.maxBytes {
        return ComputerUseCapturedImage(
          target: request.target,
          sourceID: sourceID,
          width: image.width,
          height: image.height,
          pngData: data
        )
      }
      targetSize = (
        width: max(Self.minimumCaptureDimension, Int(Double(targetSize.width) * 0.75)),
        height: max(Self.minimumCaptureDimension, Int(Double(targetSize.height) * 0.75))
      )
      if targetSize.width == Self.minimumCaptureDimension,
        targetSize.height == Self.minimumCaptureDimension
      {
        break
      }
    }
    throw ComputerUseError.screenshotTooLarge(
      actualBytes: lastByteCount,
      maximumBytes: request.maxBytes
    )
  }

  internal func currentPointerLocation() throws -> ComputerUsePoint {
    guard let event = CGEvent(source: nil) else {
      throw ComputerUseError.eventCreationFailed(kind: "pointer observation")
    }
    return ComputerUsePoint(x: event.location.x, y: event.location.y)
  }

  internal func movePointer(to point: ComputerUsePoint) throws {
    try requirePermission(.accessibility)
    guard
      let event = CGEvent(
        mouseEventSource: nil,
        mouseType: .mouseMoved,
        mouseCursorPosition: point.cgPoint,
        mouseButton: .left
      )
    else {
      throw ComputerUseError.eventCreationFailed(kind: "pointer move")
    }
    event.post(tap: .cghidEventTap)
  }

  internal func clickPointer(
    button: ComputerUsePointerButton,
    at point: ComputerUsePoint,
    clickCount: Int
  ) throws {
    try requirePermission(.accessibility)
    let eventTypes: (down: CGEventType, up: CGEventType, button: CGMouseButton)
    switch button {
    case .left:
      eventTypes = (.leftMouseDown, .leftMouseUp, .left)
    case .right:
      eventTypes = (.rightMouseDown, .rightMouseUp, .right)
    case .center:
      eventTypes = (.otherMouseDown, .otherMouseUp, .center)
    }

    for count in 1...clickCount {
      guard
        let down = CGEvent(
          mouseEventSource: nil,
          mouseType: eventTypes.down,
          mouseCursorPosition: point.cgPoint,
          mouseButton: eventTypes.button
        ),
        let up = CGEvent(
          mouseEventSource: nil,
          mouseType: eventTypes.up,
          mouseCursorPosition: point.cgPoint,
          mouseButton: eventTypes.button
        )
      else {
        throw ComputerUseError.eventCreationFailed(kind: "pointer click")
      }
      down.setIntegerValueField(.mouseEventClickState, value: Int64(count))
      up.setIntegerValueField(.mouseEventClickState, value: Int64(count))
      down.post(tap: .cghidEventTap)
      up.post(tap: .cghidEventTap)
    }
  }

  internal func pressKey(
    keyCode: UInt16,
    modifiers: Set<ComputerUseKeyModifier>,
    repeatCount: Int
  ) throws {
    try requirePermission(.accessibility)
    let flags = eventFlags(for: modifiers)
    for _ in 0..<repeatCount {
      guard
        let down = CGEvent(
          keyboardEventSource: nil,
          virtualKey: CGKeyCode(keyCode),
          keyDown: true
        ),
        let up = CGEvent(
          keyboardEventSource: nil,
          virtualKey: CGKeyCode(keyCode),
          keyDown: false
        )
      else {
        throw ComputerUseError.eventCreationFailed(kind: "keyboard key")
      }
      down.flags = flags
      up.flags = flags
      down.post(tap: .cghidEventTap)
      up.post(tap: .cghidEventTap)
    }
  }

  internal func typeText(_ text: String) throws {
    try requirePermission(.accessibility)
    guard
      let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
      let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
    else {
      throw ComputerUseError.eventCreationFailed(kind: "keyboard text")
    }

    let characters = Array(text.utf16)
    characters.withUnsafeBufferPointer { buffer in
      down.keyboardSetUnicodeString(
        stringLength: buffer.count,
        unicodeString: buffer.baseAddress
      )
      up.keyboardSetUnicodeString(
        stringLength: buffer.count,
        unicodeString: buffer.baseAddress
      )
    }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
  }

  internal func scroll(
    deltaX: Int32,
    deltaY: Int32,
    unit: ComputerUseScrollUnit,
    at point: ComputerUsePoint?
  ) throws {
    try requirePermission(.accessibility)
    let eventUnit: CGScrollEventUnit = unit == .pixel ? .pixel : .line
    guard
      let event = CGEvent(
        scrollWheelEvent2Source: nil,
        units: eventUnit,
        wheelCount: 2,
        wheel1: deltaY,
        wheel2: deltaX,
        wheel3: 0
      )
    else {
      throw ComputerUseError.eventCreationFailed(kind: "scroll")
    }
    if let point {
      event.location = point.cgPoint
    }
    event.post(tap: .cghidEventTap)
  }

  internal func queryAccessibility(
    _ query: ComputerUseAccessibilityQuery
  ) throws -> [ComputerUseAccessibilityObservation] {
    try requirePermission(.accessibility)

    struct PendingElement {
      var element: AXUIElement
      var path: [Int]
      var depth: Int
    }

    let root = AXUIElementCreateApplication(pid_t(query.processID))
    var pending = [PendingElement(element: root, path: [], depth: 0)]
    var index = 0
    var scanned = 0
    var results: [ComputerUseAccessibilityObservation] = []

    while index < pending.count,
      scanned < query.maxScannedElements,
      results.count < query.maxResults
    {
      let current = pending[index]
      index += 1
      scanned += 1

      let reference = ComputerUseAccessibilityReference(
        processID: query.processID,
        childPath: current.path
      )
      let observation = accessibilityObservation(
        for: current.element,
        reference: reference
      )
      if matches(observation, query: query) {
        results.append(observation)
      }

      guard current.depth < query.maxDepth else {
        continue
      }
      for (childIndex, child) in accessibilityChildren(of: current.element).enumerated() {
        pending.append(
          PendingElement(
            element: child,
            path: current.path + [childIndex],
            depth: current.depth + 1
          )
        )
      }
    }

    return results
  }

  internal func accessibilityAttribute(
    of reference: ComputerUseAccessibilityReference,
    attribute: ComputerUseAccessibilityAttribute
  ) throws -> ComputerUseAccessibilityValue {
    try requirePermission(.accessibility)
    let element = try resolveAccessibilityElement(reference)
    return accessibilityValue(
      copyAccessibilityValue(element, attribute: attribute.rawValue as CFString)
    )
  }

  internal func performAccessibilityAction(
    _ action: ComputerUseAccessibilityAction,
    on reference: ComputerUseAccessibilityReference
  ) throws {
    try requirePermission(.accessibility)
    let element = try resolveAccessibilityElement(reference)
    let error = AXUIElementPerformAction(element, action.rawValue as CFString)
    guard error == .success else {
      throw ComputerUseError.systemCallFailed(
        operation: "AXUIElementPerformAction(\(action.rawValue))",
        code: error.rawValue
      )
    }
  }

  internal func frontmostApplication() -> ComputerUseApplicationObservation? {
    guard let application = NSWorkspace.shared.frontmostApplication else {
      return nil
    }
    return ComputerUseApplicationObservation(
      processID: application.processIdentifier,
      bundleIdentifier: application.bundleIdentifier,
      localizedName: application.localizedName
    )
  }

  private func requirePermission(_ permission: ComputerUsePermission) throws {
    guard permissionStatus(permission) == .granted else {
      throw ComputerUseError.permissionRequired(permission)
    }
  }

  private static let minimumCaptureDimension = 64

  private func boundedPixelSize(
    sourceSize: CGSize,
    maxWidth: Int,
    maxHeight: Int
  ) -> (width: Int, height: Int) {
    let width = max(1, sourceSize.width)
    let height = max(1, sourceSize.height)
    let scale = min(Double(maxWidth) / width, Double(maxHeight) / height, 1)
    return (
      width: max(Self.minimumCaptureDimension, Int((width * scale).rounded(.down))),
      height: max(Self.minimumCaptureDimension, Int((height * scale).rounded(.down)))
    )
  }

  private func pngData(for image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data,
        UTType.png.identifier as CFString,
        1,
        nil
      )
    else {
      throw ComputerUseError.screenshotEncodingFailed
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw ComputerUseError.screenshotEncodingFailed
    }
    return data as Data
  }

  private func windowObservation(
    from dictionary: [String: Any]
  ) -> ComputerUseWindowObservation? {
    guard
      let identifier = number(in: dictionary, key: kCGWindowNumber)?.uint32Value,
      let processID = number(in: dictionary, key: kCGWindowOwnerPID)?.int32Value,
      let bounds = windowBounds(in: dictionary)
    else {
      return nil
    }

    return ComputerUseWindowObservation(
      id: identifier,
      ownerProcessID: processID,
      ownerName: dictionary[kCGWindowOwnerName as String] as? String,
      title: dictionary[kCGWindowName as String] as? String,
      bounds: bounds,
      layer: number(in: dictionary, key: kCGWindowLayer)?.intValue ?? 0,
      alpha: number(in: dictionary, key: kCGWindowAlpha)?.doubleValue ?? 1,
      isOnScreen: number(in: dictionary, key: kCGWindowIsOnscreen)?.boolValue ?? false,
      memoryBytes: number(in: dictionary, key: kCGWindowMemoryUsage)?.uint64Value,
      sharingState: number(in: dictionary, key: kCGWindowSharingState)?.uint32Value
    )
  }

  private func number(
    in dictionary: [String: Any],
    key: CFString
  ) -> NSNumber? {
    dictionary[key as String] as? NSNumber
  }

  private func windowBounds(in dictionary: [String: Any]) -> ComputerUseRect? {
    guard
      let bounds = dictionary[kCGWindowBounds as String] as? [String: Any],
      let x = (bounds["X"] as? NSNumber)?.doubleValue,
      let y = (bounds["Y"] as? NSNumber)?.doubleValue,
      let width = (bounds["Width"] as? NSNumber)?.doubleValue,
      let height = (bounds["Height"] as? NSNumber)?.doubleValue
    else {
      return nil
    }
    return ComputerUseRect(x: x, y: y, width: width, height: height)
  }

  private func eventFlags(
    for modifiers: Set<ComputerUseKeyModifier>
  ) -> CGEventFlags {
    modifiers.reduce(into: CGEventFlags()) { flags, modifier in
      switch modifier {
      case .command:
        flags.insert(.maskCommand)
      case .control:
        flags.insert(.maskControl)
      case .option:
        flags.insert(.maskAlternate)
      case .shift:
        flags.insert(.maskShift)
      case .function:
        flags.insert(.maskSecondaryFn)
      }
    }
  }

  private func resolveAccessibilityElement(
    _ reference: ComputerUseAccessibilityReference
  ) throws -> AXUIElement {
    var element = AXUIElementCreateApplication(pid_t(reference.processID))
    for childIndex in reference.childPath {
      let children = accessibilityChildren(of: element)
      guard children.indices.contains(childIndex) else {
        throw ComputerUseError.accessibilityElementUnavailable(reference)
      }
      element = children[childIndex]
    }
    return element
  }

  private func accessibilityChildren(of element: AXUIElement) -> [AXUIElement] {
    copyAccessibilityValue(element, attribute: kAXChildrenAttribute as CFString)
      as? [AXUIElement] ?? []
  }

  private func accessibilityObservation(
    for element: AXUIElement,
    reference: ComputerUseAccessibilityReference
  ) -> ComputerUseAccessibilityObservation {
    var actions: CFArray?
    let actionError = AXUIElementCopyActionNames(element, &actions)
    let actionNames =
      actionError == .success ? (actions as? [String] ?? []).sorted() : []

    return ComputerUseAccessibilityObservation(
      reference: reference,
      role: stringAccessibilityValue(element, attribute: kAXRoleAttribute),
      subrole: stringAccessibilityValue(element, attribute: kAXSubroleAttribute),
      title: stringAccessibilityValue(element, attribute: kAXTitleAttribute),
      value: optionalAccessibilityValue(
        copyAccessibilityValue(element, attribute: kAXValueAttribute as CFString)
      ),
      elementDescription: stringAccessibilityValue(
        element,
        attribute: kAXDescriptionAttribute
      ),
      identifier: stringAccessibilityValue(element, attribute: kAXIdentifierAttribute),
      enabled: boolAccessibilityValue(element, attribute: kAXEnabledAttribute),
      focused: boolAccessibilityValue(element, attribute: kAXFocusedAttribute),
      frame: accessibilityFrame(element),
      supportedActions: actionNames
    )
  }

  private func copyAccessibilityValue(
    _ element: AXUIElement,
    attribute: CFString
  ) -> CFTypeRef? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute, &value)
    return error == .success ? value : nil
  }

  private func stringAccessibilityValue(
    _ element: AXUIElement,
    attribute: String
  ) -> String? {
    copyAccessibilityValue(element, attribute: attribute as CFString) as? String
  }

  private func boolAccessibilityValue(
    _ element: AXUIElement,
    attribute: String
  ) -> Bool? {
    (copyAccessibilityValue(element, attribute: attribute as CFString) as? NSNumber)?
      .boolValue
  }

  private func optionalAccessibilityValue(_ value: CFTypeRef?) -> ComputerUseAccessibilityValue? {
    guard let value else {
      return nil
    }
    return accessibilityValue(value)
  }

  private func accessibilityValue(_ value: CFTypeRef?) -> ComputerUseAccessibilityValue {
    guard let value else {
      return .null
    }
    if let string = value as? String {
      return .string(string)
    }
    if let number = value as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        return .bool(number.boolValue)
      }
      return .number(number.doubleValue)
    }
    return .string(String(describing: value))
  }

  private func accessibilityFrame(_ element: AXUIElement) -> ComputerUseRect? {
    guard
      let positionValue = copyAccessibilityValue(
        element,
        attribute: kAXPositionAttribute as CFString
      ),
      let sizeValue = copyAccessibilityValue(
        element,
        attribute: kAXSizeAttribute as CFString
      ),
      CFGetTypeID(positionValue) == AXValueGetTypeID(),
      CFGetTypeID(sizeValue) == AXValueGetTypeID()
    else {
      return nil
    }

    var point = CGPoint.zero
    var size = CGSize.zero
    guard
      AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
      AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    else {
      return nil
    }
    return ComputerUseRect(
      x: point.x,
      y: point.y,
      width: size.width,
      height: size.height
    )
  }

  private func matches(
    _ observation: ComputerUseAccessibilityObservation,
    query: ComputerUseAccessibilityQuery
  ) -> Bool {
    if let role = query.role, observation.role != role {
      return false
    }
    if let identifier = query.identifier, observation.identifier != identifier {
      return false
    }
    if let enabled = query.enabled, observation.enabled != enabled {
      return false
    }
    if let focused = query.focused, observation.focused != focused {
      return false
    }
    if let title = query.titleContains,
      !contains(observation.title, needle: title, caseSensitive: query.caseSensitive)
    {
      return false
    }
    if let value = query.valueContains {
      let text: String?
      switch observation.value {
      case .string(let string):
        text = string
      case .bool(let bool):
        text = String(bool)
      case .number(let number):
        text = String(number)
      case .null, .none:
        text = nil
      }
      if !contains(text, needle: value, caseSensitive: query.caseSensitive) {
        return false
      }
    }
    return true
  }

  private func contains(
    _ haystack: String?,
    needle: String,
    caseSensitive: Bool
  ) -> Bool {
    guard let haystack else {
      return false
    }
    if caseSensitive {
      return haystack.contains(needle)
    }
    return haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
  }
}
