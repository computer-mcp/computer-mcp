import ComputerMCPCore
import Foundation

/// Reads bounded media metadata and searchable PDF text from already-scoped files.
/// Image and PDF operations return nil when the file cannot be opened in that format.
/// Results contain format-specific fields; callers supply operation and file identity.
/// Callers validate limits before invoking these operations.
package protocol MediaInspector: Sendable {
  func imageInfo(at url: URL, includeProperties: Bool, maxPropertyDepth: Int) throws
    -> [String: JSONValue]?
  func pdfInfo(at url: URL, maxPages: Int, includePageBoxes: Bool, includeAttributes: Bool) throws
    -> [String: JSONValue]?
  func pdfText(at url: URL, startPage: Int, maxPages: Int, maxCharacters: Int) throws
    -> [String: JSONValue]?
  func mediaInfo(at url: URL, maxTracks: Int, loadTimeoutMS: Int) throws -> [String: JSONValue]
}
