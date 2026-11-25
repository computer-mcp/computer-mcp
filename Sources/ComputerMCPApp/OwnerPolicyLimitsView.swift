import ComputerMCPControlPlane
import ComputerMCPCore
import ComputerMCPGateway
import ComputerMCPPermissions
import SwiftUI

struct OwnerPolicyLimitsView: View {
  @Environment(\.locale) private var locale
  @Environment(\.localizationResources) private var resources
  private var l: PrivacyText { .init(locale: locale, resources: resources) }

  let snapshot: GatewayOwnerPolicySnapshot
  @State private var caller: GatewayCallerKind?
  @State private var background = false

  var body: some View {
    let context = snapshot.limits.first { $0.caller == caller } ?? snapshot.limits.first
    Section(l("Current Saved Policy")) {
      if snapshot.limits.count > 1 {
        Picker(
          l("Caller"),
          selection: Binding(
            get: { context?.caller }, set: { caller = $0 })
        ) {
          ForEach(snapshot.limits.compactMap(\.caller), id: \.self) {
            Text(verbatim: l(callerName($0))).tag(Optional($0))
          }
        }
        .accessibilityIdentifier("privacy.ownerPolicy.caller")
      }
      switch context?.savedOwner {
      case .some(.available(let policy)):
        savedRules(policy)
      case .some(.unreadable):
        Text(verbatim: l("The saved policy has no readable limits."))
          .foregroundStyle(.secondary)
      case .some(.absent), nil:
        Text(
          verbatim: l(
            snapshot.savedText == nil
              ? "No policy is saved for this owner." : "This profile has no allowed callers.")
        )
        .foregroundStyle(.secondary)
      }
    }
    .accessibilityIdentifier("privacy.ownerPolicy.savedPolicySection")

    if let context {
      Section {
        effectiveRules(context)
        ForEach(snapshot.readOnlySources, id: \.source) { source in
          let details = LivePrivacySecurityService.source(source)
          DisclosureGroup {
            PolicySourceDetails(source: details)
          } label: {
            LabeledContent {
              PolicySourceStatusText(state: details.state)
            } label: {
              Text(verbatim: l(details.name))
            }
          }
        }
      } header: {
        Text(verbatim: l("Effective Limits"))
      } footer: {
        Text(
          verbatim: l(
            "These ceilings combine the applicable policy sources. Grants and individual connections can restrict access further."
          ))
      }
      .accessibilityIdentifier("privacy.ownerPolicy.effectiveLimitsSection")
    }
  }

  @ViewBuilder
  private func savedRules(_ policy: ManagedPolicy) -> some View {
    let permissions = policy.permissionCeilings.entries
    if permissions.isEmpty, policy.allowsFullAccess, policy.network.configuration == .full,
      policy.deniedReadLocations.isEmpty, policy.executionLimits == .none
    {
      Text(verbatim: l("The saved policy sets no limits for this context."))
        .foregroundStyle(.secondary)
    } else {
      ForEach(ordered(Set(permissions.keys)), id: \.self) { permission in
        limit(
          heading(permission),
          l(
            LivePrivacySecurityService.value(
              policy.permissionCeilings.state(for: permission)
            ).title))
      }
      if !policy.allowsFullAccess { limit(l("Full Access"), l("Don't Allow")) }
      if policy.network.configuration != .full {
        limit(l("Outbound Network"), network(policy.network.configuration))
      }
      if !policy.deniedReadLocations.isEmpty {
        limit(
          l("Blocked Read Locations"), l.list(policy.deniedReadLocations.map(\.string).sorted()))
      }
      ForEach(dimensions, id: \.title) { dimension in
        if let value = policy.executionLimits[keyPath: dimension.path] {
          limit(l(dimension.title), measure(value, unit: dimension.unit))
        }
      }
    }
  }

  @ViewBuilder
  private func effectiveRules(_ context: GatewayOwnerPolicySnapshot.Limits) -> some View {
    let limits = context.effective
    let unavailable = Set(
      limits.sources.compactMap { source, availability in
        availability == .unreadable ? source : nil
      })
    let sources = limits.sources.compactMapValues { availability -> ManagedPolicy? in
      if case .available(let policy) = availability { return policy }
      return nil
    }
    if !unavailable.isEmpty {
      limit(l("Access Blocked"), l("An applicable policy source can't be read."), from: unavailable)
    } else {
      let permissions = Set(sources.values.flatMap { $0.permissionCeilings.entries.keys })
      ForEach(ordered(permissions), id: \.self) { permission in
        if let (kind, object) = LivePrivacySecurityService.classify(permission, names: .init()) {
          let denied = kind.grantedValues.compactMap {
            level -> (PrivacyGrantValue.Level, Set<PolicySource>)? in
            guard case .granted(let value) = LivePrivacySecurityService.state(.granted(level))
            else { return nil }
            return (
              level,
              restrictions(
                in: limits, permission: permission, value: value, fallback: object?.id == "*")
            )
          }
          let maximum = denied.last { $0.1.isEmpty }?.0
          let contributors = denied.reduce(into: Set<PolicySource>()) { $0.formUnion($1.1) }
          limit(heading(permission), l(maximum?.title ?? "Don't Allow"), from: contributors)
        }
      }

      let fullAccess = Set(sources.compactMap { $0.value.allowsFullAccess ? nil : $0.key })
      limit(
        l("Full Access"), l(fullAccess.isEmpty ? "No Policy Ceiling" : "Don't Allow"),
        from: fullAccess)
      let outbound = limits.network(applying: .full, trustedHosts: snapshot.trustedHosts)
      let networkSources = Set(
        sources.compactMap {
          $0.value.network.configuration == .full ? nil : $0.key
        })
      limit(l("Outbound Network"), network(outbound), from: networkSources)
      let paths = Set(sources.values.flatMap(\.deniedReadLocations))
      ForEach(paths.map(\.string).sorted(), id: \.self) { path in
        if let canonical = try? CanonicalPath(path) {
          limit(l("Blocked Read Location"), path, from: limits.denying(canonical))
        }
      }

      Picker(l("Execution Context"), selection: $background) {
        Text(verbatim: l("Foreground")).tag(false)
        Text(verbatim: l("Background")).tag(true)
      }
      .accessibilityIdentifier("privacy.ownerPolicy.executionContext")
      if let effective = try? context.executionLimits(for: background ? .background : .foreground) {
        let values: [Int64?] = [
          effective.timeMilliseconds, effective.outputBytes, effective.memoryBytes,
          effective.retentionSeconds, effective.retainedOutputBytes,
        ]
        ForEach(Array(zip(dimensions, values)), id: \.0.title) { dimension, value in
          let applied = Set(
            effective.sources.compactMap { source, ceilings in
              ceilings[keyPath: dimension.path] == value && value != nil ? source : nil
            })
          limit(
            l(dimension.title), value.map { measure($0, unit: dimension.unit) } ?? l("Unbounded"),
            from: applied, defaultSource: applied.isEmpty)
        }
      }
    }
  }

  private func restrictions(
    in limits: ManagedLimits, permission: Permission, value: PermissionValue, fallback: Bool
  ) -> Set<PolicySource> {
    if fallback { return limits.restrictingSources(forDefault: permission, value: value) }
    guard let requirement = try? PermissionRequirement(permission, value) else { return [] }
    return limits.restrictingSources(for: requirement)
  }

  private var dimensions:
    [(title: String, path: KeyPath<ExecutionLimitCeilings, Int64?>, unit: String)]
  {
    [
      ("Execution Time", \.timeMilliseconds, "%@ ms"),
      ("Output", \.outputBytes, "%@ bytes"),
      ("Memory", \.memoryBytes, "%@ bytes"),
      ("Retention", \.retentionSeconds, "%@ seconds"),
      ("Retained Output", \.retainedOutputBytes, "%@ bytes"),
    ]
  }

  private func measure(_ value: Int64, unit: String) -> String {
    l.format(unit, value.formatted(.number.locale(locale)))
  }

  private func heading(_ permission: Permission) -> String {
    guard let (kind, object) = LivePrivacySecurityService.classify(permission, names: .init())
    else {
      return String(describing: permission)
    }
    return object.map { l.format("%@ · %@", l(kind.title), l($0.name)) } ?? l(kind.title)
  }

  private func ordered(_ permissions: Set<Permission>) -> [Permission] {
    permissions.sorted {
      (heading($0), String(describing: $0)) < (heading($1), String(describing: $1))
    }
  }

  private func network(_ config: NetworkAccess.Configuration) -> String {
    switch config {
    case .none: l("Don't Allow")
    case .full: l("No Policy Ceiling")
    case .trusted: l("Trusted Hosts")
    case .custom(let hosts, let trusted):
      l.list(hosts.sorted() + (trusted ? [l("Trusted Hosts")] : []))
    }
  }

  private func callerName(_ caller: GatewayCallerKind) -> String {
    switch caller {
    case .secureTunnel: "Secure Tunnel"
    case .cloudflareTunnel: "Cloudflare Tunnel"
    case .localApp: "Computer MCP App"
    case .localCLI: "Local CLI"
    case .localMCP: "Local MCP"
    }
  }

  private func limit(
    _ title: String, _ value: String, from sources: Set<PolicySource> = [],
    defaultSource: Bool = false
  ) -> some View {
    LabeledContent {
      VStack(alignment: .trailing, spacing: 3) {
        Text(verbatim: value)
          .monospacedDigit()
          .multilineTextAlignment(.trailing)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        if !sources.isEmpty || defaultSource {
          let names = sources.map { l(LivePrivacySecurityService.sourceName($0)) }.sorted()
          let source = l.format("Source: %@", defaultSource ? l("Host Default") : l.list(names))
          Text(verbatim: source)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
        }
      }
    } label: {
      Text(verbatim: title)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}
