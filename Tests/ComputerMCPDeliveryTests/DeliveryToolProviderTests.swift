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
      #expect(definitions[1].capability.risk == .projectWrite)
      for definition in definitions {
        #expect(definition.capability.id == definition.tool.name)
        #expect(definition.capability.projectRequirement == .required)
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

  @Test(arguments: [false, true])
  func preflightLeavesIndexBytesUnchanged(rejected: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      if rejected { try fixture.git(["branch", "docs/entry"]) }
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1)],
        ofItemAtPath: fixture.root.appendingPathComponent("notes/log.md").path)
      let index = fixture.root.appendingPathComponent(".git/index")
      let before = try Data(contentsOf: index)
      let repository = try fixture.repository()
      let request = try DeliveryRequest(arguments: fixture.request())
      if rejected {
        #expect(throws: DeliveryFailure.self) { try repository.preflight(request) }
      } else {
        #expect(try repository.preflight(request) == fixture.git(["rev-parse", "main"]))
      }
      #expect(try Data(contentsOf: index) == before)
      #expect(try fixture.journals().isEmpty)
      // Confirm the stale stat data would have caused an ordinary status to rewrite this index.
      try fixture.git(["status", "--porcelain=v1", "--", "notes/log.md"])
      #expect(try Data(contentsOf: index) != before)
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
    "docs: entry\n\nKey:value", "docs: entry\n\nKey : value", "docs: entry\n\nKey:",
    "docs: entry\n\nSigned-off-by:Person", "docs: entry\n\nSigned-off-by : Person",
    "docs: entry\n\nSigned-off-by:", "docs: entry\n\nReviewed-by: Person\n continued value",
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

  @Test
  func repositoryConfiguredTrailersAreRejected() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      try fixture.git(["config", "trailer.separators", "="])
      let result = try fixture.apply(fixture.request(message: "docs: entry\n\nReviewed-by=Person"))
      #expect(result["state"] == .string("aborted"))
      #expect(result["reason"] == .string("message_invalid"))
      #expect(try fixture.journals().isEmpty)
      try fixture.assertClean()
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
  func squashMergeOptionsStillFastForward(rebased: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      try fixture.git(["config", "branch.main.mergeOptions", "--squash --no-commit"])
      try fixture.git(["config", "merge.ff", "false"])
      if rebased { try fixture.advanceDuringCommit() }
      let result = try fixture.apply()
      #expect(result["state"] == .string("merged"))
      #expect(result["branch"] == nil && result["reason"] == nil)
      #expect(try fixture.git(["rev-parse", "HEAD"]) == result["commit"]?.stringValue)
      #expect(try fixture.git(["diff", "--cached", "--name-only"]).isEmpty)
      #expect(try fixture.read("notes/log.md") == "beta\nstable\n")
      #expect(try fixture.journals().first?.merged == true)
      try fixture.assertClean()
    }
  }

  @Test(arguments: [false, true])
  func successfulMergeWithoutHeadAdvancementRetainsBranch(rebased: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      if rebased { try fixture.advanceDuringCommit() }
      let wrapper = fixture.temporary.url.appendingPathComponent("git-wrapper")
      let script = """
        #!\(try testExecutable("sh"))
        for argument do
          if test "$argument" = merge; then exit 0; fi
        done
        exec \(quote(fixture.interceptedExecutable)) "$@"
        """
      try Data(script.utf8).write(to: wrapper)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
      var configuration = fixture.tools().configuration
      configuration.cli.commands[0].executable = wrapper.path
      let provider = DeliveryToolProvider(
        environment: .init(configuration: configuration, environment: fixture.environment),
        io: .init(), startsRecovery: false)
      let result = try fixture.apply(provider: provider)
      #expect(result["state"] == .string("committed"))
      #expect(result["reason"] == .string("not_fast_forward"))
      #expect(result["branch"] == .string("docs/entry"))
      #expect(try fixture.git(["rev-parse", "HEAD"]) != result["commit"]?.stringValue)
      #expect(try fixture.git(["rev-parse", "docs/entry"]) == result["commit"]?.stringValue)
      #expect(try fixture.read("notes/log.md") == "alpha\nstable\n")
      #expect(try fixture.journals().first?.merged == false)
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

  @Test(arguments: [DeliveryScope.Mode.land, .commitOnly])
  func concurrentlyStagedPathsRetainCommitWithoutLanding(mode: DeliveryScope.Mode) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let head = try fixture.git(["rev-parse", "HEAD"])
      try fixture.interceptGit(
        "before-commit", body: "printf 'concurrent change\\n' > outside.txt\ngit add -- outside.txt"
      )
      var scope = fixture.scope
      scope.mode = mode
      let result = try fixture.apply(provider: fixture.provider(scope: scope))
      #expect(result["state"] == .string("committed"))
      #expect(result["reason"] == .string("scope_changed"))
      #expect(result["branch"] == .string("docs/entry"))
      #expect(try fixture.git(["rev-parse", "HEAD"]) == head)
      #expect(try fixture.git(["rev-parse", "docs/entry"]) == result["commit"]?.stringValue)
      #expect(try fixture.git(["show", "docs/entry:outside.txt"]) == "concurrent change")
      #expect(try fixture.read("outside.txt") == "untouched\n")
      #expect(try fixture.journals().first?.reason == .scopeChanged)
      try fixture.assertClean(retained: true)
    }
  }

  @Test
  func alreadyAppliedPatchRetainsBranchAfterEmptyRebase() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let main = quote(fixture.root.path)
      let clean =
        "env -i PATH=\(quote(systemUtilityPath)) HOME=\(quote(fixture.temporary.url.path)) \(quote(fixture.executable)) -C \(main) -c core.hooksPath=/dev/null"
      try fixture.interceptGit(
        "after-commit",
        body: """
          printf 'beta\\nstable\\n' > \(main)/notes/log.md
          \(clean) commit -am 'test: independently apply the same patch'
          rm "$0"
          """)
      let result = try fixture.apply()
      #expect(result["state"] == .string("committed"))
      #expect(result["reason"] == .string("scope_changed"))
      #expect(result["branch"] == .string("docs/entry"))
      #expect(try fixture.git(["rev-parse", "HEAD"]) == result["commit"]?.stringValue)
      #expect(try fixture.git(["rev-parse", "docs/entry"]) == result["commit"]?.stringValue)
      let journal = try #require(fixture.journals().first)
      #expect(journal.state == .committed && !journal.merged && journal.phase == .finished)
      #expect(journal.reason == .scopeChanged)
      try fixture.assertClean(retained: true)
    }
  }

  @Test(arguments: [false, true])
  func branchAdvancementBeforeMergeLandsVerifiedCommit(rebased: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      if rebased { try fixture.advanceDuringCommit() }
      let git = quote(fixture.executable)
      let provider = try fixture.provider(
        wrappingGit: """
          case " $* " in *" merge "*)
            for verified do :; done
            if \(git) merge-base --is-ancestor main "$verified"; then
              advanced=$(\(git) commit-tree "$verified^{tree}" -p "$verified" -m 'test: advance delivery branch') || exit
              \(git) update-ref refs/heads/docs/entry "$advanced" "$verified" || exit
              printf '%s' "$verified" > .git/verified-commit
              printf '%s' "$advanced" > .git/advanced-commit
            fi
          esac
          """)
      let result = try fixture.apply(provider: provider)
      let verified = try fixture.read(".git/verified-commit")
      let advanced = try fixture.read(".git/advanced-commit")
      #expect(result["commit"] == .string(verified))
      #expect(try fixture.git(["rev-parse", "HEAD"]) == verified)
      #expect(try fixture.git(["rev-parse", "docs/entry"]) == advanced)
      #expect(result["state"] == .string("cleanup_pending"))
      #expect(result["reason"] == .string("cleanup_failed"))
      #expect(result["branch"] == .string("docs/entry"))
      #expect(try fixture.journals().first?.merged == true)
      try fixture.assertClean(retained: true)
    }
  }

  @Test(arguments: [false, true], ["concurrent_advancement", "command_failure", "timeout"])
  func postMergeDescendantRetainsBranch(rebased: Bool, outcome: String) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      if rebased { try fixture.advanceDuringCommit() }
      let clean =
        "env -i PATH=\(quote(systemUtilityPath)) HOME=\(quote(fixture.temporary.url.path)) \(quote(fixture.executable)) -C \(quote(fixture.root.path)) -c core.hooksPath=/dev/null"
      try fixture.interceptGit(
        "after-merge",
        body: """
          \(clean) commit --allow-empty -m 'test: post-merge descendant'
          \(outcome == "timeout" ? "sleep 5" : "exit 7")
          """)
      let provider = try fixture.provider(
        wrappingGit: outcome == "command_failure"
          ? """
          case " $* " in *" merge "*)
            \(quote(fixture.interceptedExecutable)) "$@" || exit $?
            exit 79
          esac
          """ : "", timeout: outcome == "timeout" ? 1500 : nil)
      let result = try fixture.apply(provider: provider)
      #expect(result["state"] == .string("committed"), "\(result)")
      #expect(result["branch"] == .string("docs/entry"))
      #expect(
        result["reason"]
          == .string(outcome == "concurrent_advancement" ? "not_fast_forward" : "git_failed"))
      #expect(try fixture.git(["rev-parse", "HEAD"]) != result["commit"]?.stringValue)
      #expect(try fixture.git(["rev-parse", "HEAD^"]) == result["commit"]?.stringValue)
      #expect(try fixture.git(["rev-parse", "docs/entry"]) == result["commit"]?.stringValue)
      #expect(try fixture.journals().first?.merged == false)
      try fixture.assertClean(retained: true)
    }
  }

  @Test(arguments: [false, true], ["accepted_failure", "exception", "timeout"])
  func exactHeadAfterMergeFailureCountsAsMerged(rebased: Bool, outcome: String) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      if rebased { try fixture.advanceDuringCommit() }
      let ending = outcome == "timeout" ? "sleep 5" : "exit \(outcome == "exception" ? 79 : 1)"
      let provider = try fixture.provider(
        wrappingGit: """
          case " $* " in *" merge "*)
            \(quote(fixture.interceptedExecutable)) "$@" || exit $?
            \(ending)
          esac
          """, timeout: outcome == "timeout" ? 1500 : nil)
      let result = try fixture.apply(provider: provider)
      #expect(result["state"] == .string("merged"), "\(result)")
      #expect(result["reason"] == nil && result["branch"] == nil)
      #expect(try fixture.git(["rev-parse", "HEAD"]) == result["commit"]?.stringValue)
      #expect(try fixture.journals().first?.merged == true)
      try fixture.assertClean()
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

  @Test(arguments: ["private/log.md", "notes/renamed.md"])
  func rebaseRenameRetainsBranchWithoutLanding(path: String) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let main = quote(fixture.root.path)
      let clean =
        "env -i PATH=\(quote(systemUtilityPath)) HOME=\(quote(fixture.temporary.url.path)) \(quote(fixture.executable)) -C \(main) -c core.hooksPath=/dev/null"
      try fixture.interceptGit(
        "after-commit",
        body: """
          mkdir -p \(main)/\(quote(String(path.split(separator: "/")[0])))
          \(clean) mv notes/log.md \(quote(path))
          \(clean) commit -m 'test: rename target on default branch'
          rm "$0"
          """)
      let result = try fixture.apply()
      #expect(result["state"] == .string("committed"))
      #expect(result["reason"] == .string("scope_changed"))
      #expect(result["branch"] == .string("docs/entry"))
      #expect(try fixture.read(path) == "alpha\nstable\n")
      #expect(try fixture.git(["show", "docs/entry:\(path)"]) == "beta\nstable")
      #expect(try fixture.git(["rev-parse", "docs/entry"]) == result["commit"]?.stringValue)
      #expect(try fixture.journals().first?.reason == .scopeChanged)
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
      #expect(result["state"] == .string("merged"), "\(result)")
      #expect(try fixture.read("notes/[literal]*.txt") == "literal")
      try fixture.assertClean()
    }
  }

  @Test
  func sanitizedGitEnvironmentAndHooks() async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      try fixture.interceptGit(
        "before-commit", body: "test \"$GIT_TERMINAL_PROMPT\" = 0\ntest \"$GIT_CONFIG_COUNT\" = 0")
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
  func commandFailureReturnsBoundedGitError() async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      try fixture.interceptGit("before-commit", body: "printf 'command rejected' >&2\nexit 7")
      let result = try fixture.apply()
      #expect(result["state"] == .string("aborted"))
      #expect(result["reason"] == .string("git_failed"))
      #expect(result["exit_code"] != nil)
      #expect(result["stderr"]?.stringValue?.contains("command rejected") == true)
      try fixture.assertClean()
    }
  }
  @Test
  func perCommandTimeoutStopsGitAndPreservesTheMainCheckout() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      try fixture.interceptGit(
        "before-commit",
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
