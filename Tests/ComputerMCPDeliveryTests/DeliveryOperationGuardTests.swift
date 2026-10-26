import ComputerMCPConfiguration
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPDelivery

@Suite(.nativeIntegration)
struct DeliveryOperationGuardTests {
  @Test(arguments: [false, true])
  func deliveryRebaseDoesNotExecuteInstructionFormat(global: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let marker = fixture.temporary.url.appendingPathComponent("executed")
      let config = fixture.temporary.url.appendingPathComponent("owner.config")
      let format = "%s%nexec touch \(quote(marker.path))"
      try fixture.git(
        ["config"] + (global ? ["--file", config.path] : [])
          + ["rebase.instructionFormat", format])
      let io = DeliveryIO(beforeMergeCheck: { _ in
        guard !(try fixture.git(["log", "-1", "--format=%s"])).contains("advanced") else { return }
        try fixture.write("outside.txt", "advanced\n")
        try fixture.git(HostGitConfiguration.arguments + ["add", "--", "outside.txt"])
        try fixture.git(HostGitConfiguration.arguments + ["commit", "-m", "test: advanced"])
      })
      let provider = DeliveryToolProvider(
        environment: fixture.tools(
          extraEnvironment: global ? ["GIT_CONFIG_GLOBAL": config.path] : [:]),
        io: io, startsRecovery: false)
      let result = try fixture.apply(provider: provider)
      #expect(result["state"] == .string("merged"), "\(result)")
      #expect(try fixture.read("outside.txt") == "advanced\n")
      #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
  }

  @Test
  func hostOperationsDoNotRunRepositoryPrograms() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let marker = fixture.temporary.url.appendingPathComponent("executed")
      let command = "touch \(quote(marker.path))"
      try fixture.write("notes/hooks/post-merge", "#!/bin/sh\nexit 0\n")
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: fixture.root.appendingPathComponent("notes/hooks/post-merge").path)
      try fixture.git(["add", "--", "notes/hooks/post-merge"])
      try fixture.git(["commit", "-m", "test: executable hook fixture"])
      for name in [
        "pre-commit", "post-commit", "post-checkout", "post-merge", "reference-transaction",
      ] {
        try fixture.hook(name, body: command)
      }
      for key in [
        "core.fsmonitor", "core.editor", "sequence.editor", "core.pager", "core.askPass",
        "core.sshCommand", "credential.helper", "gpg.program", "gpg.openpgp.program",
        "gpg.x509.program", "gpg.ssh.program", "gpg.ssh.defaultKeyCommand", "diff.external",
        "diff.custom.command", "diff.custom.textconv", "merge.custom.driver",
        "filter.custom.clean", "filter.custom.smudge", "filter.custom.process",
        "hook.configured.command", "uploadpack.packObjectsHook",
      ] {
        try fixture.git(["config", key, command])
      }
      try fixture.git(["config", "hook.configured.event", "pre-commit"])
      try fixture.git(["config", "rebase.instructionFormat", "%s%nexec \(command)"])
      let io = DeliveryIO(beforeMergeCheck: { _ in
        // The pending commit introduces an executable hooks directory through tracked content.
        try fixture.git(["config", "core.hooksPath", "notes/hooks"])
        guard
          !(try fixture.git(HostGitConfiguration.arguments + ["log", "-1", "--format=%s"]))
            .contains("advanced")
        else { return }
        try fixture.write("outside.txt", "advanced\n")
        try fixture.git(HostGitConfiguration.arguments + ["add", "--", "outside.txt"])
        try fixture.git(
          HostGitConfiguration.arguments + [
            "-c", "hook.configured.enabled=false", "commit", "-m", "test: advanced",
          ])
      })
      var request = fixture.request().objectValue!
      request["edits"] = .array([
        fixture.replace("notes/log.md", "alpha", "beta"),
        fixture.replace("notes/hooks/post-merge", "exit 0", command),
      ])
      let result = try fixture.apply(.object(request), provider: fixture.provider(io: io))
      #expect(result["state"] == .string("merged"), "\(result)")
      #expect(!FileManager.default.fileExists(atPath: marker.path))
      // Control: the merged executable really is a hook when normal Git runs it.
      try fixture.git(["hook", "run", "post-merge", "--", "0"])
      #expect(FileManager.default.fileExists(atPath: marker.path))
    }
  }

  @Test(arguments: [false, true])
  func mergeRefusesFilterAttributes(incoming: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let marker = fixture.temporary.url.appendingPathComponent("filter-executed")
      let command = "touch \(quote(marker.path)); cat"
      var request = fixture.request().objectValue!
      if incoming {
        request["edits"] = .array([
          fixture.replace("notes/log.md", "alpha", "beta"),
          fixture.create("notes/.gitattributes", "log.md filter=custom\n"),
        ])
      } else {
        try fixture.write("notes/.gitattributes", "log.md filter=custom\n")
        try fixture.git(["-c", "filter.custom.clean=", "add", "--", "notes/.gitattributes"])
        try fixture.git(["commit", "-m", "test: filter attributes"])
      }
      for direction in ["clean", "smudge"] {
        try fixture.git(["config", "filter.custom.\(direction)", command])
      }
      #expect(!FileManager.default.fileExists(atPath: marker.path))
      let head = try fixture.git(["rev-parse", "HEAD"])
      let result = try fixture.apply(.object(request))
      #expect(result["state"] == .string("committed"), "\(result)")
      #expect(result["reason"] == .string("git_failed"))
      #expect(try fixture.git(["rev-parse", "HEAD"]) == head)
      #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
  }

  @Test(arguments: [false, true])
  func deliveryRefusesRepositoryIncludes(filter: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let marker = fixture.temporary.url.appendingPathComponent("conditional-executed")
      try fixture.write("notes/.gitattributes", filter ? "log.md filter=conditional\n" : "")
      try fixture.git(["add", "--", "notes/.gitattributes"])
      try fixture.git(["commit", "-m", "test: attributes"])
      let included = fixture.temporary.url.appendingPathComponent("conditional.config")
      let command = "touch \(quote(marker.path)); cat"
      try fixture.git(["config", "--file", included.path, "filter.conditional.smudge", command])
      try fixture.git(["config", "--file", included.path, "filter.conditional.clean", command])
      try fixture.git(["config", "--file", included.path, "hook.conditional.command", command])
      try fixture.git([
        "config", "--file", included.path, "hook.conditional.event", "post-checkout",
      ])
      try fixture.git(["config", "includeIf.onbranch:docs/**.path", included.path])
      var scope = fixture.scope
      scope.mode = filter ? .commitOnly : .land
      let result = try fixture.apply(provider: fixture.provider(scope: scope))
      #expect(result["state"] == .string("aborted"), "\(result)")
      #expect(result["reason"] == .string("git_failed"))
      #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
  }
}
