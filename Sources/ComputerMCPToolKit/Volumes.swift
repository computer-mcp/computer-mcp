import ComputerMCPCore
import Foundation

package func volumeResourceKeys() -> [URLResourceKey] {
  var keys: [URLResourceKey] = [
    .nameKey,
    .volumeURLKey,
    .volumeNameKey,
    .volumeLocalizedNameKey,
    .volumeUUIDStringKey,
    .volumeTotalCapacityKey,
    .volumeAvailableCapacityKey,
  ]
  #if os(macOS)
    keys += [
      .volumeAvailableCapacityForImportantUsageKey,
      .volumeAvailableCapacityForOpportunisticUsageKey,
    ]
  #endif
  keys += [
    .volumeIsLocalKey,
    .volumeIsInternalKey,
    .volumeIsEjectableKey,
    .volumeIsRemovableKey,
    .volumeIsReadOnlyKey,
    .volumeSupportsCasePreservedNamesKey,
    .volumeSupportsCaseSensitiveNamesKey,
    .volumeSupportsCompressionKey,
    .volumeSupportsFileCloningKey,
    .volumeSupportsHardLinksKey,
    .volumeSupportsJournalingKey,
    .volumeSupportsPersistentIDsKey,
    .volumeSupportsSparseFilesKey,
    .volumeSupportsSymbolicLinksKey,
    .volumeSupportsVolumeSizesKey,
  ]
  return keys
}

package func volumeInfo(url: URL, keys: Set<URLResourceKey>) -> JSONValue {
  let values = try? url.resourceValues(forKeys: keys)
  let name =
    values?.volumeLocalizedName ?? values?.volumeName ?? values?.name ?? url.lastPathComponent
  // Capacity estimates are exposed only by Apple's Foundation.
  #if os(macOS)
    let importantCapacity =
      values?.volumeAvailableCapacityForImportantUsage
      .map { JSONValue.integer(Int64($0)) } ?? .null
    let opportunisticCapacity =
      values?.volumeAvailableCapacityForOpportunisticUsage
      .map { JSONValue.integer(Int64($0)) } ?? .null
  #else
    let importantCapacity = JSONValue.null
    let opportunisticCapacity = JSONValue.null
  #endif
  return .object([
    "path": .string(url.path),
    "name": .string(name),
    "localized_name": values?.volumeLocalizedName.map(JSONValue.string) ?? .null,
    "volume_name": values?.volumeName.map(JSONValue.string) ?? .null,
    "uuid": values?.volumeUUIDString.map(JSONValue.string) ?? .null,
    "total_capacity_bytes": values?.volumeTotalCapacity.map { .integer(Int64($0)) } ?? .null,
    "available_capacity_bytes": values?.volumeAvailableCapacity.map { .integer(Int64($0)) }
      ?? .null,
    "available_capacity_for_important_usage_bytes": importantCapacity,
    "available_capacity_for_opportunistic_usage_bytes": opportunisticCapacity,
    "is_local": values?.volumeIsLocal.map(JSONValue.bool) ?? .null,
    "is_internal": values?.volumeIsInternal.map(JSONValue.bool) ?? .null,
    "is_ejectable": values?.volumeIsEjectable.map(JSONValue.bool) ?? .null,
    "is_removable": values?.volumeIsRemovable.map(JSONValue.bool) ?? .null,
    "is_read_only": values?.volumeIsReadOnly.map(JSONValue.bool) ?? .null,
    "supports_case_preserved_names": values?.volumeSupportsCasePreservedNames
      .map(JSONValue.bool) ?? .null,
    "supports_case_sensitive_names": values?.volumeSupportsCaseSensitiveNames
      .map(JSONValue.bool) ?? .null,
    "supports_compression": values?.volumeSupportsCompression.map(JSONValue.bool) ?? .null,
    "supports_file_cloning": values?.volumeSupportsFileCloning.map(JSONValue.bool) ?? .null,
    "supports_hard_links": values?.volumeSupportsHardLinks.map(JSONValue.bool) ?? .null,
    "supports_journaling": values?.volumeSupportsJournaling.map(JSONValue.bool) ?? .null,
    "supports_persistent_ids": values?.volumeSupportsPersistentIDs.map(JSONValue.bool) ?? .null,
    "supports_sparse_files": values?.volumeSupportsSparseFiles.map(JSONValue.bool) ?? .null,
    "supports_symbolic_links": values?.volumeSupportsSymbolicLinks.map(JSONValue.bool) ?? .null,
    "supports_volume_sizes": values?.volumeSupportsVolumeSizes.map(JSONValue.bool) ?? .null,
  ])
}
