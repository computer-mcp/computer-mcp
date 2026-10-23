import Foundation
import Testing

@testable import ComputerMCPPermissions

let client = Principal.client("client-a")
let otherClient = Principal.client("client-b")
let instant = Date(timeIntervalSince1970: 1_000_000)

func path(_ value: String) -> CanonicalPath { try! CanonicalPath(value) }

func requirement(_ permission: Permission, _ value: PermissionValue) -> PermissionRequirement {
  try! PermissionRequirement(permission, value)
}

func invocation(
  principal: Principal = client, tool: String = "run", project: String? = "project",
  digest: String = "sha256:arguments"
) -> InvocationIdentity {
  InvocationIdentity(principal: principal, tool: tool, projectID: project, argumentsDigest: digest)
}

func action(
  _ permission: Permission = .screen, _ value: PermissionValue = .access,
  scope: RequestScope = .principal
) -> PermissionAction {
  PermissionAction(requirement: requirement(permission, value), scope: scope)
}

func granted(_ pairs: [(Permission, PermissionValue)]) throws -> Permissions {
  var rules = Permissions.newPrincipal
  for (permission, value) in pairs { try rules.set(.granted(value), for: permission) }
  return rules
}

func request(from decision: AuthorizationDecision) throws -> PermissionRequest {
  guard case .requests(let requests) = decision else {
    Issue.record("Expected a permission request, received \(decision)")
    throw PermissionModelError.unknownRequest
  }
  return try #require(requests.first)
}

func authorization(from decision: AuthorizationDecision) throws -> InvocationAuthorization {
  guard case .allowed(let authorization) = decision else {
    Issue.record("Expected authorization, received \(decision)")
    throw PermissionModelError.invalidAuthorization
  }
  return authorization
}

struct TestPathEnvironment: PathEnvironment {
  private static let registeredProjects = try! ProjectCatalog([
    RegisteredProject(id: "project", root: path("/people/me/Downloads/repo")),
    RegisteredProject(id: "derived", root: path("/people/me/tasks/job"), sourceID: "project"),
  ])
  var projects = Self.registeredProjects
  private static let initialRules: Set<PathRule> = [
    PathRule(root: path("/people/me/private/host"), kind: .hostData),
    PathRule(root: path("/people/me/toolchains/swift"), kind: .developer),
    PathRule(root: path("/people"), kind: .userData),
    PathRule(root: path("/volumes"), kind: .userData),
    PathRule(root: path("/people/me/Downloads"), kind: .folder(.downloads)),
    PathRule(root: path("/system"), kind: .systemOrApplication),
    PathRule(root: path("/apps"), kind: .systemOrApplication),
  ]
  private static let outsideIdentity = BasisIdentity()
  var pathRules = Self.initialRules
  var outsideUserDataIdentity = Self.outsideIdentity

  private func roots(_ kind: PathRule.Kind) -> Set<CanonicalPath> {
    Set(pathRules.filter { $0.kind == kind }.map(\.root))
  }
  private mutating func setRoots(_ roots: Set<CanonicalPath>, kind: PathRule.Kind) {
    let retained = pathRules.filter { $0.kind == kind && roots.contains($0.root) }
    let existing = Set(retained.map(\.root))
    pathRules = pathRules.filter { $0.kind != kind }.union(retained)
      .union(roots.subtracting(existing).map { PathRule(root: $0, kind: kind) })
  }
  var hostDataLocations: Set<CanonicalPath> {
    get { roots(.hostData) }
    set { setRoots(newValue, kind: .hostData) }
  }
  var deniedLocations: Set<CanonicalPath> {
    get { roots(.denied) }
    set { setRoots(newValue, kind: .denied) }
  }
  var developerLocations: Set<CanonicalPath> {
    get { roots(.developer) }
    set { setRoots(newValue, kind: .developer) }
  }
  var userDataLocations: Set<CanonicalPath> {
    get { roots(.userData) }
    set { setRoots(newValue, kind: .userData) }
  }
  var systemLocations: Set<CanonicalPath> {
    get { roots(.systemOrApplication) }
    set { setRoots(newValue, kind: .systemOrApplication) }
  }
  var folders: [FolderCategory: Set<CanonicalPath>] {
    get {
      Dictionary(uniqueKeysWithValues: FolderCategory.allCases.map { ($0, roots(.folder($0))) })
    }
    set {
      for category in FolderCategory.allCases {
        setRoots(newValue[category] ?? [], kind: .folder(category))
      }
    }
  }

}

func request(from decision: ProjectRegistrationDecision) throws -> PermissionRequest {
  guard case .request(let request) = decision else {
    Issue.record("Expected a registration request, received \(decision)")
    throw PermissionModelError.unknownRequest
  }
  return request
}

func hostRules(_ names: Set<String>, preserving records: Set<HostRule>) -> Set<HostRule> {
  Set(names.map { name in records.first { $0.host == HostRule(name).host } ?? HostRule(name) })
}

extension TestPathEnvironment {
  /// Host classification facts are refreshed without replacing unchanged records.
  func snapshot(preserving current: PathEnvironmentSnapshot?) -> PathEnvironmentSnapshot {
    var snapshot = PathEnvironmentSnapshot(self)
    guard let current else { return snapshot }
    snapshot.pathRules = Set(
      pathRules.map { rule in
        current.pathRules.first { $0.root == rule.root && $0.kind == rule.kind } ?? rule
      })
    try! snapshot.setProjects(
      projects.projects.map { project in
        current.registeredProjects.first {
          $0.id == project.id && $0.root == project.root && $0.sourceID == project.sourceID
        } ?? project
      })
    snapshot.outsideUserDataIdentity = current.outsideUserDataIdentity
    return snapshot
  }
}
