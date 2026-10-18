import AppKit
import CoreGraphics
import SwiftUI

enum PermissionCoachArrowDirection: Equatable, Sendable {
  case down
  case left
  case right
  case up

  var symbolName: String {
    switch self {
    case .down:
      "arrow.down"
    case .left:
      "arrow.left"
    case .right:
      "arrow.right"
    case .up:
      "arrow.up"
    }
  }
}

struct PermissionCoachPlacement: Equatable, Sendable {
  static let targetSpacing: CGFloat = 14
  static let fallbackTopSpacing: CGFloat = 24
  static let fallbackEdgeInset: CGFloat = 16

  let origin: CGPoint
  let arrowDirection: PermissionCoachArrowDirection?

  static func resolve(
    targetFrame: CGRect?,
    visibleFrame: CGRect,
    panelSize: CGSize
  ) -> PermissionCoachPlacement {
    guard let targetFrame else {
      return fallback(visibleFrame: visibleFrame, panelSize: panelSize)
    }

    let visibleTarget = targetFrame.intersection(visibleFrame)
    guard
      !visibleTarget.isNull,
      !visibleTarget.isEmpty,
      visibleTarget.area >= targetFrame.area * 0.5
    else {
      return fallback(visibleFrame: visibleFrame, panelSize: panelSize)
    }

    let centeredY = clamp(
      visibleTarget.midY - panelSize.height / 2,
      minimum: visibleFrame.minY,
      maximum: visibleFrame.maxY - panelSize.height
    )
    if visibleTarget.maxX + targetSpacing + panelSize.width <= visibleFrame.maxX {
      return PermissionCoachPlacement(
        origin: CGPoint(x: visibleTarget.maxX + targetSpacing, y: centeredY),
        arrowDirection: .left
      )
    }
    if visibleTarget.minX - targetSpacing - panelSize.width >= visibleFrame.minX {
      return PermissionCoachPlacement(
        origin: CGPoint(
          x: visibleTarget.minX - targetSpacing - panelSize.width,
          y: centeredY
        ),
        arrowDirection: .right
      )
    }

    let centeredX = clamp(
      visibleTarget.midX - panelSize.width / 2,
      minimum: visibleFrame.minX,
      maximum: visibleFrame.maxX - panelSize.width
    )
    if visibleTarget.maxY + targetSpacing + panelSize.height <= visibleFrame.maxY {
      return PermissionCoachPlacement(
        origin: CGPoint(x: centeredX, y: visibleTarget.maxY + targetSpacing),
        arrowDirection: .down
      )
    }
    if visibleTarget.minY - targetSpacing - panelSize.height >= visibleFrame.minY {
      return PermissionCoachPlacement(
        origin: CGPoint(
          x: centeredX,
          y: visibleTarget.minY - targetSpacing - panelSize.height
        ),
        arrowDirection: .up
      )
    }

    return fallback(visibleFrame: visibleFrame, panelSize: panelSize)
  }

  private static func fallback(
    visibleFrame: CGRect,
    panelSize: CGSize
  ) -> PermissionCoachPlacement {
    let minimumX = visibleFrame.minX + fallbackEdgeInset
    let maximumX = visibleFrame.maxX - panelSize.width - fallbackEdgeInset
    let minimumY = visibleFrame.minY + fallbackEdgeInset
    let maximumY = visibleFrame.maxY - panelSize.height - fallbackEdgeInset
    return PermissionCoachPlacement(
      origin: CGPoint(
        x: clamp(
          visibleFrame.midX - panelSize.width / 2,
          minimum: minimumX,
          maximum: maximumX
        ),
        y: clamp(
          visibleFrame.maxY - panelSize.height - fallbackTopSpacing,
          minimum: minimumY,
          maximum: maximumY
        )
      ),
      arrowDirection: nil
    )
  }

  private static func clamp(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
    guard maximum >= minimum else {
      return minimum
    }
    return min(max(value, minimum), maximum)
  }
}

@MainActor
protocol SystemSettingsWindowLocating {
  func windowFrame() -> CGRect?
}

struct CoreGraphicsSystemSettingsWindowLocator: SystemSettingsWindowLocating {
  func windowFrame() -> CGRect? {
    guard
      let processID = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.systempreferences"
      ).first(where: { !$0.isTerminated })?.processIdentifier,
      let windowInfo = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
      ) as? [[String: Any]]
    else {
      return nil
    }

    return windowInfo.compactMap { info -> CGRect? in
      guard
        (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
        (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
        (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
        let bounds = info[kCGWindowBounds as String] as? [String: Any],
        let quartzFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
        quartzFrame.width >= 300,
        quartzFrame.height >= 200
      else {
        return nil
      }
      return Self.appKitFrame(
        for: quartzFrame,
        desktopTop: NSScreen.screens.first?.frame.maxY ?? 0
      )
    }
    .max { lhs, rhs in
      lhs.width * lhs.height < rhs.width * rhs.height
    }
  }

  nonisolated static func appKitFrame(for quartzFrame: CGRect, desktopTop: CGFloat) -> CGRect {
    return CGRect(
      x: quartzFrame.minX,
      y: desktopTop - quartzFrame.maxY,
      width: quartzFrame.width,
      height: quartzFrame.height
    )
  }
}

enum PermissionCoachDragSource {
  static func pasteboardWriter(for appBundleURL: URL) -> any NSPasteboardWriting {
    appBundleURL as NSURL
  }
}

private final class PermissionCoachPanel: NSPanel {
  override var canBecomeKey: Bool {
    true
  }

  override var canBecomeMain: Bool {
    false
  }
}

private final class PermissionCoachDraggableAppView: NSView, NSDraggingSource {
  private let iconView = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "Computer MCP.app")
  private let instructionLabel = NSTextField(
    labelWithString: AppLocalization.string("Drag into the app list")
  )
  private var appBundleURL: URL

  init(appBundleURL: URL) {
    self.appBundleURL = appBundleURL
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.image = NSWorkspace.shared.icon(forFile: appBundleURL.path)
    iconView.imageScaling = .scaleProportionallyUpOrDown

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    titleLabel.lineBreakMode = .byTruncatingTail

    instructionLabel.translatesAutoresizingMaskIntoConstraints = false
    instructionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    instructionLabel.textColor = .secondaryLabelColor

    addSubview(iconView)
    addSubview(titleLabel)
    addSubview(instructionLabel)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: 52),
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 32),
      iconView.heightAnchor.constraint(equalToConstant: 32),
      titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      instructionLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      instructionLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
      instructionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
    ])

    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel(AppLocalization.string("Drag Computer MCP.app into the app list"))
    setAccessibilityHelp(
      AppLocalization.string(
        "Drag this app into the Screen & System Audio Recording list, then turn it on."
      )
    )
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(appBundleURL: URL) {
    guard self.appBundleURL != appBundleURL else {
      return
    }
    self.appBundleURL = appBundleURL
    iconView.image = NSWorkspace.shared.icon(forFile: appBundleURL.path)
  }

  override func mouseDown(with event: NSEvent) {
    let draggingItem = NSDraggingItem(
      pasteboardWriter: PermissionCoachDragSource.pasteboardWriter(for: appBundleURL)
    )
    let location = convert(event.locationInWindow, from: nil)
    let dragFrame = NSRect(
      x: location.x - 20,
      y: location.y - 20,
      width: 40,
      height: 40
    )
    draggingItem.setDraggingFrame(
      dragFrame,
      contents: NSWorkspace.shared.icon(forFile: appBundleURL.path)
    )
    beginDraggingSession(with: [draggingItem], event: event, source: self)
  }

  func draggingSession(
    _ session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    .copy
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .openHand)
  }
}

private struct PermissionCoachDraggableAppRow: NSViewRepresentable {
  let appBundleURL: URL

  func makeNSView(context: Context) -> PermissionCoachDraggableAppView {
    PermissionCoachDraggableAppView(appBundleURL: appBundleURL)
  }

  func updateNSView(_ nsView: PermissionCoachDraggableAppView, context: Context) {
    nsView.update(appBundleURL: appBundleURL)
  }
}

@MainActor
final class PermissionCoachWindowController {
  private static let standardPanelSize = NSSize(width: 330, height: 112)
  private static let screenRecordingPanelSize = NSSize(width: 360, height: 164)

  private let systemSettingsWindowLocator: any SystemSettingsWindowLocating
  private var panel: NSPanel?
  private var dismissalTask: Task<Void, Never>?

  init(
    systemSettingsWindowLocator: any SystemSettingsWindowLocating =
      CoreGraphicsSystemSettingsWindowLocator()
  ) {
    self.systemSettingsWindowLocator = systemSettingsWindowLocator
  }

  func show(permission: PermissionSummary) {
    dismiss()

    let panelSize = Self.panelSize(for: permission.id)
    let targetFrame = systemSettingsWindowLocator.windowFrame()
    let screen = targetFrame.flatMap(screen(containing:)) ?? NSScreen.main ?? NSScreen.screens.first
    let visibleFrame = screen?.visibleFrame ?? CGRect(origin: .zero, size: panelSize)
    let placement = PermissionCoachPlacement.resolve(
      targetFrame: targetFrame,
      visibleFrame: visibleFrame,
      panelSize: panelSize
    )
    let contentView = PermissionCoachView(
      permission: permission,
      arrowDirection: placement.arrowDirection,
      appBundleURL: permission.id == "screen-recording" ? Bundle.main.bundleURL : nil
    )
    let hostingView = NSHostingView(rootView: contentView)
    let panel = PermissionCoachPanel(
      contentRect: NSRect(origin: .zero, size: panelSize),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    panel.contentView = hostingView
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.level = .floating
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = permission.id != "screen-recording"
    panel.setFrameOrigin(placement.origin)
    panel.orderFrontRegardless()
    self.panel = panel

    dismissalTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(90))
      guard !Task.isCancelled else {
        return
      }
      self?.dismiss()
    }
  }

  func dismiss() {
    dismissalTask?.cancel()
    dismissalTask = nil
    panel?.orderOut(nil)
    panel = nil
  }

  private func screen(containing frame: CGRect) -> NSScreen? {
    NSScreen.screens.max { lhs, rhs in
      lhs.frame.intersection(frame).area < rhs.frame.intersection(frame).area
    }
  }

  private static func panelSize(for permissionID: String) -> NSSize {
    permissionID == "screen-recording" ? screenRecordingPanelSize : standardPanelSize
  }
}

private struct PermissionCoachView: View {
  let permission: PermissionSummary
  let arrowDirection: PermissionCoachArrowDirection?
  let appBundleURL: URL?

  var body: some View {
    directionalContent
      .padding(16)
      .background(.regularMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
      }
  }

  @ViewBuilder
  private var directionalContent: some View {
    if arrowDirection == .up {
      VStack(spacing: 8) {
        arrow(.up)
        message
      }
    } else if arrowDirection == .down {
      VStack(spacing: 8) {
        message
        arrow(.down)
      }
    } else {
      HStack(spacing: 12) {
        if arrowDirection == .left {
          arrow(.left)
        }

        message

        if arrowDirection == .right {
          arrow(.right)
        }
      }
    }
  }

  private var message: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Complete in System Settings")
        .font(.headline)
      Text(instruction)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if let appBundleURL {
        PermissionCoachDraggableAppRow(appBundleURL: appBundleURL)
          .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func arrow(_ direction: PermissionCoachArrowDirection) -> some View {
    Image(systemName: direction.symbolName)
      .font(.system(size: 24, weight: .semibold))
      .foregroundStyle(.tint)
      .accessibilityHidden(true)
  }

  private var instruction: String {
    switch permission.id {
    case "accessibility":
      AppLocalization.string("Turn on Computer MCP under Accessibility.")
    case "screen-recording":
      AppLocalization.string("Turn on Computer MCP under Screen & System Audio Recording.")
    default:
      String(
        format: AppLocalization.string("Turn on Computer MCP for %@."),
        permission.displayName
      )
    }
  }
}

extension CGRect {
  fileprivate var area: CGFloat {
    isNull || isInfinite ? 0 : width * height
  }
}
