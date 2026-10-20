import ComputerMCPCore
import Foundation

package func outlineItems(
  in content: String,
  language: String?,
  includeImports: Bool
) -> [FileOutlineItem] {
  var allItems: [FileOutlineItem] = []
  let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
  var insideMarkdownFence = false
  for (index, line) in lines.enumerated() {
    if language == "markdown" {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        insideMarkdownFence.toggle()
        continue
      }
      if insideMarkdownFence {
        continue
      }
    }
    guard
      let item = outlineItem(line: String(line), lineNumber: index + 1, language: language)
    else {
      continue
    }
    if item.kind == "import" && !includeImports {
      continue
    }
    allItems.append(item)
  }
  return allItems
}

package func outlineLanguage(for url: URL) -> String? {
  let name = url.lastPathComponent.lowercased()
  let ext = url.pathExtension.lowercased()
  if ["md", "markdown", "mdown"].contains(ext) {
    return "markdown"
  }
  if ext == "swift" {
    return "swift"
  }
  if ["js", "jsx", "mjs", "cjs"].contains(ext) {
    return "javascript"
  }
  if ["ts", "tsx", "mts", "cts"].contains(ext) {
    return "typescript"
  }
  if ext == "py" {
    return "python"
  }
  if ext == "go" {
    return "go"
  }
  if ext == "rs" {
    return "rust"
  }
  if ext == "java" {
    return "java"
  }
  if ["kt", "kts"].contains(ext) {
    return "kotlin"
  }
  if ["c", "h", "cc", "cpp", "cxx", "hpp"].contains(ext) {
    return "c-family"
  }
  if name == "makefile" || ext == "mk" {
    return "make"
  }
  return nil
}

private func outlineItem(line: String, lineNumber: Int, language: String?) -> FileOutlineItem? {
  let trimmed = line.trimmingCharacters(in: .whitespaces)
  guard !trimmed.isEmpty else {
    return nil
  }

  if language == "markdown", let heading = markdownHeading(trimmed, lineNumber: lineNumber) {
    return heading
  }

  var tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
  guard !tokens.isEmpty else {
    return nil
  }

  let modifiers = Set([
    "public", "private", "internal", "fileprivate", "open", "static", "final", "override",
    "mutating", "nonmutating", "lazy", "async", "throws", "rethrows", "export", "default",
    "pub", "abstract", "sealed", "data", "inline", "extern", "virtual",
  ])
  while let first = tokens.first, modifiers.contains(first) {
    tokens.removeFirst()
  }
  guard !tokens.isEmpty else {
    return nil
  }

  if tokens.count >= 2, tokens[0] == "async", tokens[1] == "def" {
    return declarationOutlineItem(
      kind: "function",
      rawName: tokens.dropFirst(2).first,
      line: line,
      lineNumber: lineNumber
    )
  }

  let keyword = tokens[0]
  let rawName = tokens.dropFirst().first
  let kind: String
  switch keyword {
  case "class":
    kind = "class"
  case "struct":
    kind = "struct"
  case "enum":
    kind = "enum"
  case "protocol", "interface", "trait":
    kind = "interface"
  case "actor":
    kind = "actor"
  case "extension", "impl":
    kind = "extension"
  case "func", "function", "def", "fn":
    kind = "function"
  case "init", "deinit", "constructor":
    kind = "function"
  case "var", "let", "const":
    kind = "variable"
  case "typealias", "type":
    kind = "type"
  case "import", "package", "mod", "use":
    kind = "import"
  default:
    if language == "make", trimmed.hasSuffix(":"), !trimmed.hasPrefix("\t"),
      !trimmed.contains("=")
    {
      let target = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
      guard !target.isEmpty else {
        return nil
      }
      return FileOutlineItem(
        line: lineNumber,
        kind: "target",
        level: nil,
        name: target,
        text: line
      )
    }
    return nil
  }

  return declarationOutlineItem(kind: kind, rawName: rawName, line: line, lineNumber: lineNumber)
}

package func markdownHeading(_ trimmed: String, lineNumber: Int) -> FileOutlineItem? {
  var level = 0
  for scalar in trimmed.unicodeScalars {
    if scalar == "#" {
      level += 1
      continue
    }
    break
  }
  guard level > 0, level <= 6 else {
    return nil
  }
  let index = trimmed.index(trimmed.startIndex, offsetBy: level)
  guard index < trimmed.endIndex, trimmed[index].isWhitespace else {
    return nil
  }
  let name = trimmed[index...].trimmingCharacters(in: .whitespaces)
  guard !name.isEmpty else {
    return nil
  }
  return FileOutlineItem(
    line: lineNumber, kind: "heading", level: level, name: name, text: trimmed)
}

private func declarationOutlineItem(
  kind: String,
  rawName: String?,
  line: String,
  lineNumber: Int
) -> FileOutlineItem? {
  guard let rawName else {
    return nil
  }
  let name = cleanedOutlineName(rawName)
  guard !name.isEmpty else {
    return nil
  }
  return FileOutlineItem(
    line: lineNumber,
    kind: kind,
    level: nil,
    name: name,
    text: line.trimmingCharacters(in: .whitespaces)
  )
}

private func cleanedOutlineName(_ raw: String) -> String {
  let delimiters = CharacterSet(charactersIn: "({[:=<,")
  let scalarView = raw.unicodeScalars
  if let delimiter = scalarView.firstIndex(where: { delimiters.contains($0) }) {
    return String(String.UnicodeScalarView(scalarView[..<delimiter]))
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
  return raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t({[:=<,"))
}

package struct FileOutlineItem {
  package var line: Int
  package var kind: String
  package var level: Int?
  package var name: String
  package var text: String

  package init(line: Int, kind: String, level: Int?, name: String, text: String) {
    self.line = line
    self.kind = kind
    self.level = level
    self.name = name
    self.text = text
  }

  package var json: JSONValue {
    .object([
      "line": .integer(Int64(line)),
      "kind": .string(kind),
      "level": level.map { .integer(Int64($0)) } ?? .null,
      "name": .string(name),
      "text": .string(text),
    ])
  }
}
