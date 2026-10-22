#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Installs a process-wide no-op SIGPIPE handler once, only for the default disposition,
/// so broken child-input pipes report write errors. Existing handlers and SIG_IGN are
/// preserved. A caught signal resets to default on exec; SIG_IGN would survive exec
/// and leak into children launched by Foundation Process on Linux.
package func installBrokenPipeHandler() {
  _ = brokenPipeHandlerInstallation
}

private let brokenPipeHandlerInstallation: Void = {
  var action = sigaction()
  guard sigaction(SIGPIPE, nil, &action) == 0 else { return }
  #if canImport(Darwin)
    guard action.__sigaction_u.__sa_handler == nil else { return }
    action.__sigaction_u.__sa_handler = { _ in }
  #elseif canImport(Glibc)
    guard action.__sigaction_handler.sa_handler == nil else { return }
    action.__sigaction_handler.sa_handler = { _ in }
  #endif
  sigemptyset(&action.sa_mask)
  action.sa_flags = SA_RESTART
  _ = sigaction(SIGPIPE, &action, nil)
}()
