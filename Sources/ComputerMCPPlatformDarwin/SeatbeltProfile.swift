// Port-restricted network rules adapted from anthropics/sandbox-runtime, Apache-2.0.
// Revision aceba124fd725f4a43d7016ed3f5651d61f83115, src/sandbox/macos-sandbox-utils.ts.
// Modified for TCP-only per-execution listeners and host-supplied read boundaries.
// See THIRD_PARTY_NOTICES.md and Licenses/sandbox-runtime-Apache-2.0.txt.
import ComputerMCPSandbox
import Foundation

package enum SeatbeltProfile {
  package static func generate(_ configuration: SandboxConfiguration) -> String {
    generate(configuration, marker: nil)
  }

  static func generate(_ configuration: SandboxConfiguration, marker: ExecutionSandboxMarker?)
    -> String
  {
    var rules = [
      "(version 1)", "(deny default)", "(allow process-exec)", "(allow process-fork)",
      "(allow process-info* (target same-sandbox))", "(allow signal (target same-sandbox))",
      "(deny process-info* (require-not (target same-sandbox)))",
      "(deny mach-priv-task-port (require-not (target same-sandbox)))",
      "(allow file-write-data (literal \"/dev/null\"))",
      "(allow file-read-metadata (literal \"/etc\") (literal \"/tmp\") (literal \"/var\"))",
    ]
    // Hardware and toolchain queries exclude process arguments and environments.
    for name in [
      "hw.activecpu", "hw.byteorder", "hw.cachelinesize", "hw.cpufamily", "hw.cputype",
      "hw.logicalcpu", "hw.logicalcpu_max", "hw.machine", "hw.memsize", "hw.ncpu", "hw.pagesize",
      "hw.pagesize_compat",
      "hw.physicalcpu", "hw.physicalcpu_max", "kern.argmax", "kern.maxfilesperproc",
      "kern.osproductversion",
      "kern.osrelease", "kern.ostype", "kern.osversion", "kern.version", "kern.hostname",
      "kern.usrstack64", "kern.iossupportversion", "machdep.cpu.brand_string",
    ] {
      rules.append("(allow sysctl-read (sysctl-name \(quote(name))))")
    }
    rules.append(
      "(allow sysctl-read (sysctl-name-prefix \"hw.optional.\") (sysctl-name-prefix \"hw.perflevel\"))"
    )
    let exclusions =
      configuration.deniedReadRegions.map { region -> String in
        let exceptions = region.exceptions.map(subpath)
        return all([subpath(region.path)] + exceptions.map { "(require-not \($0))" })
      } + configuration.forbiddenReads.map(subpath)
    let reads =
      configuration.readableRoots + configuration.writableDirectories
      + (configuration.git.map {
        [$0.sharedDirectory, $0.administrativeDirectory, $0.privateObjects]
      } ?? [])
    for path in Set(reads).sorted(by: { $0.value < $1.value }) {
      rules.append(
        "(allow file-read* \(all([subpath(path)] + exclusions.map { "(require-not \($0))" })))")
    }
    for path in Set(configuration.listableAncestors).sorted(by: { $0.value < $1.value }) {
      let filter = all(
        ["(literal \(quote(path.value)))", "(vnode-type DIRECTORY)"]
          + configuration.forbiddenReads.map { "(require-not \(subpath($0)))" })
      rules.append("(allow file-read* \(filter))")
    }
    var writeExclusions = configuration.forbiddenReads.map(subpath)
    if let git = configuration.git {
      writeExclusions.append(subpath(git.sharedDirectory))
      writeExclusions.append(subpath(git.administrativeDirectory))
      // A worktree's .git indirection is owned by the host.
      writeExclusions.append("(literal \(quote(configuration.worktree.value + "/.git")))")
    }
    for path in Set(configuration.writableDirectories).sorted(by: { $0.value < $1.value }) {
      rules.append(
        "(allow file-write* \(all([subpath(path)] + writeExclusions.map { "(require-not \($0))" })))"
      )
    }
    if let git = configuration.git {
      let exclusions = configuration.forbiddenReads.map { "(require-not \(subpath($0)))" }
      rules.append("(allow file-write* \(all([subpath(git.privateObjects)] + exclusions)))")
      for relative in [
        "HEAD", "HEAD.lock", "index", "index.lock", "ORIG_HEAD", "ORIG_HEAD.lock", "FETCH_HEAD",
        "FETCH_HEAD.lock", "logs/HEAD", "logs/HEAD.lock",
      ] {
        rules.append(
          "(allow file-write* \(all(["(literal \(quote(git.administrativeDirectory.value + "/" + relative)))"] + exclusions)))"
        )
      }
      for relative in ["rebase-merge", "rebase-apply"] {
        rules.append(
          "(allow file-write* \(all(["(subpath \(quote(git.administrativeDirectory.value + "/" + relative)))"] + exclusions)))"
        )
      }
    }
    if let proxy = configuration.proxy {
      for port in Set([proxy.http, proxy.socks]).sorted() {
        rules.append("(allow network-outbound (remote tcp \"localhost:\(port)\"))")
      }
    }
    if configuration.services.screenCapture {
      rules.append(
        "(allow mach-lookup (global-name \"com.apple.windowserver.active\") (global-name \"com.apple.replayd\"))"
      )
    }
    if configuration.services.accessibility {
      rules.append(
        "(allow mach-lookup (global-name \"com.apple.axserver\") (global-name \"com.apple.axregistrar\") (global-name \"com.apple.windowserver.active\"))"
      )
    }
    if configuration.services.appleEvents {
      // This switch represents the principal's Desktop control grant. That grant
      // covers the whole desktop, including other apps; Apple events are not confined to
      // the execution's filesystem sandbox. Without it, deny-default blocks Apple events.
      rules.append("(allow appleevent-send)")
      rules.append("(allow mach-lookup (global-name \"com.apple.coreservices.appleevents\"))")
    }
    if let marker {
      rules.append(
        "(deny file-read* (require-all \(subpath(marker.directory)) (require-not (literal \(quote(marker.own.value))))))"
      )
      rules.append("(deny file-write* \(subpath(marker.directory)))")
      rules.append("(allow file-read-data (literal \(quote(marker.own.value))))")
    }
    return rules.joined(separator: "\n") + "\n"
  }

  private static func subpath(_ path: SandboxPath) -> String { "(subpath \(quote(path.value)))" }
  private static func all(_ filters: [String]) -> String {
    filters.count == 1 ? filters[0] : "(require-all \(filters.joined(separator: " ")))"
  }
  private static func quote(_ value: String) -> String {
    "\""
      + value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"") + "\""
  }
}
