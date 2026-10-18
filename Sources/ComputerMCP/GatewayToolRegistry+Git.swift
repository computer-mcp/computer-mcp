import Foundation

extension GatewayToolRegistry {
  internal func gitRoot(arguments object: [String: JSONValue]) throws -> JSONValue {
    try gitResult(
      operation: "git.root",
      arguments: [
        "rev-parse",
        "--show-toplevel",
        "--git-dir",
        "--git-common-dir",
        "--is-inside-work-tree",
        "--is-bare-repository",
        "--show-prefix",
      ],
      timeout: optionalInt("timeout_ms", in: object)
    )
  }

  internal func gitConfig(arguments object: [String: JSONValue]) throws -> JSONValue {
    let includeValues = try optionalBool("include_values", in: object) ?? false
    let scope = try optionalString("scope", in: object) ?? "all"
    let maxResults = optionalInt("max_results", in: object) ?? 200
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 5_000)
    try validateGitConfigScope(scope)

    let args = ["config", "--list", "--show-origin", "--show-scope", "--null"]
    let command = try gitCLICommand()
    let result = try runRegisteredCLI(
      command: command,
      args: args,
      timeout: optionalInt("timeout_ms", in: object),
      requireArbitraryArgs: false
    )

    let parsed = parseGitConfigOutput(result.stdout, includeValues: includeValues)
    let scopedEntries =
      scope == "all" ? parsed.entries : parsed.entries.filter { $0.scope == scope }
    let returnedEntries = Array(scopedEntries.prefix(maxResults))
    let resultTruncated = scopedEntries.count > returnedEntries.count

    return .object([
      "operation": .string("git.config"),
      "provider": .string(command.id),
      "argv": .array(args.map(JSONValue.string)),
      "include_values": .bool(includeValues),
      "scope": .string(scope),
      "max_results": .integer(Int64(maxResults)),
      "entry_count": .integer(Int64(scopedEntries.count)),
      "returned_count": .integer(Int64(returnedEntries.count)),
      "redacted_count": .integer(Int64(returnedEntries.filter(\.valueRedacted).count)),
      "parse_incomplete": .bool(parsed.parseIncomplete),
      "stdout_truncated": .bool(result.stdoutTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(resultTruncated || result.stdoutTruncated),
      "entries": .array(returnedEntries.map(\.json)),
      "result": gitCommandMetadata(result),
    ])
  }

  private func validateGitConfigScope(_ scope: String) throws {
    let validScopes = Set(["all", "system", "global", "local", "worktree", "command"])
    guard validScopes.contains(scope) else {
      throw GatewayToolError.invalidArguments(
        "scope must be one of all, system, global, local, worktree, or command.")
    }
  }

  private func parseGitConfigOutput(_ stdout: String, includeValues: Bool)
    -> (entries: [GitConfigEntry], parseIncomplete: Bool)
  {
    let records = stdout.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
    var entries: [GitConfigEntry] = []
    var index = 0
    var parseIncomplete = false

    while index < records.count {
      if records[index].isEmpty {
        index += 1
        continue
      }
      guard index + 2 < records.count else {
        parseIncomplete = true
        break
      }

      let scope = records[index]
      let origin = records[index + 1]
      let keyValue = records[index + 2]
      index += 3

      guard let newlineIndex = keyValue.firstIndex(of: "\n") else {
        parseIncomplete = true
        entries.append(
          GitConfigEntry(
            scope: scope,
            origin: origin,
            key: nil,
            value: nil,
            valueIncluded: false,
            valueRedacted: true,
            rawRecord: nil
          ))
        continue
      }

      let key = String(keyValue[..<newlineIndex])
      let value = String(keyValue[keyValue.index(after: newlineIndex)...])
      let sensitive = gitConfigValueShouldBeRedacted(key: key, value: value)
      entries.append(
        GitConfigEntry(
          scope: scope,
          origin: origin,
          key: key,
          value: includeValues && !sensitive ? value : nil,
          valueIncluded: includeValues && !sensitive,
          valueRedacted: !includeValues || sensitive,
          rawRecord: nil
        ))
    }

    return (entries, parseIncomplete)
  }

  private func gitConfigValueShouldBeRedacted(key: String, value: String) -> Bool {
    let lowercasedKey = key.lowercased()
    let sensitiveKeyFragments = [
      "password",
      "passwd",
      "token",
      "secret",
      "credential",
      "oauth",
      "authorization",
      "cookie",
      "privatekey",
      "private-key",
      "private_key",
      "apikey",
      "api-key",
      "api_key",
      "accesskey",
      "access-key",
      "access_key",
    ]
    if sensitiveKeyFragments.contains(where: { lowercasedKey.contains($0) }) {
      return true
    }

    let lowercasedValue = value.lowercased()
    if lowercasedValue.contains("authorization:")
      || lowercasedValue.contains("bearer ")
      || lowercasedValue.contains("token=")
    {
      return true
    }

    if let schemeRange = value.range(of: "://") {
      let afterScheme = value[schemeRange.upperBound...]
      let authority =
        afterScheme.split(separator: "/", maxSplits: 1).first ?? Substring(afterScheme)
      if authority.contains("@") {
        return true
      }
    }
    return false
  }

  internal func gitRemotes(arguments object: [String: JSONValue]) throws -> JSONValue {
    try gitResult(
      operation: "git.remotes",
      arguments: ["remote", "--verbose"],
      timeout: optionalInt("timeout_ms", in: object)
    )
  }

  internal func gitWorktrees(arguments object: [String: JSONValue]) throws -> JSONValue {
    try gitResult(
      operation: "git.worktrees",
      arguments: ["worktree", "list", "--porcelain"],
      timeout: optionalInt("timeout_ms", in: object)
    )
  }

  internal func gitStashes(arguments object: [String: JSONValue]) throws -> JSONValue {
    try gitResult(
      operation: "git.stashes",
      arguments: ["stash", "list", "--date=iso-strict"],
      timeout: optionalInt("timeout_ms", in: object)
    )
  }

  internal func gitStashShow(arguments object: [String: JSONValue]) throws -> JSONValue {
    let stash = try optionalGitStashRef(in: object)
    let stat = try optionalBool("stat", in: object) ?? true
    let patch = try optionalBool("patch", in: object) ?? false
    let paths = try optionalGitPaths(in: object)
    let contextLines = optionalInt("context_lines", in: object)
    if let contextLines {
      try validateBoundedNonNegative(contextLines, name: "context_lines", upperBound: 100)
    }

    var args = paths.isEmpty ? ["stash", "show"] : ["diff"]
    if stat {
      args.append("--stat")
    }
    if patch {
      args.append("--patch")
    }
    if !stat && !patch {
      args.append("--name-only")
    }
    if let contextLines, patch {
      args.append("-U\(contextLines)")
    }
    if !paths.isEmpty {
      args.append("\(stash)^1")
    }
    args.append(stash)
    if !paths.isEmpty {
      args.append("--")
      args.append(contentsOf: paths)
    }

    return try gitResult(
      operation: "git.stash_show",
      arguments: args,
      timeout: optionalInt("timeout_ms", in: object)
    )
  }

  internal func gitStashPush(arguments object: [String: JSONValue]) throws -> JSONValue {
    let message = try requiredString("message", in: object)
    guard message.count <= 10_000 else {
      throw GatewayToolError.invalidArguments("message must be 10000 characters or fewer.")
    }

    let paths = try optionalGitPaths(in: object)
    let allPaths = try optionalBool("all_paths", in: object) ?? false
    guard allPaths || !paths.isEmpty else {
      throw GatewayToolError.invalidArguments("git.stash_push requires paths or all_paths=true.")
    }

    let includeUntracked = try optionalBool("include_untracked", in: object) ?? false
    let keepIndex = try optionalBool("keep_index", in: object) ?? false
    let dryRun = try optionalBool("dry_run", in: object) ?? false
    let timeout = optionalInt("timeout_ms", in: object)

    var effectiveKeepIndex = keepIndex
    var keepIndexOmittedForUntrackedOnlyPaths = false
    if !dryRun, includeUntracked, keepIndex, !allPaths {
      let command = try gitCLICommand()
      let trackedPathResult = try runRegisteredCLI(
        command: command,
        args: ["ls-files", "-z", "--"] + paths,
        timeout: timeout,
        requireArbitraryArgs: false
      )
      guard !trackedPathResult.timedOut else {
        throw GatewayToolError.executionFailed(
          "git.stash_push tracked-path preflight timed out.")
      }
      guard trackedPathResult.exitCode == 0 else {
        throw GatewayToolError.executionFailed(
          "git.stash_push tracked-path preflight failed with exit code \(trackedPathResult.exitCode.map(String.init) ?? "unknown")."
        )
      }
      guard !trackedPathResult.stdoutTruncated else {
        throw GatewayToolError.executionFailed(
          "git.stash_push tracked-path preflight output was truncated.")
      }
      if trackedPathResult.stdout.isEmpty {
        // Git exits 1 after successfully stashing an explicitly selected untracked-only
        // path when --keep-index is also present. No selected path has an index entry in
        // this case, so omitting --keep-index preserves the requested semantics while
        // avoiding the false failure. Paths outside the explicit pathspec are untouched.
        effectiveKeepIndex = false
        keepIndexOmittedForUntrackedOnlyPaths = true
      }
    }

    let args: [String]
    if dryRun {
      var dryRunArgs = [
        "status",
        "--porcelain=v1",
        "-z",
        includeUntracked ? "--untracked-files=all" : "--untracked-files=no",
      ]
      if !allPaths {
        dryRunArgs.append("--")
        dryRunArgs.append(contentsOf: paths)
      }
      args = dryRunArgs
    } else {
      var stashArgs = ["stash", "push", "-m", message]
      if includeUntracked {
        stashArgs.append("--include-untracked")
      }
      if effectiveKeepIndex {
        stashArgs.append("--keep-index")
      }
      if !allPaths {
        stashArgs.append("--")
        stashArgs.append(contentsOf: paths)
      }
      args = stashArgs
    }

    return try gitResult(
      operation: "git.stash_push",
      arguments: args,
      timeout: timeout,
      extra: [
        "all_paths": .bool(allPaths),
        "dry_run": .bool(dryRun),
        "effective_keep_index": .bool(effectiveKeepIndex),
        "include_untracked": .bool(includeUntracked),
        "keep_index": .bool(keepIndex),
        "keep_index_omitted_for_untracked_only_paths": .bool(
          keepIndexOmittedForUntrackedOnlyPaths),
      ]
    )
  }

  internal func gitTags(arguments object: [String: JSONValue]) throws -> JSONValue {
    try gitResult(
      operation: "git.tags",
      arguments: [
        "tag",
        "--list",
        "--sort=-creatordate",
        "--format=%(refname:short)%09%(objecttype)%09%(objectname:short)%09%(creatordate:iso-strict)%09%(subject)",
      ],
      timeout: optionalInt("timeout_ms", in: object)
    )
  }

  internal func gitTagShow(arguments object: [String: JSONValue]) throws -> JSONValue {
    let tagName = try validatedGitTagNameArgument("name", in: object)
    let stat = try optionalBool("stat", in: object) ?? true
    let timeout = optionalInt("timeout_ms", in: object)
    let command = try gitCLICommand()
    let tagRef = "refs/tags/\(tagName)"
    let existsArgs = ["show-ref", "--verify", "--quiet", tagRef]
    var showArgs = ["show", "--date=iso-strict"]
    if stat {
      showArgs.append("--stat")
    } else {
      showArgs.append("--no-patch")
    }
    showArgs.append(tagRef)

    let existsResult = try runRegisteredCLI(
      command: command,
      args: existsArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    guard !existsResult.timedOut else {
      throw GatewayToolError.invalidArguments("tag existence check timed out.")
    }
    guard existsResult.exitCode == 0 else {
      if existsResult.exitCode == 1 {
        throw GatewayToolError.invalidArguments("tag does not exist: \(tagName)")
      }
      throw GatewayToolError.invalidArguments("tag existence check failed for: \(tagName)")
    }

    let showResult = try runRegisteredCLI(
      command: command,
      args: showArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )

    return .object([
      "operation": .string("git.tag_show"),
      "provider": .string(command.id),
      "name": .string(tagName),
      "ref": .string(tagRef),
      "stat": .bool(stat),
      "argv": .array(showArgs.map(JSONValue.string)),
      "preflight": .object([
        "existing_tag": gitCommandMetadata(existsResult)
      ]),
      "result": showResult.json,
    ])
  }

  internal func gitTagCreate(arguments object: [String: JSONValue]) throws -> JSONValue {
    let tagName = try validatedGitTagNameArgument("name", in: object)
    let target = try optionalValidatedGitRefArgument("target", in: object) ?? "HEAD"
    let dryRun = try optionalBool("dry_run", in: object) ?? true
    let confirmCreate = try optionalBool("confirm_create", in: object) ?? false
    guard dryRun || confirmCreate else {
      throw GatewayToolError.invalidArguments(
        "git.tag_create requires confirm_create=true when dry_run is false.")
    }

    let timeout = optionalInt("timeout_ms", in: object)
    let command = try gitCLICommand()
    let checkNameArgs = ["check-ref-format", "refs/tags/\(tagName)"]
    let targetArgs = ["rev-parse", "--verify", "\(target)^{object}"]
    let existsArgs = ["show-ref", "--verify", "--quiet", "refs/tags/\(tagName)"]

    let checkNameResult = try runRegisteredCLI(
      command: command,
      args: checkNameArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    guard !checkNameResult.timedOut, checkNameResult.exitCode == 0 else {
      throw GatewayToolError.invalidArguments(
        "tag name is not accepted by git check-ref-format: \(tagName)")
    }

    let targetResult = try runRegisteredCLI(
      command: command,
      args: targetArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    guard !targetResult.timedOut, targetResult.exitCode == 0 else {
      throw GatewayToolError.invalidArguments("target is not an existing Git object: \(target)")
    }

    let existsResult = try runRegisteredCLI(
      command: command,
      args: existsArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    guard !existsResult.timedOut else {
      throw GatewayToolError.invalidArguments("tag existence check timed out.")
    }
    guard existsResult.exitCode != 0 else {
      throw GatewayToolError.invalidArguments("tag already exists: \(tagName)")
    }
    guard existsResult.exitCode == 1 else {
      throw GatewayToolError.invalidArguments("tag existence check failed for: \(tagName)")
    }

    let createArgs = ["tag", tagName, target]
    var result: JSONValue = .null
    if !dryRun {
      let createResult = try runRegisteredCLI(
        command: command,
        args: createArgs,
        timeout: timeout,
        requireArbitraryArgs: false
      )
      result = createResult.json
    }

    return .object([
      "operation": .string("git.tag_create"),
      "provider": .string(command.id),
      "name": .string(tagName),
      "target": .string(target),
      "argv": .array(createArgs.map(JSONValue.string)),
      "dry_run": .bool(dryRun),
      "confirm_create": .bool(confirmCreate),
      "preflight": .object([
        "check_ref_format": gitCommandMetadata(checkNameResult),
        "target": gitCommandMetadata(targetResult),
        "existing_tag": gitCommandMetadata(existsResult),
      ]),
      "result": result,
      "would_create": .bool(true),
    ])
  }

  internal func gitTagDelete(arguments object: [String: JSONValue]) throws -> JSONValue {
    let tagName = try validatedGitTagNameArgument("name", in: object)
    let dryRun = try optionalBool("dry_run", in: object) ?? true
    let confirmDelete = try optionalBool("confirm_delete", in: object) ?? false
    guard dryRun || confirmDelete else {
      throw GatewayToolError.invalidArguments(
        "git.tag_delete requires confirm_delete=true when dry_run is false.")
    }

    let timeout = optionalInt("timeout_ms", in: object)
    let command = try gitCLICommand()
    let existsArgs = ["show-ref", "--verify", "--quiet", "refs/tags/\(tagName)"]
    let revParseArgs = ["rev-parse", "--verify", "refs/tags/\(tagName)^{object}"]

    let existsResult = try runRegisteredCLI(
      command: command,
      args: existsArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    guard !existsResult.timedOut else {
      throw GatewayToolError.invalidArguments("tag existence check timed out.")
    }
    guard existsResult.exitCode == 0 else {
      if existsResult.exitCode == 1 {
        throw GatewayToolError.invalidArguments("tag does not exist: \(tagName)")
      }
      throw GatewayToolError.invalidArguments("tag existence check failed for: \(tagName)")
    }

    let revParseResult = try runRegisteredCLI(
      command: command,
      args: revParseArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    guard !revParseResult.timedOut, revParseResult.exitCode == 0 else {
      throw GatewayToolError.invalidArguments("tag object cannot be resolved: \(tagName)")
    }

    let deleteArgs = ["tag", "-d", tagName]
    var result: JSONValue = .null
    if !dryRun {
      let deleteResult = try runRegisteredCLI(
        command: command,
        args: deleteArgs,
        timeout: timeout,
        requireArbitraryArgs: false
      )
      result = deleteResult.json
    }

    return .object([
      "operation": .string("git.tag_delete"),
      "provider": .string(command.id),
      "name": .string(tagName),
      "argv": .array(deleteArgs.map(JSONValue.string)),
      "dry_run": .bool(dryRun),
      "confirm_delete": .bool(confirmDelete),
      "preflight": .object([
        "existing_tag": gitCommandMetadata(existsResult),
        "tag_object": gitCommandMetadata(revParseResult),
      ]),
      "result": result,
      "would_delete": .bool(true),
    ])
  }

  internal func gitIgnored(arguments object: [String: JSONValue]) throws -> JSONValue {
    let paths = try optionalGitPaths(in: object)
    guard !paths.isEmpty else {
      throw GatewayToolError.invalidArguments("git.ignored requires at least one path.")
    }
    return try gitResult(
      operation: "git.ignored",
      arguments: ["check-ignore", "--verbose", "--"] + paths,
      timeout: optionalInt("timeout_ms", in: object)
    )
  }

  internal func gitSubmodules(arguments object: [String: JSONValue]) throws -> JSONValue {
    try gitResult(
      operation: "git.submodules",
      arguments: ["submodule", "status", "--recursive"],
      timeout: optionalInt("timeout_ms", in: object)
    )
  }

  internal func gitFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    var args = ["ls-files", "--stage", "--eol"]
    let paths = try optionalGitPaths(in: object)
    if !paths.isEmpty {
      args.append("--")
      args.append(contentsOf: paths)
    }
    return try gitResult(
      operation: "git.files",
      arguments: args,
      timeout: optionalInt("timeout_ms", in: object)
    )
  }

  internal func gitGrep(arguments object: [String: JSONValue]) throws -> JSONValue {
    let query = try requiredString("query", in: object)
    try validateGitGrepQuery(query)
    let paths = try optionalGitPaths(in: object)
    let caseSensitive = try optionalBool("case_sensitive", in: object) ?? true
    let maxResults = optionalInt("max_results", in: object) ?? 200
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 5_000)

    var args = [
      "grep",
      "--line-number",
      "-I",
      "--null",
      "--fixed-strings",
      "--max-count",
      "\(maxResults)",
    ]
    if !caseSensitive {
      args.append("--ignore-case")
    }
    args.append(contentsOf: ["-e", query, "--"])
    args.append(contentsOf: paths)

    let command = try gitCLICommand()
    let result = try runRegisteredCLI(
      command: command,
      args: args,
      timeout: optionalInt("timeout_ms", in: object),
      requireArbitraryArgs: false
    )
    let parsed = parseGitGrepZ(result.stdout)
    let returnedMatches = Array(parsed.matches.prefix(maxResults))
    let resultTruncated = parsed.matches.count > returnedMatches.count
    let parseIncomplete = parsed.parseIncomplete || result.stdoutTruncated

    return .object([
      "operation": .string("git.grep"),
      "provider": .string(command.id),
      "query": .string(query),
      "case_sensitive": .bool(caseSensitive),
      "paths": .array(paths.map(JSONValue.string)),
      "max_results": .integer(Int64(maxResults)),
      "argv": .array(args.map(JSONValue.string)),
      "match_count": .integer(Int64(parsed.matches.count)),
      "returned_count": .integer(Int64(returnedMatches.count)),
      "result_truncated": .bool(resultTruncated),
      "stdout_truncated": .bool(result.stdoutTruncated),
      "parse_incomplete": .bool(parseIncomplete),
      "truncated": .bool(resultTruncated || parseIncomplete),
      "matches": .array(returnedMatches.map(\.json)),
      "result": result.json,
    ])
  }

  internal func gitBlame(arguments object: [String: JSONValue]) throws -> JSONValue {
    guard let path = try optionalString("path", in: object), !path.isEmpty else {
      throw GatewayToolError.invalidArguments("git.blame requires path.")
    }
    let paths = try optionalGitPaths(in: ["paths": .array([.string(path)])])
    let startLine = optionalInt("start_line", in: object) ?? 1
    let maxLines = optionalInt("max_lines", in: object) ?? 200
    try validateBoundedPositive(startLine, name: "start_line", upperBound: 10_000_000)
    try validateBoundedPositive(maxLines, name: "max_lines", upperBound: 1_000)
    return try gitResult(
      operation: "git.blame",
      arguments: ["blame", "--line-porcelain", "-L", "\(startLine),+\(maxLines)", "--", paths[0]],
      timeout: optionalInt("timeout_ms", in: object)
    )
  }

  internal func gitFileHistory(arguments object: [String: JSONValue]) throws -> JSONValue {
    guard let path = try optionalString("path", in: object), !path.isEmpty else {
      throw GatewayToolError.invalidArguments("git.file_history requires path.")
    }
    let paths = try optionalGitPaths(in: ["paths": .array([.string(path)])])
    let limit = optionalInt("limit", in: object) ?? 50
    try validateBoundedPositive(limit, name: "limit", upperBound: 200)
    let maxResults = optionalInt("max_results", in: object) ?? limit
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 200)
    let follow = try optionalBool("follow", in: object) ?? true
    let includeMerges = try optionalBool("include_merges", in: object) ?? true

    var args = [
      "log",
      "--date=iso-strict",
      "--pretty=format:%H%x09%h%x09%ad%x09%an%x09%s",
      "-n",
      "\(limit)",
    ]
    if follow {
      args.insert("--follow", at: 1)
    }
    if !includeMerges {
      args.append("--no-merges")
    }
    args.append("--")
    args.append(paths[0])

    let command = try gitCLICommand()
    let result = try runRegisteredCLI(
      command: command,
      args: args,
      timeout: optionalInt("timeout_ms", in: object),
      requireArbitraryArgs: false
    )
    let rawLines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
      .filter { !$0.isEmpty }
    let entries = rawLines.map(parseGitFileHistoryLine)
    let returnedEntries = Array(entries.prefix(maxResults))
    let returnedRawLines = Array(rawLines.prefix(maxResults))
    let resultTruncated =
      entries.count > returnedEntries.count || rawLines.count > returnedRawLines.count

    return .object([
      "operation": .string("git.file_history"),
      "provider": .string(command.id),
      "argv": .array(args.map(JSONValue.string)),
      "path": .string(paths[0]),
      "workspace_relative_path": .string(paths[0]),
      "follow": .bool(follow),
      "include_merges": .bool(includeMerges),
      "limit": .integer(Int64(limit)),
      "max_results": .integer(Int64(maxResults)),
      "entry_count": .integer(Int64(entries.count)),
      "returned_entry_count": .integer(Int64(returnedEntries.count)),
      "raw_line_count": .integer(Int64(rawLines.count)),
      "returned_raw_line_count": .integer(Int64(returnedRawLines.count)),
      "result_truncated": .bool(resultTruncated),
      "stdout_truncated": .bool(result.stdoutTruncated),
      "parse_incomplete": .bool(result.stdoutTruncated),
      "truncated": .bool(resultTruncated || result.stdoutTruncated),
      "entries": .array(returnedEntries.map(\.json)),
      "raw_lines": .array(returnedRawLines.map(JSONValue.string)),
      "result": gitCommandMetadata(result),
    ])
  }

  private func parseGitFileHistoryLine(_ line: String) -> GitFileHistoryEntry {
    let parts = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
      .map(String.init)
    guard parts.count == 5 else {
      return GitFileHistoryEntry(
        commit: nil,
        abbreviatedCommit: nil,
        committedAt: nil,
        author: nil,
        subject: nil,
        rawLine: line
      )
    }
    return GitFileHistoryEntry(
      commit: parts[0].isEmpty ? nil : parts[0],
      abbreviatedCommit: parts[1].isEmpty ? nil : parts[1],
      committedAt: parts[2].isEmpty ? nil : parts[2],
      author: parts[3].isEmpty ? nil : parts[3],
      subject: parts[4].isEmpty ? nil : parts[4],
      rawLine: line
    )
  }

  internal func gitFileAtRevision(arguments object: [String: JSONValue]) throws -> JSONValue {
    let revision = try validatedGitRefArgument("revision", in: object)
    guard let path = try optionalString("path", in: object), !path.isEmpty else {
      throw GatewayToolError.invalidArguments("git.file_at_revision requires path.")
    }
    let paths = try optionalGitPaths(in: ["paths": .array([.string(path)])])
    let maxBytes =
      optionalInt("max_bytes", in: object) ?? min(65_536, configuration.policy.maxOutputBytes)
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)
    guard maxBytes <= configuration.policy.maxOutputBytes else {
      throw GatewayToolError.invalidArguments(
        "max_bytes must be less than or equal to policy.max_output_bytes (\(configuration.policy.maxOutputBytes))."
      )
    }

    let objectSpec = "\(revision):\(paths[0])"
    let args = ["show", objectSpec]
    let command = try gitCLICommand()
    let result = try runRegisteredCLI(
      command: command,
      args: args,
      timeout: optionalInt("timeout_ms", in: object),
      requireArbitraryArgs: false
    )
    let stdoutData = Data(result.stdout.utf8)
    let contentTruncated = stdoutData.count > maxBytes || result.stdoutTruncated
    let contentData = stdoutData.count > maxBytes ? Data(stdoutData.prefix(maxBytes)) : stdoutData
    let content = String(decoding: contentData, as: UTF8.self)
    let lineCount =
      content.isEmpty
      ? 0
      : content.split(separator: "\n", omittingEmptySubsequences: false).count

    return .object([
      "operation": .string("git.file_at_revision"),
      "provider": .string(command.id),
      "argv": .array(args.map(JSONValue.string)),
      "revision": .string(revision),
      "path": .string(paths[0]),
      "workspace_relative_path": .string(paths[0]),
      "object_spec": .string(objectSpec),
      "encoding": .string("utf-8"),
      "content": .string(content),
      "bytes_returned": .integer(Int64(contentData.count)),
      "line_count": .integer(Int64(lineCount)),
      "max_bytes": .integer(Int64(maxBytes)),
      "content_truncated": .bool(contentTruncated),
      "stdout_truncated": .bool(result.stdoutTruncated),
      "truncated": .bool(contentTruncated),
      "result": gitCommandMetadata(result),
    ])
  }

  internal func gitStagedFile(arguments object: [String: JSONValue]) throws -> JSONValue {
    guard let path = try optionalString("path", in: object), !path.isEmpty else {
      throw GatewayToolError.invalidArguments("git.staged_file requires path.")
    }
    let paths = try optionalGitPaths(in: ["paths": .array([.string(path)])])
    let maxBytes =
      optionalInt("max_bytes", in: object) ?? min(65_536, configuration.policy.maxOutputBytes)
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)
    guard maxBytes <= configuration.policy.maxOutputBytes else {
      throw GatewayToolError.invalidArguments(
        "max_bytes must be less than or equal to policy.max_output_bytes (\(configuration.policy.maxOutputBytes))."
      )
    }

    let objectSpec = ":\(paths[0])"
    let args = ["show", objectSpec]
    let command = try gitCLICommand()
    let result = try runRegisteredCLI(
      command: command,
      args: args,
      timeout: optionalInt("timeout_ms", in: object),
      requireArbitraryArgs: false
    )
    let stdoutData = Data(result.stdout.utf8)
    let contentTruncated = stdoutData.count > maxBytes || result.stdoutTruncated
    let contentData = stdoutData.count > maxBytes ? Data(stdoutData.prefix(maxBytes)) : stdoutData
    let content = String(decoding: contentData, as: UTF8.self)
    let lineCount =
      content.isEmpty
      ? 0
      : content.split(separator: "\n", omittingEmptySubsequences: false).count

    return .object([
      "operation": .string("git.staged_file"),
      "provider": .string(command.id),
      "argv": .array(args.map(JSONValue.string)),
      "path": .string(paths[0]),
      "workspace_relative_path": .string(paths[0]),
      "object_spec": .string(objectSpec),
      "source": .string("index"),
      "index_stage": .number(0),
      "encoding": .string("utf-8"),
      "content": .string(content),
      "bytes_returned": .integer(Int64(contentData.count)),
      "line_count": .integer(Int64(lineCount)),
      "max_bytes": .integer(Int64(maxBytes)),
      "content_truncated": .bool(contentTruncated),
      "stdout_truncated": .bool(result.stdoutTruncated),
      "truncated": .bool(contentTruncated),
      "result": gitCommandMetadata(result),
    ])
  }

  internal func gitConflicts(arguments object: [String: JSONValue]) throws -> JSONValue {
    var args = ["ls-files", "--unmerged"]
    let paths = try optionalGitPaths(in: object)
    if !paths.isEmpty {
      args.append("--")
      args.append(contentsOf: paths)
    }
    return try gitResult(
      operation: "git.conflicts",
      arguments: args,
      timeout: optionalInt("timeout_ms", in: object)
    )
  }

  internal func gitStatus(arguments object: [String: JSONValue]) throws -> JSONValue {
    var args = ["status", "--short", "--branch", "--porcelain=v1"]
    let paths = try optionalGitPaths(in: object)
    if !paths.isEmpty {
      args.append("--")
      args.append(contentsOf: paths)
    }
    return try gitResult(
      operation: "git.status",
      arguments: args,
      timeout: optionalInt("timeout_ms", in: object)
    )
  }

  internal func gitTrackingStatus(arguments object: [String: JSONValue]) throws -> JSONValue {
    let command = try gitCLICommand()
    let args = ["status", "--branch", "--porcelain=v1"]
    let result = try runRegisteredCLI(
      command: command,
      args: args,
      timeout: optionalInt("timeout_ms", in: object),
      requireArbitraryArgs: false
    )
    let branchLine = result.stdout.split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init)
      .first { $0.hasPrefix("## ") }
    let parsed = parseGitTrackingStatus(branchLine)

    return .object([
      "operation": .string("git.tracking_status"),
      "provider": .string(command.id),
      "argv": .array(args.map(JSONValue.string)),
      "parsed": .bool(parsed != nil),
      "status": parsed?.json ?? .null,
      "result": gitCommandMetadata(result),
    ])
  }

  private func parseGitTrackingStatus(_ branchLine: String?) -> GitTrackingStatusInfo? {
    guard let branchLine, branchLine.hasPrefix("## ") else {
      return nil
    }

    let body = String(branchLine.dropFirst(3))
    if body == "HEAD (no branch)" {
      return GitTrackingStatusInfo(
        branch: nil,
        upstream: nil,
        ahead: nil,
        behind: nil,
        flags: [],
        detached: true,
        unborn: false,
        rawBranchLine: branchLine
      )
    }

    if body.hasPrefix("No commits yet on ") {
      return GitTrackingStatusInfo(
        branch: String(body.dropFirst("No commits yet on ".count)),
        upstream: nil,
        ahead: nil,
        behind: nil,
        flags: [],
        detached: false,
        unborn: true,
        rawBranchLine: branchLine
      )
    }

    let parsedBody = splitGitTrackingStatusBody(body)
    let tracking = splitGitTrackingBranchAndUpstream(parsedBody.base)
    let details = parseGitTrackingDetails(parsedBody.details)

    return GitTrackingStatusInfo(
      branch: tracking.branch,
      upstream: tracking.upstream,
      ahead: tracking.upstream == nil ? nil : details.ahead,
      behind: tracking.upstream == nil ? nil : details.behind,
      flags: details.flags,
      detached: false,
      unborn: false,
      rawBranchLine: branchLine
    )
  }

  private func splitGitTrackingBranchAndUpstream(_ value: String) -> (
    branch: String?, upstream: String?
  ) {
    guard let range = value.range(of: "...") else {
      return (value.isEmpty ? nil : value, nil)
    }
    let branch = String(value[..<range.lowerBound])
    let upstream = String(value[range.upperBound...])
    return (branch.isEmpty ? nil : branch, upstream.isEmpty ? nil : upstream)
  }

  private func splitGitTrackingStatusBody(_ body: String) -> (base: String, details: String?) {
    guard body.hasSuffix("]"), let open = body.lastIndex(of: "[") else {
      return (body, nil)
    }
    let base = String(body[..<open]).trimmingCharacters(in: .whitespaces)
    let detailsStart = body.index(after: open)
    let detailsEnd = body.index(before: body.endIndex)
    return (base, String(body[detailsStart..<detailsEnd]))
  }

  private func parseGitTrackingDetails(_ details: String?) -> (
    ahead: Int, behind: Int, flags: [String]
  ) {
    guard let details, !details.isEmpty else {
      return (0, 0, [])
    }
    var ahead = 0
    var behind = 0
    var flags: [String] = []
    for part in details.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
      if part.hasPrefix("ahead "), let value = Int(part.dropFirst("ahead ".count)) {
        ahead = value
      } else if part.hasPrefix("behind "), let value = Int(part.dropFirst("behind ".count)) {
        behind = value
      } else if !part.isEmpty {
        flags.append(part)
      }
    }
    return (ahead, behind, flags)
  }

  internal func gitCleanPreview(arguments object: [String: JSONValue]) throws -> JSONValue {
    let includeIgnored = try optionalBool("include_ignored", in: object) ?? false
    let ignoredOnly = try optionalBool("ignored_only", in: object) ?? false
    let paths = try optionalGitPaths(in: object)
    let maxResults = optionalInt("max_results", in: object) ?? 200
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 5_000)
    if includeIgnored && ignoredOnly {
      throw GatewayToolError.invalidArguments(
        "include_ignored and ignored_only cannot both be true.")
    }

    var args = ["clean", "--dry-run", "-d"]
    if includeIgnored {
      args.append("-x")
    }
    if ignoredOnly {
      args.append("-X")
    }
    if !paths.isEmpty {
      args.append("--")
      args.append(contentsOf: paths)
    }

    let command = try gitCLICommand()
    let result = try runRegisteredCLI(
      command: command,
      args: args,
      timeout: optionalInt("timeout_ms", in: object),
      requireArbitraryArgs: false
    )
    let rawLines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
      .filter { !$0.isEmpty }
    let items = rawLines.map(parseGitCleanPreviewLine)
    let returnedItems = Array(items.prefix(maxResults))
    let returnedRawLines = Array(rawLines.prefix(maxResults))
    let resultTruncated =
      items.count > returnedItems.count || rawLines.count > returnedRawLines.count

    return .object([
      "operation": .string("git.clean_preview"),
      "provider": .string(command.id),
      "argv": .array(args.map(JSONValue.string)),
      "include_ignored": .bool(includeIgnored),
      "ignored_only": .bool(ignoredOnly),
      "paths": .array(paths.map(JSONValue.string)),
      "max_results": .integer(Int64(maxResults)),
      "item_count": .integer(Int64(items.count)),
      "returned_item_count": .integer(Int64(returnedItems.count)),
      "raw_line_count": .integer(Int64(rawLines.count)),
      "returned_raw_line_count": .integer(Int64(returnedRawLines.count)),
      "result_truncated": .bool(resultTruncated),
      "stdout_truncated": .bool(result.stdoutTruncated),
      "parse_incomplete": .bool(result.stdoutTruncated),
      "truncated": .bool(resultTruncated || result.stdoutTruncated),
      "items": .array(returnedItems.map(\.json)),
      "raw_lines": .array(returnedRawLines.map(JSONValue.string)),
      "result": gitCommandMetadata(result),
    ])
  }

  private func parseGitCleanPreviewLine(_ line: String) -> GitCleanPreviewItem {
    let prefixes = [
      ("Would remove ", "remove"),
      ("Would skip repository ", "skip_repository"),
      ("Would not remove ", "not_remove"),
    ]
    for (prefix, action) in prefixes where line.hasPrefix(prefix) {
      let path = String(line.dropFirst(prefix.count))
      return GitCleanPreviewItem(
        action: action,
        path: path.isEmpty ? nil : path,
        directory: path.hasSuffix("/"),
        rawLine: line
      )
    }
    return GitCleanPreviewItem(action: "other", path: nil, directory: false, rawLine: line)
  }

  internal func gitClean(arguments object: [String: JSONValue]) throws -> JSONValue {
    let includeIgnored = try optionalBool("include_ignored", in: object) ?? false
    let ignoredOnly = try optionalBool("ignored_only", in: object) ?? false
    guard !(includeIgnored && ignoredOnly) else {
      throw GatewayToolError.invalidArguments(
        "include_ignored and ignored_only cannot both be true.")
    }

    let paths = try optionalGitPaths(in: object)
    let allPaths = try optionalBool("all_paths", in: object) ?? false
    guard allPaths || !paths.isEmpty else {
      throw GatewayToolError.invalidArguments("git.clean requires paths or all_paths=true.")
    }
    guard !(allPaths && !paths.isEmpty) else {
      throw GatewayToolError.invalidArguments("git.clean cannot combine paths with all_paths=true.")
    }

    let dryRun = try optionalBool("dry_run", in: object) ?? true
    let confirmDelete = try optionalBool("confirm_delete", in: object) ?? false
    guard dryRun || confirmDelete else {
      throw GatewayToolError.invalidArguments(
        "git.clean requires confirm_delete=true when dry_run is false.")
    }

    var args = ["clean"]
    if dryRun {
      args.append("--dry-run")
    } else {
      args.append("-f")
    }
    args.append("-d")
    if includeIgnored {
      args.append("-x")
    }
    if ignoredOnly {
      args.append("-X")
    }
    if !allPaths {
      args.append("--")
      args.append(contentsOf: paths)
    }

    return try gitResult(
      operation: "git.clean",
      arguments: args,
      timeout: optionalInt("timeout_ms", in: object),
      extra: [
        "all_paths": .bool(allPaths),
        "confirm_delete": .bool(confirmDelete),
        "dry_run": .bool(dryRun),
        "ignored_only": .bool(ignoredOnly),
        "include_ignored": .bool(includeIgnored),
        "paths": .array(paths.map(JSONValue.string)),
      ]
    )
  }

  internal func gitReflog(arguments object: [String: JSONValue]) throws -> JSONValue {
    let limit = optionalInt("limit", in: object) ?? 50
    try validateBoundedPositive(limit, name: "limit", upperBound: 200)
    let maxResults = optionalInt("max_results", in: object) ?? limit
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 200)

    let args = [
      "reflog",
      "show",
      "--date=iso-strict",
      "--pretty=format:%H%x09%h%x09%gd%x09%gs%x09%ad",
      "-n",
      "\(limit)",
    ]
    let command = try gitCLICommand()
    let result = try runRegisteredCLI(
      command: command,
      args: args,
      timeout: optionalInt("timeout_ms", in: object),
      requireArbitraryArgs: false
    )
    let rawLines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
      .filter { !$0.isEmpty }
    let entries = rawLines.map(parseGitReflogLine)
    let returnedEntries = Array(entries.prefix(maxResults))
    let returnedRawLines = Array(rawLines.prefix(maxResults))
    let resultTruncated =
      entries.count > returnedEntries.count || rawLines.count > returnedRawLines.count

    return .object([
      "operation": .string("git.reflog"),
      "provider": .string(command.id),
      "argv": .array(args.map(JSONValue.string)),
      "limit": .integer(Int64(limit)),
      "max_results": .integer(Int64(maxResults)),
      "entry_count": .integer(Int64(entries.count)),
      "returned_entry_count": .integer(Int64(returnedEntries.count)),
      "raw_line_count": .integer(Int64(rawLines.count)),
      "returned_raw_line_count": .integer(Int64(returnedRawLines.count)),
      "result_truncated": .bool(resultTruncated),
      "stdout_truncated": .bool(result.stdoutTruncated),
      "parse_incomplete": .bool(result.stdoutTruncated),
      "truncated": .bool(resultTruncated || result.stdoutTruncated),
      "entries": .array(returnedEntries.map(\.json)),
      "raw_lines": .array(returnedRawLines.map(JSONValue.string)),
      "result": gitCommandMetadata(result),
    ])
  }

  private func parseGitReflogLine(_ line: String) -> GitReflogEntry {
    let parts = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
      .map(String.init)
    guard parts.count == 5 else {
      return GitReflogEntry(
        commit: nil,
        abbreviatedCommit: nil,
        selector: nil,
        action: nil,
        message: nil,
        committedAt: nil,
        rawLine: line
      )
    }

    let parsedMessage = parseGitReflogSubject(parts[3])
    return GitReflogEntry(
      commit: parts[0].isEmpty ? nil : parts[0],
      abbreviatedCommit: parts[1].isEmpty ? nil : parts[1],
      selector: parts[2].isEmpty ? nil : parts[2],
      action: parsedMessage.action,
      message: parsedMessage.message,
      committedAt: parts[4].isEmpty ? nil : parts[4],
      rawLine: line
    )
  }

  private func parseGitReflogSubject(_ subject: String) -> (action: String?, message: String?) {
    guard let separator = subject.range(of: ": ") else {
      return (subject.isEmpty ? nil : subject, nil)
    }
    let action = String(subject[..<separator.lowerBound])
    let message = String(subject[separator.upperBound...])
    return (action.isEmpty ? nil : action, message.isEmpty ? nil : message)
  }

  internal func gitRefs(arguments object: [String: JSONValue]) throws -> JSONValue {
    let includeBranches = try optionalBool("include_branches", in: object) ?? true
    let includeRemotes = try optionalBool("include_remotes", in: object) ?? true
    let includeTags = try optionalBool("include_tags", in: object) ?? false
    guard includeBranches || includeRemotes || includeTags else {
      throw GatewayToolError.invalidArguments(
        "At least one of include_branches, include_remotes, or include_tags must be true.")
    }

    let limit = optionalInt("limit", in: object) ?? 200
    try validateBoundedPositive(limit, name: "limit", upperBound: 1_000)
    let maxResults = optionalInt("max_results", in: object) ?? limit
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 1_000)

    var namespaces: [String] = []
    if includeBranches {
      namespaces.append("refs/heads")
    }
    if includeRemotes {
      namespaces.append("refs/remotes")
    }
    if includeTags {
      namespaces.append("refs/tags")
    }

    var args = [
      "for-each-ref",
      "--sort=-committerdate",
      "--count",
      "\(limit)",
      "--format=%(refname)%09%(refname:short)%09%(objectname)%09%(objectname:short)%09%(objecttype)%09%(committerdate:iso-strict)%09%(subject)",
    ]
    args.append(contentsOf: namespaces)

    let command = try gitCLICommand()
    let result = try runRegisteredCLI(
      command: command,
      args: args,
      timeout: optionalInt("timeout_ms", in: object),
      requireArbitraryArgs: false
    )
    let rawLines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
      .filter { !$0.isEmpty }
    let refs = rawLines.map(parseGitRefLine)
    let returnedRefs = Array(refs.prefix(maxResults))
    let returnedRawLines = Array(rawLines.prefix(maxResults))
    let resultTruncated = refs.count > returnedRefs.count || rawLines.count > returnedRawLines.count

    return .object([
      "operation": .string("git.refs"),
      "provider": .string(command.id),
      "argv": .array(args.map(JSONValue.string)),
      "include_branches": .bool(includeBranches),
      "include_remotes": .bool(includeRemotes),
      "include_tags": .bool(includeTags),
      "namespaces": .array(namespaces.map(JSONValue.string)),
      "limit": .integer(Int64(limit)),
      "max_results": .integer(Int64(maxResults)),
      "ref_count": .integer(Int64(refs.count)),
      "returned_ref_count": .integer(Int64(returnedRefs.count)),
      "raw_line_count": .integer(Int64(rawLines.count)),
      "returned_raw_line_count": .integer(Int64(returnedRawLines.count)),
      "result_truncated": .bool(resultTruncated),
      "stdout_truncated": .bool(result.stdoutTruncated),
      "parse_incomplete": .bool(result.stdoutTruncated),
      "truncated": .bool(resultTruncated || result.stdoutTruncated),
      "refs": .array(returnedRefs.map(\.json)),
      "raw_lines": .array(returnedRawLines.map(JSONValue.string)),
      "result": gitCommandMetadata(result),
    ])
  }

  private func parseGitRefLine(_ line: String) -> GitRefInfo {
    let parts = line.split(separator: "\t", maxSplits: 6, omittingEmptySubsequences: false)
      .map(String.init)
    guard parts.count == 7 else {
      return GitRefInfo(
        kind: "other",
        refname: nil,
        shortName: nil,
        object: nil,
        abbreviatedObject: nil,
        objectType: nil,
        committerDate: nil,
        subject: nil,
        rawLine: line
      )
    }

    return GitRefInfo(
      kind: gitRefKind(parts[0]),
      refname: parts[0].isEmpty ? nil : parts[0],
      shortName: parts[1].isEmpty ? nil : parts[1],
      object: parts[2].isEmpty ? nil : parts[2],
      abbreviatedObject: parts[3].isEmpty ? nil : parts[3],
      objectType: parts[4].isEmpty ? nil : parts[4],
      committerDate: parts[5].isEmpty ? nil : parts[5],
      subject: parts[6].isEmpty ? nil : parts[6],
      rawLine: line
    )
  }

  private func gitRefKind(_ refname: String) -> String {
    if refname.hasPrefix("refs/heads/") {
      return "local_branch"
    }
    if refname.hasPrefix("refs/remotes/") {
      return "remote_branch"
    }
    if refname.hasPrefix("refs/tags/") {
      return "tag"
    }
    return "other"
  }

  internal func gitCompareRefs(arguments object: [String: JSONValue]) throws -> JSONValue {
    let base = try validatedGitRefArgument("base", in: object)
    let head = try validatedGitRefArgument("head", in: object)
    let limit = optionalInt("limit", in: object) ?? 20
    try validateBoundedPositive(limit, name: "limit", upperBound: 200)
    let maxResults = optionalInt("max_results", in: object) ?? limit
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 200)
    let cherryPick = try optionalBool("cherry_pick", in: object) ?? false
    let timeout = optionalInt("timeout_ms", in: object)
    let range = "\(base)...\(head)"

    var countArgs = ["rev-list", "--left-right", "--count"]
    if cherryPick {
      countArgs.append("--cherry-pick")
    }
    countArgs.append(range)

    let mergeBaseArgs = ["merge-base", base, head]

    var logArgs = [
      "log",
      "--left-right",
      "--date=iso-strict",
      "--pretty=format:%m%x09%H%x09%h%x09%ad%x09%an%x09%s",
      "-n",
      "\(limit)",
    ]
    if cherryPick {
      logArgs.insert("--cherry-pick", at: 2)
    }
    logArgs.append(range)

    let command = try gitCLICommand()
    let countResult = try runRegisteredCLI(
      command: command,
      args: countArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    let mergeBaseResult = try runRegisteredCLI(
      command: command,
      args: mergeBaseArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    let logResult = try runRegisteredCLI(
      command: command,
      args: logArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )

    let counts = parseGitCompareCounts(countResult.stdout)
    let rawLines = logResult.stdout.split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
      .filter { !$0.isEmpty }
    let commits = rawLines.map(parseGitCompareCommitLine)
    let returnedCommits = Array(commits.prefix(maxResults))
    let returnedRawLines = Array(rawLines.prefix(maxResults))
    let resultTruncated =
      commits.count > returnedCommits.count || rawLines.count > returnedRawLines.count
    let mergeBase = mergeBaseResult.exitCode == 0 ? firstNonEmptyLine(mergeBaseResult.stdout) : nil
    let parseIncomplete =
      countResult.stdoutTruncated || mergeBaseResult.stdoutTruncated || logResult.stdoutTruncated
      || counts == nil

    return .object([
      "operation": .string("git.compare_refs"),
      "provider": .string(command.id),
      "base": .string(base),
      "head": .string(head),
      "range": .string(range),
      "cherry_pick": .bool(cherryPick),
      "limit": .integer(Int64(limit)),
      "max_results": .integer(Int64(maxResults)),
      "argv": .object([
        "counts": .array(countArgs.map(JSONValue.string)),
        "merge_base": .array(mergeBaseArgs.map(JSONValue.string)),
        "commits": .array(logArgs.map(JSONValue.string)),
      ]),
      "counts": counts?.json ?? .null,
      "base_only_count": counts.map { .integer(Int64($0.baseOnly)) } ?? .null,
      "head_only_count": counts.map { .integer(Int64($0.headOnly)) } ?? .null,
      "head_ahead": counts.map { .integer(Int64($0.headOnly)) } ?? .null,
      "head_behind": counts.map { .integer(Int64($0.baseOnly)) } ?? .null,
      "merge_base": mergeBase.map(JSONValue.string) ?? .null,
      "has_merge_base": .bool(mergeBase != nil),
      "commit_count": .integer(Int64(commits.count)),
      "returned_commit_count": .integer(Int64(returnedCommits.count)),
      "raw_line_count": .integer(Int64(rawLines.count)),
      "returned_raw_line_count": .integer(Int64(returnedRawLines.count)),
      "result_truncated": .bool(resultTruncated),
      "stdout_truncated": .bool(
        countResult.stdoutTruncated || mergeBaseResult.stdoutTruncated || logResult.stdoutTruncated
      ),
      "parse_incomplete": .bool(parseIncomplete),
      "truncated": .bool(resultTruncated || parseIncomplete),
      "commits": .array(returnedCommits.map(\.json)),
      "raw_lines": .array(returnedRawLines.map(JSONValue.string)),
      "results": .object([
        "counts": gitCommandMetadata(countResult),
        "merge_base": gitCommandMetadata(mergeBaseResult),
        "commits": gitCommandMetadata(logResult),
      ]),
    ])
  }

  internal func gitResolveRef(arguments object: [String: JSONValue]) throws -> JSONValue {
    let ref = try validatedGitRefArgument("ref", in: object)
    let timeout = optionalInt("timeout_ms", in: object)
    let command = try gitCLICommand()
    let objectSpec = "\(ref)^{object}"
    let revParseArgs = ["rev-parse", "--verify", objectSpec]
    let revParseResult = try runRegisteredCLI(
      command: command,
      args: revParseArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    guard !revParseResult.timedOut else {
      throw GatewayToolError.invalidArguments("git.resolve_ref timed out while resolving ref.")
    }
    guard revParseResult.exitCode == 0, let objectID = firstNonEmptyLine(revParseResult.stdout)
    else {
      throw GatewayToolError.invalidArguments("git.resolve_ref failed for the supplied ref.")
    }

    let typeArgs = ["cat-file", "-t", objectID]
    let typeResult = try runRegisteredCLI(
      command: command,
      args: typeArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    guard !typeResult.timedOut else {
      throw GatewayToolError.invalidArguments(
        "git.resolve_ref timed out while reading object type.")
    }
    guard typeResult.exitCode == 0, let objectType = firstNonEmptyLine(typeResult.stdout) else {
      throw GatewayToolError.invalidArguments("git.resolve_ref failed while reading object type.")
    }

    return .object([
      "operation": .string("git.resolve_ref"),
      "provider": .string(command.id),
      "ref": .string(ref),
      "object_spec": .string(objectSpec),
      "object": .string(objectID),
      "object_type": .string(objectType),
      "argv": .object([
        "resolve": .array(revParseArgs.map(JSONValue.string)),
        "type": .array(typeArgs.map(JSONValue.string)),
      ]),
      "results": .object([
        "resolve": gitCommandMetadata(revParseResult),
        "type": gitCommandMetadata(typeResult),
      ]),
    ])
  }

  internal func gitMergeBase(arguments object: [String: JSONValue]) throws -> JSONValue {
    let rawRefs = try requiredStringArray("refs", in: object)
    guard rawRefs.count >= 2 else {
      throw GatewayToolError.invalidArguments("refs must contain at least 2 values.")
    }
    guard rawRefs.count <= 16 else {
      throw GatewayToolError.invalidArguments("refs must contain at most 16 values.")
    }

    var refs: [String] = []
    for (index, ref) in rawRefs.enumerated() {
      guard !ref.isEmpty else {
        throw GatewayToolError.invalidArguments("refs[\(index)] must not be empty.")
      }
      refs.append(try validateGitRefToken(ref, name: "refs[\(index)]"))
    }

    let all = try optionalBool("all", in: object) ?? false
    let timeout = optionalInt("timeout_ms", in: object)
    let command = try gitCLICommand()
    var args = ["merge-base"]
    if all {
      args.append("--all")
    }
    args.append(contentsOf: refs)

    let result = try runRegisteredCLI(
      command: command,
      args: args,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    guard !result.timedOut else {
      throw GatewayToolError.invalidArguments("git.merge_base timed out.")
    }
    guard result.exitCode == 0 || result.exitCode == 1 else {
      throw GatewayToolError.invalidArguments("git.merge_base failed for the supplied refs.")
    }

    let mergeBases =
      result.exitCode == 0
      ? result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
        .filter { !$0.isEmpty }
      : []

    return .object([
      "operation": .string("git.merge_base"),
      "provider": .string(command.id),
      "refs": .array(refs.map(JSONValue.string)),
      "all": .bool(all),
      "argv": .array(args.map(JSONValue.string)),
      "merge_bases": .array(mergeBases.map(JSONValue.string)),
      "merge_base": mergeBases.first.map(JSONValue.string) ?? .null,
      "merge_base_count": .integer(Int64(mergeBases.count)),
      "has_merge_base": .bool(!mergeBases.isEmpty),
      "result": gitCommandMetadata(result),
    ])
  }

  internal func gitIsAncestor(arguments object: [String: JSONValue]) throws -> JSONValue {
    let ancestor = try validatedGitRefArgument("ancestor", in: object)
    let descendant = try validatedGitRefArgument("descendant", in: object)
    let timeout = optionalInt("timeout_ms", in: object)
    let command = try gitCLICommand()
    let args = ["merge-base", "--is-ancestor", ancestor, descendant]
    let result = try runRegisteredCLI(
      command: command,
      args: args,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    guard !result.timedOut else {
      throw GatewayToolError.invalidArguments("git.is_ancestor timed out.")
    }
    guard result.exitCode == 0 || result.exitCode == 1 else {
      throw GatewayToolError.invalidArguments("git.is_ancestor failed for the supplied refs.")
    }

    return .object([
      "operation": .string("git.is_ancestor"),
      "provider": .string(command.id),
      "ancestor": .string(ancestor),
      "descendant": .string(descendant),
      "argv": .array(args.map(JSONValue.string)),
      "is_ancestor": .bool(result.exitCode == 0),
      "result": result.json,
    ])
  }

  private func validatedGitRefArgument(_ name: String, in object: [String: JSONValue]) throws
    -> String
  {
    let ref = try requiredString(name, in: object)
    return try validateGitRefToken(ref, name: name)
  }

  private func optionalValidatedGitRefArgument(_ name: String, in object: [String: JSONValue])
    throws
    -> String?
  {
    guard let ref = try optionalString(name, in: object) else {
      return nil
    }
    return try validateGitRefToken(ref, name: name)
  }

  private func validateGitRefToken(_ ref: String, name: String) throws -> String {
    guard ref.utf8.count <= 256 else {
      throw GatewayToolError.invalidArguments("\(name) must be 256 bytes or fewer.")
    }
    guard !ref.hasPrefix("-") else {
      throw GatewayToolError.invalidArguments("\(name) must not start with '-'.")
    }
    guard !ref.hasPrefix("/"), !ref.hasSuffix("/") else {
      throw GatewayToolError.invalidArguments("\(name) must not start or end with '/'.")
    }
    let forbiddenSubstrings = ["..", "@{", "//", ".lock"]
    for substring in forbiddenSubstrings where ref.contains(substring) {
      throw GatewayToolError.invalidArguments(
        "\(name) contains unsupported Git ref syntax: \(substring)")
    }
    let allowedPunctuation = Set("._/@+-")
    for scalar in ref.unicodeScalars {
      let isAlphaNumeric =
        (scalar.value >= 48 && scalar.value <= 57)
        || (scalar.value >= 65 && scalar.value <= 90)
        || (scalar.value >= 97 && scalar.value <= 122)
      let isAllowedPunctuation = allowedPunctuation.contains(Character(scalar))
      guard isAlphaNumeric || isAllowedPunctuation else {
        throw GatewayToolError.invalidArguments(
          "\(name) may only contain ASCII letters, digits, '.', '_', '/', '@', '+', or '-'.")
      }
    }
    return ref
  }

  private func validatedGitBranchNameArgument(_ name: String, in object: [String: JSONValue]) throws
    -> String
  {
    let branch = try requiredString(name, in: object)
    _ = try validateGitRefToken(branch, name: name)
    guard branch != "HEAD" else {
      throw GatewayToolError.invalidArguments("\(name) must not be HEAD.")
    }
    guard !branch.hasPrefix("refs/") else {
      throw GatewayToolError.invalidArguments("\(name) must be a branch name, not a full ref.")
    }
    guard !branch.contains("@") else {
      throw GatewayToolError.invalidArguments("\(name) must not contain '@'.")
    }
    return branch
  }

  private func validatedGitTagNameArgument(_ name: String, in object: [String: JSONValue]) throws
    -> String
  {
    let tag = try requiredString(name, in: object)
    _ = try validateGitRefToken(tag, name: name)
    guard tag != "HEAD" else {
      throw GatewayToolError.invalidArguments("\(name) must not be HEAD.")
    }
    guard !tag.hasPrefix("refs/") else {
      throw GatewayToolError.invalidArguments("\(name) must be a tag name, not a full ref.")
    }
    guard !tag.contains("@") else {
      throw GatewayToolError.invalidArguments("\(name) must not contain '@'.")
    }
    return tag
  }

  private func optionalGitStashRef(in object: [String: JSONValue]) throws -> String {
    let stash = try optionalString("stash", in: object) ?? "stash@{0}"
    guard stash.utf8.count <= 64 else {
      throw GatewayToolError.invalidArguments("stash must be 64 bytes or fewer.")
    }
    guard stash.hasPrefix("stash@{"), stash.hasSuffix("}") else {
      throw GatewayToolError.invalidArguments("stash must use stash@{N} syntax.")
    }

    let start = stash.index(stash.startIndex, offsetBy: "stash@{".count)
    let digits = stash[start..<stash.index(before: stash.endIndex)]
    guard !digits.isEmpty else {
      throw GatewayToolError.invalidArguments("stash index must not be empty.")
    }
    for scalar in digits.unicodeScalars {
      guard scalar.value >= 48 && scalar.value <= 57 else {
        throw GatewayToolError.invalidArguments("stash index must be a non-negative integer.")
      }
    }
    guard Int(String(digits)) != nil else {
      throw GatewayToolError.invalidArguments("stash index is too large.")
    }
    return stash
  }

  private func validateGitGrepQuery(_ query: String) throws {
    guard !query.isEmpty else {
      throw GatewayToolError.invalidArguments("query must not be empty.")
    }
    try validateUTF8ByteLimit(query, name: "query", maxBytes: 1_024)
    guard !query.contains("\0") else {
      throw GatewayToolError.invalidArguments("query must not contain null bytes.")
    }
    guard query.rangeOfCharacter(from: .newlines) == nil else {
      throw GatewayToolError.invalidArguments("query must not contain newlines.")
    }
  }

  private func parseGitGrepZ(_ stdout: String) -> (matches: [GitGrepMatch], parseIncomplete: Bool) {
    var matches: [GitGrepMatch] = []
    var index = stdout.startIndex
    var parseIncomplete = false

    while index < stdout.endIndex {
      guard let pathEnd = stdout[index...].firstIndex(of: "\0") else {
        parseIncomplete = true
        break
      }
      let path = String(stdout[index..<pathEnd])
      index = stdout.index(after: pathEnd)

      guard index < stdout.endIndex,
        let lineEnd = stdout[index...].firstIndex(of: "\0")
      else {
        parseIncomplete = true
        break
      }
      let lineString = String(stdout[index..<lineEnd])
      index = stdout.index(after: lineEnd)

      let textEnd = stdout[index...].firstIndex(of: "\n") ?? stdout.endIndex
      let text = String(stdout[index..<textEnd])
      if textEnd < stdout.endIndex {
        index = stdout.index(after: textEnd)
      } else {
        index = stdout.endIndex
      }

      guard !path.isEmpty, let line = Int(lineString), line > 0 else {
        parseIncomplete = true
        continue
      }
      matches.append(
        GitGrepMatch(
          path: path,
          line: line,
          text: text,
          rawRecord: "\(path)\t\(lineString)\t\(text)"
        ))
    }

    return (matches, parseIncomplete)
  }

  private func parseGitCompareCounts(_ stdout: String) -> GitCompareCounts? {
    let values = stdout.split { $0 == " " || $0 == "\t" || $0 == "\n" }.compactMap { Int($0) }
    guard values.count >= 2 else {
      return nil
    }
    return GitCompareCounts(baseOnly: values[0], headOnly: values[1])
  }

  private func parseGitCompareCommitLine(_ line: String) -> GitCompareCommit {
    let parts = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
      .map(String.init)
    guard parts.count == 6 else {
      return GitCompareCommit(
        side: nil,
        refSide: "other",
        commit: nil,
        abbreviatedCommit: nil,
        committedAt: nil,
        author: nil,
        subject: nil,
        rawLine: line
      )
    }

    return GitCompareCommit(
      side: parts[0].isEmpty ? nil : parts[0],
      refSide: gitCompareRefSide(parts[0]),
      commit: parts[1].isEmpty ? nil : parts[1],
      abbreviatedCommit: parts[2].isEmpty ? nil : parts[2],
      committedAt: parts[3].isEmpty ? nil : parts[3],
      author: parts[4].isEmpty ? nil : parts[4],
      subject: parts[5].isEmpty ? nil : parts[5],
      rawLine: line
    )
  }

  private func gitCompareRefSide(_ marker: String) -> String {
    switch marker {
    case "<":
      return "base"
    case ">":
      return "head"
    default:
      return "other"
    }
  }

  private func firstNonEmptyLine(_ stdout: String) -> String? {
    stdout.split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
      .first { !$0.isEmpty }
  }

  private func gitPorcelainZEntryCount(_ stdout: String) -> Int {
    stdout.split(separator: "\u{0}", omittingEmptySubsequences: true).count
  }

  internal func gitDiff(arguments object: [String: JSONValue]) throws -> JSONValue {
    let staged = try optionalBool("staged", in: object) ?? false
    let stat = try optionalBool("stat", in: object) ?? false
    let paths = try optionalGitPaths(in: object)
    let contextLines = optionalInt("context_lines", in: object)
    if let contextLines {
      try validateBoundedNonNegative(contextLines, name: "context_lines", upperBound: 100)
    }

    var args = ["diff", "--no-ext-diff"]
    if staged {
      args.append("--cached")
    }
    if stat {
      args.append("--stat")
    }
    if let contextLines {
      args.append("-U\(contextLines)")
    }
    if !paths.isEmpty {
      args.append("--")
      args.append(contentsOf: paths)
    }
    return try gitResult(
      operation: "git.diff",
      arguments: args,
      timeout: optionalInt("timeout_ms", in: object)
    )
  }

  internal func gitDiffSummary(arguments object: [String: JSONValue]) throws -> JSONValue {
    let staged = try optionalBool("staged", in: object) ?? false
    let paths = try optionalGitPaths(in: object)
    let maxResults = optionalInt("max_results", in: object) ?? 200
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 5_000)

    let command = try gitCLICommand()
    var baseArgs = ["diff", "--no-ext-diff", "--no-color"]
    if staged {
      baseArgs.append("--cached")
    }

    var numstatArgs = baseArgs + ["--numstat", "-z"]
    var summaryArgs = baseArgs + ["--summary"]
    if !paths.isEmpty {
      numstatArgs.append("--")
      numstatArgs.append(contentsOf: paths)
      summaryArgs.append("--")
      summaryArgs.append(contentsOf: paths)
    }

    let timeout = optionalInt("timeout_ms", in: object)
    let numstatResult = try runRegisteredCLI(
      command: command,
      args: numstatArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    let summaryResult = try runRegisteredCLI(
      command: command,
      args: summaryArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )

    let files = parseGitDiffNumstatZ(numstatResult.stdout)
    let summaryItems = parseGitDiffSummaryLines(summaryResult.stdout)
    let returnedFiles = Array(files.prefix(maxResults))
    let returnedSummaryItems = Array(summaryItems.prefix(maxResults))
    let totalAdditions = files.compactMap(\.additions).reduce(0, +)
    let totalDeletions = files.compactMap(\.deletions).reduce(0, +)
    let binaryFileCount = files.filter(\.binary).count
    let resultTruncated =
      files.count > returnedFiles.count
      || summaryItems.count > returnedSummaryItems.count
    let stdoutTruncated = numstatResult.stdoutTruncated || summaryResult.stdoutTruncated

    return .object([
      "operation": .string("git.diff_summary"),
      "provider": .string(command.id),
      "staged": .bool(staged),
      "paths": .array(paths.map(JSONValue.string)),
      "max_results": .integer(Int64(maxResults)),
      "commands": .object([
        "numstat": .array(numstatArgs.map(JSONValue.string)),
        "summary": .array(summaryArgs.map(JSONValue.string)),
      ]),
      "file_count": .integer(Int64(files.count)),
      "returned_file_count": .integer(Int64(returnedFiles.count)),
      "summary_count": .integer(Int64(summaryItems.count)),
      "returned_summary_count": .integer(Int64(returnedSummaryItems.count)),
      "total_additions": .integer(Int64(totalAdditions)),
      "total_deletions": .integer(Int64(totalDeletions)),
      "binary_file_count": .integer(Int64(binaryFileCount)),
      "result_truncated": .bool(resultTruncated),
      "stdout_truncated": .bool(stdoutTruncated),
      "parse_incomplete": .bool(stdoutTruncated),
      "truncated": .bool(resultTruncated || stdoutTruncated),
      "files": .array(returnedFiles.map(\.json)),
      "summary": .array(returnedSummaryItems.map(\.json)),
      "results": .object([
        "numstat": gitCommandMetadata(numstatResult),
        "summary": gitCommandMetadata(summaryResult),
      ]),
    ])
  }

  private func parseGitDiffNumstatZ(_ stdout: String) -> [GitDiffNumstatFile] {
    let records = stdout.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
    var files: [GitDiffNumstatFile] = []
    var index = 0

    while index < records.count {
      let record = records[index]
      guard !record.isEmpty else {
        index += 1
        continue
      }

      let parts = record.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard parts.count >= 3 else {
        index += 1
        continue
      }

      let additions = gitNumstatValue(parts[0])
      let deletions = gitNumstatValue(parts[1])
      let binary = parts[0] == "-" || parts[1] == "-"
      let path = parts[2]
      if path.isEmpty {
        guard index + 2 < records.count else {
          break
        }
        files.append(
          GitDiffNumstatFile(
            path: records[index + 2],
            oldPath: records[index + 1],
            additions: additions,
            deletions: deletions,
            binary: binary
          ))
        index += 3
      } else {
        files.append(
          GitDiffNumstatFile(
            path: path,
            oldPath: nil,
            additions: additions,
            deletions: deletions,
            binary: binary
          ))
        index += 1
      }
    }

    return files
  }

  private func gitNumstatValue(_ value: String) -> Int? {
    value == "-" ? nil : Int(value)
  }

  private func parseGitDiffSummaryLines(_ stdout: String) -> [GitDiffSummaryItem] {
    stdout.split(separator: "\n", omittingEmptySubsequences: true).map { line in
      parseGitDiffSummaryLine(String(line))
    }
  }

  private func parseGitDiffSummaryLine(_ line: String) -> GitDiffSummaryItem {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if let item = parseGitDiffModeSummaryLine(trimmed, rawLine: line) {
      return item
    }
    if let item = parseGitDiffMoveSummaryLine(trimmed, rawLine: line) {
      return item
    }
    return GitDiffSummaryItem(
      kind: "other", path: nil, oldPath: nil, newPath: nil, oldMode: nil,
      newMode: nil, mode: nil, similarity: nil, rawLine: line)
  }

  private func parseGitDiffModeSummaryLine(_ trimmed: String, rawLine: String)
    -> GitDiffSummaryItem?
  {
    if trimmed.hasPrefix("create mode ") {
      let rest = String(trimmed.dropFirst("create mode ".count))
      let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
      guard parts.count == 2 else {
        return nil
      }
      return GitDiffSummaryItem(
        kind: "create", path: String(parts[1]), oldPath: nil,
        newPath: String(parts[1]), oldMode: nil, newMode: nil, mode: String(parts[0]),
        similarity: nil, rawLine: rawLine)
    }

    if trimmed.hasPrefix("delete mode ") {
      let rest = String(trimmed.dropFirst("delete mode ".count))
      let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
      guard parts.count == 2 else {
        return nil
      }
      return GitDiffSummaryItem(
        kind: "delete", path: String(parts[1]), oldPath: String(parts[1]),
        newPath: nil, oldMode: nil, newMode: nil, mode: String(parts[0]),
        similarity: nil, rawLine: rawLine)
    }

    if trimmed.hasPrefix("mode change ") {
      let rest = String(trimmed.dropFirst("mode change ".count))
      let parts = rest.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
      guard parts.count == 4, parts[1] == "=>" else {
        return nil
      }
      return GitDiffSummaryItem(
        kind: "mode_change", path: String(parts[3]), oldPath: nil,
        newPath: nil, oldMode: String(parts[0]), newMode: String(parts[2]), mode: nil,
        similarity: nil, rawLine: rawLine)
    }

    return nil
  }

  private func parseGitDiffMoveSummaryLine(_ trimmed: String, rawLine: String)
    -> GitDiffSummaryItem?
  {
    let kind: String
    let prefix: String
    if trimmed.hasPrefix("rename ") {
      kind = "rename"
      prefix = "rename "
    } else if trimmed.hasPrefix("copy ") {
      kind = "copy"
      prefix = "copy "
    } else {
      return nil
    }

    let rest = String(trimmed.dropFirst(prefix.count))
    let similarity: Int?
    let body: String
    if let open = rest.lastIndex(of: "("), rest.hasSuffix("%)") {
      let percentStart = rest.index(after: open)
      let percentEnd = rest.index(rest.endIndex, offsetBy: -2)
      similarity = Int(rest[percentStart..<percentEnd])
      body = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
    } else {
      similarity = nil
      body = rest
    }

    let separator = " => "
    guard let range = body.range(of: separator) else {
      return GitDiffSummaryItem(
        kind: kind, path: nil, oldPath: nil, newPath: nil, oldMode: nil,
        newMode: nil, mode: nil, similarity: similarity, rawLine: rawLine)
    }
    let oldPath = String(body[..<range.lowerBound])
    let newPath = String(body[range.upperBound...])
    return GitDiffSummaryItem(
      kind: kind, path: newPath, oldPath: oldPath, newPath: newPath,
      oldMode: nil, newMode: nil, mode: nil, similarity: similarity, rawLine: rawLine)
  }

  internal func gitDiffCheck(arguments object: [String: JSONValue]) throws -> JSONValue {
    let staged = try optionalBool("staged", in: object) ?? false
    let paths = try optionalGitPaths(in: object)
    let maxResults = optionalInt("max_results", in: object) ?? 200
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 5_000)

    var args = ["diff", "--no-ext-diff", "--no-color", "--check"]
    if staged {
      args.append("--cached")
    }
    if !paths.isEmpty {
      args.append("--")
      args.append(contentsOf: paths)
    }

    let command = try gitCLICommand()
    let result = try runRegisteredCLI(
      command: command,
      args: args,
      timeout: optionalInt("timeout_ms", in: object),
      requireArbitraryArgs: false
    )
    let issues = parseGitDiffCheckIssues(result.stdout)
    let rawLines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
      .filter { !$0.isEmpty }
    let returnedIssues = Array(issues.prefix(maxResults))
    let returnedRawLines = Array(rawLines.prefix(maxResults))
    let resultTruncated =
      issues.count > returnedIssues.count || rawLines.count > returnedRawLines.count

    return .object([
      "operation": .string("git.diff_check"),
      "provider": .string(command.id),
      "argv": .array(args.map(JSONValue.string)),
      "staged": .bool(staged),
      "paths": .array(paths.map(JSONValue.string)),
      "max_results": .integer(Int64(maxResults)),
      "passed": .bool(result.exitCode == 0 && issues.isEmpty && !result.stdoutTruncated),
      "issue_count": .integer(Int64(issues.count)),
      "returned_issue_count": .integer(Int64(returnedIssues.count)),
      "raw_line_count": .integer(Int64(rawLines.count)),
      "returned_raw_line_count": .integer(Int64(returnedRawLines.count)),
      "result_truncated": .bool(resultTruncated),
      "stdout_truncated": .bool(result.stdoutTruncated),
      "parse_incomplete": .bool(result.stdoutTruncated),
      "truncated": .bool(resultTruncated || result.stdoutTruncated),
      "issues": .array(returnedIssues.map(\.json)),
      "raw_lines": .array(returnedRawLines.map(JSONValue.string)),
      "result": gitCommandMetadata(result),
    ])
  }

  private func parseGitDiffCheckIssues(_ stdout: String) -> [GitDiffCheckIssue] {
    stdout.split(separator: "\n", omittingEmptySubsequences: true).compactMap { rawLine in
      parseGitDiffCheckIssueLine(String(rawLine))
    }
  }

  private func parseGitDiffCheckIssueLine(_ line: String) -> GitDiffCheckIssue? {
    guard let secondColon = line.range(of: ":", options: [], range: line.startIndex..<line.endIndex)
    else {
      return nil
    }
    let path = String(line[..<secondColon.lowerBound])
    let afterPath = line[secondColon.upperBound...]
    guard let lineColon = afterPath.firstIndex(of: ":") else {
      return nil
    }
    let lineNumberText = String(afterPath[..<lineColon])
    guard let lineNumber = Int(lineNumberText) else {
      return nil
    }
    let message = String(afterPath[afterPath.index(after: lineColon)...])
      .trimmingCharacters(in: .whitespaces)
    guard !path.isEmpty, !message.isEmpty else {
      return nil
    }
    return GitDiffCheckIssue(path: path, line: lineNumber, message: message, rawLine: line)
  }

  internal func gitBranch(arguments object: [String: JSONValue]) throws -> JSONValue {
    let all = try optionalBool("all", in: object) ?? false
    let verbose = try optionalBool("verbose", in: object) ?? false
    var args = ["--no-pager", "branch", "--list", "--no-color", "--no-column"]
    if all {
      args.append("--all")
    }
    if verbose {
      args.append("--verbose")
    }
    return try gitResult(
      operation: "git.branch",
      arguments: args,
      timeout: optionalInt("timeout_ms", in: object)
    )
  }

  internal func gitBranchCreate(arguments object: [String: JSONValue]) throws -> JSONValue {
    let branchName = try validatedGitBranchNameArgument("name", in: object)
    let startPoint = try optionalValidatedGitRefArgument("start_point", in: object) ?? "HEAD"
    let dryRun = try optionalBool("dry_run", in: object) ?? true
    let confirmCreate = try optionalBool("confirm_create", in: object) ?? false
    guard dryRun || confirmCreate else {
      throw GatewayToolError.invalidArguments(
        "git.branch_create requires confirm_create=true when dry_run is false.")
    }

    let timeout = optionalInt("timeout_ms", in: object)
    let command = try gitCLICommand()
    let checkNameArgs = ["check-ref-format", "--branch", branchName]
    let existsArgs = ["show-ref", "--verify", "--quiet", "refs/heads/\(branchName)"]
    let startPointArgs = ["rev-parse", "--verify", "\(startPoint)^{commit}"]

    let checkNameResult = try runRegisteredCLI(
      command: command,
      args: checkNameArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    guard !checkNameResult.timedOut, checkNameResult.exitCode == 0 else {
      throw GatewayToolError.invalidArguments(
        "branch name is not accepted by git check-ref-format: \(branchName)")
    }

    let existsResult = try runRegisteredCLI(
      command: command,
      args: existsArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    guard !existsResult.timedOut else {
      throw GatewayToolError.invalidArguments("branch existence check timed out.")
    }
    guard existsResult.exitCode != 0 else {
      throw GatewayToolError.invalidArguments("branch already exists: \(branchName)")
    }
    guard existsResult.exitCode == 1 else {
      throw GatewayToolError.invalidArguments("branch existence check failed for: \(branchName)")
    }

    let startPointResult = try runRegisteredCLI(
      command: command,
      args: startPointArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    guard !startPointResult.timedOut, startPointResult.exitCode == 0 else {
      throw GatewayToolError.invalidArguments(
        "start_point is not a commit-ish ref: \(startPoint)")
    }

    let createArgs = ["branch", branchName, startPoint]
    var result: JSONValue = .null
    if !dryRun {
      let createResult = try runRegisteredCLI(
        command: command,
        args: createArgs,
        timeout: timeout,
        requireArbitraryArgs: false
      )
      result = createResult.json
    }

    return .object([
      "operation": .string("git.branch_create"),
      "provider": .string(command.id),
      "name": .string(branchName),
      "start_point": .string(startPoint),
      "argv": .array(createArgs.map(JSONValue.string)),
      "dry_run": .bool(dryRun),
      "confirm_create": .bool(confirmCreate),
      "preflight": .object([
        "check_ref_format": gitCommandMetadata(checkNameResult),
        "existing_branch": gitCommandMetadata(existsResult),
        "start_point": gitCommandMetadata(startPointResult),
      ]),
      "result": result,
      "would_create": .bool(true),
    ])
  }

  internal func gitBranchDelete(arguments object: [String: JSONValue]) throws -> JSONValue {
    let branchName = try validatedGitBranchNameArgument("name", in: object)
    let force = try optionalBool("force", in: object) ?? false
    let dryRun = try optionalBool("dry_run", in: object) ?? true
    let confirmDelete = try optionalBool("confirm_delete", in: object) ?? false
    guard dryRun || confirmDelete else {
      throw GatewayToolError.invalidArguments(
        "git.branch_delete requires confirm_delete=true when dry_run is false.")
    }

    let timeout = optionalInt("timeout_ms", in: object)
    let command = try gitCLICommand()
    let checkNameArgs = ["check-ref-format", "--branch", branchName]
    let existsArgs = ["show-ref", "--verify", "--quiet", "refs/heads/\(branchName)"]
    let currentBranchArgs = ["branch", "--show-current"]

    let checkNameResult = try runRegisteredCLI(
      command: command,
      args: checkNameArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    guard !checkNameResult.timedOut, checkNameResult.exitCode == 0 else {
      throw GatewayToolError.invalidArguments(
        "branch name is not accepted by git check-ref-format: \(branchName)")
    }

    let existsResult = try runRegisteredCLI(
      command: command,
      args: existsArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    guard !existsResult.timedOut else {
      throw GatewayToolError.invalidArguments("branch existence check timed out.")
    }
    guard existsResult.exitCode == 0 else {
      if existsResult.exitCode == 1 {
        throw GatewayToolError.invalidArguments("local branch does not exist: \(branchName)")
      }
      throw GatewayToolError.invalidArguments("branch existence check failed for: \(branchName)")
    }

    let currentBranchResult = try runRegisteredCLI(
      command: command,
      args: currentBranchArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    guard !currentBranchResult.timedOut, currentBranchResult.exitCode == 0 else {
      throw GatewayToolError.invalidArguments("current branch check failed.")
    }
    let currentBranch = firstNonEmptyLine(currentBranchResult.stdout) ?? ""
    guard currentBranch != branchName else {
      throw GatewayToolError.invalidArguments("cannot delete the current branch: \(branchName)")
    }

    let deleteArgs = ["branch", force ? "-D" : "-d", branchName]
    var result: JSONValue = .null
    if !dryRun {
      let deleteResult = try runRegisteredCLI(
        command: command,
        args: deleteArgs,
        timeout: timeout,
        requireArbitraryArgs: false
      )
      result = deleteResult.json
    }

    return .object([
      "operation": .string("git.branch_delete"),
      "provider": .string(command.id),
      "name": .string(branchName),
      "force": .bool(force),
      "argv": .array(deleteArgs.map(JSONValue.string)),
      "dry_run": .bool(dryRun),
      "confirm_delete": .bool(confirmDelete),
      "current_branch": currentBranch.isEmpty ? .null : .string(currentBranch),
      "preflight": .object([
        "check_ref_format": gitCommandMetadata(checkNameResult),
        "existing_branch": gitCommandMetadata(existsResult),
        "current_branch": gitCommandMetadata(currentBranchResult),
      ]),
      "result": result,
      "would_delete": .bool(true),
    ])
  }

  internal func gitBranchRename(arguments object: [String: JSONValue]) throws -> JSONValue {
    let oldName = try validatedGitBranchNameArgument("old_name", in: object)
    let newName = try validatedGitBranchNameArgument("new_name", in: object)
    let force = try optionalBool("force", in: object) ?? false
    let dryRun = try optionalBool("dry_run", in: object) ?? true
    let confirmRename = try optionalBool("confirm_rename", in: object) ?? false
    guard oldName != newName else {
      throw GatewayToolError.invalidArguments("old_name and new_name must be different.")
    }
    guard dryRun || confirmRename else {
      throw GatewayToolError.invalidArguments(
        "git.branch_rename requires confirm_rename=true when dry_run is false.")
    }

    let timeout = optionalInt("timeout_ms", in: object)
    let command = try gitCLICommand()
    let checkOldNameArgs = ["check-ref-format", "--branch", oldName]
    let checkNewNameArgs = ["check-ref-format", "--branch", newName]
    let oldExistsArgs = ["show-ref", "--verify", "--quiet", "refs/heads/\(oldName)"]
    let newExistsArgs = ["show-ref", "--verify", "--quiet", "refs/heads/\(newName)"]
    let currentBranchArgs = ["branch", "--show-current"]

    let checkOldNameResult = try runRegisteredCLI(
      command: command,
      args: checkOldNameArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    guard !checkOldNameResult.timedOut, checkOldNameResult.exitCode == 0 else {
      throw GatewayToolError.invalidArguments(
        "old_name is not accepted by git check-ref-format: \(oldName)")
    }

    let checkNewNameResult = try runRegisteredCLI(
      command: command,
      args: checkNewNameArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    guard !checkNewNameResult.timedOut, checkNewNameResult.exitCode == 0 else {
      throw GatewayToolError.invalidArguments(
        "new_name is not accepted by git check-ref-format: \(newName)")
    }

    let oldExistsResult = try runRegisteredCLI(
      command: command,
      args: oldExistsArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    guard !oldExistsResult.timedOut else {
      throw GatewayToolError.invalidArguments("old branch existence check timed out.")
    }
    guard oldExistsResult.exitCode == 0 else {
      if oldExistsResult.exitCode == 1 {
        throw GatewayToolError.invalidArguments("local branch does not exist: \(oldName)")
      }
      throw GatewayToolError.invalidArguments("old branch existence check failed for: \(oldName)")
    }

    let newExistsResult = try runRegisteredCLI(
      command: command,
      args: newExistsArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    guard !newExistsResult.timedOut else {
      throw GatewayToolError.invalidArguments("new branch existence check timed out.")
    }
    if newExistsResult.exitCode == 0, !force {
      throw GatewayToolError.invalidArguments("target branch already exists: \(newName)")
    }
    guard newExistsResult.exitCode == 0 || newExistsResult.exitCode == 1 else {
      throw GatewayToolError.invalidArguments("new branch existence check failed for: \(newName)")
    }

    let currentBranchResult = try runRegisteredCLI(
      command: command,
      args: currentBranchArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    guard !currentBranchResult.timedOut, currentBranchResult.exitCode == 0 else {
      throw GatewayToolError.invalidArguments("current branch check failed.")
    }
    let currentBranch = firstNonEmptyLine(currentBranchResult.stdout) ?? ""

    let renameArgs = ["branch", force ? "-M" : "-m", oldName, newName]
    var result: JSONValue = .null
    if !dryRun {
      let renameResult = try runRegisteredCLI(
        command: command,
        args: renameArgs,
        timeout: timeout,
        requireArbitraryArgs: false
      )
      result = renameResult.json
    }

    return .object([
      "operation": .string("git.branch_rename"),
      "provider": .string(command.id),
      "old_name": .string(oldName),
      "new_name": .string(newName),
      "force": .bool(force),
      "argv": .array(renameArgs.map(JSONValue.string)),
      "dry_run": .bool(dryRun),
      "confirm_rename": .bool(confirmRename),
      "current_branch": currentBranch.isEmpty ? .null : .string(currentBranch),
      "renames_current_branch": .bool(currentBranch == oldName),
      "target_exists": .bool(newExistsResult.exitCode == 0),
      "preflight": .object([
        "check_old_ref_format": gitCommandMetadata(checkOldNameResult),
        "check_new_ref_format": gitCommandMetadata(checkNewNameResult),
        "old_branch": gitCommandMetadata(oldExistsResult),
        "target_branch": gitCommandMetadata(newExistsResult),
        "current_branch": gitCommandMetadata(currentBranchResult),
      ]),
      "result": result,
      "would_rename": .bool(true),
    ])
  }

  internal func gitBranchSwitch(arguments object: [String: JSONValue]) throws -> JSONValue {
    let branchName = try validatedGitBranchNameArgument("name", in: object)
    let dryRun = try optionalBool("dry_run", in: object) ?? true
    let confirmSwitch = try optionalBool("confirm_switch", in: object) ?? false
    let allowDirty = try optionalBool("allow_dirty", in: object) ?? false
    guard dryRun || confirmSwitch else {
      throw GatewayToolError.invalidArguments(
        "git.branch_switch requires confirm_switch=true when dry_run is false.")
    }

    let timeout = optionalInt("timeout_ms", in: object)
    let command = try gitCLICommand()
    let checkNameArgs = ["check-ref-format", "--branch", branchName]
    let existsArgs = ["show-ref", "--verify", "--quiet", "refs/heads/\(branchName)"]
    let currentBranchArgs = ["branch", "--show-current"]
    let statusArgs = ["status", "--porcelain=v1", "-z"]

    let checkNameResult = try runRegisteredCLI(
      command: command,
      args: checkNameArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    guard !checkNameResult.timedOut, checkNameResult.exitCode == 0 else {
      throw GatewayToolError.invalidArguments(
        "branch name is not accepted by git check-ref-format: \(branchName)")
    }

    let existsResult = try runRegisteredCLI(
      command: command,
      args: existsArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    guard !existsResult.timedOut else {
      throw GatewayToolError.invalidArguments("branch existence check timed out.")
    }
    guard existsResult.exitCode == 0 else {
      if existsResult.exitCode == 1 {
        throw GatewayToolError.invalidArguments("local branch does not exist: \(branchName)")
      }
      throw GatewayToolError.invalidArguments("branch existence check failed for: \(branchName)")
    }

    let currentBranchResult = try runRegisteredCLI(
      command: command,
      args: currentBranchArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    guard !currentBranchResult.timedOut, currentBranchResult.exitCode == 0 else {
      throw GatewayToolError.invalidArguments("current branch check failed.")
    }
    let currentBranch = firstNonEmptyLine(currentBranchResult.stdout) ?? ""

    let statusResult = try runRegisteredCLI(
      command: command,
      args: statusArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    guard !statusResult.timedOut, statusResult.exitCode == 0 else {
      throw GatewayToolError.invalidArguments("working tree status check failed.")
    }
    let changeCount = gitPorcelainZEntryCount(statusResult.stdout)
    let dirty = changeCount > 0
    if !dryRun, dirty, !allowDirty {
      throw GatewayToolError.invalidArguments(
        "git.branch_switch requires allow_dirty=true when the working tree has changes.")
    }

    let switchArgs = ["switch", "--no-guess", branchName]
    let alreadyCurrent = currentBranch == branchName
    var result: JSONValue = .null
    if !dryRun, !alreadyCurrent {
      let switchResult = try runRegisteredCLI(
        command: command,
        args: switchArgs,
        timeout: timeout,
        requireArbitraryArgs: false
      )
      result = switchResult.json
    }

    return .object([
      "operation": .string("git.branch_switch"),
      "provider": .string(command.id),
      "name": .string(branchName),
      "argv": .array(switchArgs.map(JSONValue.string)),
      "dry_run": .bool(dryRun),
      "confirm_switch": .bool(confirmSwitch),
      "allow_dirty": .bool(allowDirty),
      "current_branch": currentBranch.isEmpty ? .null : .string(currentBranch),
      "already_current": .bool(alreadyCurrent),
      "dirty_worktree": .bool(dirty),
      "working_tree_change_count": .integer(Int64(changeCount)),
      "preflight": .object([
        "check_ref_format": gitCommandMetadata(checkNameResult),
        "existing_branch": gitCommandMetadata(existsResult),
        "current_branch": gitCommandMetadata(currentBranchResult),
        "working_tree_status": gitCommandMetadata(statusResult),
      ]),
      "result": result,
      "would_switch": .bool(!alreadyCurrent),
    ])
  }

  internal func gitLog(arguments object: [String: JSONValue]) throws -> JSONValue {
    let limit = optionalInt("limit", in: object) ?? 20
    try validateBoundedPositive(limit, name: "limit", upperBound: 200)
    let paths = try optionalGitPaths(in: object)
    var args = [
      "log",
      "--date=iso-strict",
      "--pretty=format:%H%x09%h%x09%ad%x09%an%x09%s",
      "-n",
      "\(limit)",
    ]
    if !paths.isEmpty {
      args.append("--")
      args.append(contentsOf: paths)
    }
    return try gitResult(
      operation: "git.log",
      arguments: args,
      timeout: optionalInt("timeout_ms", in: object)
    )
  }

  internal func gitCommitFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let revision = try validatedGitRefArgument("revision", in: object)
    let maxResults = optionalInt("max_results", in: object) ?? 200
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 5_000)

    let metadataArgs = [
      "show",
      "-s",
      "--date=iso-strict",
      "--format=%H%x09%h%x09%ad%x09%an%x09%s",
      revision,
    ]
    let filesArgs = [
      "diff-tree",
      "--root",
      "--no-commit-id",
      "--name-status",
      "-M",
      "-r",
      "-z",
      revision,
    ]

    let timeout = optionalInt("timeout_ms", in: object)
    let command = try gitCLICommand()
    let metadataResult = try runRegisteredCLI(
      command: command,
      args: metadataArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    let filesResult = try runRegisteredCLI(
      command: command,
      args: filesArgs,
      timeout: timeout,
      requireArbitraryArgs: false
    )

    let metadata = parseGitCommitMetadataLine(firstNonEmptyLine(metadataResult.stdout) ?? "")
    let files = parseGitCommitFilesZ(filesResult.stdout)
    let returnedFiles = Array(files.prefix(maxResults))
    let rawRecords = files.map(\.rawRecord)
    let returnedRawRecords = Array(rawRecords.prefix(maxResults))
    let resultTruncated =
      files.count > returnedFiles.count || rawRecords.count > returnedRawRecords.count
    let stdoutTruncated = metadataResult.stdoutTruncated || filesResult.stdoutTruncated
    let parseIncomplete = stdoutTruncated || metadata.commit == nil

    return .object([
      "operation": .string("git.commit_files"),
      "provider": .string(command.id),
      "revision": .string(revision),
      "max_results": .integer(Int64(maxResults)),
      "commands": .object([
        "metadata": .array(metadataArgs.map(JSONValue.string)),
        "files": .array(filesArgs.map(JSONValue.string)),
      ]),
      "commit": metadata.json,
      "commit_hash": metadata.commit.map(JSONValue.string) ?? .null,
      "abbreviated_commit": metadata.abbreviatedCommit.map(JSONValue.string) ?? .null,
      "committed_at": metadata.committedAt.map(JSONValue.string) ?? .null,
      "author": metadata.author.map(JSONValue.string) ?? .null,
      "subject": metadata.subject.map(JSONValue.string) ?? .null,
      "file_count": .integer(Int64(files.count)),
      "returned_file_count": .integer(Int64(returnedFiles.count)),
      "raw_record_count": .integer(Int64(rawRecords.count)),
      "returned_raw_record_count": .integer(Int64(returnedRawRecords.count)),
      "result_truncated": .bool(resultTruncated),
      "stdout_truncated": .bool(stdoutTruncated),
      "parse_incomplete": .bool(parseIncomplete),
      "truncated": .bool(resultTruncated || stdoutTruncated),
      "files": .array(returnedFiles.map(\.json)),
      "raw_records": .array(returnedRawRecords.map(JSONValue.string)),
      "results": .object([
        "metadata": gitCommandMetadata(metadataResult),
        "files": gitCommandMetadata(filesResult),
      ]),
    ])
  }

  private func parseGitCommitMetadataLine(_ line: String) -> GitCommitMetadata {
    let parts = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
      .map(String.init)
    guard parts.count == 5 else {
      return GitCommitMetadata(
        commit: nil,
        abbreviatedCommit: nil,
        committedAt: nil,
        author: nil,
        subject: nil,
        rawLine: line
      )
    }
    return GitCommitMetadata(
      commit: parts[0].isEmpty ? nil : parts[0],
      abbreviatedCommit: parts[1].isEmpty ? nil : parts[1],
      committedAt: parts[2].isEmpty ? nil : parts[2],
      author: parts[3].isEmpty ? nil : parts[3],
      subject: parts[4].isEmpty ? nil : parts[4],
      rawLine: line
    )
  }

  private func parseGitCommitFilesZ(_ stdout: String) -> [GitCommitFileChange] {
    let records = stdout.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
    var files: [GitCommitFileChange] = []
    var index = 0
    while index < records.count {
      let status = records[index]
      guard !status.isEmpty else {
        index += 1
        continue
      }
      if status.hasPrefix("R") || status.hasPrefix("C") {
        guard index + 2 < records.count else {
          break
        }
        let oldPath = records[index + 1]
        let newPath = records[index + 2]
        files.append(
          GitCommitFileChange(
            status: status,
            kind: gitCommitFileKind(status),
            path: newPath,
            oldPath: oldPath,
            score: gitCommitFileScore(status),
            rawRecord: [status, oldPath, newPath].joined(separator: "\t")
          ))
        index += 3
      } else {
        guard index + 1 < records.count else {
          break
        }
        let path = records[index + 1]
        files.append(
          GitCommitFileChange(
            status: status,
            kind: gitCommitFileKind(status),
            path: path,
            oldPath: nil,
            score: nil,
            rawRecord: [status, path].joined(separator: "\t")
          ))
        index += 2
      }
    }
    return files
  }

  private func gitCommitFileKind(_ status: String) -> String {
    guard let first = status.first else {
      return "unknown"
    }
    switch first {
    case "A":
      return "added"
    case "M":
      return "modified"
    case "D":
      return "deleted"
    case "R":
      return "renamed"
    case "C":
      return "copied"
    case "T":
      return "type_changed"
    case "U":
      return "unmerged"
    case "X":
      return "unknown"
    case "B":
      return "pairing_broken"
    default:
      return "other"
    }
  }

  private func gitCommitFileScore(_ status: String) -> Int? {
    guard status.count > 1 else {
      return nil
    }
    return Int(status.dropFirst())
  }

  internal func gitShow(arguments object: [String: JSONValue]) throws -> JSONValue {
    let revision = try optionalString("revision", in: object) ?? "HEAD"
    let stat = try optionalBool("stat", in: object) ?? false
    let patch = try optionalBool("patch", in: object) ?? false
    let paths = try optionalGitPaths(in: object)
    let contextLines = optionalInt("context_lines", in: object)
    if let contextLines {
      try validateBoundedNonNegative(contextLines, name: "context_lines", upperBound: 100)
    }

    var args = ["show", "--date=iso-strict"]
    if stat {
      args.append("--stat")
    }
    if !patch && !stat {
      args.append("--no-patch")
    }
    if let contextLines, patch {
      args.append("-U\(contextLines)")
    }
    args.append(revision)
    if !paths.isEmpty {
      args.append("--")
      args.append(contentsOf: paths)
    }
    return try gitResult(
      operation: "git.show",
      arguments: args,
      timeout: optionalInt("timeout_ms", in: object)
    )
  }

  internal func gitAdd(arguments object: [String: JSONValue]) throws -> JSONValue {
    let paths = try optionalGitPaths(in: object)
    guard !paths.isEmpty else {
      throw GatewayToolError.invalidArguments("git.add requires at least one path.")
    }
    let dryRun = try optionalBool("dry_run", in: object) ?? false
    var args = ["add"]
    if dryRun {
      args.append("--dry-run")
    }
    if try optionalBool("intent_to_add", in: object) ?? false {
      args.append("--intent-to-add")
    }
    args.append("--")
    args.append(contentsOf: paths)
    return try gitResult(
      operation: "git.add",
      arguments: args,
      timeout: optionalInt("timeout_ms", in: object),
      extra: ["dry_run": .bool(dryRun)]
    )
  }

  internal func gitUnstage(arguments object: [String: JSONValue]) throws -> JSONValue {
    let paths = try optionalGitPaths(in: object)
    guard !paths.isEmpty else {
      throw GatewayToolError.invalidArguments("git.unstage requires at least one path.")
    }
    let dryRun = try optionalBool("dry_run", in: object) ?? false
    var args = dryRun ? ["diff", "--cached", "--name-only", "--"] : ["restore", "--staged", "--"]
    args.append(contentsOf: paths)
    return try gitResult(
      operation: "git.unstage",
      arguments: args,
      timeout: optionalInt("timeout_ms", in: object),
      extra: ["dry_run": .bool(dryRun)]
    )
  }

  internal func gitRestoreWorktree(arguments object: [String: JSONValue]) throws -> JSONValue {
    let paths = try optionalGitPaths(in: object)
    guard !paths.isEmpty else {
      throw GatewayToolError.invalidArguments("git.restore_worktree requires at least one path.")
    }

    let dryRun = try optionalBool("dry_run", in: object) ?? true
    let confirmDiscard = try optionalBool("confirm_discard", in: object) ?? false
    guard dryRun || confirmDiscard else {
      throw GatewayToolError.invalidArguments(
        "git.restore_worktree requires confirm_discard=true when dry_run is false.")
    }

    var args = dryRun ? ["diff", "--name-only", "--"] : ["restore", "--worktree", "--"]
    args.append(contentsOf: paths)
    return try gitResult(
      operation: "git.restore_worktree",
      arguments: args,
      timeout: optionalInt("timeout_ms", in: object),
      extra: [
        "confirm_discard": .bool(confirmDiscard),
        "dry_run": .bool(dryRun),
      ]
    )
  }

  internal func gitCommit(arguments object: [String: JSONValue]) throws -> JSONValue {
    let message = try requiredString("message", in: object)
    guard message.count <= 10_000 else {
      throw GatewayToolError.invalidArguments("message must be 10000 characters or fewer.")
    }
    var args = ["commit", "-m", message]
    let dryRun = try optionalBool("dry_run", in: object) ?? false
    if dryRun {
      args.insert("--dry-run", at: 1)
    }
    if try optionalBool("all", in: object) ?? false {
      args.append("--all")
    }
    if try optionalBool("allow_empty", in: object) ?? false {
      args.append("--allow-empty")
    }
    return try gitResult(
      operation: "git.commit",
      arguments: args,
      timeout: optionalInt("timeout_ms", in: object),
      extra: ["dry_run": .bool(dryRun)]
    )
  }

  private func gitResult(
    operation: String,
    arguments: [String],
    timeout: Int?,
    extra: [String: JSONValue] = [:]
  ) throws -> JSONValue {
    let command = try gitCLICommand()
    let result = try runRegisteredCLI(
      command: command,
      args: arguments,
      timeout: timeout,
      requireArbitraryArgs: false
    )
    var payload: [String: JSONValue] = [
      "operation": .string(operation),
      "provider": .string(command.id),
      "argv": .array(arguments.map { .string($0) }),
      "result": result.json,
    ]
    for (key, value) in extra {
      payload[key] = value
    }
    return .object(payload)
  }

  private func gitCommandMetadata(_ result: CommandResult) -> JSONValue {
    .object([
      "executable": .string(result.executable),
      "arguments": .array(result.arguments.map(JSONValue.string)),
      "exit_code": result.exitCode.map { .integer(Int64($0)) } ?? .null,
      "timed_out": .bool(result.timedOut),
      "stderr": .string(result.stderr),
      "stdout_bytes": .integer(Int64(result.stdout.utf8.count)),
      "stdout_truncated": .bool(result.stdoutTruncated),
      "stderr_truncated": .bool(result.stderrTruncated),
    ])
  }

  internal func gitCLICommand() throws -> CLICommandConfig {
    guard let command = configuration.cli.commands.first(where: { $0.id == "git" }) else {
      throw GatewayToolError.disabled(
        "git.* tools require a registered CLI provider with id 'git'.")
    }
    return command
  }

  internal func optionalGitPaths(in object: [String: JSONValue]) throws -> [String] {
    let paths = try optionalStringArray("paths", in: object)
    for path in paths {
      guard !path.isEmpty else {
        throw GatewayToolError.invalidArguments("paths must not contain empty strings.")
      }
      guard !path.hasPrefix("/") else {
        throw GatewayToolError.invalidArguments("paths must be workspace-relative: \(path)")
      }
      guard !path.hasPrefix(":("), !path.hasPrefix(":/") else {
        throw GatewayToolError.invalidArguments("git pathspec magic is not supported: \(path)")
      }
      let components = path.split(separator: "/", omittingEmptySubsequences: false)
      guard !components.contains("..") else {
        throw GatewayToolError.invalidArguments("paths must not escape workspace: \(path)")
      }
    }
    return paths
  }
}

private struct GitDiffNumstatFile {
  var path: String
  var oldPath: String?
  var additions: Int?
  var deletions: Int?
  var binary: Bool

  var json: JSONValue {
    .object([
      "path": .string(path),
      "workspace_relative_path": .string(path),
      "old_path": oldPath.map(JSONValue.string) ?? .null,
      "old_workspace_relative_path": oldPath.map(JSONValue.string) ?? .null,
      "additions": additions.map { .integer(Int64($0)) } ?? .null,
      "deletions": deletions.map { .integer(Int64($0)) } ?? .null,
      "binary": .bool(binary),
    ])
  }
}

private struct GitConfigEntry {
  var scope: String
  var origin: String
  var key: String?
  var value: String?
  var valueIncluded: Bool
  var valueRedacted: Bool
  var rawRecord: String?

  var json: JSONValue {
    .object([
      "scope": .string(scope),
      "origin": .string(origin),
      "key": key.map(JSONValue.string) ?? .null,
      "value": value.map(JSONValue.string) ?? .null,
      "value_included": .bool(valueIncluded),
      "value_redacted": .bool(valueRedacted),
      "raw_record": rawRecord.map(JSONValue.string) ?? .null,
    ])
  }
}

private struct GitDiffSummaryItem {
  var kind: String
  var path: String?
  var oldPath: String?
  var newPath: String?
  var oldMode: String?
  var newMode: String?
  var mode: String?
  var similarity: Int?
  var rawLine: String

  var json: JSONValue {
    .object([
      "kind": .string(kind),
      "path": path.map(JSONValue.string) ?? .null,
      "workspace_relative_path": path.map(JSONValue.string) ?? .null,
      "old_path": oldPath.map(JSONValue.string) ?? .null,
      "new_path": newPath.map(JSONValue.string) ?? .null,
      "old_mode": oldMode.map(JSONValue.string) ?? .null,
      "new_mode": newMode.map(JSONValue.string) ?? .null,
      "mode": mode.map(JSONValue.string) ?? .null,
      "similarity": similarity.map { .integer(Int64($0)) } ?? .null,
      "raw_line": .string(rawLine),
    ])
  }
}

private struct GitDiffCheckIssue {
  var path: String
  var line: Int
  var message: String
  var rawLine: String

  var json: JSONValue {
    .object([
      "path": .string(path),
      "workspace_relative_path": .string(path),
      "line": .integer(Int64(line)),
      "message": .string(message),
      "raw_line": .string(rawLine),
    ])
  }
}

private struct GitFileHistoryEntry {
  var commit: String?
  var abbreviatedCommit: String?
  var committedAt: String?
  var author: String?
  var subject: String?
  var rawLine: String

  var json: JSONValue {
    .object([
      "commit": commit.map(JSONValue.string) ?? .null,
      "abbreviated_commit": abbreviatedCommit.map(JSONValue.string) ?? .null,
      "committed_at": committedAt.map(JSONValue.string) ?? .null,
      "author": author.map(JSONValue.string) ?? .null,
      "subject": subject.map(JSONValue.string) ?? .null,
      "raw_line": .string(rawLine),
    ])
  }
}

private struct GitGrepMatch {
  var path: String
  var line: Int
  var text: String
  var rawRecord: String

  var json: JSONValue {
    .object([
      "path": .string(path),
      "workspace_relative_path": .string(path),
      "line": .integer(Int64(line)),
      "text": .string(text),
      "raw_record": .string(rawRecord),
      "read_context": .object([
        "tool": .string("file.read_lines"),
        "path": .string(path),
        "start_line": .integer(Int64(max(1, line - 5))),
        "line_count": .number(11),
      ]),
    ])
  }
}

private struct GitCommitMetadata {
  var commit: String?
  var abbreviatedCommit: String?
  var committedAt: String?
  var author: String?
  var subject: String?
  var rawLine: String

  var json: JSONValue {
    .object([
      "commit": commit.map(JSONValue.string) ?? .null,
      "abbreviated_commit": abbreviatedCommit.map(JSONValue.string) ?? .null,
      "committed_at": committedAt.map(JSONValue.string) ?? .null,
      "author": author.map(JSONValue.string) ?? .null,
      "subject": subject.map(JSONValue.string) ?? .null,
      "raw_line": .string(rawLine),
    ])
  }
}

private struct GitCommitFileChange {
  var status: String
  var kind: String
  var path: String
  var oldPath: String?
  var score: Int?
  var rawRecord: String

  var json: JSONValue {
    .object([
      "status": .string(status),
      "kind": .string(kind),
      "path": .string(path),
      "workspace_relative_path": .string(path),
      "old_path": oldPath.map(JSONValue.string) ?? .null,
      "old_workspace_relative_path": oldPath.map(JSONValue.string) ?? .null,
      "score": score.map { .integer(Int64($0)) } ?? .null,
      "raw_record": .string(rawRecord),
    ])
  }
}

private struct GitCleanPreviewItem {
  var action: String
  var path: String?
  var directory: Bool
  var rawLine: String

  var json: JSONValue {
    .object([
      "action": .string(action),
      "path": path.map(JSONValue.string) ?? .null,
      "workspace_relative_path": path.map(JSONValue.string) ?? .null,
      "directory": .bool(directory),
      "raw_line": .string(rawLine),
    ])
  }
}

private struct GitReflogEntry {
  var commit: String?
  var abbreviatedCommit: String?
  var selector: String?
  var action: String?
  var message: String?
  var committedAt: String?
  var rawLine: String

  var json: JSONValue {
    .object([
      "commit": commit.map(JSONValue.string) ?? .null,
      "abbreviated_commit": abbreviatedCommit.map(JSONValue.string) ?? .null,
      "selector": selector.map(JSONValue.string) ?? .null,
      "action": action.map(JSONValue.string) ?? .null,
      "message": message.map(JSONValue.string) ?? .null,
      "committed_at": committedAt.map(JSONValue.string) ?? .null,
      "raw_line": .string(rawLine),
    ])
  }
}

private struct GitRefInfo {
  var kind: String
  var refname: String?
  var shortName: String?
  var object: String?
  var abbreviatedObject: String?
  var objectType: String?
  var committerDate: String?
  var subject: String?
  var rawLine: String

  var json: JSONValue {
    .object([
      "kind": .string(kind),
      "refname": refname.map(JSONValue.string) ?? .null,
      "short_name": shortName.map(JSONValue.string) ?? .null,
      "object": object.map(JSONValue.string) ?? .null,
      "abbreviated_object": abbreviatedObject.map(JSONValue.string) ?? .null,
      "object_type": objectType.map(JSONValue.string) ?? .null,
      "committer_date": committerDate.map(JSONValue.string) ?? .null,
      "subject": subject.map(JSONValue.string) ?? .null,
      "raw_line": .string(rawLine),
    ])
  }
}

private struct GitCompareCounts {
  var baseOnly: Int
  var headOnly: Int

  var json: JSONValue {
    .object([
      "base_only": .integer(Int64(baseOnly)),
      "head_only": .integer(Int64(headOnly)),
      "head_ahead": .integer(Int64(headOnly)),
      "head_behind": .integer(Int64(baseOnly)),
    ])
  }
}

private struct GitCompareCommit {
  var side: String?
  var refSide: String
  var commit: String?
  var abbreviatedCommit: String?
  var committedAt: String?
  var author: String?
  var subject: String?
  var rawLine: String

  var json: JSONValue {
    .object([
      "side": side.map(JSONValue.string) ?? .null,
      "ref_side": .string(refSide),
      "commit": commit.map(JSONValue.string) ?? .null,
      "abbreviated_commit": abbreviatedCommit.map(JSONValue.string) ?? .null,
      "committed_at": committedAt.map(JSONValue.string) ?? .null,
      "author": author.map(JSONValue.string) ?? .null,
      "subject": subject.map(JSONValue.string) ?? .null,
      "raw_line": .string(rawLine),
    ])
  }
}

private struct GitTrackingStatusInfo {
  var branch: String?
  var upstream: String?
  var ahead: Int?
  var behind: Int?
  var flags: [String]
  var detached: Bool
  var unborn: Bool
  var rawBranchLine: String

  var hasUpstream: Bool {
    upstream != nil
  }

  var state: String {
    if detached {
      return "detached"
    }
    if unborn {
      return "unborn"
    }
    if flags.contains("gone") {
      return "gone"
    }
    guard hasUpstream else {
      return "no_upstream"
    }
    let aheadValue = ahead ?? 0
    let behindValue = behind ?? 0
    if aheadValue > 0 && behindValue > 0 {
      return "diverged"
    }
    if aheadValue > 0 {
      return "ahead"
    }
    if behindValue > 0 {
      return "behind"
    }
    return "up_to_date"
  }

  var json: JSONValue {
    .object([
      "branch": branch.map(JSONValue.string) ?? .null,
      "upstream": upstream.map(JSONValue.string) ?? .null,
      "has_upstream": .bool(hasUpstream),
      "ahead": ahead.map { .integer(Int64($0)) } ?? .null,
      "behind": behind.map { .integer(Int64($0)) } ?? .null,
      "flags": .array(flags.map(JSONValue.string)),
      "detached": .bool(detached),
      "unborn": .bool(unborn),
      "state": .string(state),
      "raw_branch_line": .string(rawBranchLine),
    ])
  }
}
