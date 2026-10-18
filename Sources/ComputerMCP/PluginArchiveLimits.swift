struct PluginArchiveLimits: Sendable {
  var archiveBytes = 512 * 1_024 * 1_024
  var expandedBytes = 1_024 * 1_024 * 1_024
  var fileBytes = 256 * 1_024 * 1_024
  var entries = 20_000
  var pathBytes = 4_096
  var pathDepth = 32

  func validate() throws {
    guard archiveBytes > 0, expandedBytes > 0, fileBytes > 0,
      entries > 0, entries <= 20_000, pathBytes > 0, pathBytes <= 4_096,
      pathDepth > 0, pathDepth <= 32,
      archiveBytes <= 512 * 1_024 * 1_024,
      expandedBytes <= 1_024 * 1_024 * 1_024,
      fileBytes <= 256 * 1_024 * 1_024
    else { throw PluginArchiveError.invalidInput }
  }
}
