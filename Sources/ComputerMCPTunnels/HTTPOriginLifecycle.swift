/// Stops the HTTP origin owned by a tunnel's runtime.
package protocol HTTPOriginLifecycle: Sendable {
  func stop() async
}
