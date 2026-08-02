import ArgumentParser
import ComputerMCPValidation
import Foundation

struct TestCaseCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "test-case",
    abstract: "Inspect and validate the canonical Validation Test Case catalog.",
    subcommands: [List.self, Validate.self]
  )

  struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "list",
      abstract: "List the canonical Validation Test Cases."
    )

    @Flag(name: .long, help: "Emit the complete catalog as JSON.")
    var json = false

    func run() throws {
      let catalog = try ValidationTestCaseCatalog.bundled()
      if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(catalog.testCases), as: UTF8.self))
      } else {
        for testCase in catalog.testCases {
          print(
            "\(testCase.id)\t\(testCase.category.rawValue)\t"
              + "\(testCase.transports.map(\.rawValue).joined(separator: ","))\t"
              + testCase.riskLevel.rawValue
          )
        }
      }
    }
  }

  struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "validate",
      abstract: "Validate schema, identifiers, steps, and fail-closed evidence requirements."
    )

    func run() throws {
      let catalog = try ValidationTestCaseCatalog.bundled()
      let issues = catalog.validate()
      guard issues.isEmpty else {
        for issue in issues {
          print("\(issue.testCaseID) [\(issue.field)] \(issue.message)")
        }
        throw ExitCode.failure
      }
      print(
        "Validated \(catalog.testCases.count) Validation Test Cases "
          + "(schema \(ValidationTestCaseCatalog.schemaVersion))."
      )
    }
  }
}

struct RunbookCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "runbook",
    abstract: "Generate a Validation Run runbook from the canonical Test Case catalog.",
    subcommands: [Generate.self]
  )

  struct Generate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "generate")

    @Option(
      name: .customLong("test-case"),
      help: "Generate one Test Case instead of the complete catalog."
    )
    var testCaseID: String?

    @Option(name: .long, help: "Write the Markdown runbook to this path.")
    var output: String?

    func run() throws {
      let rendered = try ValidationTestCaseCatalog.bundled().runbook(testCaseID: testCaseID)
      if let output {
        let url = URL(fileURLWithPath: output).standardizedFileURL
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try Data(rendered.utf8).write(to: url, options: .atomic)
      } else {
        print(rendered, terminator: "")
      }
    }
  }
}
