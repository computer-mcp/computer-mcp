import ArgumentParser
import ComputerMCP
import Foundation

struct AppControlConnectionOptions: ParsableArguments {
  @Option(
    name: .long,
    help:
      "Explicit owner-only control socket for an isolated App instance; defaults to the production App."
  )
  var controlSocket: String?

  func validateStandalone(config: String?) throws {
    if config != nil && controlSocket != nil {
      throw ValidationError("--control-socket cannot be combined with --config.")
    }
  }

  func client() throws -> AppControlPlaneServiceClient {
    if let controlSocket {
      return AppControlPlaneServiceClient(socketURL: URL(fileURLWithPath: controlSocket))
    }
    return try .live()
  }
}
