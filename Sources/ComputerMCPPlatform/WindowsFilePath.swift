import Foundation

#if os(Windows)
  import WinSDK
#endif

/// Win32 filesystem names; device namespaces and alternate streams are not paths here.
enum WindowsFilePath {
  #if os(Windows)
    static func native(_ url: URL) -> String? {
      guard url.isFileURL else { return nil }
      return url.withUnsafeFileSystemRepresentation { $0.map(String.init(cString:)) }
    }

  #endif

  static func isAbsolute(_ value: String) -> Bool {
    let path = value.replacingOccurrences(of: "/", with: "\\")
    let bytes = Array(path.utf8.prefix(3))
    return path.hasPrefix("\\\\")
      || (bytes.count == 3 && isDriveLetter(bytes[0]) && bytes[1] == 58 && bytes[2] == 92)
  }

  static func isDriveLetter(_ value: UInt8) -> Bool {
    (65...90).contains(value) || (97...122).contains(value)
  }

  static func isValid(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf16.count < 32_767,
      !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    else { return false }
    let path = value.replacingOccurrences(of: "/", with: "\\")
    guard !path.hasPrefix("\\\\?\\"), !path.hasPrefix("\\\\.\\"), !path.hasPrefix("\\??\\"),
      !path.contains(where: { "<>\"|?*".contains($0) })
    else { return false }
    let bytes = Array(path.utf8)
    let withoutDrive =
      bytes.count >= 3 && isDriveLetter(bytes[0]) && bytes[1] == 58 && bytes[2] == 92
      ? String(path.dropFirst(2)) : path
    guard !withoutDrive.contains(":") else { return false }
    let components = withoutDrive.split(separator: "\\")
    if path.hasPrefix("\\\\") {
      guard components.count >= 2,
        !components.prefix(2).contains(where: { $0 == "." || $0 == ".." }),
        !["pipe", "mailslot"].contains(components[1].lowercased())
      else { return false }
    }
    return components.allSatisfy { component in
      if component == "." || component == ".." { return true }
      guard component.last != ".", component.last != " " else { return false }
      let stem = component.split(separator: ".", maxSplits: 1).first?.uppercased() ?? ""
      return !["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"].contains(stem)
        && !["COM¹", "COM²", "COM³", "LPT¹", "LPT²", "LPT³"].contains(stem)
        && !(1...9).contains(where: { stem == "COM\($0)" || stem == "LPT\($0)" })
    }
  }

  #if os(Windows)
    static func absolute(_ value: String, cwd: String) -> String? {
      guard isValid(value) else { return nil }
      let path = value.replacingOccurrences(of: "/", with: "\\")
      guard !path.hasPrefix("\\") || path.hasPrefix("\\\\") else { return nil }
      let joined = isAbsolute(path) ? path : cwd + "\\" + path
      guard joined.utf16.count < 32_767 else { return nil }
      var output = [WCHAR](repeating: 0, count: 32_768)
      let length = GetFullPathNameW(Array(joined.utf16) + [0], DWORD(output.count), &output, nil)
      guard length > 0, length < output.count else { return nil }
      return String(decoding: output.prefix(Int(length)), as: UTF16.self)
    }
  #endif
}
