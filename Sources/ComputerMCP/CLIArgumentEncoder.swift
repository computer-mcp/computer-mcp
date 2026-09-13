import Foundation

/// Only execution consumes argv/stdin. Diagnostics must not serialize this value.
struct CLIInvocation: Sendable {
  let arguments: [String]
  let standardInput: Data
}

enum CLIArgumentEncoder {
  static func encode(_ input: JSONValue, command: CLICommandDescriptor) throws -> CLIInvocation {
    try command.validate()
    guard command.executable, let object = input.objectValue else {
      throw CLITreeError.invalid("An executable command and object input are required.")
    }
    let names = Set(command.parameters.map(\.name))
    guard Set(object.keys).isSubset(of: names) else {
      throw CLITreeError.invalid("Unknown input parameter.")
    }
    for parameter in command.parameters {
      guard let value = object[parameter.name] else {
        if parameter.required { throw CLITreeError.invalid("Missing '\(parameter.name)'.") }
        continue
      }
      try CLIValueValidation.validate(value, schema: parameter.schema, path: parameter.name)
      guard parameter.conflicts.allSatisfy({ object[$0] == nil }),
        parameter.requires.allSatisfy({ object[$0] != nil })
      else {
        throw CLITreeError.invalid("Conflicting or missing related input for '\(parameter.name)'.")
      }
    }
    var arguments: [String] = []
    var positionalOmitted = false
    var optionsTerminated = false
    for token in command.argv {
      if token.kind == .literal {
        let value = token.value!
        arguments.append(value)
        if value == "--" { optionsTerminated = true }
        continue
      }
      guard let value = object[token.parameter!] else {
        if token.kind == .positional { positionalOmitted = true }
        continue
      }
      if token.kind == .flag {
        if value.boolValue == true {
          arguments.append(token.flag!)
        } else if let inverse = token.inverse {
          arguments.append(inverse)
        } else {
          // False is not omission: a one-way flag cannot encode it faithfully.
          throw CLITreeError.invalid("False requires an inverse flag for '\(token.parameter!)'.")
        }
        continue
      }
      let values = try (value.arrayValue ?? [value]).map(scalar)
      if token.kind == .positional {
        guard !positionalOmitted || values.isEmpty else {
          throw CLITreeError.invalid("An omitted positional would shift a later positional.")
        }
        guard optionsTerminated || values.allSatisfy({ !$0.hasPrefix("-") }) else {
          throw CLITreeError.invalid(
            "Leading '-' positional values require a declared -- separator.")
        }
        if values.isEmpty { positionalOmitted = true }
        arguments += values
      } else {
        guard !optionsTerminated else { throw CLITreeError.invalid("Option mapping follows --.") }
        if token.style == .equals {
          arguments += values.map { "\(token.flag!)=\($0)" }
        } else {
          guard values.allSatisfy({ !$0.hasPrefix("-") }) else {
            throw CLITreeError.invalid("Leading '-' option values need equals mapping.")
          }
          if token.style == .repeated {
            arguments += values.flatMap { [token.flag!, $0] }
          } else if !values.isEmpty {
            arguments += [token.flag!] + values
          }
        }
      }
    }
    var standardInput = Data()
    if let stdin = command.stdin, let value = object[stdin.parameter] {
      switch stdin.encoding {
      case .utf8: standardInput = Data(value.stringValue!.utf8)
      case .base64:
        guard let decoded = Data(base64Encoded: value.stringValue!) else {
          throw CLITreeError.invalid("Invalid base64 stdin.")
        }
        standardInput = decoded
      case .json:
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        standardInput = try encoder.encode(value)
      }
    }
    guard arguments.count <= 16_384,
      arguments.reduce(0, { $0 + $1.utf8.count + 1 }) <= 1_048_576,
      standardInput.count <= 4_194_304
    else { throw CLITreeError.invalid("Encoded invocation exceeds its byte or argument limit.") }
    return CLIInvocation(arguments: arguments, standardInput: standardInput)
  }

  private static func scalar(_ value: JSONValue) throws -> String {
    switch value {
    case .string(let string):
      guard !string.contains("\0") else { throw CLITreeError.invalid("Argv cannot contain NUL.") }
      return string
    case .bool(let value): return value ? "true" : "false"
    case .number:
      return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    default: throw CLITreeError.invalid("Argv value is not a scalar.")
    }
  }
}
