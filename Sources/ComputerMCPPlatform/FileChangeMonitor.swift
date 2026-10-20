/// Reports possible file changes, including one notification at startup.
/// Consumers reread and compare the file; notifications may be coalesced.
package protocol FileChangeMonitor: Sendable {
  var changes: AsyncStream<Void> { get }
  func close() async
}
