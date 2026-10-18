import Darwin
import Foundation

extension GatewayToolRegistry {
  internal func networkInterfaces(arguments object: [String: JSONValue]) throws -> JSONValue {
    let interface = try optionalString("interface", in: object)
    let timeout = optionalInt("timeout_ms", in: object) ?? 10_000
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)

    let arguments: [String]
    if let interface {
      try validateNetworkInterfaceName(interface)
      arguments = [interface]
    } else {
      arguments = ["-a"]
    }

    let result = try commandRunner.run(
      executable: "/sbin/ifconfig",
      arguments: arguments,
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: configuration.policy.maxOutputBytes
    )

    return .object([
      "operation": .string("network.interfaces"),
      "interface": interface.map(JSONValue.string) ?? .null,
      "result": result.json,
    ])
  }

  internal func networkDNS(arguments object: [String: JSONValue]) throws -> JSONValue {
    let timeout = optionalInt("timeout_ms", in: object) ?? 10_000
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)

    let result = try commandRunner.run(
      executable: "/usr/sbin/scutil",
      arguments: ["--dns"],
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: configuration.policy.maxOutputBytes
    )

    return .object([
      "operation": .string("network.dns"),
      "result": result.json,
    ])
  }

  internal func networkResolve(arguments object: [String: JSONValue]) throws -> JSONValue {
    let host = try requiredString("host", in: object)
    let family = try optionalString("family", in: object) ?? "any"
    let maxResults = optionalInt("max_results", in: object) ?? 50
    try validateNetworkHost(host)
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 1_000)

    var hints = addrinfo()
    hints.ai_family = try addressFamilyValue(family)
    hints.ai_socktype = SOCK_STREAM
    hints.ai_protocol = 0

    var result: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, nil, &hints, &result)
    guard status == 0 else {
      return .object([
        "operation": .string("network.resolve"),
        "source": .string("getaddrinfo"),
        "host": .string(host),
        "family": .string(family),
        "resolved": .bool(false),
        "error_code": .integer(Int64(status)),
        "error": .string(String(cString: gai_strerror(status))),
        "result_count": .number(0),
        "truncated": .bool(false),
        "addresses": .array([]),
      ])
    }
    defer {
      if let result {
        freeaddrinfo(result)
      }
    }

    var addresses: [JSONValue] = []
    var scannedCount = 0
    var current = result
    while let pointer = current {
      scannedCount += 1
      if addresses.count < maxResults, let address = numericHostAddress(pointer) {
        addresses.append(
          .object([
            "address": .string(address),
            "family": .string(addressFamilyName(pointer.pointee.ai_family)),
            "socket_type": .string(socketTypeName(pointer.pointee.ai_socktype)),
            "protocol": .integer(Int64(pointer.pointee.ai_protocol)),
            "flags": .integer(Int64(pointer.pointee.ai_flags)),
          ]))
      }
      current = pointer.pointee.ai_next
    }

    return .object([
      "operation": .string("network.resolve"),
      "source": .string("getaddrinfo"),
      "host": .string(host),
      "family": .string(family),
      "resolved": .bool(!addresses.isEmpty),
      "error_code": .null,
      "error": .null,
      "result_count": .integer(Int64(addresses.count)),
      "scanned_count": .integer(Int64(scannedCount)),
      "max_results": .integer(Int64(maxResults)),
      "truncated": .bool(scannedCount > addresses.count),
      "addresses": .array(addresses),
    ])
  }

  internal func networkProxy(arguments object: [String: JSONValue]) throws -> JSONValue {
    let timeout = optionalInt("timeout_ms", in: object) ?? 10_000
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)

    let result = try commandRunner.run(
      executable: "/usr/sbin/scutil",
      arguments: ["--proxy"],
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: configuration.policy.maxOutputBytes
    )

    return .object([
      "operation": .string("network.proxy"),
      "result": result.json,
    ])
  }

  internal func networkServices(arguments object: [String: JSONValue]) throws -> JSONValue {
    let timeout = optionalInt("timeout_ms", in: object) ?? 10_000
    let maxOutputBytes =
      optionalInt("max_output_bytes", in: object)
      ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)
    try validateBoundedPositive(maxOutputBytes, name: "max_output_bytes", upperBound: 20_971_520)

    let arguments = ["-listallnetworkservices"]
    let result = try commandRunner.run(
      executable: "/usr/sbin/networksetup",
      arguments: arguments,
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )

    return .object([
      "operation": .string("network.services"),
      "argv": .array(arguments.map(JSONValue.string)),
      "max_output_bytes": .integer(Int64(maxOutputBytes)),
      "result": result.json,
    ])
  }

  internal func networkHardwarePorts(arguments object: [String: JSONValue]) throws -> JSONValue {
    let timeout = optionalInt("timeout_ms", in: object) ?? 10_000
    let maxOutputBytes =
      optionalInt("max_output_bytes", in: object)
      ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)
    try validateBoundedPositive(maxOutputBytes, name: "max_output_bytes", upperBound: 20_971_520)

    let arguments = ["-listallhardwareports"]
    let result = try commandRunner.run(
      executable: "/usr/sbin/networksetup",
      arguments: arguments,
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )

    return .object([
      "operation": .string("network.hardware_ports"),
      "argv": .array(arguments.map(JSONValue.string)),
      "max_output_bytes": .integer(Int64(maxOutputBytes)),
      "result": result.json,
    ])
  }

  internal func networkWiFi(arguments object: [String: JSONValue]) throws -> JSONValue {
    let requestedDevice = try optionalString("device", in: object)
    let timeout = optionalInt("timeout_ms", in: object) ?? 10_000
    let maxOutputBytes =
      optionalInt("max_output_bytes", in: object)
      ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)
    try validateBoundedPositive(maxOutputBytes, name: "max_output_bytes", upperBound: 20_971_520)
    if let requestedDevice {
      try validateNetworkInterfaceName(requestedDevice)
    }

    let discoveryArguments = ["-listallhardwareports"]
    let discovery = try commandRunner.run(
      executable: "/usr/sbin/networksetup",
      arguments: discoveryArguments,
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )
    let ports = parseNetworkHardwarePorts(discovery.stdout)
    let wifiPort =
      requestedDevice.map { device in
        ports.first { $0.device == device }
          ?? NetworkHardwarePort(hardwarePort: nil, device: device, ethernetAddress: nil)
      }
      ?? ports.first { port in
        let name = port.hardwarePort?.lowercased() ?? ""
        return name == "wi-fi" || name == "wifi" || name.contains("airport")
      }

    guard let wifiPort else {
      return .object([
        "operation": .string("network.wifi"),
        "available": .bool(false),
        "device": .null,
        "hardware_port": .null,
        "power": .null,
        "associated": .bool(false),
        "ssid": .null,
        "discovery_argv": .array(discoveryArguments.map(JSONValue.string)),
        "power_argv": .null,
        "network_argv": .null,
        "max_output_bytes": .integer(Int64(maxOutputBytes)),
        "discovery": networkCommandSummary(discovery),
        "power_result": .null,
        "network_result": .null,
      ])
    }

    let powerArguments = ["-getairportpower", wifiPort.device]
    let power = try commandRunner.run(
      executable: "/usr/sbin/networksetup",
      arguments: powerArguments,
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )

    let networkArguments = ["-getairportnetwork", wifiPort.device]
    let network = try commandRunner.run(
      executable: "/usr/sbin/networksetup",
      arguments: networkArguments,
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )
    let powerState = parseWiFiPower(power.stdout)
    let association = parseWiFiNetwork(network.stdout)

    return .object([
      "operation": .string("network.wifi"),
      "available": .bool(true),
      "device": .string(wifiPort.device),
      "hardware_port": wifiPort.hardwarePort.map(JSONValue.string) ?? .null,
      "power": powerState.map(JSONValue.string) ?? .null,
      "associated": .bool(association.associated),
      "ssid": association.ssid.map(JSONValue.string) ?? .null,
      "discovery_argv": .array(discoveryArguments.map(JSONValue.string)),
      "power_argv": .array(powerArguments.map(JSONValue.string)),
      "network_argv": .array(networkArguments.map(JSONValue.string)),
      "max_output_bytes": .integer(Int64(maxOutputBytes)),
      "discovery": networkCommandSummary(discovery),
      "power_result": networkCommandSummary(power),
      "network_result": networkCommandSummary(network),
    ])
  }

  private func parseNetworkHardwarePorts(_ stdout: String) -> [NetworkHardwarePort] {
    var ports: [NetworkHardwarePort] = []
    var hardwarePort: String?
    var device: String?
    var ethernetAddress: String?

    func flush() {
      guard let currentDevice = device, !currentDevice.isEmpty else {
        hardwarePort = nil
        ethernetAddress = nil
        return
      }
      ports.append(
        NetworkHardwarePort(
          hardwarePort: hardwarePort,
          device: currentDevice,
          ethernetAddress: ethernetAddress
        ))
      hardwarePort = nil
      device = nil
      ethernetAddress = nil
    }

    for rawLine in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.isEmpty {
        flush()
        continue
      }
      if let value = line.droppingPrefix("Hardware Port:") {
        if device != nil {
          flush()
        }
        hardwarePort = value
      } else if let value = line.droppingPrefix("Device:") {
        device = value
      } else if let value = line.droppingPrefix("Ethernet Address:") {
        ethernetAddress = value
      }
    }
    flush()
    return ports
  }

  private func parseWiFiPower(_ stdout: String) -> String? {
    let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }
    if let range = trimmed.range(of: ":", options: .backwards) {
      let value = trimmed[range.upperBound...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      if value == "on" || value == "off" {
        return value
      }
    }
    return nil
  }

  private func parseWiFiNetwork(_ stdout: String) -> (associated: Bool, ssid: String?) {
    let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return (false, nil)
    }
    if let value = trimmed.droppingPrefix("Current Wi-Fi Network:") {
      return (true, value)
    }
    if let value = trimmed.droppingPrefix("Current AirPort Network:") {
      return (true, value)
    }
    if trimmed.localizedCaseInsensitiveContains("not associated") {
      return (false, nil)
    }
    return (false, nil)
  }

  internal func networkCommandSummary(_ result: CommandResult) -> JSONValue {
    .object([
      "exit_code": result.exitCode.map { .integer(Int64($0)) } ?? .null,
      "timed_out": .bool(result.timedOut),
      "stderr": .string(result.stderr),
      "stdout_truncated": .bool(result.stdoutTruncated),
      "stderr_truncated": .bool(result.stderrTruncated),
    ])
  }

  internal func networkVPN(arguments object: [String: JSONValue]) throws -> JSONValue {
    let maxResults = optionalInt("max_results", in: object) ?? 100
    let timeout = optionalInt("timeout_ms", in: object) ?? 10_000
    let maxOutputBytes =
      optionalInt("max_output_bytes", in: object)
      ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 1_000)
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)
    try validateBoundedPositive(maxOutputBytes, name: "max_output_bytes", upperBound: 20_971_520)

    let arguments = ["--nc", "list"]
    let result = try commandRunner.run(
      executable: "/usr/sbin/scutil",
      arguments: arguments,
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )
    let parsed = parseNetworkConnectionServices(result.stdout, maxResults: maxResults)

    return .object([
      "operation": .string("network.vpn"),
      "argv": .array(arguments.map(JSONValue.string)),
      "max_results": .integer(Int64(maxResults)),
      "max_output_bytes": .integer(Int64(maxOutputBytes)),
      "service_count": .integer(Int64(parsed.serviceCount)),
      "returned_count": .integer(Int64(parsed.services.count)),
      "truncated": .bool(parsed.serviceCount > parsed.services.count),
      "services": .array(parsed.services.map(\.json)),
      "result": networkCommandSummary(result),
    ])
  }

  private func parseNetworkConnectionServices(
    _ stdout: String,
    maxResults: Int
  ) -> (serviceCount: Int, services: [NetworkConnectionService]) {
    var services: [NetworkConnectionService] = []
    var count = 0

    for rawLine in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
      var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty, !line.hasPrefix("Available network connection services") else {
        continue
      }

      let enabled = line.hasPrefix("*")
      if enabled {
        line = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
      }

      guard line.hasPrefix("("),
        let statusEnd = line.firstIndex(of: ")")
      else {
        continue
      }
      let status = String(line[line.index(after: line.startIndex)..<statusEnd])
      let remainder = line[line.index(after: statusEnd)...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let parts = remainder.split(
        maxSplits: 1,
        whereSeparator: { $0 == " " || $0 == "\t" }
      )
      guard let idPart = parts.first else {
        continue
      }
      let id = String(idPart)
      let details = parts.count > 1 ? String(parts[1]) : ""
      count += 1
      guard services.count < maxResults else {
        continue
      }
      services.append(
        parseNetworkConnectionServiceDetails(
          enabled: enabled,
          status: status,
          id: id,
          details: details
        ))
    }

    return (count, services)
  }

  private func parseNetworkConnectionServiceDetails(
    enabled: Bool,
    status: String,
    id: String,
    details: String
  ) -> NetworkConnectionService {
    var working = details.trimmingCharacters(in: .whitespacesAndNewlines)
    var type: String?
    if let open = working.lastIndex(of: "["),
      let close = working.lastIndex(of: "]"),
      open < close
    {
      type = String(working[working.index(after: open)..<close])
      working = String(working[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var protocolName: String?
    var nameText = working
    if let range = working.range(of: "-->") {
      protocolName = String(working[..<range.lowerBound])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      nameText = String(working[range.upperBound...])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let quoted = quotedString(in: nameText) {
      nameText = quoted
    }

    return NetworkConnectionService(
      enabled: enabled,
      status: status,
      id: id,
      name: nameText.isEmpty ? nil : nameText,
      protocolName: protocolName?.isEmpty == false ? protocolName : nil,
      type: type,
      description: details.isEmpty ? nil : details
    )
  }

  private func quotedString(in value: String) -> String? {
    guard let start = value.firstIndex(of: "\"") else {
      return nil
    }
    let afterStart = value.index(after: start)
    guard let end = value[afterStart...].lastIndex(of: "\""), end > afterStart else {
      return nil
    }
    return String(value[afterStart..<end])
  }

  internal func networkLocations(arguments object: [String: JSONValue]) throws -> JSONValue {
    let timeout = optionalInt("timeout_ms", in: object) ?? 10_000
    let maxOutputBytes =
      optionalInt("max_output_bytes", in: object)
      ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)
    try validateBoundedPositive(maxOutputBytes, name: "max_output_bytes", upperBound: 20_971_520)

    let currentArguments = ["-getcurrentlocation"]
    let listArguments = ["-listlocations"]
    let current = try commandRunner.run(
      executable: "/usr/sbin/networksetup",
      arguments: currentArguments,
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )
    let locations = try commandRunner.run(
      executable: "/usr/sbin/networksetup",
      arguments: listArguments,
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )

    return .object([
      "operation": .string("network.locations"),
      "current_argv": .array(currentArguments.map(JSONValue.string)),
      "list_argv": .array(listArguments.map(JSONValue.string)),
      "max_output_bytes": .integer(Int64(maxOutputBytes)),
      "current": current.json,
      "locations": locations.json,
    ])
  }

  internal func networkRoutes(arguments object: [String: JSONValue]) throws -> JSONValue {
    let family = try optionalString("family", in: object) ?? "all"
    let timeout = optionalInt("timeout_ms", in: object) ?? 10_000
    let maxOutputBytes =
      optionalInt("max_output_bytes", in: object)
      ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)
    try validateBoundedPositive(maxOutputBytes, name: "max_output_bytes", upperBound: 20_971_520)

    var arguments = ["-rn"]
    switch family {
    case "all":
      break
    case "inet", "inet6":
      arguments += ["-f", family]
    default:
      throw GatewayToolError.invalidArguments("family must be all, inet, or inet6.")
    }

    let result = try commandRunner.run(
      executable: "/usr/sbin/netstat",
      arguments: arguments,
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )

    return .object([
      "operation": .string("network.routes"),
      "family": .string(family),
      "result": result.json,
    ])
  }

  internal func networkConnections(arguments object: [String: JSONValue]) throws -> JSONValue {
    let family = try optionalString("family", in: object) ?? "all"
    let timeout = optionalInt("timeout_ms", in: object) ?? 10_000
    let maxOutputBytes =
      optionalInt("max_output_bytes", in: object)
      ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)
    try validateBoundedPositive(maxOutputBytes, name: "max_output_bytes", upperBound: 20_971_520)

    var arguments = ["-an"]
    switch family {
    case "all":
      break
    case "inet", "inet6":
      arguments += ["-f", family]
    default:
      throw GatewayToolError.invalidArguments("family must be all, inet, or inet6.")
    }

    let result = try commandRunner.run(
      executable: "/usr/sbin/netstat",
      arguments: arguments,
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )

    return .object([
      "operation": .string("network.connections"),
      "family": .string(family),
      "argv": .array(arguments.map(JSONValue.string)),
      "max_output_bytes": .integer(Int64(maxOutputBytes)),
      "result": result.json,
    ])
  }

  internal func networkARP(arguments object: [String: JSONValue]) throws -> JSONValue {
    let timeout = optionalInt("timeout_ms", in: object) ?? 10_000
    let maxOutputBytes =
      optionalInt("max_output_bytes", in: object)
      ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)
    try validateBoundedPositive(maxOutputBytes, name: "max_output_bytes", upperBound: 20_971_520)

    let arguments = ["-an"]
    let result = try commandRunner.run(
      executable: "/usr/sbin/arp",
      arguments: arguments,
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )

    return .object([
      "operation": .string("network.arp"),
      "argv": .array(arguments.map(JSONValue.string)),
      "max_output_bytes": .integer(Int64(maxOutputBytes)),
      "result": result.json,
    ])
  }

  internal func networkPing(arguments object: [String: JSONValue]) throws -> JSONValue {
    let host = try requiredString("host", in: object)
    let count = optionalInt("count", in: object) ?? 3
    let timeout = optionalInt("timeout_ms", in: object) ?? 30_000
    let maxOutputBytes =
      optionalInt("max_output_bytes", in: object)
      ?? configuration.policy.maxOutputBytes
    try validateNetworkHost(host)
    try validateBoundedPositive(count, name: "count", upperBound: 10)
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)
    try validateBoundedPositive(maxOutputBytes, name: "max_output_bytes", upperBound: 20_971_520)

    let arguments = ["-c", "\(count)", host]
    let result = try commandRunner.run(
      executable: "/sbin/ping",
      arguments: arguments,
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )

    return .object([
      "operation": .string("network.ping"),
      "host": .string(host),
      "count": .integer(Int64(count)),
      "argv": .array(arguments.map(JSONValue.string)),
      "max_output_bytes": .integer(Int64(maxOutputBytes)),
      "result": result.json,
    ])
  }

  internal func networkTCPCheck(arguments object: [String: JSONValue]) throws -> JSONValue {
    let host = try requiredString("host", in: object)
    guard let port = optionalInt("port", in: object) else {
      throw GatewayToolError.invalidArguments("Missing required integer argument: port")
    }
    let connectTimeoutSeconds = optionalInt("connect_timeout_seconds", in: object) ?? 5
    let timeout = optionalInt("timeout_ms", in: object) ?? 30_000
    let maxOutputBytes =
      optionalInt("max_output_bytes", in: object)
      ?? configuration.policy.maxOutputBytes
    try validateNetworkHost(host)
    try validateNetworkPort(port)
    try validateBoundedPositive(
      connectTimeoutSeconds, name: "connect_timeout_seconds", upperBound: 60)
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)
    try validateBoundedPositive(maxOutputBytes, name: "max_output_bytes", upperBound: 20_971_520)

    let arguments = ["-G", "\(connectTimeoutSeconds)", "-zv", host, "\(port)"]
    let result = try commandRunner.run(
      executable: "/usr/bin/nc",
      arguments: arguments,
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )

    return .object([
      "operation": .string("network.tcp_check"),
      "host": .string(host),
      "port": .integer(Int64(port)),
      "connect_timeout_seconds": .integer(Int64(connectTimeoutSeconds)),
      "argv": .array(arguments.map(JSONValue.string)),
      "max_output_bytes": .integer(Int64(maxOutputBytes)),
      "result": result.json,
    ])
  }

  internal func networkHTTPCheck(arguments object: [String: JSONValue]) throws -> JSONValue {
    let url = try requiredString("url", in: object)
    let method = (try optionalString("method", in: object) ?? "HEAD").uppercased()
    let includeBody = try optionalBool("include_body", in: object) ?? false
    let followRedirects = try optionalBool("follow_redirects", in: object) ?? false
    let maxRedirects = optionalInt("max_redirects", in: object) ?? 5
    let connectTimeoutSeconds = optionalInt("connect_timeout_seconds", in: object) ?? 5
    let timeout = optionalInt("timeout_ms", in: object) ?? 30_000
    let maxBodyBytes = optionalInt("max_body_bytes", in: object) ?? 4_096
    let maxOutputBytes =
      optionalInt("max_output_bytes", in: object)
      ?? min(configuration.policy.maxOutputBytes, maxBodyBytes + 16_384)
    let validatedURL = try validateHTTPCheckURL(url)
    guard method == "HEAD" || method == "GET" else {
      throw GatewayToolError.invalidArguments("method must be HEAD or GET.")
    }
    try validateBoundedPositive(maxRedirects, name: "max_redirects", upperBound: 20)
    try validateBoundedPositive(
      connectTimeoutSeconds, name: "connect_timeout_seconds", upperBound: 60)
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)
    try validateBoundedPositive(maxBodyBytes, name: "max_body_bytes", upperBound: 1_048_576)
    try validateBoundedPositive(maxOutputBytes, name: "max_output_bytes", upperBound: 20_971_520)

    let marker = "__COMPUTER_MCP_HTTP_CHECK_META__"
    var arguments = [
      "--silent",
      "--show-error",
      "--max-time",
      "\(max(1, timeout / 1000))",
      "--connect-timeout",
      "\(connectTimeoutSeconds)",
    ]
    if followRedirects {
      arguments += ["--location", "--max-redirs", "\(maxRedirects)"]
    }
    if method == "HEAD" {
      arguments.append("--head")
    } else {
      arguments += ["--request", "GET"]
    }
    if includeBody, method == "GET" {
      arguments += ["--range", "0-\(maxBodyBytes - 1)", "--output", "-"]
    } else {
      arguments += ["--output", "/dev/null"]
    }
    arguments += [
      "--write-out",
      "\n\(marker)\nhttp_code=%{http_code}\nurl_effective=%{url_effective}\ncontent_type=%{content_type}\nredirect_url=%{redirect_url}\ntime_total=%{time_total}\nsize_download=%{size_download}\n",
      validatedURL.absoluteString,
    ]

    let result = try commandRunner.run(
      executable: "/usr/bin/curl",
      arguments: arguments,
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )
    let parsed = parseHTTPCheckOutput(
      result.stdout,
      marker: marker,
      includeBody: includeBody && method == "GET",
      maxBodyBytes: maxBodyBytes,
      stdoutTruncated: result.stdoutTruncated
    )

    return .object([
      "operation": .string("network.http_check"),
      "url": .string(validatedURL.absoluteString),
      "scheme": .string(validatedURL.scheme ?? ""),
      "host": .string(validatedURL.host ?? ""),
      "method": .string(method),
      "include_body": .bool(includeBody && method == "GET"),
      "follow_redirects": .bool(followRedirects),
      "max_redirects": .integer(Int64(maxRedirects)),
      "connect_timeout_seconds": .integer(Int64(connectTimeoutSeconds)),
      "timeout_ms": .integer(Int64(timeout)),
      "max_body_bytes": .integer(Int64(maxBodyBytes)),
      "max_output_bytes": .integer(Int64(maxOutputBytes)),
      "argv": .array(arguments.map(JSONValue.string)),
      "http_code": parsed.httpCode.map { .integer(Int64($0)) } ?? .null,
      "url_effective": parsed.urlEffective.map(JSONValue.string) ?? .null,
      "content_type": parsed.contentType.map(JSONValue.string) ?? .null,
      "redirect_url": parsed.redirectURL.map(JSONValue.string) ?? .null,
      "time_total_seconds": parsed.timeTotal.map { .number($0) } ?? .null,
      "size_download_bytes": parsed.sizeDownload.map { .number($0) } ?? .null,
      "body": parsed.body.map(JSONValue.string) ?? .null,
      "body_bytes": parsed.body.map { .integer(Int64($0.utf8.count)) } ?? .null,
      "body_truncated": .bool(parsed.bodyTruncated),
      "meta_found": .bool(parsed.metaFound),
      "result": networkCommandSummary(result),
    ])
  }

  internal func parseHTTPCheckOutput(
    _ stdout: String,
    marker: String,
    includeBody: Bool,
    maxBodyBytes: Int,
    stdoutTruncated: Bool
  ) -> HTTPCheckOutput {
    guard let markerRange = stdout.range(of: "\n\(marker)\n", options: .backwards) else {
      let body = includeBody && !stdout.isEmpty ? String(stdout.prefix(maxBodyBytes)) : nil
      return HTTPCheckOutput(
        metaFound: false,
        httpCode: nil,
        urlEffective: nil,
        contentType: nil,
        redirectURL: nil,
        timeTotal: nil,
        sizeDownload: nil,
        body: body,
        bodyTruncated: includeBody && (stdoutTruncated || stdout.utf8.count > maxBodyBytes)
      )
    }

    let bodyText = String(stdout[..<markerRange.lowerBound])
    let metaText = String(stdout[markerRange.upperBound...])
    let meta = Dictionary(
      uniqueKeysWithValues: metaText.split(separator: "\n").compactMap {
        line -> (String, String)? in
        guard let separator = line.firstIndex(of: "=") else {
          return nil
        }
        let key = String(line[..<separator])
        let value = String(line[line.index(after: separator)...])
        return (key, value)
      })

    let body: String?
    let bodyTruncated: Bool
    if includeBody {
      let limitedBody =
        bodyText.utf8.count > maxBodyBytes ? String(bodyText.prefix(maxBodyBytes)) : bodyText
      body = limitedBody
      bodyTruncated =
        stdoutTruncated || bodyText.utf8.count > maxBodyBytes
        || (Double(meta["size_download"] ?? "") ?? 0) > Double(maxBodyBytes)
    } else {
      body = nil
      bodyTruncated = false
    }

    return HTTPCheckOutput(
      metaFound: true,
      httpCode: Int(meta["http_code"] ?? ""),
      urlEffective: emptyStringAsNil(meta["url_effective"]),
      contentType: emptyStringAsNil(meta["content_type"]),
      redirectURL: emptyStringAsNil(meta["redirect_url"]),
      timeTotal: Double(meta["time_total"] ?? ""),
      sizeDownload: Double(meta["size_download"] ?? ""),
      body: body,
      bodyTruncated: bodyTruncated
    )
  }

  internal func networkListeners(arguments object: [String: JSONValue]) throws -> JSONValue {
    let timeout = optionalInt("timeout_ms", in: object) ?? 10_000
    let maxOutputBytes =
      optionalInt("max_output_bytes", in: object)
      ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)
    try validateBoundedPositive(maxOutputBytes, name: "max_output_bytes", upperBound: 20_971_520)

    let arguments = ["-nP", "-iTCP", "-sTCP:LISTEN"]
    let result = try commandRunner.run(
      executable: "/usr/sbin/lsof",
      arguments: arguments,
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )

    return .object([
      "operation": .string("network.listeners"),
      "argv": .array(arguments.map(JSONValue.string)),
      "max_output_bytes": .integer(Int64(maxOutputBytes)),
      "result": result.json,
    ])
  }

  private func validateNetworkInterfaceName(_ name: String) throws {
    try validateUTF8ByteLimit(name, name: "interface", maxBytes: 64)
    guard !name.hasPrefix("-") else {
      throw GatewayToolError.invalidArguments("interface must not be an option.")
    }
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
    guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
      throw GatewayToolError.invalidArguments(
        "interface may contain only letters, digits, dot, underscore, or hyphen.")
    }
  }

  private func validateNetworkHost(_ host: String) throws {
    try validateUTF8ByteLimit(host, name: "host", maxBytes: 253)
    guard !host.isEmpty else {
      throw GatewayToolError.invalidArguments("host must not be empty.")
    }
    guard !host.hasPrefix("-") else {
      throw GatewayToolError.invalidArguments("host must not be an option.")
    }
    guard host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
      throw GatewayToolError.invalidArguments("host must not contain whitespace.")
    }
    guard !host.contains("/") && !host.contains("@") else {
      throw GatewayToolError.invalidArguments("host must be a hostname or IP address, not a URL.")
    }
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-:%_")
    guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
      throw GatewayToolError.invalidArguments(
        "host may contain only letters, digits, dot, hyphen, colon, percent, or underscore.")
    }
  }

  internal func validateHTTPCheckURL(_ value: String) throws -> URL {
    try validateUTF8ByteLimit(value, name: "url", maxBytes: 4_096)
    guard !value.isEmpty else {
      throw GatewayToolError.invalidArguments("url must not be empty.")
    }
    guard value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
      throw GatewayToolError.invalidArguments("url must not contain whitespace.")
    }
    guard
      value.unicodeScalars.allSatisfy({ scalar in
        !((scalar.value <= 0x1F) || (scalar.value >= 0x7F && scalar.value <= 0x9F))
      })
    else {
      throw GatewayToolError.invalidArguments("url must not contain control characters.")
    }
    guard var components = URLComponents(string: value),
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = components.host,
      !host.isEmpty
    else {
      throw GatewayToolError.invalidArguments("url must be an absolute http or https URL.")
    }
    guard components.user == nil, components.password == nil else {
      throw GatewayToolError.invalidArguments("url must not contain userinfo credentials.")
    }
    components.scheme = scheme
    guard let url = components.url else {
      throw GatewayToolError.invalidArguments("url must be a valid absolute URL.")
    }
    return url
  }

  private func validateNetworkPort(_ port: Int) throws {
    guard (1...65_535).contains(port) else {
      throw GatewayToolError.invalidArguments("port must be between 1 and 65535.")
    }
  }

  private func emptyStringAsNil(_ value: String?) -> String? {
    guard let value, !value.isEmpty else {
      return nil
    }
    return value
  }

  private func addressFamilyValue(_ family: String) throws -> Int32 {
    switch family {
    case "any", "all":
      return AF_UNSPEC
    case "ipv4", "inet":
      return AF_INET
    case "ipv6", "inet6":
      return AF_INET6
    default:
      throw GatewayToolError.invalidArguments(
        "family must be any, all, ipv4, inet, ipv6, or inet6.")
    }
  }

  private func addressFamilyName(_ family: Int32) -> String {
    switch family {
    case AF_INET:
      return "ipv4"
    case AF_INET6:
      return "ipv6"
    case AF_UNSPEC:
      return "any"
    default:
      return "unknown"
    }
  }

  private func socketTypeName(_ socketType: Int32) -> String {
    switch socketType {
    case SOCK_STREAM:
      return "stream"
    case SOCK_DGRAM:
      return "datagram"
    case SOCK_RAW:
      return "raw"
    default:
      return "unknown"
    }
  }

  private func numericHostAddress(_ pointer: UnsafeMutablePointer<addrinfo>) -> String? {
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let status = host.withUnsafeMutableBufferPointer { buffer in
      getnameinfo(
        pointer.pointee.ai_addr,
        pointer.pointee.ai_addrlen,
        buffer.baseAddress,
        socklen_t(buffer.count),
        nil,
        0,
        NI_NUMERICHOST
      )
    }
    guard status == 0 else {
      return nil
    }
    return stringFromNullTerminatedCString(host)
  }
}

private struct NetworkHardwarePort {
  var hardwarePort: String?
  var device: String
  var ethernetAddress: String?
}

internal struct HTTPCheckOutput {
  var metaFound: Bool
  var httpCode: Int?
  var urlEffective: String?
  var contentType: String?
  var redirectURL: String?
  var timeTotal: Double?
  var sizeDownload: Double?
  var body: String?
  var bodyTruncated: Bool
}

private struct NetworkConnectionService {
  var enabled: Bool
  var status: String
  var id: String
  var name: String?
  var protocolName: String?
  var type: String?
  var description: String?

  var json: JSONValue {
    .object([
      "enabled": .bool(enabled),
      "status": .string(status),
      "connected": .bool(status.lowercased() == "connected"),
      "id": .string(id),
      "name": name.map(JSONValue.string) ?? .null,
      "protocol": protocolName.map(JSONValue.string) ?? .null,
      "type": type.map(JSONValue.string) ?? .null,
      "description": description.map(JSONValue.string) ?? .null,
    ])
  }
}
