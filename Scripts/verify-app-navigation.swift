import AppKit
import ApplicationServices
import Foundation

func fail(_ text: String, code: Int32 = 1) -> Never {
  FileHandle.standardError.write(Data((text + "\n").utf8))
  exit(code)
}

guard CommandLine.arguments.count == 3, let pid = Int32(CommandLine.arguments[1]) else {
  fail("Usage: verify-app-navigation.swift PID APP_PATH")
}
let appURL = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
guard let application = NSRunningApplication(processIdentifier: pid),
  application.bundleURL?.standardizedFileURL == appURL
else { fail("The requested process is not the installed candidate App") }
guard AXIsProcessTrusted() else {
  fail(
    "Required action: grant Accessibility access to the application running release acceptance, then resume.",
    code: 75)
}
application.activate()
let root = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(root, 2)

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
  var value: CFTypeRef?
  return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func find(_ identifier: String) -> AXUIElement? {
  var queue = [root]
  var index = 0
  while index < queue.count, index < 2_000 {
    let element = queue[index]
    index += 1
    if attribute(element, "AXIdentifier") as? String == identifier { return element }
    queue.append(contentsOf: attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
  }
  return nil
}

func waitFor(_ identifier: String) -> AXUIElement? {
  let deadline = Date().addingTimeInterval(5)
  repeat {
    if let element = find(identifier) { return element }
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
  } while Date() < deadline
  return nil
}

let pages = [
  "home", "chatgpt", "workspaces", "profiles", "providers", "plugins", "tunnels",
  "permissions", "audit", "diagnostics", "home",
]
for page in pages {
  guard let item = waitFor("navigation." + page) else { fail("Missing navigation item: " + page) }
  var row = item
  var selected = false
  for _ in 0..<6 {
    if attribute(row, kAXRoleAttribute) as? String == kAXRowRole {
      selected =
        AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        == .success
      break
    }
    guard let parent = attribute(row, kAXParentAttribute),
      CFGetTypeID(parent) == AXUIElementGetTypeID()
    else { break }
    row = unsafeBitCast(parent, to: AXUIElement.self)
  }
  guard selected, waitFor("page." + page) != nil else {
    fail("Navigation did not display page: " + page)
  }
}
let result: [String: Any] = [
  "status": "passed", "pid": pid, "pages": pages, "scope": "navigation and page availability",
]
FileHandle.standardOutput.write(
  try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
print()
