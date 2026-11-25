import ComputerMCPCore
import Foundation
import Testing

@testable import ComputerMCPGateway

struct ClaudePrintRecipeTests {
  @Test func printArgumentsUseOnlyAdmittedTypedValues() throws {
    let recipe = try JSONDecoder().decode(ClaudePrintRecipe.self, from: Data(Self.recipe.utf8))
    #expect(recipe.isSupported)
    let prompt = "--allow-dangerously-skip-permissions"
    let arguments: [String: JSONValue] = [
      "prompt": .string(prompt), "model": .string("model-alias"), "effort": .string("high"),
      "session_id": .string("12345678-1234-4234-9234-123456789013"), "max_budget_usd": .number(0.5),
      "append_system_prompt": .string("--model=text"), "no_session_persistence": .bool(true),
      "timeout_seconds": .integer(30), "max_events": .integer(4),
    ]
    #expect(
      try recipe.arguments(arguments) == [
        "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
        "--permission-mode", "dontAsk", "--model=model-alias",
        "--session-id=12345678-1234-4234-9234-123456789013", "--max-budget-usd=0.5",
        "--effort=high", "--append-system-prompt=--model=text", "--no-session-persistence", "--",
        prompt,
      ])
    for extra: [String: JSONValue] in [
      ["permission_mode": .string("bypassPermissions")],
      ["argv": .array([.string("--tools")])],
      ["continue_previous": .bool(true)],
      ["resume_session_id": .string("persisted")],
      ["max_budget_usd": .integer(-1)],
      ["model": .string("a\0b")],
    ] {
      #expect(throws: VendorExecutionFailure.denied) {
        try recipe.arguments(arguments.merging(extra) { _, new in new })
      }
    }
    let changed = Self.recipe.replacingOccurrences(of: "--effort", with: "--tools")
    let mismatched = try JSONDecoder().decode(ClaudePrintRecipe.self, from: Data(changed.utf8))
    #expect(!mismatched.isSupported)
  }

  static let recipe = #"""
    {"kind":"print","argv":[
      {"kind":"literal","value":"-p"},
      {"kind":"literal","value":"--output-format"},
      {"kind":"literal","value":"stream-json"},
      {"kind":"literal","value":"--verbose"},
      {"kind":"literal","value":"--include-partial-messages"},
      {"kind":"option","parameter":"permission_mode","flag":"--permission-mode","style":"separate","default":"dontAsk"},
      {"kind":"option","parameter":"model","flag":"--model","style":"equals"},
      {"kind":"option","parameter":"resume_session_id","flag":"--resume","style":"equals"},
      {"kind":"option","parameter":"session_id","flag":"--session-id","style":"equals"},
      {"kind":"option","parameter":"max_budget_usd","flag":"--max-budget-usd","style":"equals"},
      {"kind":"option","parameter":"effort","flag":"--effort","style":"equals"},
      {"kind":"option","parameter":"append_system_prompt","flag":"--append-system-prompt","style":"equals"},
      {"kind":"flag","parameter":"continue_previous","flag":"--continue"},
      {"kind":"flag","parameter":"no_session_persistence","flag":"--no-session-persistence"},
      {"kind":"literal","value":"--"},
      {"kind":"positional","parameter":"prompt"}
    ]}
    """#
}
