import Foundation

enum CLITreeError: Error, Equatable, LocalizedError {
  case invalid(String)
  case document(CLITreeDiagnostic)

  var errorDescription: String? {
    switch self {
    case .invalid(let reason): "Invalid CLI tree or input: \(reason)"
    case .document(let issue): issue.message
    }
  }
}

/// A machine-readable interface, not an executable or a grant. Paths identify nodes;
/// argv is the complete ordered mapping, including command words and separators.
struct CLITree: Codable, Equatable, Sendable {
  enum Coverage: String, Codable, Sendable { case complete, partial }

  let formatVersion: Int
  let source: String
  let executableVersion: String
  let coverage: Coverage
  let omissions: [String]
  let commands: [CLICommandDescriptor]
  let executableChecks: [CLIExecutableCheck]

  init(
    formatVersion: Int, source: String, executableVersion: String, coverage: Coverage,
    omissions: [String], commands: [CLICommandDescriptor],
    executableChecks: [CLIExecutableCheck] = []
  ) {
    self.formatVersion = formatVersion
    self.source = source
    self.executableVersion = executableVersion
    self.coverage = coverage
    self.omissions = omissions
    self.commands = commands
    self.executableChecks = executableChecks
  }

  private enum CodingKeys: String, CodingKey {
    case formatVersion = "format_version"
    case source, coverage, omissions, commands
    case executableVersion = "executable_version"
    case executableChecks = "executable_checks"
  }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    formatVersion = try c.decode(Int.self, forKey: .formatVersion)
    source = try c.decode(String.self, forKey: .source)
    executableVersion = try c.decode(String.self, forKey: .executableVersion)
    coverage = try c.decode(Coverage.self, forKey: .coverage)
    omissions = try c.decode([String].self, forKey: .omissions)
    commands = try c.decode([CLICommandDescriptor].self, forKey: .commands)
    executableChecks =
      c.contains(.executableChecks)
      ? try c.decode([CLIExecutableCheck].self, forKey: .executableChecks) : []
  }

  static func parse(_ data: Data) throws -> Self {
    guard data.count <= 4_194_304 else {
      throw CLITreeError.document(
        .init(code: "clitree.document.too_large", path: "", message: "Tree exceeds 4 MiB."))
    }
    let json = try JSONDecoder().decode(JSONValue.self, from: data)
    try cliTreeKeys(
      json,
      allowed: [
        "format_version", "source", "executable_version", "coverage", "omissions", "commands",
        "executable_checks",
      ])
    for (index, check) in (json.objectValue?["executable_checks"]?.arrayValue ?? []).enumerated() {
      try cliTreeKeys(
        check, path: "/executable_checks/\(index)", allowed: ["args", "stdout", "stdout_sha256"])
    }
    for (index, command) in (json.objectValue?["commands"]?.arrayValue ?? []).enumerated() {
      let path = "/commands/\(index)"
      try cliTreeKeys(
        command, path: path,
        allowed: [
          "id", "path", "description", "executable", "parameters", "argv", "stdin", "stdout",
          "output_schema", "help_argv", "dry_run_parameter", "risk_hint",
        ])
      for (index, parameter) in (command.objectValue?["parameters"]?.arrayValue ?? []).enumerated()
      {
        try cliTreeKeys(
          parameter, path: path + "/parameters/\(index)",
          allowed: [
            "name", "description", "schema", "required", "default", "secret", "conflicts",
            "requires",
          ])
      }
      for (index, token) in (command.objectValue?["argv"]?.arrayValue ?? []).enumerated() {
        try cliTreeKeys(
          token, path: path + "/argv/\(index)",
          allowed: ["kind", "value", "parameter", "flag", "inverse", "style"])
      }
      if let stdin = command.objectValue?["stdin"], stdin != .null {
        try cliTreeKeys(stdin, path: path + "/stdin", allowed: ["parameter", "encoding"])
      }
    }
    let tree = try JSONDecoder().decode(Self.self, from: data)
    try tree.validate()
    return tree
  }

  func validate() throws {
    guard formatVersion == 1 else {
      throw CLITreeError.document(
        .init(
          code: "clitree.format.unsupported", path: "/format_version",
          message: "Unsupported format_version."))
    }
    guard executableChecks.count <= 4 else {
      throw CLITreeError.document(
        .init(
          code: "clitree.check.invalid", path: "/executable_checks",
          message: "Too many executable checks."))
    }
    for (index, check) in executableChecks.enumerated() {
      try cliTreeAt("/executable_checks/\(index)", code: "clitree.check.invalid") {
        try check.validate()
      }
    }
    for (path, valid, message) in [
      ("/source", !source.isEmpty, "Source must not be empty."),
      ("/executable_version", !executableVersion.isEmpty, "Executable version must not be empty."),
      ("/commands", (1...4_096).contains(commands.count), "Tree must contain 1...4096 commands."),
      (
        "/omissions", coverage == .partial ? !omissions.isEmpty : omissions.isEmpty,
        "Omissions must match declared coverage."
      ),
    ] where !valid {
      throw CLITreeError.document(
        .init(code: "clitree.document.invalid", path: path, message: message))
    }
    var ids = Set<String>()
    var paths = Set<[String]>()
    for (index, command) in commands.enumerated() {
      guard ids.insert(command.id).inserted, paths.insert(command.path).inserted else {
        throw CLITreeError.document(
          .init(
            code: "clitree.command.duplicate", path: "/commands/\(index)",
            message: "Duplicate command identity or path."))
      }
      try cliTreeAt("/commands/\(index)", code: "clitree.command.invalid") {
        try command.validate()
      }
    }
    for (index, command) in commands.enumerated() where command.path.count > 1 {
      guard paths.contains(Array(command.path.dropLast())) else {
        throw CLITreeError.document(
          .init(
            code: "clitree.command.missing_parent", path: "/commands/\(index)/path",
            message: "A command is missing its parent node."))
      }
    }
  }
}

struct CLIParameter: Codable, Equatable, Sendable {
  let name: String
  var description: String? = nil
  let schema: JSONValue
  var required: Bool = false
  /// Documents the CLI's own default. Omitted input never emits this value.
  var defaultValue: JSONValue? = nil
  var secret: Bool = false
  var conflicts: [String] = []
  var requires: [String] = []

  private enum CodingKeys: String, CodingKey {
    case name, description, schema, required, secret, conflicts, requires
    case defaultValue = "default"
  }

  init(
    name: String, description: String? = nil, schema: JSONValue, required: Bool = false,
    defaultValue: JSONValue? = nil, secret: Bool = false, conflicts: [String] = [],
    requires: [String] = []
  ) {
    self.name = name
    self.description = description
    self.schema = schema
    self.required = required
    self.defaultValue = defaultValue
    self.secret = secret
    self.conflicts = conflicts
    self.requires = requires
  }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    description = try c.decodeIfPresent(String.self, forKey: .description)
    schema = try c.decode(JSONValue.self, forKey: .schema)
    required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
    defaultValue =
      c.contains(.defaultValue) ? try c.decode(JSONValue.self, forKey: .defaultValue) : nil
    secret = try c.decodeIfPresent(Bool.self, forKey: .secret) ?? false
    conflicts = try c.decodeIfPresent([String].self, forKey: .conflicts) ?? []
    requires = try c.decodeIfPresent([String].self, forKey: .requires) ?? []
  }
}

struct CLIArgumentToken: Codable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable { case literal, positional, option, flag }
  enum Style: String, Codable, Sendable {
    /// One flag followed by one scalar or all array elements.
    case separate
    /// One flag=value per scalar/array element; leading '-' values are unambiguous.
    case equals
    /// A separate flag before each array element.
    case repeated
  }

  let kind: Kind
  var value: String? = nil
  var parameter: String? = nil
  var flag: String? = nil
  var inverse: String? = nil
  var style: Style? = nil
}

struct CLIStandardInput: Codable, Equatable, Sendable {
  enum Encoding: String, Codable, Sendable { case utf8, base64, json }
  let parameter: String
  let encoding: Encoding
}

struct CLICommandDescriptor: Codable, Equatable, Sendable {
  enum Output: String, Codable, Sendable { case text, binary, json }

  let id: String
  let path: [String]
  let description: String
  var executable: Bool = true
  var parameters: [CLIParameter] = []
  var argv: [CLIArgumentToken] = []
  var stdin: CLIStandardInput? = nil
  var stdout: Output = .text
  var outputSchema: JSONValue? = nil
  var helpArgv: [String]? = nil
  var dryRunParameter: String? = nil
  /// Publisher hints never determine Gateway capabilities or profile grants.
  var riskHint: CapabilityRisk? = nil

  private enum CodingKeys: String, CodingKey {
    case id, path, description, executable, parameters, argv, stdin, stdout
    case outputSchema = "output_schema"
    case helpArgv = "help_argv"
    case dryRunParameter = "dry_run_parameter"
    case riskHint = "risk_hint"
  }

  func validate() throws {
    guard cliTreeIdentifier(id), !description.isEmpty, path.count <= 32,
      path.allSatisfy({ !$0.isEmpty && !$0.contains("\0") && !$0.hasPrefix("-") }),
      parameters.count <= 256, argv.count <= 1_024
    else { throw CLITreeError.invalid("Command identity, path, or size is invalid.") }
    if !executable {
      guard parameters.isEmpty, argv.isEmpty, stdin == nil, outputSchema == nil,
        dryRunParameter == nil
      else { throw CLITreeError.invalid("A non-executable node cannot define an invocation.") }
    }
    let names = Set(parameters.map(\.name))
    guard !names.contains("workspace_id") else {
      throw CLITreeError.invalid(
        "workspace_id belongs to Gateway routing; choose another parameter name.")
    }
    guard names.count == parameters.count, names.allSatisfy(cliTreeIdentifier) else {
      throw CLITreeError.invalid("Parameter names must be unique identifiers.")
    }
    for (index, parameter) in parameters.enumerated() {
      try cliTreeAt("/parameters/\(index)", code: "clitree.parameter.invalid") {
        try CLIValueValidation.validateSchema(parameter.schema)
        guard !parameter.required || parameter.defaultValue == nil else {
          throw CLITreeError.invalid("A required parameter cannot have an omitted-input default.")
        }
        if let value = parameter.defaultValue {
          try CLIValueValidation.validate(value, schema: parameter.schema, path: parameter.name)
          guard !parameter.secret else {
            throw CLITreeError.invalid("Secret defaults are not publishable.")
          }
        }
        let relations = parameter.requires + parameter.conflicts
        guard relations.allSatisfy({ names.contains($0) && $0 != parameter.name }),
          Set(parameter.requires).isDisjoint(with: parameter.conflicts)
        else { throw CLITreeError.invalid("Invalid parameter relationship.") }
      }
    }
    var mapped = Set<String>()
    var optionsTerminated = false
    for (index, token) in argv.enumerated() {
      try cliTreeAt("/argv/\(index)", code: "clitree.argv.invalid") {
        switch token.kind {
        case .literal:
          guard let value = token.value, !value.contains("\0"), token.parameter == nil,
            token.flag == nil, token.inverse == nil, token.style == nil
          else { throw CLITreeError.invalid("Invalid literal argv token.") }
          if value == "--" { optionsTerminated = true }
        case .positional, .option, .flag:
          guard let name = token.parameter,
            let parameter = parameters.first(where: { $0.name == name }),
            mapped.insert(name).inserted, token.value == nil
          else { throw CLITreeError.invalid("Unknown or multiply mapped argv parameter.") }
          let type = parameter.schema.objectValue?["type"]?.stringValue
          if token.kind != .positional, optionsTerminated {
            throw CLITreeError.invalid("An option or flag mapping follows --.")
          }
          if token.kind == .flag {
            guard type == "boolean", validFlag(token.flag), token.style == nil,
              token.inverse == nil || validFlag(token.inverse), token.inverse != token.flag
            else { throw CLITreeError.invalid("Invalid Boolean flag mapping.") }
            if token.inverse == nil {
              try CLIValueValidation.validate(
                .bool(true), schema: parameter.schema, path: parameter.name)
            }
          } else {
            let elementType =
              type == "array"
              ? parameter.schema.objectValue?["items"]?.objectValue?["type"]?.stringValue : type
            guard let elementType,
              ["string", "integer", "number", "boolean"].contains(elementType),
              token.inverse == nil
            else {
              throw CLITreeError.invalid("Argv requires scalar values or arrays of scalars.")
            }
            if token.kind == .positional {
              guard token.flag == nil, token.style == nil else {
                throw CLITreeError.invalid("A positional mapping cannot define a flag or style.")
              }
              if type == "array",
                argv.dropFirst(index + 1).contains(where: { $0.kind == .positional })
              {
                let schema = parameter.schema.objectValue!
                guard let count = schema["minItems"]?.intValue,
                  schema["maxItems"]?.intValue == count
                else {
                  throw CLITreeError.invalid("A variadic positional must be the last positional.")
                }
              }
            } else {
              guard validFlag(token.flag), token.style != nil,
                token.style != .equals || token.flag?.hasPrefix("--") == true
              else { throw CLITreeError.invalid("Invalid option flag or value style.") }
            }
          }
        }
      }
    }
    if let stdin {
      guard names.contains(stdin.parameter), mapped.insert(stdin.parameter).inserted,
        stdin.encoding == .json
          || parameters.first(where: { $0.name == stdin.parameter })?.schema.objectValue?["type"]
            == .string("string")
      else { throw CLITreeError.invalid("Invalid stdin mapping.") }
    }
    guard mapped == names else {
      throw CLITreeError.invalid("Every input needs exactly one argv/stdin mapping.")
    }
    if let outputSchema {
      guard stdout == .json else {
        throw CLITreeError.invalid("Only JSON stdout may declare a schema.")
      }
      try CLIValueValidation.validateSchema(outputSchema)
    }
    if let helpArgv {
      guard !helpArgv.isEmpty, helpArgv.allSatisfy({ !$0.contains("\0") }) else {
        throw CLITreeError.invalid("Invalid declared help argv.")
      }
    }
    if let dryRunParameter {
      guard
        parameters.contains(where: {
          $0.name == dryRunParameter && $0.schema.objectValue?["type"] == .string("boolean")
        }), argv.contains(where: { $0.parameter == dryRunParameter && $0.kind == .flag })
      else {
        throw CLITreeError.invalid("Dry-run must reference an actual Boolean flag.")
      }
    }
  }

  var inputSchema: JSONValue {
    var properties: [String: JSONValue] = [:]
    for parameter in parameters {
      var schema = parameter.schema.objectValue ?? [:]
      if let description = parameter.description { schema["description"] = .string(description) }
      if let value = parameter.defaultValue { schema["default"] = value }
      if parameter.secret { schema["writeOnly"] = .bool(true) }
      if argv.contains(where: {
        $0.kind == .flag && $0.parameter == parameter.name && $0.inverse == nil
      }) {
        schema["const"] = .bool(true)
        if schema["default"] != .bool(true) { schema.removeValue(forKey: "default") }
      }
      properties[parameter.name] = .object(schema)
    }
    var schema: [String: JSONValue] = [
      "type": .string("object"), "properties": .object(properties),
      "additionalProperties": .bool(false),
      "required": .array(parameters.filter(\.required).map { .string($0.name) }),
    ]
    var dependencies: [String: JSONValue] = [:]
    var constraints: [JSONValue] = []
    for parameter in parameters {
      if !parameter.requires.isEmpty {
        dependencies[parameter.name] = .array(parameter.requires.map(JSONValue.string))
      }
      for conflict in parameter.conflicts {
        constraints.append(
          .object([
            "not": .object([
              "required": .array([.string(parameter.name), .string(conflict)])
            ])
          ]))
      }
    }
    if !dependencies.isEmpty { schema["dependentRequired"] = .object(dependencies) }
    if !constraints.isEmpty { schema["allOf"] = .array(constraints) }
    return .object(schema)
  }

  private func validFlag(_ flag: String?) -> Bool {
    guard let flag, flag.hasPrefix("-"), flag != "-", flag != "--" else { return false }
    return !flag.contains("\0") && !flag.contains("=") && !flag.contains(where: \.isWhitespace)
  }
}

private func cliTreeIdentifier(_ value: String) -> Bool {
  !value.isEmpty && value.utf8.count <= 64
    && value.utf8.allSatisfy {
      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
        || $0 == 95
    }
}

private func cliTreeKeys(_ value: JSONValue, path: String = "", allowed: Set<String>) throws {
  guard let object = value.objectValue else {
    throw CLITreeError.document(
      .init(code: "clitree.document.type", path: path, message: "Expected an object."))
  }
  if let key = Set(object.keys).subtracting(allowed).sorted().first {
    throw CLITreeError.document(
      .init(
        code: "clitree.document.unknown_field", path: path + CLITreeDiagnostic.pointer([key]),
        message: "Unexpected field in tree document."))
  }
}

private func cliTreeAt(_ path: String, code: String, operation: () throws -> Void) throws {
  do { try operation() } catch CLITreeError.document(let issue) {
    throw CLITreeError.document(
      .init(code: issue.code, path: path + issue.path, message: issue.message))
  } catch {
    throw CLITreeError.document(.init(code: code, path: path, message: error.localizedDescription))
  }
}
