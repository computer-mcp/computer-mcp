package struct PluginArchiveLimits: Sendable {
  package var archiveBytes: Int
  package var expandedBytes: Int
  package var fileBytes: Int
  package var entries: Int
  package var pathBytes: Int
  package var pathDepth: Int

  package init(
    archiveBytes: Int = 512 * 1_024 * 1_024, expandedBytes: Int = 1_024 * 1_024 * 1_024,
    fileBytes: Int = 256 * 1_024 * 1_024, entries: Int = 20_000, pathBytes: Int = 4_096,
    pathDepth: Int = 32
  ) {
    self.archiveBytes = archiveBytes
    self.expandedBytes = expandedBytes
    self.fileBytes = fileBytes
    self.entries = entries
    self.pathBytes = pathBytes
    self.pathDepth = pathDepth
  }

  package func validate() throws {
    guard archiveBytes > 0, expandedBytes > 0, fileBytes > 0,
      entries > 0, entries <= 20_000, pathBytes > 0, pathBytes <= 4_096,
      pathDepth > 0, pathDepth <= 32,
      archiveBytes <= 512 * 1_024 * 1_024,
      expandedBytes <= 1_024 * 1_024 * 1_024,
      fileBytes <= 256 * 1_024 * 1_024
    else { throw PluginArchiveError.invalidInput }
  }
}
