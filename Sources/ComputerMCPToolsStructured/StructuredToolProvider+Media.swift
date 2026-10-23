import ComputerMCPCore
import ComputerMCPToolKit
import Foundation

extension StructuredToolProvider {
  internal func imageInfo(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let includeProperties = try optionalBool("include_properties", in: object) ?? false
    let maxPropertyDepth = optionalInt("max_property_depth", in: object) ?? 2
    try validateBoundedNonNegative(maxPropertyDepth, name: "max_property_depth", upperBound: 6)

    let url = try projectScope.resolvedProjectURL(path)
    let info = try projectScope.fileInfo(url: url)
    guard info.type == "file" else {
      throw GatewayToolError.invalidArguments("Path is not a file: \(path)")
    }

    guard let inspector = environment.mediaInspector else {
      throw GatewayToolError.disabled("Media inspection is unavailable on this platform.")
    }
    guard
      var result = try inspector.imageInfo(
        at: url, includeProperties: includeProperties, maxPropertyDepth: maxPropertyDepth)
    else {
      throw GatewayToolError.invalidArguments("Unable to read image metadata: \(path)")
    }
    result["operation"] = .string("image.info")
    result["path"] = .string(url.path)
    result["project_relative_path"] = .string(info.projectRelativePath)
    result["size_bytes"] = info.size.map { .integer(Int64($0)) } ?? .null
    result["modified_at"] = info.modifiedAt.map { .string(iso8601String($0)) } ?? .null
    return .object(result)
  }

  internal func pdfInfo(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let maxPages = optionalInt("max_pages", in: object) ?? 20
    let includePageBoxes = try optionalBool("include_page_boxes", in: object) ?? true
    let includeAttributes = try optionalBool("include_attributes", in: object) ?? true
    try validateBoundedNonNegative(maxPages, name: "max_pages", upperBound: 10_000)

    let url = try projectScope.resolvedProjectURL(path)
    let info = try projectScope.fileInfo(url: url)
    guard info.type == "file" else {
      throw GatewayToolError.invalidArguments("Path is not a file: \(path)")
    }
    guard let inspector = environment.mediaInspector else {
      throw GatewayToolError.disabled("Media inspection is unavailable on this platform.")
    }
    guard
      var result = try inspector.pdfInfo(
        at: url, maxPages: maxPages, includePageBoxes: includePageBoxes,
        includeAttributes: includeAttributes)
    else {
      throw GatewayToolError.invalidArguments("Unable to read PDF metadata: \(path)")
    }
    result["operation"] = .string("pdf.info")
    result["path"] = .string(url.path)
    result["project_relative_path"] = .string(info.projectRelativePath)
    result["size_bytes"] = info.size.map { .integer(Int64($0)) } ?? .null
    result["modified_at"] = info.modifiedAt.map { .string(iso8601String($0)) } ?? .null
    return .object(result)
  }

  internal func pdfText(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let startPage = optionalInt("start_page", in: object) ?? 1
    let maxPages = optionalInt("max_pages", in: object) ?? 10
    let maxCharacters = optionalInt("max_characters", in: object) ?? 100_000
    try validateBoundedPositive(startPage, name: "start_page", upperBound: 1_000_000)
    try validateBoundedPositive(maxPages, name: "max_pages", upperBound: 10_000)
    try validateBoundedPositive(maxCharacters, name: "max_characters", upperBound: 5_000_000)

    let url = try projectScope.resolvedProjectURL(path)
    let info = try projectScope.fileInfo(url: url)
    guard info.type == "file" else {
      throw GatewayToolError.invalidArguments("Path is not a file: \(path)")
    }
    guard let inspector = environment.mediaInspector else {
      throw GatewayToolError.disabled("Media inspection is unavailable on this platform.")
    }
    guard
      var result = try inspector.pdfText(
        at: url, startPage: startPage, maxPages: maxPages, maxCharacters: maxCharacters)
    else {
      throw GatewayToolError.invalidArguments("Unable to read PDF text: \(path)")
    }
    result["operation"] = .string("pdf.text")
    result["path"] = .string(url.path)
    result["project_relative_path"] = .string(info.projectRelativePath)
    result["size_bytes"] = info.size.map { .integer(Int64($0)) } ?? .null
    result["modified_at"] = info.modifiedAt.map { .string(iso8601String($0)) } ?? .null
    return .object(result)
  }

  internal func mediaInfo(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let maxTracks = optionalInt("max_tracks", in: object) ?? 20
    let loadTimeoutMS = optionalInt("load_timeout_ms", in: object) ?? 5_000
    try validateBoundedNonNegative(maxTracks, name: "max_tracks", upperBound: 1_000)
    try validateBoundedPositive(loadTimeoutMS, name: "load_timeout_ms", upperBound: 600_000)

    let url = try projectScope.resolvedProjectURL(path)
    let info = try projectScope.fileInfo(url: url)
    guard info.type == "file" else {
      throw GatewayToolError.invalidArguments("Path is not a file: \(path)")
    }

    guard let inspector = environment.mediaInspector else {
      throw GatewayToolError.disabled("Media inspection is unavailable on this platform.")
    }
    var result = try inspector.mediaInfo(
      at: url, maxTracks: maxTracks, loadTimeoutMS: loadTimeoutMS)
    result["operation"] = .string("media.info")
    result["path"] = .string(url.path)
    result["project_relative_path"] = .string(info.projectRelativePath)
    result["size_bytes"] = info.size.map { .integer(Int64($0)) } ?? .null
    result["modified_at"] = info.modifiedAt.map { .string(iso8601String($0)) } ?? .null
    result["extension"] = .string(
      (info.projectRelativePath as NSString).pathExtension.lowercased())
    return .object(result)
  }
}
