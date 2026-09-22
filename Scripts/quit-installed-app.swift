import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { exit(64) }
let expected = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let applications = NSWorkspace.shared.runningApplications.filter {
  $0.bundleURL?.standardizedFileURL == expected
}
for application in applications {
  guard application.terminate() else {
    fputs("App refused the normal quit request; no forced termination was attempted.\n", stderr)
    exit(1)
  }
}
let data = try JSONSerialization.data(
  withJSONObject: applications.map { Int($0.processIdentifier) })
print(String(decoding: data, as: UTF8.self))
