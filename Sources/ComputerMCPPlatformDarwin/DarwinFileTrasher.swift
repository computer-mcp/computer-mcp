import ComputerMCPPlatform
import Foundation

package struct DarwinFileTrasher: FileTrashing {
  package init() {}

  package func trashItem(at url: URL) throws -> URL? {
    var resultingURL: NSURL?
    try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
    return resultingURL as URL?
  }
}
