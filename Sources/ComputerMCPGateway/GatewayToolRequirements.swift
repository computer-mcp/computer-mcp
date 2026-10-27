import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPPlugins
import Foundation

struct GatewayPermissionRetryInput: Sendable {
  static let field = "_permission_request_ids"
  let arguments: [String: JSONValue]
  let requestIDs: Set<UUID>

  init(_ arguments: [String: JSONValue]) throws {
    var clean = arguments
    if let value = clean.removeValue(forKey: Self.field) {
      guard let values = value.arrayValue, values.count <= 64,
        values.allSatisfy({ $0.stringValue.flatMap(UUID.init(uuidString:)) != nil })
      else {
        throw GatewayToolError.invalidArguments(
          "[permission.invalid_retry] _permission_request_ids must contain at most 64 UUID strings."
        )
      }
      requestIDs = Set(values.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) })
    } else {
      requestIDs = []
    }
    self.arguments = clean
  }
}

struct GatewayToolRequirementResolver {
  let configuration: GatewayConfiguration
  let origins: [IntegrationRegistration: PluginContributionOrigin]
  let paths: PathEnvironmentSnapshot

  func resolve(
    descriptor: CapabilityDescriptor, arguments: [String: JSONValue], projectID: String?,
    mode: ExecutionMode
  ) throws -> (InvocationRequirements, Set<PluginIdentity>, [GatewaySkillLibraryRequirement]) {
    let declaration = descriptor.requirement
    switch declaration.execution {
    case .read, .input, .cancel, .list:
      // The retained resource checks its originating execution through executionAccess.
      // Requiring a standing grant here would discard Only this time authority.
      return (InvocationRequirements(mode: .sandbox), [], [])
    default: break
    }
    let sourceID = projectID.flatMap { paths.projects.sourceID(for: $0) }
    let project = projectID.flatMap { id in paths.projects.projects.first { $0.id == id } }
    let root =
      project.map { URL(fileURLWithPath: $0.root.string) }
      ?? URL(fileURLWithPath: "/", isDirectory: true)
    var actions = declaration.permissions.map { PermissionAction(requirement: $0) }
    var requirements: [PathRequirement] = []
    var networks: [NetworkRequirement] = []
    var plugins: Set<PluginIdentity> = []
    var skillLibraries: [GatewaySkillLibraryRequirement] = []
    let access: PermissionValue?
    switch declaration.access {
    case .none: access = declaration.namedProjectAccess
    case .read: access = .read
    case .projectWrite, .sourceProjectWrite: access = .write
    }
    if let access, let sourceID {
      actions.append(
        PermissionAction(
          requirement: try PermissionRequirement(.project(sourceID), access),
          scope: .project(sourceID)))
    }
    for path in declaration.paths {
      let values: [JSONValue]
      switch path.source {
      case .project: values = [.string(root.path)]
      case .argument(let selector):
        values = try selected(selector, in: .object(arguments))
      }
      let targets = values.isEmpty && path.defaultToProject ? [.string(root.path)] : values
      for value in targets {
        guard let text = value.stringValue else {
          throw GatewayToolError.invalidArguments(
            "[permission.invalid_path] A path argument must be a string.")
        }
        let base: URL
        switch path.relativeBase {
        case .project: base = root
        case .deliveryScope(let argument):
          guard let id = arguments[argument]?.stringValue,
            let scope = configuration.delivery.scopes.first(where: {
              $0.id == id && $0.project == projectID
            })
          else {
            throw GatewayToolError.invalidArguments(
              "[permission.invalid_scope] The delivery scope is unavailable.")
          }
          base = try ProjectPathResolver.resolve(scope.repository, relativeTo: root)
        case .linkParent(let argument):
          guard let link = arguments[argument]?.stringValue else {
            throw GatewayToolError.invalidArguments(
              "[permission.invalid_path] The link path is required.")
          }
          base = try ProjectPathResolver.resolve(link, relativeTo: root).deletingLastPathComponent()
        }
        let canonical: URL
        if case .project = path.relativeBase, !text.hasPrefix("/") {
          // Registered roots can be unavailable. Preserve their captured boundary
          // while resolving existing ancestors before permission evaluation.
          let target = ProjectPathResolver.lexicallyNormalized(base.appendingPathComponent(text))
          guard ProjectPathResolver.contains(target, in: base) else {
            throw ProjectPathResolutionError.escapesProject
          }
          canonical = try ProjectPathResolver.resolve(
            target.path, relativeTo: URL(fileURLWithPath: "/"))
          guard ProjectPathResolver.contains(canonical, in: base) else {
            throw ProjectPathResolutionError.escapesProject
          }
        } else {
          canonical = try ProjectPathResolver.resolve(
            text,
            relativeTo: text.hasPrefix("/") ? URL(fileURLWithPath: "/") : base)
        }
        requirements.append(
          PathRequirement(path: try CanonicalPath(canonical.path), operation: path.operation))
      }
    }
    switch declaration.target {
    case .mcp(let object, let value):
      if let server = try objectID(object, arguments: arguments),
        origins[.init(kind: .mcp, id: server)] == nil
      {
        actions.append(
          PermissionAction(requirement: try PermissionRequirement(.mcpServer(server), value)))
      }
    case .none, .forwarded: break
    }
    if let reference = descriptor.mcpReference,
      origins[.init(kind: .mcp, id: reference.serverID)] == nil,
      !actions.contains(where: { $0.requirement.permission == .mcpServer(reference.serverID) })
    {
      actions.append(
        PermissionAction(
          requirement: try PermissionRequirement(
            .mcpServer(reference.serverID), descriptor.risk == .readOnly ? .read : .all)))
    }
    if let contribution = declaration.contribution {
      let kind: IntegrationKind
      let object: ToolRequirement.Object
      switch contribution {
      case .cli(let selection):
        kind = .cli
        object = selection
      case .skills(let selection):
        kind = .skills
        object = selection
      case .mcp(let selection):
        kind = .mcp
        object = selection
      }
      let selectedID = try objectID(object, arguments: arguments)
      let aggregateSkills = kind == .skills && selectedID == nil
      let selectedIDs =
        aggregateSkills
        ? configuration.skills.roots.map(\.id) : selectedID.map { [$0] } ?? []
      for id in selectedIDs {
        let pluginID = origins[.init(kind: kind, id: id)]?.pluginID
        if kind == .skills, let skillRoot = configuration.skills.roots.first(where: { $0.id == id })
        {
          let library = try CanonicalPath(
            ProjectPathResolver.resolve(
              skillRoot.path, relativeTo: URL(fileURLWithPath: "/")
            ).path)
          let path = PathRequirement(
            path: library, operation: .read, purpose: .skillLibrary(root: library))
          if aggregateSkills {
            skillLibraries.append(.init(path: path, pluginID: pluginID))
            continue
          }
          requirements.append(path)
        }
        if let pluginID {
          plugins.insert(.package(pluginID))
          let requirement = try PermissionRequirement(.plugin(pluginID), .use)
          if !actions.contains(where: { $0.requirement == requirement }) {
            actions.append(PermissionAction(requirement: requirement))
          }
        }
      }
      if kind == .mcp, selectedIDs.isEmpty, let server = descriptor.mcpReference?.serverID,
        let origin = origins[.init(kind: .mcp, id: server)]
      {
        plugins.insert(.package(origin.pluginID))
        actions.append(
          PermissionAction(requirement: try PermissionRequirement(.plugin(origin.pluginID), .use)))
      }
    }
    if let selector = declaration.networkURL,
      let value = try selected(selector, in: .object(arguments)).first
    {
      guard let text = value.stringValue, let url = URL(string: text), let host = url.host,
        ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let sourceID
      else {
        throw GatewayToolError.invalidArguments(
          "[permission.invalid_network] A project and an HTTP(S) URL are required.")
      }
      let normalized = try NetworkHost.normalize(host)
      let local =
        normalized == "localhost" || normalized.hasSuffix(".local")
        || normalized.hasPrefix("127.") || normalized == "::1" || normalized.hasPrefix("169.254.")
        || normalized.hasPrefix("10.") || normalized.hasPrefix("192.168.")
      networks.append(
        NetworkRequirement(host: normalized, projectID: sourceID, isLocalNetwork: local))
    }
    let selectedMode: ExecutionMode =
      declaration.requiresFullAccess && mode == .sandbox ? .fullAccess(.notGranted) : mode
    let execution = try ExecutionLimitRequest(
      background: arguments["background"]?.boolValue == true || descriptor.id == "shell.spawn"
        || descriptor.id == "process.spawn",
      timeMilliseconds: arguments["timeout_ms"]?.int64Value)
    return (
      InvocationRequirements(
        actions: actions, paths: requirements, networks: networks,
        mode: selectedMode, sandboxProjectID: sourceID, execution: execution), plugins,
      skillLibraries
    )
  }

  private func objectID(_ object: ToolRequirement.Object, arguments: [String: JSONValue]) throws
    -> String?
  {
    switch object {
    case .registered(let id): return id
    case .argument(let name): return arguments[name]?.stringValue
    case .catalog: return nil
    case .skill(_, let root): return arguments[root]?.stringValue
    }
  }

  private func selected(_ selector: String, in value: JSONValue) throws -> [JSONValue] {
    var values = [value]
    for component in selector.split(separator: ".").map(String.init) {
      let array = component.hasSuffix("[]")
      let key = array ? String(component.dropLast(2)) : component
      var next: [JSONValue] = []
      for value in values {
        guard let object = value.objectValue else {
          throw GatewayToolError.invalidArguments(
            "[permission.invalid_selector] A path selector crosses a non-object value.")
        }
        guard let selected = object[key] else { continue }
        if array {
          guard let children = selected.arrayValue else {
            throw GatewayToolError.invalidArguments(
              "[permission.invalid_selector] A path selector requires an array.")
          }
          next += children
        } else {
          next.append(selected)
        }
      }
      values = next
    }
    return values
  }
}

/// Aggregate scans admit each library independently inside the authority transaction.
package struct GatewaySkillLibraryRequirement: Sendable {
  let path: PathRequirement
  let pluginID: String?

  static func selecting(
    _ libraries: [Self], requirements: InvocationRequirements,
    ledger: PermissionLedger, principal: Principal, connectionID: String?
  ) -> InvocationRequirements {
    var actions = requirements.actions
    var paths = requirements.paths
    for library in libraries
    where ledger.permitsSkillLibrary(
      library.path.path, pluginID: library.pluginID, principal: principal,
      mode: requirements.mode, sandboxProjectID: requirements.sandboxProjectID,
      connectionID: connectionID)
    {
      paths.append(library.path)
      if let pluginID = library.pluginID {
        actions.append(.init(requirement: try! PermissionRequirement(.plugin(pluginID), .use)))
      }
    }
    return InvocationRequirements(
      actions: actions, paths: paths, networks: requirements.networks,
      mode: requirements.mode, sandboxProjectID: requirements.sandboxProjectID,
      execution: requirements.execution)
  }
}
