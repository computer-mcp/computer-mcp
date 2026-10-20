import Foundation
import Testing

@testable import ComputerMCPPlatform
@testable import ComputerMCPPlatformPOSIX

struct PlatformExecutableInspectionTests {
  @Test
  func observesRealExecutableWithoutLaunchingIt() throws {
    let result = ExecutableInspection.inspect(
      "/bin/echo", workingDirectory: FileManager.default.temporaryDirectory,
      environment: ["PATH": "/usr/bin:/bin"])
    #expect(result.status == .passed)
    #expect(result.path == "/bin/echo")
    #expect(
      try JSONDecoder().decode(ExecutableInspection.self, from: JSONEncoder().encode(result))
        == result)
  }

}
