import ArgumentParser
import ComputerMCP
import Foundation

struct Doctor: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "doctor",
    abstract: "Check App-owned readiness and print the next safe action."
  )

  enum Journey: String, CaseIterable, ExpressibleByArgument {
    case local
    case chatgpt
    case cloudflare

    var productJourney: ProductJourney {
      switch self {
      case .local: .local
      case .chatgpt: .chatgpt
      case .cloudflare: .cloudflare
      }
    }
  }

  @Option(
    name: .long,
    help: "Readiness path to check: local, chatgpt, or cloudflare."
  )
  var journey: Journey = .local

  @Flag(name: .long, help: "Emit the stable schema-1 JSON readiness contract.")
  var json = false

  func run() async throws {
    let snapshot: ProductReadinessSnapshot
    do {
      let value = try await AppControlPlaneServiceClient.live().call(
        "readiness",
        arguments: .object(["journey": .string(journey.rawValue)]),
        timeout: .seconds(5)
      )
      snapshot = try JSONDecoder().decode(
        ProductReadinessSnapshot.self,
        from: JSONEncoder().encode(value)
      )
    } catch {
      snapshot = .appUnavailable(journey: journey.productJourney)
    }

    if json {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(snapshot)
      guard let output = String(data: data, encoding: .utf8) else {
        throw ValidationError("Unable to encode doctor JSON as UTF-8.")
      }
      print(output)
    } else {
      print(Self.humanReadable(snapshot))
    }

    guard snapshot.status == .ready || snapshot.status == .verified else {
      throw ExitCode.failure
    }
  }

  static func humanReadable(_ snapshot: ProductReadinessSnapshot) -> String {
    var lines = [
      "Computer MCP doctor: \(snapshot.journey.rawValue)",
      "Status: \(snapshot.status.rawValue)",
      "",
    ]
    lines.append(
      contentsOf: snapshot.checks.map { check in
        "[\(check.status.rawValue)] \(check.summary) — \(check.detail)"
      }
    )
    if let action = snapshot.nextAction {
      lines.append("")
      lines.append("Next: \(action.label)")
      if !action.redactedTarget.isEmpty {
        lines.append("Target: \(action.redactedTarget)")
      }
    }
    if let request = snapshot.verifiedRequest {
      lines.append("")
      lines.append("Verified request: \(request.requestID) (\(request.capability))")
      lines.append("Verified at: \(ISO8601DateFormatter().string(from: request.timestamp))")
    }
    return lines.joined(separator: "\n")
  }
}
