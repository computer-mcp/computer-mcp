#if os(Linux)
  import ComputerMCPProcess
  import ComputerMCPPlatformPOSIX

  package func testExecutionLauncher(observations: ExecutionObservations? = nil)
    -> ExecutionLauncher
  {
    let base = POSIXExecutionPlatform()
    if let observations {
      return ExecutionLauncher(
        platform: ObservedExecutionPlatform(base: base, observations: observations))
    }
    return ExecutionLauncher(platform: base)
  }
#endif
