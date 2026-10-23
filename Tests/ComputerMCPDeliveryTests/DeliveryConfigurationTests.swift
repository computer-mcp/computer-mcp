import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPDelivery

@Suite(.nativeIntegration)
struct DeliveryConfigurationTests {
  @Test(arguments: [false, true])
  func standaloneAndAppManifestsRoundTrip(app: Bool) async throws {
    try await deliveryTest {

      let temporary = try ScopedTemporaryDirectory()
      let manifest = """
        schema_version = 1
        [[projects]]
        id = "project"
        \(app ? "" : "path = \".\"")
        [[delivery.scopes]]
        id = "journal"
        project = "project"
        paths = ["notes/**/*.md", "exports/*.csv"]
        default_branch = "main"
        """
      let configuration = try GatewayConfiguration.load(text: manifest, baseURL: temporary.url)
      let scope = try #require(configuration.delivery.scopes.first)
      #expect(scope.repository == "." && scope.worktreeRoot == ".claude/worktrees")
      #expect(!scope.sparse && scope.mode == .land)
      let exported = try configuration.exportedTOML()
      #expect(exported.contains("[[delivery.scopes]]"))
      #expect(
        try GatewayConfiguration.load(text: exported, baseURL: temporary.url) == configuration)
      var changed = configuration
      changed.delivery.scopes[0].mode = .commitOnly
      changed.delivery.scopes[0].sparse = true
      #expect(
        try GatewayConfiguration.load(text: changed.exportedTOML(), baseURL: temporary.url).delivery
          == changed.delivery)
    }
  }

  @Test(arguments: [
    "repository = \"../outside\"", "repository = \"/absolute\"", "worktree_root = \"../outside\"",
    "worktree_root = \".git/worktrees\"", "paths = [\"../*.md\"]", "paths = [\"/notes/**\"]",
    "paths = [\"notes/***\"]", "paths = []", "paths = [\"notes/[\"]", "mode = \"unknown\"",
    "project = \"missing\"", "default_branch = \"bad..branch\"",
  ])
  func invalidScopeFields(override: String) async throws {
    try await deliveryTest {

      let defaults = [
        "id = \"journal\"", "project = \"project\"", "paths = [\"notes/**\"]",
        "default_branch = \"main\"",
      ]
      let key = override.split(separator: "=").first!.trimmingCharacters(in: .whitespaces)
      let fields = defaults.filter { !$0.hasPrefix(key + " =") } + [override]
      let manifest =
        "schema_version = 1\n[[projects]]\nid = \"project\"\n[[delivery.scopes]]\n"
        + fields.joined(separator: "\n")
      #expect(throws: (any Error).self) { try GatewayConfiguration.load(text: manifest) }
    }
  }

  @Test
  func duplicateScopeIDsAndUnknownFieldsAreRejected() async throws {
    try await deliveryTest {

      var configuration = GatewayConfiguration(
        projects: [.init(id: "project")],
        delivery: .init(scopes: [
          .init(id: "same", project: "project", paths: ["**"], defaultBranch: "main"),
          .init(id: "same", project: "project", paths: ["notes/**"], defaultBranch: "main"),
        ]))
      #expect(throws: ConfigurationError.self) { try configuration.validate() }
      configuration.delivery.scopes.removeLast()
      let text = try configuration.exportedTOML()
      #expect(throws: ConfigurationError.self) {
        try GatewayConfiguration.load(text: text + "\n[delivery.extra]\nfield = true")
      }
    }
  }

  @Test
  func globSemantics() async throws {
    try await deliveryTest {

      let scope = DeliveryScope(
        id: "notes", project: "project", paths: ["notes/*.txt", "logs/**/*.md"],
        defaultBranch: "main")
      #expect(scope.contains(path: "notes/day.txt"))
      #expect(!scope.contains(path: "notes/nested/day.txt"))
      #expect(scope.contains(path: "logs/day.md"))
      #expect(scope.contains(path: "logs/year/month/day.md"))
      #expect(!scope.contains(path: "other/day.md"))
    }
  }

  @Test
  func worktreeRootSymlinkRejectedBeforeJournal() async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      try FileManager.default.createSymbolicLink(
        at: fixture.root.appendingPathComponent("linked"), withDestinationURL: fixture.temporary.url
      )
      var scope = fixture.scope
      scope.worktreeRoot = "linked/worktrees"
      #expect(
        try fixture.apply(provider: fixture.provider(scope: scope))["reason"]
          == .string("path_invalid"))
      #expect(try fixture.journals().isEmpty)
    }
  }

  @Test
  func inputBoundsAndErrorEnvelope() async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      let provider = fixture.provider()
      var request = fixture.request().objectValue!
      for slug in ["", "Upper", "trailing-", String(repeating: "a", count: 49)] {
        request["slug"] = .string(slug)
        #expect(try fixture.apply(.object(request))["reason"] == .string("message_invalid"))
      }
      request = fixture.request().objectValue!
      for count in [0, 65] {
        request["edits"] = .array(
          Array(repeating: fixture.create("notes/a.txt", "a"), count: count))
        #expect(try fixture.apply(.object(request))["reason"] == .string("path_invalid"))
      }
      request["edits"] = .array([
        fixture.create("notes/a.txt", String(repeating: "a", count: 1_048_577))
      ])
      #expect(try fixture.apply(.object(request))["reason"] == .string("path_invalid"))
      request["edits"] = .array([
        fixture.replace(
          "notes/log.md", String(repeating: "a", count: 600_000),
          String(repeating: "b", count: 600_000))
      ])
      #expect(try fixture.apply(.object(request))["reason"] == .string("path_invalid"))
      request = fixture.request().objectValue!
      request["scope"] = .string("unknown")
      let error = try provider.callTool(
        .init(name: "delivery.apply", arguments: .object(request), context: .empty))
      #expect(error.objectValue?["isError"] == .bool(true))
      #expect(
        error.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?["code"]
          == .string("delivery.scope_unknown"))
    }
  }

  @Test
  func snippetsUseFinalTextContextAndByteLimits() async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      try fixture.write("notes/log.md", (0..<15).map { "line \($0)" }.joined(separator: "\n"))
      try fixture.git(["add", "notes/log.md"])
      try fixture.git(["commit", "-m", "test: multiline input"])
      var request = fixture.request(old: "line 7", new: "changed").objectValue!
      request["edits"] = .array([
        fixture.replace("notes/log.md", "line 7", "changed"),
        fixture.create(
          "notes/new.txt",
          (0..<30).map { _ in String(repeating: "中", count: 200) }.joined(separator: "\n")),
      ])
      let result = try fixture.apply(.object(request))
      let files = try #require(result["files"]?.arrayValue)
      let existing = try #require(
        files.first { $0.objectValue?["path"] == .string("notes/log.md") })
      #expect(
        existing.objectValue?["snippets"]?.arrayValue == [
          .string("line 4\nline 5\nline 6\nchanged\nline 8\nline 9\nline 10")
        ])
      for file in files {
        for snippet in file.objectValue?["snippets"]?.arrayValue ?? [] {
          #expect(snippet.stringValue!.utf8.count <= 4096)
          #expect(!snippet.stringValue!.contains("�"))
        }
      }
    }
  }
}
