import Foundation

/// Owns one bounded discovery snapshot. Searches and release choices never enumerate GitHub.
actor StaticPluginCatalog: PluginCatalogBrowsing {
  static let refreshInterval: TimeInterval = 600
  static let manualRefreshInterval: TimeInterval = 30
  private let http: any StaticPluginCatalogFetching
  private let cache: StaticPluginCatalogCache?
  private let now: @Sendable () -> Date
  private var current: Value?
  private var didReadCache = false
  private var failures = 0
  private var retryAt = Date.distantPast
  private var lastIssue: PluginCatalogError?
  private var cacheIssue = false
  private var pending: (id: UUID, task: Task<Attempt, Never>)?

  struct Filter: Sendable {
    var host: PluginVersion
    var architecture: String
    var platform = "macos"
    var includePrereleases = false
    var includeIncompatible = false
  }

  struct Value: Sendable {
    let record: StaticPluginCatalogCacheRecord
    let document: StaticPluginCatalogDocument
  }

  struct Snapshot: Sendable {
    let value: Value
    let cached: Bool
    let status: PluginCatalogStatus
    let issues: [PluginCatalogIssue]
  }

  private struct Attempt: Sendable {
    let value: Value?
    let error: PluginCatalogError?
    let cacheIssue: Bool
    let requested: Bool
    let retryAt: Date
  }

  init(
    cacheURL: URL? = nil,
    http: any StaticPluginCatalogFetching = StaticPluginCatalogHTTP(),
    now: @escaping @Sendable () -> Date = { .now }
  ) {
    self.http = http
    cache = cacheURL.map { StaticPluginCatalogCache(url: $0) }
    self.now = now
  }

  func search(
    query: String = "", kind: IntegrationKind? = nil, page: Int = 1, refresh: Bool = false
  )
    async throws -> PluginCatalogSearchResult
  {
    try await search(
      query: query, kind: kind, page: page, refresh: refresh,
      filter: Filter(
        host: PluginVersion(ComputerMCPCLI.version), architecture: PluginHost.architecture))
  }

  func search(query: String, kind: IntegrationKind?, page: Int, refresh: Bool, filter: Filter)
    async throws -> PluginCatalogSearchResult
  {
    guard query.utf8.count <= 256, !query.contains("\0"), (1...100_000).contains(page) else {
      throw PluginCatalogError.invalidQuery
    }
    let snapshot = try await load(refresh: refresh)
    let releases = snapshot.value.document.releases.filter {
      !$0.withdrawn && (filter.includePrereleases || !$0.prerelease)
        && (filter.includeIncompatible
          || $0.matches(
            host: filter.host, architecture: filter.architecture, platform: filter.platform))
    }.sorted(by: Self.newer)
    var selected: [String: StaticPluginCatalogDocument.Release] = [:]
    for release in releases where selected[release.pluginID] == nil {
      selected[release.pluginID] = release
    }
    let entries = selected.values.map(\.declaration).filter { $0.matches(query: query, kind: kind) }
      .sorted { $0.pluginID < $1.pluginID }
    let offset = (page - 1) * 10
    let values = Array(entries.dropFirst(offset).prefix(10))
    return PluginCatalogSearchResult(
      publisher: GitHubPluginSource.publisher, publisherID: GitHubPluginSource.publisherID,
      query: query, kind: kind, page: page,
      nextPage: offset + values.count < entries.count ? page + 1 : nil,
      checkedRepositories: Set(snapshot.value.document.releases.map(\.repositoryID)).count,
      fetchedAt: snapshot.value.record.validatedAt, cached: snapshot.cached,
      entries: values, issues: snapshot.issues, catalog: snapshot.status)
  }

  func artifacts(repository: String, repositoryID: Int64, tag: String? = nil, page: Int = 1)
    async throws -> GitHubPluginReleaseArtifacts
  {
    try await artifacts(
      repository: repository, repositoryID: repositoryID, tag: tag, page: page,
      filter: Filter(
        host: PluginVersion(ComputerMCPCLI.version), architecture: PluginHost.architecture))
  }

  func artifacts(repository: String, repositoryID: Int64, tag: String?, page: Int, filter: Filter)
    async throws -> GitHubPluginReleaseArtifacts
  {
    try GitHubPluginSource.Repository.validateName(repository)
    guard GitHubPluginArtifact.validID(repositoryID), (1...1_000).contains(page),
      tag.map({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }) ?? true
    else { throw PluginCatalogError.invalidQuery }
    let snapshot = try await load()
    let releases = snapshot.value.document.releases.filter {
      $0.repositoryID == repositoryID && $0.repository == repository
    }.sorted(by: Self.newer)
    let selected = releases.first {
      if let tag { return $0.tag == tag }
      return !$0.withdrawn && !$0.prerelease
        && $0.matches(
          host: filter.host, architecture: filter.architecture, platform: filter.platform)
    }
    guard let selected else { throw PluginCatalogError.httpStatus(404) }
    let permitted =
      !selected.withdrawn
      && selected.matches(
        host: filter.host, architecture: filter.architecture, platform: filter.platform)
    let assets = permitted ? selected.assets.map { selected.artifact($0) } : []
    let offset = (page - 1) * 10
    let pageAssets = Array(assets.dropFirst(offset).prefix(10))
    var issues = snapshot.issues
    if !permitted {
      issues.append(
        .init(
          repository: repository,
          code: selected.withdrawn ? "plugin.catalog.withdrawn" : "plugin.catalog.incompatible",
          message: selected.withdrawalReason
            ?? "This release is incompatible with the selected host."))
    }
    return GitHubPluginReleaseArtifacts(
      declaration: selected.declaration, releaseID: selected.releaseID, tag: selected.tag,
      prerelease: selected.prerelease, page: page,
      nextPage: offset + pageAssets.count < assets.count ? page + 1 : nil,
      artifacts: pageAssets, issues: issues, catalog: snapshot.status,
      versions: releases.map {
        PluginCatalogReleaseVersion(
          tag: $0.tag, version: $0.version, prerelease: $0.prerelease,
          withdrawn: $0.withdrawn, withdrawalReason: $0.withdrawalReason,
          compatible: $0.matches(
            host: filter.host, architecture: filter.architecture, platform: filter.platform),
          dependencies: $0.dependencies)
      })
  }

  func load(refresh: Bool = false) async throws -> Snapshot {
    try Task.checkCancellation()
    let date = now()
    if pending == nil, didReadCache {
      let age = current.map { date.timeIntervalSince($0.record.validatedAt) }
      let interval = refresh ? Self.manualRefreshInterval : Self.refreshInterval
      if date < retryAt || age.map({ (0..<interval).contains($0) }) == true {
        return try snapshot(cached: true)
      }
    }
    if pending == nil {
      let http = http
      let cache = cache
      let current = current
      let readCache = !didReadCache
      let failures = failures
      let now = now
      pending = (
        UUID(),
        Task {
          await Self.fetch(
            http: http, cache: cache, current: current, readCache: readCache,
            refresh: refresh, failures: failures, now: now)
        }
      )
    }
    let flight = pending!
    let attempt = await flight.task.value
    if pending?.id == flight.id {
      pending = nil
      didReadCache = true
      current = attempt.value
      lastIssue = attempt.error
      cacheIssue = attempt.cacheIssue
      retryAt = attempt.retryAt
      failures = attempt.error == nil ? 0 : min(failures + 1, 7)
    }
    try Task.checkCancellation()
    return try snapshot(cached: !attempt.requested || attempt.error != nil)
  }

  private func snapshot(cached: Bool) throws -> Snapshot {
    guard let current else { throw lastIssue ?? PluginCatalogError.networkUnavailable }
    let age = now().timeIntervalSince(current.record.validatedAt)
    let stale = lastIssue != nil || !(0..<Self.refreshInterval).contains(age)
    var issues: [PluginCatalogIssue] = []
    if let lastIssue {
      issues.append(
        .init(
          repository: GitHubPluginSource.publisher, code: lastIssue.code,
          message:
            "The official catalog could not be refreshed. Previously verified discovery data is shown."
        ))
    }
    if cacheIssue {
      issues.append(
        .init(
          repository: GitHubPluginSource.publisher, code: "plugin.catalog.cache_unavailable",
          message:
            "The catalog cache could not be read or saved. Current results remain available in this process."
        ))
    }
    let document = current.document
    return Snapshot(
      value: current, cached: cached,
      status: PluginCatalogStatus(
        generation: document.generation, revision: document.revision,
        generatedAt: StaticPluginCatalogDocument.timestamp(document.generatedAt)!,
        validatedAt: current.record.validatedAt, stale: stale,
        nextRefreshAt: max(
          retryAt, current.record.validatedAt.addingTimeInterval(Self.refreshInterval))),
      issues: issues)
  }

  private static func fetch(
    http: any StaticPluginCatalogFetching, cache: StaticPluginCatalogCache?,
    current: Value?, readCache: Bool, refresh: Bool, failures: Int, now: @Sendable () -> Date
  ) async -> Attempt {
    var previous = current
    var cacheIssue = false
    if readCache, let cache {
      do {
        if let record = try await cache.read() {
          previous = Value(record: record, document: try record.document())
        }
      } catch { cacheIssue = true }
    }
    let started = now()
    if let previous,
      (0..<(refresh ? manualRefreshInterval : refreshInterval))
        .contains(started.timeIntervalSince(previous.record.validatedAt))
    {
      return Attempt(
        value: previous, error: nil, cacheIssue: cacheIssue, requested: false, retryAt: .distantPast
      )
    }
    do {
      let validators = previous?.record.validators ?? StaticPluginCatalogValidators()
      let response = try await http.fetch(validators: validators)
      let body: Data
      let document: StaticPluginCatalogDocument
      if response.status == 304 {
        guard let previous, validators.etag != nil || validators.lastModified != nil else {
          throw PluginCatalogError.invalidResponse
        }
        body = previous.record.body
        document = previous.document
      } else {
        try response.requireSuccess()
        let mime = response.headers["content-type"]?.split(separator: ";").first?.lowercased()
        guard mime == "application/json" else { throw PluginCatalogError.invalidResponse }
        document = try StaticPluginCatalogDocument.decode(response.body)
        if let previous { try document.validateSuccessor(of: previous.document) }
        body = response.body
      }
      let nextValidators = StaticPluginCatalogValidators(
        etag: response.headers["etag"] ?? (response.status == 304 ? validators.etag : nil),
        lastModified: response.headers["last-modified"]
          ?? (response.status == 304 ? validators.lastModified : nil))
      let record = StaticPluginCatalogCacheRecord(
        body: body, validators: nextValidators, validatedAt: now())
      if let cache {
        do { try await cache.write(record) } catch { cacheIssue = true }
      }
      return Attempt(
        value: Value(record: record, document: document), error: nil,
        cacheIssue: cacheIssue, requested: true, retryAt: .distantPast)
    } catch {
      let failure = Self.failure(error)
      let delay: TimeInterval
      if case .rateLimited(let seconds) = failure {
        delay = max(60, min(86_400, TimeInterval(seconds ?? 60)))
      } else {
        delay = min(3_600, 60 * pow(2, Double(failures)))
      }
      return Attempt(
        value: previous, error: failure, cacheIssue: cacheIssue, requested: true,
        retryAt: now().addingTimeInterval(delay))
    }
  }

  private static func failure(_ error: any Error) -> PluginCatalogError {
    if let error = error as? PluginCatalogError { return error }
    if (error as? URLError)?.code == .timedOut { return .timedOut }
    return .networkUnavailable
  }

  private static func newer(
    _ lhs: StaticPluginCatalogDocument.Release, _ rhs: StaticPluginCatalogDocument.Release
  ) -> Bool {
    if lhs.version.precedes(rhs.version) { return false }
    if rhs.version.precedes(lhs.version) { return true }
    return lhs.releaseID > rhs.releaseID
  }

  deinit { pending?.task.cancel() }
}
