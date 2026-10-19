import ComputerMCPProcess

extension ExternalProviderDiscovery {
  /// The ChatGPT and Codex App bundles, Homebrew, MacPorts and the system locations, in
  /// search order.
  static let macOSSearchDirectories = [
    "/Applications/ChatGPT.app/Contents/Resources",
    "/Applications/Codex.app/Contents/Resources",
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/opt/local/bin",
    "/usr/bin",
    "/bin",
  ]
}
