import ComputerMCPCore
import ComputerMCPSandbox
import Foundation
import Testing

@testable import ComputerMCPGateway
@testable import ComputerMCPPermissions
@testable import ComputerMCPProcess

struct FixedHostOperationTests {
  @Test func serializedDescriptorsCannotSelectHostExecution() throws {
    let descriptor = CapabilityDescriptor(
      id: "file.write", risk: .destructive, requirement: .init(access: .projectWrite),
      hostOperation: .fileMutation)
    let encoded = try JSONEncoder().encode(descriptor)
    #expect(try JSONDecoder().decode(CapabilityDescriptor.self, from: encoded).hostOperation == nil)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["hostOperation"] = "git"
    let supplied = try JSONSerialization.data(withJSONObject: object)
    #expect(
      try JSONDecoder().decode(CapabilityDescriptor.self, from: supplied).hostOperation == nil)
    #expect(
      CapabilityDescriptor(id: "git.fake", risk: .readOnly, requirement: .none).hostOperation == nil
    )
  }

  @Test(arguments: [HostOperation.fileMutation, .git], [false, true])
  func compilerRequiresConsentForWritesAndKeepsHelpersConfined(
    operation: HostOperation, fullAccess: Bool
  ) throws {
    var fixture = try SandboxCompilerFixture()
    let mode: ComputerMCPPermissions.ExecutionMode =
      fullAccess ? .fullAccess(.connection("client")) : .sandbox
    var environment = fixture.ledger.environment
    environment.connections["client"] = PermissionConnection(
      principal: fixture.principal,
      consent: fullAccess ? fixture.ledger.consent(for: fixture.principal, mode: mode) : nil)
    _ = try fixture.ledger.reconcile(
      environment: environment, expectedRevision: fixture.ledger.revision)
    let decision = try fixture.ledger.authorize(
      invocation: .init(
        principal: fixture.principal, tool: "fixed", projectID: "project", argumentsDigest: "digest"
      ),
      requirements: .init(
        actions: [.init(requirement: try PermissionRequirement(.project("project"), .write))],
        mode: mode, sandboxProjectID: "project"), connectionID: "client", now: Date())
    guard case .allowed(let proof) = decision else {
      Issue.record("Fixture admission failed")
      return
    }
    let directory = try SandboxPath("/people/me/Downloads/repo")
    let context = GatewaySandboxContext(
      directory: directory, temporaryDirectory: try SandboxPath("/tmp/execution"),
      fixedHostOperation: .init(
        operation: operation, gitExecutable: try SandboxPath("/usr/bin/git"),
        directory: directory, allowsWrites: true))
    if fullAccess {
      let configuration = try GatewaySandboxCompiler.compile(
        ledger: &fixture.ledger, authorizationID: proof.id, context: context)
      #expect(configuration.sandbox?.readOnly == true)
      #expect(!configuration.permitsProgramLaunch)
      #expect(configuration.egress.access == .none)
      if operation == .git {
        #expect(
          configuration.sandbox?.deniedWriteRegions.contains {
            $0.path.value == "/people/me/Downloads/repo/secret"
          } == true)
      }
    } else {
      #expect(throws: ExecutionEnvironmentError.self) {
        try GatewaySandboxCompiler.compile(
          ledger: &fixture.ledger, authorizationID: proof.id, context: context)
      }
    }
  }

  @Test(arguments: [HostOperation.fileMutation, .git])
  func readOnlyPreviewsKeepSandboxAdmission(operation: HostOperation) throws {
    var fixture = try SandboxCompilerFixture()
    let decision = try fixture.ledger.authorize(
      invocation: .init(
        principal: fixture.principal, tool: "preview", projectID: "project",
        argumentsDigest: "digest"),
      requirements: .init(
        actions: [.init(requirement: try PermissionRequirement(.project("project"), .read))],
        sandboxProjectID: "project"), now: Date())
    guard case .allowed(let proof) = decision else {
      Issue.record("Read admission failed")
      return
    }
    let directory = try SandboxPath("/people/me/Downloads/repo")
    let compiled = try GatewaySandboxCompiler.compile(
      ledger: &fixture.ledger, authorizationID: proof.id,
      context: .init(
        directory: directory, temporaryDirectory: try SandboxPath("/tmp/execution"),
        fixedHostOperation: .init(
          operation: operation, gitExecutable: try SandboxPath("/usr/bin/git"),
          directory: directory, allowsWrites: false)))
    #expect(compiled.sandbox?.readOnly == true)
    #expect(!compiled.permitsProgramLaunch)
  }

  @Test func exactHelperBindingSharesLimitsAndRechecksPathAuthority() throws {
    let authority = FixedOperationAuthority()
    let paths = FixedOperationPaths()
    let directory = try SandboxPath("/project")
    let temporary = try SandboxPath("/scratch")
    let sandbox = try SandboxConfiguration(
      readOnly: true, worktree: directory, temporaryDirectory: temporary,
      homeDirectory: temporary, cacheDirectory: temporary, readableRoots: [directory],
      forbiddenReads: [try SandboxPath("/project/private")])
    let context = PreparedExecutionContext(
      authority: authority, mode: .sandbox(sandbox),
      environment: try ExecutionEnvironment(
        searchPath: [try SandboxPath("/usr/bin")], home: temporary, temporary: temporary,
        cache: temporary),
      limits: authority.limits, pathAccess: paths, permitsProgramLaunch: false,
      fixedHostOperation: .init(
        operation: .git, gitExecutable: try SandboxPath("/usr/bin/git"), directory: directory,
        allowsWrites: true))
    let arguments = ["--no-pager", "status"]
    let environment = ["GIT_CONFIG_GLOBAL": "/dev/null"]
    #expect(throws: ExecutionEnvironmentError.self) {
      try context.validateFixedCommand(
        executable: .init("/usr/bin/git"), arguments: arguments,
        directory: directory, directoryDescriptor: nil, inheritedDescriptors: [:])
    }
    try context.withHostGitCommand(
      arguments: arguments, directory: directory, environment: environment,
      writing: .init("/project/.git")
    ) {
      let scoped = try #require(try PreparedExecutionContext.current())
      try HostCommandEnvironment.$current.withValue(environment) {
        try scoped.validateFixedCommand(
          executable: .init("/usr/bin/git"), arguments: arguments,
          directory: directory, directoryDescriptor: nil, inheritedDescriptors: [:])
        for executable in ["/bin/sh", "/project/git"] {
          #expect(throws: ExecutionEnvironmentError.self) {
            try scoped.validateFixedCommand(
              executable: .init(executable), arguments: arguments,
              directory: directory, directoryDescriptor: nil, inheritedDescriptors: [:])
          }
        }
        #expect(throws: ExecutionEnvironmentError.self) {
          try scoped.validateFixedCommand(
            executable: .init("/usr/bin/git"), arguments: ["shell"],
            directory: directory, directoryDescriptor: nil, inheritedDescriptors: [:])
        }
      }
      #expect(throws: ExecutionEnvironmentError.self) {
        try scoped.validateFixedCommand(
          executable: .init("/usr/bin/git"), arguments: arguments,
          directory: directory, directoryDescriptor: nil, inheritedDescriptors: [:])
      }
      guard case .sandbox(let policy) = scoped.mode else {
        Issue.record("Helper escaped sandbox")
        return
      }
      #expect(policy.hostGitDirectory == (try SandboxPath("/project/.git")))
      #expect(policy.forbiddenReads == sandbox.forbiddenReads)
      let limits = EffectiveExecutionLimits(
        timeMilliseconds: nil, outputBytes: 16, memoryBytes: nil, retentionSeconds: 60,
        retainedOutputBytes: 1024, sources: [:])
      context.applyLimits(limits)
      #expect(scoped.limits.outputBytes == 16)
    }
    paths.deny()
    #expect(throws: PermissionModelError.self) {
      try context.withHostGitCommand(
        arguments: arguments, directory: directory, environment: environment,
        writing: .init("/project/.git")
      ) { Issue.record("Revoked helper dispatched") }
    }
  }
}

private struct FixedOperationAuthority: ExecutionAuthorizing {
  let executionID = UUID()
  let authorizationIDs: Set<UUID> = [UUID()]
  let limits = EffectiveExecutionLimits(
    timeMilliseconds: nil, outputBytes: 1024, memoryBytes: nil, retentionSeconds: 60,
    retainedOutputBytes: 1024, sources: [:])
  func reserveChild(_ id: UUID) {}
  func bindChild(_ id: UUID, ownership: any ExecutionOwnership) {}
  func launchFailed(_ id: UUID) {}
  func finishAdmission() {}
  func access(_ executionID: UUID, operation: ExecutionOperation) -> EffectiveExecutionLimits {
    limits
  }
}

private final class FixedOperationPaths: HostPathAccessChecking, @unchecked Sendable {
  private let lock = NSLock()
  private var allowed = true
  func deny() { lock.withLock { allowed = false } }
  func check(_ path: URL, operation: HostPathOperation) throws {
    guard lock.withLock({ allowed }) else { throw PermissionModelError.invalidAuthorization }
  }
}
