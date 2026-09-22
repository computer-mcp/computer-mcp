import ArgumentParser
import ComputerMCP
import Foundation

struct Plugins: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "plugins",
    abstract: "Manage App-owned plugin registrations and host settings.",
    discussion:
      "Read list/show first, then supply the returned state.revision with each change. Development registration does not build, execute, or install external dependencies. Changes do not interrupt connected gateway clients.",
    subcommands: [
      List.self, Show.self, Doctor.self, Register.self, Configure.self, Enable.self, Disable.self,
      Select.self,
      Remove.self, Search.self, Artifacts.self, Install.self, InstallRelease.self,
      Uninstall.self, Recover.self,
    ])

  struct Revision: ParsableArguments {
    @OptionGroup var connection: AppControlConnectionOptions
    @Option(name: .long, help: "state.revision returned by list/show; stale updates are rejected.")
    var expectedRevision: Int64

    func validate() throws {
      guard (0...9_007_199_254_740_991).contains(expectedRevision) else {
        throw ValidationError("--expected-revision must be a nonnegative exact JSON integer.")
      }
    }
    var arguments: [String: JSONValue] { ["expected_revision": .number(Double(expectedRevision))] }
  }

  struct List: AsyncParsableCommand {
    @OptionGroup var connection: AppControlConnectionOptions
    static let configuration = CommandConfiguration(
      commandName: "list",
      abstract: "Read sources, settings, contribution origins and resolution diagnostics as JSON.")
    func run() async throws {
      printJSON(try await connection.client().call("plugin.list"))
    }
  }

  struct Show: AsyncParsableCommand {
    @OptionGroup var connection: AppControlConnectionOptions
    static let configuration = CommandConfiguration(
      commandName: "show", abstract: "Read one plugin's recorded source and settings.")
    @Argument var id: String
    func run() async throws {
      printJSON(
        try await connection.client().call(
          "plugin.show", arguments: .object(["id": .string(id)])))
    }
  }

  struct Doctor: AsyncParsableCommand {
    @OptionGroup var connection: AppControlConnectionOptions
    @Argument(help: "Plugin ID from list, including disabled packages.") var id: String
    static let configuration = CommandConfiguration(
      commandName: "doctor",
      abstract: "Check one package's source, compatibility, dependencies and files as JSON.",
      discussion:
        "Checks disabled contributions without enabling them. No contribution, version probe, connection, permission prompt or installer is started. Read scope and notChecked: file checks do not prove runtime compatibility or connection health. Exit 1 means a failed check or control error; unverified checks remain explicit in a successful report. No settings revision is changed."
    )
    func run() async throws {
      let report = try await Plugins.perform(
        "plugin.doctor", arguments: ["id": .string(id)], connection: connection, mutation: false)
      if report.objectValue?["status"] == .string("failed") { throw ExitCode.failure }
    }
  }

  struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "search",
      abstract: "Search official GitHub plugin declarations as JSON; does not install or execute.",
      discussion:
        "Each page checks up to 10 official repositories and filters their manifests by query and contribution kind. Follow next_page even when a filtered page has no entries. Source provenance is not an artifact signature. Results may be cached for 60 seconds; --refresh requests fresh metadata."
    )
    @Argument(help: "Words matched against repository, plugin ID, name and description.")
    var query = ""
    @Option(name: .long, help: "Contribution filter: mcp, cli, or skills.") var kind: String?
    @Option(name: .long, help: "Repository page, starting at 1.") var page = 1
    @Flag(name: .long, help: "Bypass the host's short-lived metadata cache.") var refresh = false
    @OptionGroup var connection: AppControlConnectionOptions

    func validate() throws {
      guard query.utf8.count <= 256, !query.contains("\0"), (1...100_000).contains(page),
        kind == nil || IntegrationKind(rawValue: kind!) != nil
      else {
        throw ValidationError(
          "Use a query of at most 256 bytes, --page 1...100000 and --kind mcp|cli|skills.")
      }
    }

    func run() async throws {
      var args: [String: JSONValue] = [
        "query": .string(query), "page": .number(Double(page)), "refresh": .bool(refresh),
      ]
      args["kind"] = kind.map(JSONValue.string)
      do {
        printJSON(try await connection.client().call("plugin.search", arguments: .object(args)))
      } catch {
        let failure = error as? ControlSocketCallError
        printJSON(
          .object([
            "error": .object([
              "code": .string(failure?.code ?? "control.unavailable"),
              "message": .string(failure?.message ?? "The App control socket is unavailable."),
            ])
          ]))
        throw ExitCode.failure
      }
    }
  }

  struct Register: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "register",
      abstract: "Register or refresh a development checkout; new plugins start disabled.")
    @Argument(help: "Directory containing computer-mcp-plugin.toml.") var path: String
    @OptionGroup var revision: Revision
    func run() async throws {
      var args = revision.arguments
      args["path"] = .string(URL(fileURLWithPath: path).standardizedFileURL.path)
      printJSON(
        try await revision.connection.client().call(
          "plugin.register", arguments: .object(args)))
    }
  }

  struct Artifacts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "artifacts",
      abstract: "List installable archives from an official GitHub release as JSON.",
      discussion:
        "Use repository and repository_id from plugins search. Defaults to the latest published stable release; --tag selects a published tag, including prereleases. Follow next_page even when artifacts is empty. Save one complete artifacts entry as JSON for install-release. Listing does not download or install archives."
    )
    @Argument(help: "Official owner/repository from search.") var repository: String
    @Option(name: .long, help: "Stable repository_id from search.") var repositoryID: Int64
    @Option(name: .long, help: "Exact published release tag; omitted means latest stable release.")
    var tag: String?
    @Option(name: .long, help: "Asset page, starting at 1; up to 100 assets per page.") var page = 1
    @OptionGroup var connection: AppControlConnectionOptions

    func validate() throws {
      guard (1...9_007_199_254_740_991).contains(repositoryID), (1...1_000).contains(page) else {
        throw ValidationError("Use a positive exact JSON repository ID and --page 1...1000.")
      }
    }

    func run() async throws {
      var args: [String: JSONValue] = [
        "repository": .string(repository), "repository_id": .number(Double(repositoryID)),
        "page": .number(Double(page)),
      ]
      args["tag"] = tag.map(JSONValue.string)
      try await Plugins.perform(
        "plugin.artifacts", arguments: args, connection: connection, mutation: false)
    }
  }

  struct InstallRelease: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "install-release",
      abstract: "Download and install one exact archive selected with plugins artifacts.",
      discussion:
        "The selection file must contain one complete artifacts entry, not the entire listing. The App revalidates GitHub repository/release/asset identity and checks the archive digest and manifest before committing. New plugins start disabled; updates retain host settings and older versions. Downloads have a 120-second deadline, in addition to metadata and archive checks. Losing the control connection does not prove rollback: read list/show before retrying. No external dependencies are installed."
    )
    @Argument(help: "JSON file containing one selected artifact, at most 256 KiB.")
    var selectionFile: String
    @OptionGroup var revision: Revision

    func run() async throws {
      let selection: JSONValue
      do {
        guard !selectionFile.contains("\0") else { throw PluginCatalogError.invalidResponse }
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: selectionFile))
        defer { try? file.close() }
        let data = try file.read(upToCount: 262_145) ?? Data()
        guard data.count <= 262_144 else { throw PluginCatalogError.invalidResponse }
        selection = try JSONDecoder().decode(JSONValue.self, from: data)
        guard selection.objectValue != nil else { throw PluginCatalogError.invalidResponse }
      } catch {
        printJSON(
          .object([
            "error": .object([
              "code": .string("plugin.selection.invalid"),
              "message": .string(
                "Read a JSON object of at most 256 KiB containing one complete artifact from plugins artifacts."
              ),
            ])
          ]))
        throw ExitCode.failure
      }
      var args = revision.arguments
      args["artifact"] = selection
      try await Plugins.perform(
        "plugin.install_release", arguments: args, connection: revision.connection)
    }
  }

  struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "install",
      abstract:
        "Install or update a plugin from a local ZIP/TAR/gzip archive with a known SHA-256.",
      discussion:
        "Supply the expected plugin ID, version and lowercase SHA-256 from a trusted source. The App checks the archive before selecting it. New plugins start disabled; updates retain settings and earlier versions. Use select --installation-id to roll back. A matching digest verifies bytes, not an official publisher. No external dependencies are installed. JSON issues describe cleanup still needed after a successful commit; do not blindly repeat the install."
    )
    @Argument(help: "Archive file; resolved from the caller's working directory.") var archive:
      String
    @Option(name: .long, help: "Expected plugin ID in the manifest.") var id: String
    @Option(name: .long, help: "Expected semantic version in the manifest.") var version: String
    @Option(name: .long, help: "Expected SHA-256: exactly 64 lowercase hexadecimal digits.")
    var sha256: String
    @OptionGroup var revision: Revision

    func validate() throws {
      _ = try PluginVersion(version)
      guard !archive.contains("\0"), sha256.utf8.count == 64,
        sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
      else {
        throw ValidationError(
          "Use a NUL-free archive path and 64 lowercase hexadecimal SHA-256 digits.")
      }
    }

    func run() async throws {
      var args = revision.arguments
      args["archive"] = .string(URL(fileURLWithPath: archive).standardizedFileURL.path)
      args["id"] = .string(id)
      args["version"] = .string(version)
      args["sha256"] = .string(sha256)
      try await Plugins.perform("plugin.install", arguments: args, connection: revision.connection)
    }
  }

  struct Uninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "uninstall",
      abstract:
        "Uninstall one artifact by installation ID, retaining host settings and other versions.",
      discussion:
        "Only matching App-owned files are removed. Development checkouts and external binaries are not deleted. JSON issues indicate cleanup requiring attention after registration was revoked."
    )
    @Argument(help: "Exact artifact installation ID from list/show, not a plugin ID or path.")
    var installationID: String
    @OptionGroup var revision: Revision
    func run() async throws {
      var args = revision.arguments
      args["installation_id"] = .string(installationID)
      try await Plugins.perform(
        "plugin.uninstall", arguments: args, connection: revision.connection)
    }
  }

  struct Recover: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "recover",
      abstract: "Retry App-owned file cleanup and report recovery issues as JSON.",
      discussion:
        "Leaves selections, grants and unknown directories unchanged. The App also attempts recovery at startup. Disconnect gateway clients before retrying; connected clients and active installation workers block recovery."
    )
    @OptionGroup var revision: Revision
    func run() async throws {
      try await Plugins.perform(
        "plugin.recover", arguments: revision.arguments, connection: revision.connection)
    }
  }

  @discardableResult
  private static func perform(
    _ action: String, arguments: [String: JSONValue], connection: AppControlConnectionOptions,
    mutation: Bool = true
  ) async throws -> JSONValue {
    do {
      let result = try await connection.client().call(action, arguments: .object(arguments))
      printJSON(result)
      return result
    } catch {
      let failure = error as? ControlSocketCallError
      printJSON(
        .object([
          "error": .object([
            "code": .string(failure?.code ?? "control.unavailable"),
            "message": .string(
              failure?.message
                ?? (mutation
                  ? "The App control socket is unavailable. Read list/show before retrying a change whose outcome is unknown."
                  : "The App control socket is unavailable.")
            ),
          ])
        ]))
      throw ExitCode.failure
    }
  }

  struct Configure: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "configure", abstract: "Replace host settings for one plugin using a JSON file.",
      discussion:
        "Use the settings object from list/show as a starting point. This replaces, rather than merges, the settings; omitted enabled defaults to false and omitted tool selection grants no tools. Unknown fields are rejected."
    )
    @Argument var id: String
    @Option(name: .long, help: "PluginSettings JSON file, up to 4 MiB; no secrets.")
    var settingsFile: String
    @OptionGroup var revision: Revision
    func run() async throws {
      let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: settingsFile))
      defer { try? handle.close() }
      let data = try handle.read(upToCount: 4_194_305) ?? Data()
      guard data.count <= 4_194_304 else { throw ValidationError("Settings exceed 4 MiB.") }
      let settings = try JSONDecoder().decode(PluginSettings.self, from: data)
      var args = revision.arguments
      args["id"] = .string(id)
      args["settings"] = try .encoded(settings)
      printJSON(
        try await revision.connection.client().call(
          "plugin.configure", arguments: .object(args)))
    }
  }

  struct Enable: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "enable", abstract: "Enable a plugin using its existing host grants.")
    @Argument var id: String
    @OptionGroup var revision: Revision
    func run() async throws { try await Plugins.setEnabled(true, id: id, revision: revision) }
  }

  struct Disable: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "disable",
      abstract: "Disable a plugin while retaining source selection and grants.")
    @Argument var id: String
    @OptionGroup var revision: Revision
    func run() async throws { try await Plugins.setEnabled(false, id: id, revision: revision) }
  }

  private static func setEnabled(_ enabled: Bool, id: String, revision: Revision) async throws {
    var args = revision.arguments
    args["id"] = .string(id)
    printJSON(
      try await revision.connection.client().call(
        enabled ? "plugin.enable" : "plugin.disable", arguments: .object(args)))
  }

  struct Select: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "select", abstract: "Select an installation record, or restore bundled fallback."
    )
    @Argument var id: String
    @Option(name: .long) var installationID: String?
    @Flag(name: .long, help: "Restore bundled fallback; retains the enabled state and host grants.")
    var bundled = false
    @OptionGroup var revision: Revision
    func validate() throws {
      guard (installationID != nil) != bundled else {
        throw ValidationError("Choose --installation-id or --bundled.")
      }
    }
    func run() async throws {
      var args = revision.arguments
      args["id"] = .string(id)
      args["installation_id"] = installationID.map(JSONValue.string)
      printJSON(
        try await revision.connection.client().call(
          "plugin.select", arguments: .object(args)))
    }
  }

  struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "remove",
      abstract:
        "Remove a development installation reference, retaining its checkout and host overrides.")
    @Argument(help: "Exact installation record ID from list/show, not a directory to delete.")
    var installationID: String
    @OptionGroup var revision: Revision
    func run() async throws {
      var args = revision.arguments
      args["installation_id"] = .string(installationID)
      printJSON(
        try await revision.connection.client().call(
          "plugin.remove", arguments: .object(args)))
    }
  }
}
