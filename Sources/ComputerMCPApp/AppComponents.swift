import SwiftUI

struct WorkspaceHeader<Actions: View>: View {
  let title: String
  let subtitle: String
  let actions: Actions

  init(
    _ title: String,
    subtitle: String,
    @ViewBuilder actions: () -> Actions
  ) {
    self.title = title
    self.subtitle = subtitle
    self.actions = actions()
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.title2.weight(.semibold))
        Text(subtitle)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 24)

      actions
        .controlSize(.regular)
    }
    .padding(.horizontal, 24)
    .padding(.top, 20)
    .padding(.bottom, 14)
  }
}

struct RefreshButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label("Refresh", systemImage: "arrow.clockwise")
    }
  }
}

struct LoadingWorkspaceView: View {
  let title: String

  var body: some View {
    VStack(spacing: 10) {
      ProgressView()
        .controlSize(.regular)
      Text(title)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct EmptyWorkspaceView: View {
  let title: String
  let detail: String
  let systemImage: String

  var body: some View {
    ContentUnavailableView(
      title,
      systemImage: systemImage,
      description: Text(detail)
    )
  }
}

struct FailedWorkspaceView: View {
  let message: String
  let retry: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label("Control plane unavailable", systemImage: "exclamationmark.triangle")
    } description: {
      Text(message)
    } actions: {
      Button("Retry", action: retry)
    }
  }
}

struct StateBadge: View {
  let text: String
  let color: Color
  var systemImage: String?

  var body: some View {
    HStack(spacing: 5) {
      if let systemImage {
        Image(systemName: systemImage)
      }
      Text(text)
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(color)
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(color.opacity(0.12))
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .accessibilityElement(children: .combine)
  }
}

extension ServiceState {
  var color: Color {
    switch self {
    case .running: .green
    case .starting, .stopping: .blue
    case .degraded: .orange
    case .failed: .red
    case .stopped: .secondary
    }
  }

  var systemImage: String {
    switch self {
    case .running: "checkmark.circle.fill"
    case .starting, .stopping: "arrow.triangle.2.circlepath"
    case .degraded: "exclamationmark.triangle.fill"
    case .failed: "xmark.octagon.fill"
    case .stopped: "stop.circle"
    }
  }
}

extension WorkspaceHealth {
  var color: Color {
    switch self {
    case .available: .green
    case .bookmarkStale: .orange
    case .missing: .red
    }
  }
}

extension RiskLevel {
  var color: Color {
    switch self {
    case .low: .green
    case .elevated: .orange
    case .high: .red
    }
  }
}

extension PermissionState {
  var color: Color {
    switch self {
    case .granted: .green
    case .denied: .red
    case .notGranted: .orange
    case .notDetermined: .orange
    case .unavailable: .secondary
    }
  }
}

extension AuditDecision {
  var color: Color {
    switch self {
    case .allowed, .committed: .green
    case .denied, .failed: .red
    case .prepared: .blue
    }
  }
}

extension DiagnosticLevel {
  var color: Color {
    switch self {
    case .information: .secondary
    case .warning: .orange
    case .error: .red
    }
  }

  var systemImage: String {
    switch self {
    case .information: "info.circle"
    case .warning: "exclamationmark.triangle"
    case .error: "xmark.octagon"
    }
  }
}

extension DateFormatter {
  static let computerMCPDateTime: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .medium
    return formatter
  }()
}
