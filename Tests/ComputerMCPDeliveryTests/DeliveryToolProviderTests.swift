import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPDelivery

@Suite(.nativeIntegration)
struct DeliveryToolProviderTests {
  @Test
  func definitionsAndScopeListing() async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      let provider = fixture.provider()
      #expect(provider.id == "delivery" && provider.namespaces == ["delivery"])
      let definitions = provider.definitions()
      #expect(definitions.map(\.tool.name) == ["delivery.scopes.list", "delivery.apply"])
      #expect(definitions[0].capability.risk == .readOnly)
      #expect(definitions[1].capability.risk == .workspaceWrite)
      for definition in definitions {
        #expect(definition.capability.id == definition.tool.name)
        #expect(definition.capability.workspaceRequirement == .required)
        #expect(!definition.capability.usesNetwork && !definition.capability.localOnly)
        #expect(definition.tool.annotations?.openWorldHint == false)
      }
      let response = try provider.callTool(
        .init(name: "delivery.scopes.list", arguments: nil, context: .empty))
      let scopes = try #require(
        response.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?["scopes"]?
          .arrayValue)
      #expect(scopes.count == 1)
      #expect(
        Set(scopes[0].objectValue!.keys) == [
          "id", "repository", "paths", "default_branch", "worktree_root", "sparse", "mode",
        ])
      #expect(scopes[0].objectValue?["id"] == .string("notes"))
      let disabled = DeliveryToolProvider(environment: .init(configuration: .init()))
      #expect(disabled.definitions().isEmpty)
      #expect(throws: GatewayToolError.self) {
        try disabled.callTool(
          .init(name: "delivery.apply", arguments: fixture.request(), context: .empty))
      }
    }
  }

  @Test
  func landOrderedEditsAndCreateWithReadbackAndSnippets() async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      var request = fixture.request().objectValue!
      request["edits"] = .array([
        fixture.replace("notes/./log.md", "alpha", "beta"),
        fixture.replace("notes/log.md", "beta", "final"),
        fixture.create("notes/new/deep.txt", "new\nfile\n"),
      ])
      let result = try fixture.apply(.object(request))
      #expect(result["state"] == .string("merged"), "\(result)")
      #expect(result["reason"] == nil && result["branch"] == nil)
      #expect(result["commit"]?.stringValue?.count == 40)
      #expect(try fixture.read("notes/log.md") == "final\nstable\n")
      #expect(try fixture.read("notes/new/deep.txt") == "new\nfile\n")
      #expect(try fixture.read("outside.txt") == "untouched\n")
      #expect(result["files"]?.arrayValue?.count == 2)
      #expect(try fixture.journals().first?.phase == .finished)
      try fixture.assertClean()
    }
  }

  @Test(arguments: [("missing", "match_missing"), ("a", "match_ambiguous")])
  func missingAndMultipleMatches(old: String, reason: String) async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      let result = try fixture.apply(fixture.request(old: old))
      #expect(result["state"] == .string("aborted"))
      #expect(result["reason"] == .string(reason))
      #expect(result["code"] == .string("delivery.\(reason)"))
      try fixture.assertClean()
      #expect(try fixture.read("notes/log.md") == "alpha\nstable\n")
    }
  }

  @Test
  func failedEditRollsBackAllEarlierEdits() async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      var request = fixture.request().objectValue!
      request["edits"] = .array([
        fixture.create("notes/earlier.txt", "earlier"),
        fixture.replace("notes/log.md", "absent", "x"),
      ])
      let result = try fixture.apply(.object(request))
      #expect(result["reason"] == .string("match_missing"))
      #expect(
        !FileManager.default.fileExists(
          atPath: fixture.root.appendingPathComponent("notes/earlier.txt").path))
      try fixture.assertClean()
    }
  }

  @Test(arguments: ["notes/log.md", "notes/missing.md", "notes/binary.md"])
  func fileStateRejections(path: String) async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      if path.hasSuffix("binary.md") {
        try Data([0xff, 0xfe]).write(to: fixture.root.appendingPathComponent(path))
        try fixture.git(["add", path])
        try fixture.git(["commit", "-m", "test: add binary"])
      }
      var request = fixture.request(path: path).objectValue!
      let reason: String
      if path == "notes/log.md" {
        request["edits"] = .array([fixture.create(path, "exists")])
        reason = "file_exists"
      } else {
        reason = path.hasSuffix("binary.md") ? "not_text" : "file_missing"
      }
      #expect(try fixture.apply(.object(request))["reason"] == .string(reason))
      try fixture.assertClean()
    }
  }

  @Test(arguments: [
    "../outside.txt", "/tmp/outside.txt", "notes/../../outside.txt", ".git/config",
    "notes/.git/config", "notes\\log.md", "outside.txt",
  ])
  func pathRejections(path: String) async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      let reason = path == "outside.txt" ? "path_outside_scope" : "path_invalid"
      #expect(try fixture.apply(fixture.request(path: path))["reason"] == .string(reason))
      #expect(try fixture.journals().isEmpty)
      try fixture.assertClean()
    }
  }

  @Test(arguments: [false, true])
  func symlinkEscapeAndDanglingSymlink(dangling: Bool) async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      let target = fixture.temporary.url.appendingPathComponent(dangling ? "absent" : "outside")
      if !dangling {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
      }
      try FileManager.default.createSymbolicLink(
        at: fixture.root.appendingPathComponent("notes/link"), withDestinationURL: target)
      try fixture.git(["add", "notes/link"])
      try fixture.git(["commit", "-m", "test: add symlink"])
      #expect(
        try fixture.apply(fixture.request(path: "notes/link/file.txt"))["reason"]
          == .string("path_invalid"))
      #expect(try fixture.journals().isEmpty)
      try fixture.assertClean()
    }
  }

  @Test(arguments: [false, true])
  func mainTargetDirty(staged: Bool) async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      try fixture.write("notes/log.md", "local change\n")
      if staged { try fixture.git(["add", "notes/log.md"]) }
      #expect(try fixture.apply()["reason"] == .string("main_checkout_dirty"))
      #expect(try fixture.read("notes/log.md") == "local change\n")
      #expect(try fixture.journals().isEmpty)
    }
  }

  @Test(arguments: [false, true])
  func untrackedAndIgnoredTargetsAreDirty(ignored: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let path = ignored ? "notes/new.ignored" : "notes/new.md"
      if ignored {
        try fixture.write(".gitignore", ".claude/worktrees/\n*.ignored\n")
        try fixture.git(["add", ".gitignore"])
        try fixture.git(["commit", "-m", "test: ignore local files"])
      }
      try fixture.write(path, "local content")
      var request = fixture.request().objectValue!
      request["edits"] = .array([fixture.create(path, "delivery content")])
      #expect(try fixture.apply(.object(request))["reason"] == .string("main_checkout_dirty"))
      #expect(try fixture.read(path) == "local content")
      #expect(try fixture.journals().isEmpty)
    }
  }

  @Test
  func unrelatedMainChangesArePreserved() async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      try fixture.write("outside.txt", "local change\n")
      try fixture.git(["add", "outside.txt"])
      #expect(try fixture.apply()["state"] == .string("merged"))
      #expect(try fixture.read("outside.txt") == "local change\n")
      #expect(try fixture.git(["diff", "--cached", "--name-only"]) == "outside.txt")
    }
  }

  @Test
  func mainBranchAndUnignoredRootAndExistingBranch() async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      try fixture.git(["switch", "-c", "other"])
      #expect(try fixture.apply()["reason"] == .string("main_checkout_branch"))
      try fixture.git(["switch", "main"])
      try fixture.git(["branch", "docs/entry"])
      #expect(try fixture.apply()["reason"] == .string("branch_exists"))
      #expect(try fixture.journals().isEmpty)
      let unignored = try DeliveryFixture(ignored: false)
      #expect(try unignored.apply()["reason"] == .string("worktree_root_not_ignored"))
      #expect(try unignored.journals().isEmpty)
    }
  }

  @Test(arguments: [
    "plain message", "unknown: subject", "feat: ",
    "docs: entry\n\nCo-Authored-By: Person <person@example.invalid>",
    "docs: entry\n\nBody\n\nSigned-off-by: Person", "docs: entry\n\nReviewed-by: Person",
    "docs: entry\r\rSigned-off-by: Person", "docs: entry\r\n\r\nReviewed-by: Person",
  ])
  func invalidMessages(message: String) async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      #expect(
        try fixture.apply(fixture.request(message: message))["reason"] == .string("message_invalid")
      )
      #expect(try fixture.journals().isEmpty)
    }
  }

  @Test(arguments: [
    "feat(core)!: subject\n\nA useful body.", "fix!: subject", "docs(scope): subject",
  ])
  func validConventionalMessages(message: String) async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      #expect(try fixture.apply(fixture.request(message: message))["state"] == .string("merged"))
    }
  }

  @Test
  func commitOnlyKeepsBranchOnAnotherMainBranch() async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      try fixture.git(["switch", "-c", "other"])
      var scope = fixture.scope
      scope.mode = .commitOnly
      let result = try fixture.apply(provider: fixture.provider(scope: scope))
      #expect(result["state"] == .string("committed"))
      #expect(result["reason"] == .string("commit_only"))
      #expect(result["branch"] == .string("docs/entry"))
      #expect(try fixture.read("notes/log.md") == "alpha\nstable\n")
      try fixture.assertClean(retained: true)
    }
  }

  @Test(arguments: [false, true])
  func rebaseAfterDefaultAdvances(conflict: Bool) async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      try fixture.advanceDuringCommit(conflict: conflict)
      let result = try fixture.apply()
      #expect(result["state"] == .string(conflict ? "committed" : "merged"))
      #expect(result["reason"] == (conflict ? .string("rebase_conflict") : nil))
      #expect(try fixture.read("notes/log.md") == (conflict ? "gamma\nstable\n" : "beta\nstable\n"))
      if conflict {
        #expect(try fixture.git(["show", "docs/entry:notes/log.md"]) == "beta\nstable")
        #expect(try fixture.git(["rev-parse", "docs/entry"]) == result["commit"]?.stringValue)
      }
      try fixture.assertClean(retained: conflict)
    }
  }

  @Test
  func secondFastForwardFailureRetainsRebasedCommit() async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      try fixture.advanceDuringCommit(twice: true)
      let result = try fixture.apply()
      #expect(result["state"] == .string("committed"))
      #expect(result["reason"] == .string("not_fast_forward"))
      #expect(try fixture.git(["rev-parse", "docs/entry"]) == result["commit"]?.stringValue)
      try fixture.assertClean(retained: true)
    }
  }

  @Test
  func sparseCheckoutAndLiteralPaths() async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      var scope = fixture.scope
      scope.sparse = true
      var request = fixture.request().objectValue!
      request["edits"] = .array([
        fixture.replace("notes/log.md", "alpha", "beta"),
        fixture.create("notes/[literal]*.txt", "literal"),
      ])
      let result = try fixture.apply(.object(request), provider: fixture.provider(scope: scope))
      #expect(result["state"] == .string("merged"))
      #expect(try fixture.read("notes/[literal]*.txt") == "literal")
      try fixture.assertClean()
    }
  }

  @Test
  func sanitizedGitEnvironmentAndHooks() async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      try fixture.hook(
        "pre-commit", body: "test \"$GIT_TERMINAL_PROMPT\" = 0\n! test -v GIT_CONFIG_COUNT")
      let environment = fixture.tools(
        extraEnvironment: [
          "GIT_DIR": "/missing", "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "user.name",
          "GIT_CONFIG_VALUE_0": "Bad",
        ],
        commandEnvironment: ["GIT_WORK_TREE": "/missing", "GIT_TERMINAL_PROMPT": "1"])
      let provider = DeliveryToolProvider(
        environment: environment, io: .init(), startsRecovery: false)
      #expect(try fixture.apply(provider: provider)["state"] == .string("merged"))
      #expect(try fixture.git(["log", "-1", "--format=%an"]) == "Delivery Test")
    }
  }

  @Test
  func hookFailureReturnsBoundedGitError() async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      try fixture.hook("pre-commit", body: "printf 'hook rejected' >&2\nexit 7")
      let result = try fixture.apply()
      #expect(result["state"] == .string("aborted"))
      #expect(result["reason"] == .string("git_failed"))
      #expect(result["exit_code"] != nil)
      #expect(result["stderr"]?.stringValue?.contains("hook rejected") == true)
      try fixture.assertClean()
    }
  }
  @Test
  func perCommandTimeoutStopsGitAndPreservesTheMainCheckout() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      try fixture.hook(
        "pre-commit",
        body:
          "touch \(quote(fixture.root.appendingPathComponent(".git/timeout-entered").path))\nsleep 5"
      )
      let provider = DeliveryToolProvider(
        environment: fixture.tools(timeout: 1000), io: .init(), startsRecovery: false)
      let result = try fixture.apply(provider: provider)
      #expect(result["state"] == .string("aborted"), "\(result)")
      #expect(result["reason"] == .string("git_failed"))
      #expect(
        FileManager.default.fileExists(
          atPath: fixture.root.appendingPathComponent(".git/timeout-entered").path))
      #expect(try fixture.read("notes/log.md") == "alpha\nstable\n")
      try fixture.assertClean()
    }
  }

}
