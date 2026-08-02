#!/usr/bin/env swift
import CryptoKit
import Foundation

private struct ResolvedFile: Decodable {
  let pins: [Pin]
}

private struct Pin: Decodable {
  let identity: String
  let location: String
  let state: State

  struct State: Decodable {
    let revision: String
    let version: String?
  }
}

private struct DistributedDefinition {
  let licenseExpression: String
  let legalFiles: [String]
}

private struct Manifest: Encodable {
  let schemaVersion = 1
  let product: Product
  let packageResolvedSHA256: String
  let linkedDistributed: [ManifestComponent]
  let resolvedOnly: [ManifestComponent]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case product
    case packageResolvedSHA256 = "package_resolved_sha256"
    case linkedDistributed = "linked_distributed"
    case resolvedOnly = "resolved_only"
  }

  struct Product: Encodable {
    let name: String
    let version: String
    let build: String
    let artifact: String
  }
}

private struct ManifestComponent: Encodable {
  let identity: String
  let version: String
  let revision: String
  let source: String
  let licenseExpression: String?

  enum CodingKeys: String, CodingKey {
    case identity
    case version
    case revision
    case source
    case licenseExpression = "license_expression"
  }
}

private struct CycloneDX: Encodable {
  let bomFormat = "CycloneDX"
  let specVersion = "1.6"
  let version = 1
  let metadata: Metadata
  let components: [Component]
  let dependencies: [Dependency]

  struct Metadata: Encodable {
    let component: RootComponent
  }

  struct RootComponent: Encodable {
    let type = "application"
    let bomRef: String
    let group: String
    let name: String
    let version: String
    let supplier: Supplier
    let licenses: [LicenseChoice]
    let properties: [Property]

    enum CodingKeys: String, CodingKey {
      case type
      case bomRef = "bom-ref"
      case group
      case name
      case version
      case supplier
      case licenses
      case properties
    }
  }

  struct Supplier: Encodable {
    let name: String
  }

  struct Component: Encodable {
    let type = "library"
    let bomRef: String
    let name: String
    let version: String
    let scope: String
    let purl: String?
    let licenses: [LicenseChoice]?
    let externalReferences: [ExternalReference]
    let properties: [Property]

    enum CodingKeys: String, CodingKey {
      case type
      case bomRef = "bom-ref"
      case name
      case version
      case scope
      case purl
      case licenses
      case externalReferences = "externalReferences"
      case properties
    }
  }

  struct LicenseChoice: Encodable {
    let expression: String
  }

  struct ExternalReference: Encodable {
    let type: String
    let url: String
  }

  struct Property: Encodable {
    let name: String
    let value: String
  }

  struct Dependency: Encodable {
    let ref: String
    let dependsOn: [String]
  }
}

private enum MetadataError: Error, CustomStringConvertible {
  case usage(String)
  case invalidResolvedFile(String)
  case missingPin(String)
  case unexpectedLinkedPackages(expected: [String], actual: [String])
  case missingLegalFile(String)

  var description: String {
    switch self {
    case .usage(let message):
      return message
    case .invalidResolvedFile(let message):
      return "Invalid Package.resolved: \(message)"
    case .missingPin(let identity):
      return "Package.resolved is missing required linked package '\(identity)'."
    case .unexpectedLinkedPackages(let expected, let actual):
      return "Linked-package classification mismatch. expected=\(expected) actual=\(actual)"
    case .missingLegalFile(let path):
      return "Missing third-party legal file: \(path)"
    }
  }
}

private let distributed: [String: DistributedDefinition] = [
  "grdb.swift": DistributedDefinition(
    licenseExpression: "MIT",
    legalFiles: ["LICENSE"]
  ),
  "yams": DistributedDefinition(
    licenseExpression: "MIT",
    legalFiles: ["LICENSE"]
  ),
  "eventsource": DistributedDefinition(
    licenseExpression: "MIT",
    legalFiles: ["LICENSE.md"]
  ),
  "swift-argument-parser": DistributedDefinition(
    licenseExpression: "Apache-2.0",
    legalFiles: ["LICENSE.txt"]
  ),
  "swift-atomics": DistributedDefinition(
    licenseExpression: "Apache-2.0",
    legalFiles: ["LICENSE.txt"]
  ),
  "swift-codex": DistributedDefinition(
    licenseExpression: "MIT AND Apache-2.0",
    legalFiles: [
      "LICENSE",
      "THIRD_PARTY_NOTICES.md",
      "Vendor/CodexAppServerProtocolSchema/LICENSE",
      "Vendor/CodexAppServerProtocolSchema/NOTICE",
    ]
  ),
  "swift-collections": DistributedDefinition(
    licenseExpression: "Apache-2.0",
    legalFiles: ["LICENSE.txt"]
  ),
  "swift-log": DistributedDefinition(
    licenseExpression: "Apache-2.0",
    legalFiles: ["LICENSE.txt", "NOTICE.txt"]
  ),
  "swift-nio": DistributedDefinition(
    licenseExpression: "Apache-2.0",
    legalFiles: ["LICENSE.txt", "NOTICE.txt", "Sources/CNIOLLHTTP/LICENSE"]
  ),
  "swift-sdk": DistributedDefinition(
    licenseExpression: "Apache-2.0 AND MIT",
    legalFiles: ["LICENSE"]
  ),
  "swift-subprocess": DistributedDefinition(
    licenseExpression: "Apache-2.0",
    legalFiles: ["LICENSE"]
  ),
  "swift-system": DistributedDefinition(
    licenseExpression: "Apache-2.0",
    legalFiles: ["LICENSE.txt"]
  ),
  "swift-toml": DistributedDefinition(
    licenseExpression: "MIT",
    legalFiles: ["LICENSE.md"]
  ),
]

private struct Options {
  let root: URL
  let output: URL
  let buildDescription: URL?
  let checkoutRoot: URL

  init(arguments: [String]) throws {
    let script = URL(fileURLWithPath: arguments.first ?? #filePath).standardizedFileURL
    var root = script.deletingLastPathComponent().deletingLastPathComponent()
    var output: URL?
    var buildDescription: URL?
    var checkoutRoot: URL?
    var index = 1
    while index < arguments.count {
      let option = arguments[index]
      guard index + 1 < arguments.count else {
        throw MetadataError.usage("Missing value for \(option).")
      }
      let value = arguments[index + 1]
      switch option {
      case "--root":
        root = URL(fileURLWithPath: value).standardizedFileURL
      case "--output":
        output = URL(fileURLWithPath: value).standardizedFileURL
      case "--build-description":
        buildDescription = URL(fileURLWithPath: value).standardizedFileURL
      case "--checkout-root":
        checkoutRoot = URL(fileURLWithPath: value).standardizedFileURL
      default:
        throw MetadataError.usage("Unknown option: \(option)")
      }
      index += 2
    }
    self.root = root
    self.output = output ?? root.appendingPathComponent("dist/ReleaseMetadata", isDirectory: true)
    self.buildDescription = buildDescription
    self.checkoutRoot =
      checkoutRoot ?? root.appendingPathComponent(".build/checkouts", isDirectory: true)
  }
}

private func sha256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func componentReference(_ pin: Pin) -> String {
  "pkg:swift/\(pin.identity)@\(pin.state.version ?? pin.state.revision)"
}

private func githubPURL(_ pin: Pin) -> String? {
  guard var components = URLComponents(string: pin.location),
    components.host?.lowercased() == "github.com"
  else {
    return nil
  }
  var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  if path.hasSuffix(".git") {
    path.removeLast(4)
  }
  guard path.split(separator: "/").count == 2 else { return nil }
  components = URLComponents()
  return "pkg:github/\(path)@\(pin.state.version ?? pin.state.revision)"
}

private func encodedJSON<T: Encodable>(_ value: T) throws -> Data {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  var data = try encoder.encode(value)
  data.append(0x0A)
  return data
}

private func linkedPackages(from descriptionURL: URL) throws -> Set<String> {
  let object = try JSONSerialization.jsonObject(with: Data(contentsOf: descriptionURL))
  guard let description = object as? [String: Any],
    let dependencyMap = description["targetDependencyMap"] as? [String: [String]],
    let commands = description["swiftCommands"] as? [String: [String: Any]]
  else {
    throw MetadataError.usage("Malformed SwiftPM build description: \(descriptionURL.path)")
  }

  let targetNames = Set(
    (dependencyMap["ComputerMCPApp"] ?? [])
      + (dependencyMap["computer_mcp"] ?? [])
      + ["ComputerMCPApp", "computer_mcp"]
  )
  var sourcesByModule: [String: String] = [:]
  for command in commands.values {
    guard let moduleName = command["moduleName"] as? String,
      let sources = command["sources"] as? [String],
      let source = sources.first
    else {
      continue
    }
    sourcesByModule[moduleName] = source
  }

  return Set(
    targetNames.compactMap { targetName in
      guard let source = sourcesByModule[targetName],
        let range = source.range(of: "/checkouts/")
      else {
        return nil
      }
      let suffix = source[range.upperBound...]
      return suffix.split(separator: "/").first.map(String.init)?.lowercased()
    })
}

private func makeNotices(
  pins: [Pin],
  checkoutRoot: URL,
  resolvedHash: String
) throws -> Data {
  let linkedNames = distributed.keys.sorted()
  let resolvedOnlyNames = pins.map(\.identity).filter { distributed[$0] == nil }.sorted()
  var text = """
    Computer MCP Third-Party Notices
    Product: Computer MCP 1.0.0 (1)
    Artifact: Computer-MCP-1.0.0-universal.dmg
    Package.resolved SHA-256: \(resolvedHash)

    This deterministic file is generated from the locked SwiftPM checkouts.
    Original Computer MCP code is governed by the separate proprietary LICENSE.

    LINKED AND DISTRIBUTED COMPONENTS

    """
  for identity in linkedNames {
    guard let pin = pins.first(where: { $0.identity == identity }),
      let definition = distributed[identity]
    else {
      throw MetadataError.missingPin(identity)
    }
    text += "- \(identity) \(pin.state.version ?? "unversioned")\n"
    text += "  Revision: \(pin.state.revision)\n"
    text += "  Source: \(pin.location)\n"
    text += "  License: \(definition.licenseExpression)\n"
  }
  text += "\nRESOLVED ONLY — NOT LINKED INTO THE APP OR EMBEDDED CLI\n\n"
  for identity in resolvedOnlyNames {
    guard let pin = pins.first(where: { $0.identity == identity }) else { continue }
    text += "- \(identity) \(pin.state.version ?? "unversioned") @ \(pin.state.revision)\n"
  }
  text += "\nCOMPLETE LICENSE AND NOTICE TEXTS FOR LINKED COMPONENTS\n"

  for identity in linkedNames {
    guard let definition = distributed[identity] else { continue }
    for relativePath in definition.legalFiles {
      let fileURL = checkoutRoot.appendingPathComponent("\(identity)/\(relativePath)")
      guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
        throw MetadataError.missingLegalFile(fileURL.path)
      }
      let legalText = try String(contentsOf: fileURL, encoding: .utf8)
      text += "\n======================================================================\n"
      text += "\(identity) — \(relativePath)\n"
      text += "======================================================================\n\n"
      text += legalText
      if !legalText.hasSuffix("\n") {
        text += "\n"
      }
    }
  }
  return Data(text.utf8)
}

do {
  let options = try Options(arguments: CommandLine.arguments)
  let resolvedURL = options.root.appendingPathComponent("Package.resolved")
  let resolvedData = try Data(contentsOf: resolvedURL)
  let resolved = try JSONDecoder().decode(ResolvedFile.self, from: resolvedData)
  let pins = resolved.pins.sorted { $0.identity < $1.identity }
  guard Set(pins.map(\.identity)).count == pins.count else {
    throw MetadataError.invalidResolvedFile("duplicate identities")
  }

  if let buildDescription = options.buildDescription {
    let actual = try linkedPackages(from: buildDescription)
    let expected = Set(distributed.keys)
    guard actual == expected else {
      throw MetadataError.unexpectedLinkedPackages(
        expected: expected.sorted(),
        actual: actual.sorted()
      )
    }
  }

  let resolvedHash = sha256(resolvedData)
  let manifestComponents = pins.map { pin in
    ManifestComponent(
      identity: pin.identity,
      version: pin.state.version ?? "unversioned",
      revision: pin.state.revision,
      source: pin.location,
      licenseExpression: distributed[pin.identity]?.licenseExpression
    )
  }
  let manifest = Manifest(
    product: Manifest.Product(
      name: "Computer MCP",
      version: "1.0.0",
      build: "1",
      artifact: "Computer-MCP-1.0.0-universal.dmg"
    ),
    packageResolvedSHA256: resolvedHash,
    linkedDistributed: manifestComponents.filter { distributed[$0.identity] != nil },
    resolvedOnly: manifestComponents.filter { distributed[$0.identity] == nil }
  )

  let rootReference = "pkg:generic/computer-mcp@1.0.0?build=1"
  let components = pins.map { pin in
    let definition = distributed[pin.identity]
    return CycloneDX.Component(
      bomRef: componentReference(pin),
      name: pin.identity,
      version: pin.state.version ?? "unversioned",
      scope: definition == nil ? "excluded" : "required",
      purl: githubPURL(pin),
      licenses: definition.map { [CycloneDX.LicenseChoice(expression: $0.licenseExpression)] },
      externalReferences: [
        CycloneDX.ExternalReference(type: "vcs", url: pin.location)
      ],
      properties: [
        CycloneDX.Property(
          name: "computer-mcp:release-classification",
          value: definition == nil ? "resolved-only" : "linked-and-distributed"
        ),
        CycloneDX.Property(name: "computer-mcp:resolved-revision", value: pin.state.revision),
      ]
    )
  }
  let sbom = CycloneDX(
    metadata: CycloneDX.Metadata(
      component: CycloneDX.RootComponent(
        bomRef: rootReference,
        group: "computer-mcp",
        name: "Computer MCP",
        version: "1.0.0",
        supplier: CycloneDX.Supplier(name: "Xudong Xu (@showxu)"),
        licenses: [
          CycloneDX.LicenseChoice(expression: "LicenseRef-Computer-MCP-Source-Visible-1.0")
        ],
        properties: [
          CycloneDX.Property(name: "computer-mcp:build", value: "1"),
          CycloneDX.Property(name: "computer-mcp:package-resolved-sha256", value: resolvedHash),
        ]
      )
    ),
    components: components,
    dependencies: [
      CycloneDX.Dependency(
        ref: rootReference,
        dependsOn: pins.filter { distributed[$0.identity] != nil }.map(componentReference)
      )
    ]
  )

  try FileManager.default.createDirectory(
    at: options.output,
    withIntermediateDirectories: true
  )
  try makeNotices(
    pins: pins,
    checkoutRoot: options.checkoutRoot,
    resolvedHash: resolvedHash
  ).write(
    to: options.output.appendingPathComponent("ThirdPartyNotices.txt"),
    options: .atomic
  )
  try encodedJSON(manifest).write(
    to: options.output.appendingPathComponent(
      "Computer-MCP-1.0.0-DependencyManifest.json"
    ),
    options: .atomic
  )
  try encodedJSON(sbom).write(
    to: options.output.appendingPathComponent("Computer-MCP-1.0.0-SBOM.cdx.json"),
    options: .atomic
  )
  print("Generated deterministic release metadata in \(options.output.path)")
} catch {
  FileHandle.standardError.write(Data("error: \(error)\n".utf8))
  exit(1)
}
