@preconcurrency import AVFoundation
import AppKit
import Foundation
import ImageIO
import PDFKit

extension GatewayToolRegistry {
  internal func imageInfo(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let includeProperties = try optionalBool("include_properties", in: object) ?? false
    let maxPropertyDepth = optionalInt("max_property_depth", in: object) ?? 2
    try validateBoundedNonNegative(maxPropertyDepth, name: "max_property_depth", upperBound: 6)

    let url = try resolvedWorkspaceURL(path)
    let info = try fileInfo(url: url)
    guard info.type == "file" else {
      throw GatewayToolError.invalidArguments("Path is not a file: \(path)")
    }

    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      throw GatewayToolError.invalidArguments("Unable to read image metadata: \(path)")
    }

    let imageCount = CGImageSourceGetCount(source)
    guard imageCount > 0 else {
      throw GatewayToolError.invalidArguments("Unable to read image metadata: \(path)")
    }

    let typeIdentifier = CGImageSourceGetType(source).map { String($0) }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let globalProperties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]

    let pixelWidth = intImageProperty(properties, kCGImagePropertyPixelWidth)
    let pixelHeight = intImageProperty(properties, kCGImagePropertyPixelHeight)
    let depth = intImageProperty(properties, kCGImagePropertyDepth)
    let orientation = intImageProperty(properties, kCGImagePropertyOrientation)
    let dpiWidth = doubleImageProperty(properties, kCGImagePropertyDPIWidth)
    let dpiHeight = doubleImageProperty(properties, kCGImagePropertyDPIHeight)
    let hasAlpha = boolImageProperty(properties, kCGImagePropertyHasAlpha)
    let isFloat = boolImageProperty(properties, kCGImagePropertyIsFloat)
    let colorModel = stringImageProperty(properties, kCGImagePropertyColorModel)
    let profileName = stringImageProperty(properties, kCGImagePropertyProfileName)
    var propertiesTruncated = false

    var result: [String: JSONValue] = [
      "operation": .string("image.info"),
      "path": .string(url.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "type_identifier": typeIdentifier.map(JSONValue.string) ?? .null,
      "mime_type": typeIdentifier.flatMap(imageMIMEType(for:)).map(JSONValue.string) ?? .null,
      "frame_count": .integer(Int64(imageCount)),
      "pixel_width": pixelWidth.map { .integer(Int64($0)) } ?? .null,
      "pixel_height": pixelHeight.map { .integer(Int64($0)) } ?? .null,
      "depth": depth.map { .integer(Int64($0)) } ?? .null,
      "orientation": orientation.map { .integer(Int64($0)) } ?? .null,
      "dpi_width": dpiWidth.map(JSONValue.number) ?? .null,
      "dpi_height": dpiHeight.map(JSONValue.number) ?? .null,
      "has_alpha": hasAlpha.map(JSONValue.bool) ?? .null,
      "is_float": isFloat.map(JSONValue.bool) ?? .null,
      "color_model": colorModel.map(JSONValue.string) ?? .null,
      "profile_name": profileName.map(JSONValue.string) ?? .null,
      "properties_included": .bool(includeProperties),
    ]

    if includeProperties {
      result["properties"] = try imagePropertiesJSON(
        properties,
        maxDepth: maxPropertyDepth,
        truncated: &propertiesTruncated
      )
      result["global_properties"] = try imagePropertiesJSON(
        globalProperties,
        maxDepth: maxPropertyDepth,
        truncated: &propertiesTruncated
      )
    }
    result["properties_truncated"] = .bool(propertiesTruncated)
    result["truncated"] = .bool(propertiesTruncated)

    return .object(result)
  }

  private func intImageProperty(_ properties: [CFString: Any]?, _ key: CFString) -> Int? {
    guard let value = properties?[key] else {
      return nil
    }
    if let number = value as? NSNumber {
      return number.intValue
    }
    if let string = value as? String {
      return Int(string)
    }
    return nil
  }

  private func doubleImageProperty(_ properties: [CFString: Any]?, _ key: CFString) -> Double? {
    guard let value = properties?[key] else {
      return nil
    }
    if let number = value as? NSNumber {
      return number.doubleValue
    }
    if let string = value as? String {
      return Double(string)
    }
    return nil
  }

  private func boolImageProperty(_ properties: [CFString: Any]?, _ key: CFString) -> Bool? {
    guard let value = properties?[key] else {
      return nil
    }
    if let bool = value as? Bool {
      return bool
    }
    if let number = value as? NSNumber {
      return number.boolValue
    }
    if let string = value as? String {
      return Bool(string)
    }
    return nil
  }

  private func stringImageProperty(_ properties: [CFString: Any]?, _ key: CFString) -> String? {
    guard let value = properties?[key] else {
      return nil
    }
    if let string = value as? String {
      return string
    }
    if let number = value as? NSNumber {
      return number.stringValue
    }
    return nil
  }

  private func imageMIMEType(for typeIdentifier: String) -> String? {
    let lowercased = typeIdentifier.lowercased()
    if lowercased.contains("png") {
      return "image/png"
    }
    if lowercased.contains("jpeg") || lowercased.contains("jpg") {
      return "image/jpeg"
    }
    if lowercased.contains("gif") {
      return "image/gif"
    }
    if lowercased.contains("tiff") || lowercased.contains("tif") {
      return "image/tiff"
    }
    if lowercased.contains("bmp") {
      return "image/bmp"
    }
    if lowercased.contains("webp") {
      return "image/webp"
    }
    if lowercased.contains("heic") {
      return "image/heic"
    }
    if lowercased.contains("heif") {
      return "image/heif"
    }
    if lowercased.contains("ico") {
      return "image/vnd.microsoft.icon"
    }
    if lowercased.contains("icns") {
      return "image/icns"
    }
    return nil
  }

  private func imagePropertiesJSON(
    _ properties: [CFString: Any]?,
    maxDepth: Int,
    truncated: inout Bool
  ) throws -> JSONValue {
    guard let properties else {
      return .null
    }

    let entries = properties.sorted {
      String($0.key).localizedStandardCompare(String($1.key)) == .orderedAscending
    }
    var object: [String: JSONValue] = [:]
    for (index, entry) in entries.enumerated() {
      if index >= 200 {
        truncated = true
        break
      }
      object[String(entry.key)] = try imagePropertyValueJSON(
        entry.value,
        depth: maxDepth,
        truncated: &truncated
      )
    }
    return .object(object)
  }

  private func imagePropertyValueJSON(
    _ value: Any,
    depth: Int,
    truncated: inout Bool
  ) throws -> JSONValue {
    if let number = value as? NSNumber {
      return try JSONValue(foundationNumber: number)
    }
    if let string = value as? String {
      if string.utf8.count > 4_096 {
        let preview = utf8Preview(string, maxBytes: 4_096)
        truncated = true
        return .string(preview.text)
      }
      return .string(string)
    }
    if let date = value as? Date {
      return .string(iso8601String(date))
    }
    if let data = value as? Data {
      let maxBytes = 256
      let bounded = data.prefix(maxBytes)
      if data.count > maxBytes {
        truncated = true
      }
      return .object([
        "type": .string("data"),
        "size_bytes": .integer(Int64(data.count)),
        "base64_prefix": .string(Data(bounded).base64EncodedString()),
        "truncated": .bool(data.count > maxBytes),
      ])
    }
    if let dictionary = value as? [CFString: Any] {
      return try imageDictionaryJSON(dictionary, depth: depth, truncated: &truncated)
    }
    if let dictionary = value as? [String: Any] {
      return try imageDictionaryJSON(dictionary, depth: depth, truncated: &truncated)
    }
    if let array = value as? [Any] {
      guard depth > 0 else {
        truncated = true
        return .object([
          "type": .string("array"),
          "count": .integer(Int64(array.count)),
          "truncated": .bool(true),
        ])
      }
      let maxItems = 100
      if array.count > maxItems {
        truncated = true
      }
      return .array(
        try array.prefix(maxItems).map {
          try imagePropertyValueJSON($0, depth: depth - 1, truncated: &truncated)
        })
    }

    return .string(String(describing: value))
  }

  private func imageDictionaryJSON(
    _ dictionary: [CFString: Any],
    depth: Int,
    truncated: inout Bool
  ) throws -> JSONValue {
    let stringDictionary = Dictionary(
      uniqueKeysWithValues: dictionary.map { (String($0.key), $0.value) })
    return try imageDictionaryJSON(stringDictionary, depth: depth, truncated: &truncated)
  }

  private func imageDictionaryJSON(
    _ dictionary: [String: Any],
    depth: Int,
    truncated: inout Bool
  ) throws -> JSONValue {
    guard depth > 0 else {
      truncated = true
      return .object([
        "type": .string("dictionary"),
        "count": .integer(Int64(dictionary.count)),
        "truncated": .bool(true),
      ])
    }

    let entries = dictionary.sorted {
      $0.key.localizedStandardCompare($1.key) == .orderedAscending
    }
    let maxEntries = 200
    if entries.count > maxEntries {
      truncated = true
    }
    var object: [String: JSONValue] = [:]
    for entry in entries.prefix(maxEntries) {
      object[entry.key] = try imagePropertyValueJSON(
        entry.value,
        depth: depth - 1,
        truncated: &truncated
      )
    }
    return .object(object)
  }

  internal func pdfInfo(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let maxPages = optionalInt("max_pages", in: object) ?? 20
    let includePageBoxes = try optionalBool("include_page_boxes", in: object) ?? true
    let includeAttributes = try optionalBool("include_attributes", in: object) ?? true
    try validateBoundedNonNegative(maxPages, name: "max_pages", upperBound: 10_000)

    let url = try resolvedWorkspaceURL(path)
    let info = try fileInfo(url: url)
    guard info.type == "file" else {
      throw GatewayToolError.invalidArguments("Path is not a file: \(path)")
    }
    guard let document = PDFDocument(url: url) else {
      throw GatewayToolError.invalidArguments("Unable to read PDF metadata: \(path)")
    }

    let pageCount = document.pageCount
    let returnedPageCount = min(maxPages, pageCount)
    var pages: [JSONValue] = []
    for index in 0..<returnedPageCount {
      guard let page = document.page(at: index) else {
        continue
      }
      var pageObject: [String: JSONValue] = [
        "index": .integer(Int64(index)),
        "number": .integer(Int64(index + 1)),
        "label": page.label.map(JSONValue.string) ?? .null,
        "rotation": .integer(Int64(page.rotation)),
      ]
      if includePageBoxes {
        pageObject["boxes"] = .object([
          "media": pdfRectJSON(page.bounds(for: .mediaBox)),
          "crop": pdfRectJSON(page.bounds(for: .cropBox)),
          "bleed": pdfRectJSON(page.bounds(for: .bleedBox)),
          "trim": pdfRectJSON(page.bounds(for: .trimBox)),
          "art": pdfRectJSON(page.bounds(for: .artBox)),
        ])
      }
      pages.append(.object(pageObject))
    }

    var attributesTruncated = false
    var result: [String: JSONValue] = [
      "operation": .string("pdf.info"),
      "path": .string(url.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "page_count": .integer(Int64(pageCount)),
      "returned_page_count": .integer(Int64(pages.count)),
      "pages_truncated": .bool(pageCount > returnedPageCount),
      "include_page_boxes": .bool(includePageBoxes),
      "attributes_included": .bool(includeAttributes),
      "is_encrypted": .bool(document.isEncrypted),
      "is_locked": .bool(document.isLocked),
      "allows_copying": .bool(document.allowsCopying),
      "allows_printing": .bool(document.allowsPrinting),
      "pages": .array(pages),
    ]

    if includeAttributes {
      result["attributes"] = try pdfAttributesJSON(
        document.documentAttributes ?? [:],
        truncated: &attributesTruncated
      )
    }
    result["attributes_truncated"] = .bool(attributesTruncated)
    result["truncated"] = .bool(pageCount > returnedPageCount || attributesTruncated)

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

    let url = try resolvedWorkspaceURL(path)
    let info = try fileInfo(url: url)
    guard info.type == "file" else {
      throw GatewayToolError.invalidArguments("Path is not a file: \(path)")
    }
    guard let document = PDFDocument(url: url) else {
      throw GatewayToolError.invalidArguments("Unable to read PDF text: \(path)")
    }
    guard !document.isLocked else {
      throw GatewayToolError.invalidArguments("Unable to read PDF text: document is locked.")
    }
    guard document.allowsCopying else {
      throw GatewayToolError.invalidArguments("Unable to read PDF text: copying is not allowed.")
    }

    let pageCount = document.pageCount
    if pageCount == 0 {
      return .object([
        "operation": .string("pdf.text"),
        "path": .string(url.path),
        "workspace_relative_path": .string(info.workspaceRelativePath),
        "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
        "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
        "page_count": .number(0),
        "start_page": .integer(Int64(startPage)),
        "max_pages": .integer(Int64(maxPages)),
        "max_characters": .integer(Int64(maxCharacters)),
        "returned_page_count": .number(0),
        "total_extracted_character_count": .number(0),
        "page_range_truncated": .bool(false),
        "text_truncated": .bool(false),
        "truncated": .bool(false),
        "pages": .array([]),
      ])
    }
    guard startPage <= pageCount else {
      throw GatewayToolError.invalidArguments(
        "start_page exceeds PDF page_count (\(pageCount)): \(startPage)")
    }

    let startIndex = startPage - 1
    let exclusiveEndIndex = min(pageCount, startIndex + maxPages)
    var pages: [JSONValue] = []
    var remainingCharacters = maxCharacters
    var totalExtractedCharacters = 0
    var textTruncated = false

    for index in startIndex..<exclusiveEndIndex {
      guard let page = document.page(at: index) else {
        continue
      }
      guard remainingCharacters > 0 else {
        textTruncated = true
        break
      }

      let rawText = page.string ?? ""
      let pageCharacterCount = rawText.count
      let pageText: String
      let pageTextTruncated: Bool
      if pageCharacterCount > remainingCharacters {
        pageText = String(rawText.prefix(remainingCharacters))
        pageTextTruncated = true
        textTruncated = true
        remainingCharacters = 0
      } else {
        pageText = rawText
        pageTextTruncated = false
        remainingCharacters -= pageCharacterCount
      }
      totalExtractedCharacters += pageText.count
      pages.append(
        .object([
          "index": .integer(Int64(index)),
          "number": .integer(Int64(index + 1)),
          "label": page.label.map(JSONValue.string) ?? .null,
          "text": .string(pageText),
          "character_count": .integer(Int64(pageCharacterCount)),
          "extracted_character_count": .integer(Int64(pageText.count)),
          "text_truncated": .bool(pageTextTruncated),
        ]))
      if pageTextTruncated {
        break
      }
    }

    let pageRangeTruncated = exclusiveEndIndex < pageCount
    return .object([
      "operation": .string("pdf.text"),
      "path": .string(url.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "page_count": .integer(Int64(pageCount)),
      "start_page": .integer(Int64(startPage)),
      "max_pages": .integer(Int64(maxPages)),
      "max_characters": .integer(Int64(maxCharacters)),
      "returned_page_count": .integer(Int64(pages.count)),
      "total_extracted_character_count": .integer(Int64(totalExtractedCharacters)),
      "page_range_truncated": .bool(pageRangeTruncated),
      "text_truncated": .bool(textTruncated),
      "truncated": .bool(pageRangeTruncated || textTruncated),
      "pages": .array(pages),
    ])
  }

  private func pdfRectJSON(_ rect: CGRect) -> JSONValue {
    .object([
      "x": .number(Double(rect.origin.x)),
      "y": .number(Double(rect.origin.y)),
      "width": .number(Double(rect.width)),
      "height": .number(Double(rect.height)),
      "min_x": .number(Double(rect.minX)),
      "min_y": .number(Double(rect.minY)),
      "max_x": .number(Double(rect.maxX)),
      "max_y": .number(Double(rect.maxY)),
    ])
  }

  private func pdfAttributesJSON(
    _ attributes: [AnyHashable: Any],
    truncated: inout Bool
  ) throws -> JSONValue {
    let entries = attributes.sorted {
      pdfAttributeName($0.key).localizedStandardCompare(pdfAttributeName($1.key))
        == .orderedAscending
    }
    let maxEntries = 200
    if entries.count > maxEntries {
      truncated = true
    }
    var object: [String: JSONValue] = [:]
    for entry in entries.prefix(maxEntries) {
      object[pdfAttributeName(entry.key)] = try pdfAttributeValueJSON(
        entry.value,
        depth: 2,
        truncated: &truncated
      )
    }
    return .object(object)
  }

  private func pdfAttributeName(_ key: AnyHashable) -> String {
    if let attribute = key.base as? PDFDocumentAttribute {
      return attribute.rawValue
    }
    return String(describing: key.base)
  }

  private func pdfAttributeValueJSON(
    _ value: Any,
    depth: Int,
    truncated: inout Bool
  ) throws -> JSONValue {
    if let number = value as? NSNumber {
      return try JSONValue(foundationNumber: number)
    }
    if let string = value as? String {
      if string.utf8.count > 4_096 {
        let preview = utf8Preview(string, maxBytes: 4_096)
        truncated = true
        return .string(preview.text)
      }
      return .string(string)
    }
    if let date = value as? Date {
      return .string(iso8601String(date))
    }
    if let array = value as? [Any] {
      guard depth > 0 else {
        truncated = true
        return .object([
          "type": .string("array"),
          "count": .integer(Int64(array.count)),
          "truncated": .bool(true),
        ])
      }
      let maxItems = 100
      if array.count > maxItems {
        truncated = true
      }
      return .array(
        try array.prefix(maxItems).map {
          try pdfAttributeValueJSON($0, depth: depth - 1, truncated: &truncated)
        })
    }
    if let dictionary = value as? [String: Any] {
      guard depth > 0 else {
        truncated = true
        return .object([
          "type": .string("dictionary"),
          "count": .integer(Int64(dictionary.count)),
          "truncated": .bool(true),
        ])
      }
      let entries = dictionary.sorted {
        $0.key.localizedStandardCompare($1.key) == .orderedAscending
      }
      let maxEntries = 200
      if entries.count > maxEntries {
        truncated = true
      }
      var object: [String: JSONValue] = [:]
      for entry in entries.prefix(maxEntries) {
        object[entry.key] = try pdfAttributeValueJSON(
          entry.value,
          depth: depth - 1,
          truncated: &truncated
        )
      }
      return .object(object)
    }
    return .string(String(describing: value))
  }

  internal func mediaInfo(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let maxTracks = optionalInt("max_tracks", in: object) ?? 20
    let loadTimeoutMS = optionalInt("load_timeout_ms", in: object) ?? 5_000
    try validateBoundedNonNegative(maxTracks, name: "max_tracks", upperBound: 1_000)
    try validateBoundedPositive(loadTimeoutMS, name: "load_timeout_ms", upperBound: 600_000)

    let url = try resolvedWorkspaceURL(path)
    let info = try fileInfo(url: url)
    guard info.type == "file" else {
      throw GatewayToolError.invalidArguments("Path is not a file: \(path)")
    }

    let duration: CMTime
    let tracks: [AVAssetTrack]
    let isPlayable: Bool
    let hasProtectedContent: Bool
    let providesPreciseDurationAndTiming: Bool
    let availableMetadataFormats: [AVMetadataFormat]
    do {
      duration = try loadMediaProperty(timeoutMilliseconds: loadTimeoutMS) {
        try await AVURLAsset(url: url).load(.duration)
      }
      tracks = try loadMediaProperty(timeoutMilliseconds: loadTimeoutMS) {
        try await AVURLAsset(url: url).load(.tracks)
      }
      isPlayable = try loadMediaProperty(timeoutMilliseconds: loadTimeoutMS) {
        try await AVURLAsset(url: url).load(.isPlayable)
      }
      hasProtectedContent = try loadMediaProperty(timeoutMilliseconds: loadTimeoutMS) {
        try await AVURLAsset(url: url).load(.hasProtectedContent)
      }
      providesPreciseDurationAndTiming = try loadMediaProperty(timeoutMilliseconds: loadTimeoutMS) {
        try await AVURLAsset(url: url).load(.providesPreciseDurationAndTiming)
      }
      availableMetadataFormats = try loadMediaProperty(timeoutMilliseconds: loadTimeoutMS) {
        try await AVURLAsset(url: url).load(.availableMetadataFormats)
      }
    } catch {
      throw GatewayToolError.invalidArguments(
        "Unable to read media metadata: \(error.localizedDescription)")
    }

    var mediaTypes = Set<String>()
    var trackRows: [JSONValue] = []
    for (index, track) in tracks.prefix(maxTracks).enumerated() {
      let mediaType = mediaTypeName(track.mediaType)
      mediaTypes.insert(mediaType)
      trackRows.append(
        mediaTrackJSON(
          track,
          index: index,
          mediaType: mediaType,
          timeoutMilliseconds: loadTimeoutMS
        ))
    }

    return .object([
      "operation": .string("media.info"),
      "path": .string(url.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "extension": .string((info.workspaceRelativePath as NSString).pathExtension.lowercased()),
      "duration_seconds": finiteMediaSeconds(duration).map(JSONValue.number) ?? .null,
      "duration_timescale": .integer(Int64(duration.timescale)),
      "is_playable": .bool(isPlayable),
      "has_protected_content": .bool(hasProtectedContent),
      "provides_precise_duration_and_timing": .bool(providesPreciseDurationAndTiming),
      "track_count": .integer(Int64(tracks.count)),
      "returned_track_count": .integer(Int64(trackRows.count)),
      "tracks_truncated": .bool(tracks.count > trackRows.count),
      "media_types": .array(mediaTypes.sorted().map(JSONValue.string)),
      "metadata_format_count": .integer(Int64(availableMetadataFormats.count)),
      "available_metadata_formats": .array(
        availableMetadataFormats.map { .string($0.rawValue) }),
      "load_timeout_ms": .integer(Int64(loadTimeoutMS)),
      "tracks": .array(trackRows),
      "truncated": .bool(tracks.count > trackRows.count),
    ])
  }

  private func mediaTrackJSON(
    _ track: AVAssetTrack,
    index: Int,
    mediaType: String,
    timeoutMilliseconds: Int
  ) -> JSONValue {
    let naturalSize = try? loadMediaProperty(timeoutMilliseconds: timeoutMilliseconds) {
      try await track.load(.naturalSize)
    }
    let nominalFrameRate = try? loadMediaProperty(timeoutMilliseconds: timeoutMilliseconds) {
      try await track.load(.nominalFrameRate)
    }
    let estimatedDataRate = try? loadMediaProperty(timeoutMilliseconds: timeoutMilliseconds) {
      try await track.load(.estimatedDataRate)
    }
    let timeRange = try? loadMediaProperty(timeoutMilliseconds: timeoutMilliseconds) {
      try await track.load(.timeRange)
    }
    let languageCode = try? loadMediaProperty(timeoutMilliseconds: timeoutMilliseconds) {
      try await track.load(.languageCode)
    }
    let isEnabled = try? loadMediaProperty(timeoutMilliseconds: timeoutMilliseconds) {
      try await track.load(.isEnabled)
    }
    let isPlayable = try? loadMediaProperty(timeoutMilliseconds: timeoutMilliseconds) {
      try await track.load(.isPlayable)
    }
    let formatDescriptions = try? loadMediaProperty(timeoutMilliseconds: timeoutMilliseconds) {
      try await track.load(.formatDescriptions)
    }

    var object: [String: JSONValue] = [
      "index": .integer(Int64(index)),
      "media_type": .string(mediaType),
      "duration_seconds": timeRange.flatMap { finiteMediaSeconds($0.duration) }.map(
        JSONValue.number)
        ?? .null,
      "is_enabled": isEnabled.map(JSONValue.bool) ?? .null,
      "is_playable": isPlayable.map(JSONValue.bool) ?? .null,
      "estimated_data_rate": estimatedDataRate.map { .number(Double($0)) } ?? .null,
      "language_code": languageCode.map(JSONValue.string) ?? .null,
      "codec_types": .array(mediaCodecTypes(formatDescriptions ?? []).map(JSONValue.string)),
    ]

    if let naturalSize {
      object["natural_size"] = .object([
        "width": .number(Double(naturalSize.width)),
        "height": .number(Double(naturalSize.height)),
      ])
    } else {
      object["natural_size"] = .null
    }
    if let nominalFrameRate {
      object["nominal_frame_rate"] = .number(Double(nominalFrameRate))
    } else {
      object["nominal_frame_rate"] = .null
    }

    return .object(object)
  }

  private func loadMediaProperty<T>(
    timeoutMilliseconds: Int,
    _ operation: @escaping @Sendable () async throws -> T
  ) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let resultBox = AsyncMediaLoadResultBox<T>()
    let task = Task {
      do {
        resultBox.set(.success(try await operation()))
      } catch {
        resultBox.set(.failure(error))
      }
      semaphore.signal()
    }

    let timeout = DispatchTime.now() + .milliseconds(timeoutMilliseconds)
    guard semaphore.wait(timeout: timeout) == .success else {
      task.cancel()
      throw GatewayToolError.invalidArguments("Timed out reading media metadata.")
    }
    guard let result = resultBox.get() else {
      throw GatewayToolError.invalidArguments("Unable to read media metadata.")
    }
    return try result.get()
  }

  private func mediaTypeName(_ mediaType: AVMediaType) -> String {
    switch mediaType {
    case .audio:
      return "audio"
    case .video:
      return "video"
    case .text:
      return "text"
    case .closedCaption:
      return "closed_caption"
    case .subtitle:
      return "subtitle"
    case .timecode:
      return "timecode"
    case .metadata:
      return "metadata"
    case .muxed:
      return "muxed"
    default:
      return mediaType.rawValue
    }
  }

  private func finiteMediaSeconds(_ time: CMTime) -> Double? {
    guard time.isValid, !time.isIndefinite, !time.isPositiveInfinity, !time.isNegativeInfinity
    else {
      return nil
    }
    let seconds = CMTimeGetSeconds(time)
    guard seconds.isFinite else {
      return nil
    }
    return seconds
  }

  private func mediaCodecTypes(_ formatDescriptions: [CMFormatDescription]) -> [String] {
    Array(
      Set(
        formatDescriptions.map {
          fourCharacterCodeString(CMFormatDescriptionGetMediaSubType($0))
        }
      )
    )
    .sorted()
  }

  private func fourCharacterCodeString(_ code: FourCharCode) -> String {
    let littleEndian = code.littleEndian
    let bytes = [
      UInt8((littleEndian >> 24) & 0xff),
      UInt8((littleEndian >> 16) & 0xff),
      UInt8((littleEndian >> 8) & 0xff),
      UInt8(littleEndian & 0xff),
    ]
    let scalars = bytes.map { byte -> UnicodeScalar in
      if byte >= 32, byte <= 126 {
        return UnicodeScalar(byte)
      }
      return UnicodeScalar(0x2e)
    }
    return String(String.UnicodeScalarView(scalars))
  }
}

private final class AsyncMediaLoadResultBox<T>: @unchecked Sendable {
  private let queue = DispatchQueue(label: "computer-mcp.media-load-result")
  private var result: Result<T, Error>?

  func set(_ value: Result<T, Error>) {
    queue.sync {
      result = value
    }
  }

  func get() -> Result<T, Error>? {
    queue.sync {
      result
    }
  }
}
