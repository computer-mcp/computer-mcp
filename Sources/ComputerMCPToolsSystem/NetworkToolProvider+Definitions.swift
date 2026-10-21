import ComputerMCPCore

extension NetworkToolProvider {
  static func toolDefinitions(toolMeta: JSONValue?) -> [ToolDefinition] {
    [
      ToolDefinition(
        tool: MCPTool(
          name: "network.interfaces",
          description:
            "Return raw macOS network interface status using /sbin/ifconfig. This is read-only and runs fixed argv only.",
          inputSchema: objectSchema(
            properties: [
              "interface": stringSchema(
                "Optional interface name such as en0 or lo0. Omit to run ifconfig -a."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "network.interfaces", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "network.dns",
          description:
            "Return raw macOS DNS resolver configuration using /usr/sbin/scutil --dns. This is read-only.",
          inputSchema: objectSchema(
            properties: [
              "timeout_ms": integerSchema("Optional timeout in milliseconds.")
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "network.dns", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "network.resolve",
          description:
            "Resolve a hostname or IP address through the system resolver using getaddrinfo. This is read-only and does not run shell commands.",
          inputSchema: objectSchema(
            properties: [
              "host": stringSchema("Hostname or IP address to resolve."),
              "family": stringSchema(
                "Address family: any, all, ipv4, inet, ipv6, or inet6. Defaults to any."),
              "max_results": integerSchema("Maximum addresses to return. Defaults to 50."),
            ],
            required: ["host"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "network.resolve", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "network.proxy",
          description:
            "Return raw macOS network proxy settings using /usr/sbin/scutil --proxy. This is read-only.",
          inputSchema: objectSchema(
            properties: [
              "timeout_ms": integerSchema("Optional timeout in milliseconds.")
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "network.proxy", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "network.services",
          description:
            "Return the raw macOS network service list using fixed /usr/sbin/networksetup -listallnetworkservices argv. This is read-only and does not make outbound network requests.",
          inputSchema: objectSchema(
            properties: [
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
              "max_output_bytes": integerSchema(
                "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "network.services", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "network.hardware_ports",
          description:
            "Return the raw macOS network hardware port list using fixed /usr/sbin/networksetup -listallhardwareports argv. This is read-only and may reveal local network hardware identifiers.",
          inputSchema: objectSchema(
            properties: [
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
              "max_output_bytes": integerSchema(
                "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "network.hardware_ports", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "network.wifi",
          description:
            "Return read-only current macOS Wi-Fi interface status using fixed /usr/sbin/networksetup argv. The gateway discovers or accepts a Wi-Fi device, then queries power and current network association. This does not scan nearby networks, join networks, change settings, make outbound network requests, or expose full hardware-port raw output.",
          inputSchema: objectSchema(
            properties: [
              "device": stringSchema(
                "Optional network interface device such as en0. Omit to discover the first Wi-Fi/AirPort hardware port."
              ),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
              "max_output_bytes": integerSchema(
                "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "network.wifi", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "network.vpn",
          description:
            "Return read-only macOS Network Connection/VPN service list using fixed /usr/sbin/scutil --nc list argv. The gateway parses enabled state, connection status, service id, name, protocol, and type. This does not start, stop, select, trigger, enable, disable, or show detailed VPN configuration.",
          inputSchema: objectSchema(
            properties: [
              "max_results": integerSchema("Maximum services to return. Defaults to 100."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
              "max_output_bytes": integerSchema(
                "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "network.vpn", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "network.locations",
          description:
            "Return the raw current and configured macOS network locations using fixed /usr/sbin/networksetup -getcurrentlocation and -listlocations argv. This is read-only and does not make outbound network requests.",
          inputSchema: objectSchema(
            properties: [
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
              "max_output_bytes": integerSchema(
                "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "network.locations", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "network.routes",
          description:
            "Return the raw macOS routing table using fixed /usr/sbin/netstat -rn argv. This is read-only and does not make outbound network requests.",
          inputSchema: objectSchema(
            properties: [
              "family": stringSchema("Address family: all, inet, or inet6. Defaults to all."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
              "max_output_bytes": integerSchema(
                "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "network.routes", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "network.connections",
          description:
            "Return the raw local network connection table using fixed /usr/sbin/netstat -an argv. This is read-only and may reveal local and remote endpoints.",
          inputSchema: objectSchema(
            properties: [
              "family": stringSchema("Address family: all, inet, or inet6. Defaults to all."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
              "max_output_bytes": integerSchema(
                "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "network.connections", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "network.arp",
          description:
            "Return the raw local IPv4 ARP neighbor cache using fixed /usr/sbin/arp -an argv. This is read-only and may reveal local network devices.",
          inputSchema: objectSchema(
            properties: [
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
              "max_output_bytes": integerSchema(
                "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "network.arp", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "network.ping",
          description:
            "Run a bounded ICMP ping to a hostname or IP address using fixed /sbin/ping -c argv. This performs network I/O.",
          inputSchema: objectSchema(
            properties: [
              "host": stringSchema("Hostname or IP address to ping. URLs are rejected."),
              "count": integerSchema("Number of echo requests. Defaults to 3; max 10."),
              "timeout_ms": integerSchema(
                "Process timeout in milliseconds. Defaults to 30000."),
              "max_output_bytes": integerSchema(
                "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
            ],
            required: ["host"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "network.ping", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "network.tcp_check",
          description:
            "Check TCP connectivity to a host and port using fixed /usr/bin/nc -G <seconds> -zv argv. This performs network I/O.",
          inputSchema: objectSchema(
            properties: [
              "host": stringSchema("Hostname or IP address to connect to. URLs are rejected."),
              "port": integerSchema("TCP port number, 1 through 65535."),
              "connect_timeout_seconds": integerSchema(
                "nc connection timeout in seconds. Defaults to 5; max 60."),
              "timeout_ms": integerSchema(
                "Process timeout in milliseconds. Defaults to 30000."),
              "max_output_bytes": integerSchema(
                "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
            ],
            required: ["host", "port"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "network.tcp_check", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "network.http_check",
          description:
            "Check an absolute HTTP or HTTPS URL using fixed /usr/bin/curl argv. This performs bounded network I/O, supports HEAD or GET, returns curl metadata such as HTTP status and effective URL, and optionally returns a bounded GET body prefix. It does not send custom headers, request bodies, cookies, or shell commands.",
          inputSchema: objectSchema(
            properties: [
              "url": stringSchema("Absolute http or https URL to check."),
              "method": stringSchema("HTTP method: HEAD or GET. Defaults to HEAD."),
              "include_body": boolSchema(
                "Whether to include a bounded GET response body prefix. Defaults to false and is ignored for HEAD."
              ),
              "follow_redirects": boolSchema(
                "Whether curl should follow redirects. Defaults to false."),
              "max_redirects": integerSchema(
                "Maximum redirects when following. Defaults to 5."),
              "connect_timeout_seconds": integerSchema(
                "Connection timeout in seconds. Defaults to 5; max 60."),
              "timeout_ms": integerSchema(
                "Process timeout in milliseconds. Defaults to 30000."),
              "max_body_bytes": integerSchema(
                "Maximum GET body bytes to return when include_body is true. Defaults to 4096."
              ),
              "max_output_bytes": integerSchema(
                "Maximum stdout/stderr bytes per stream. Defaults to max_body_bytes plus metadata allowance."
              ),
            ],
            required: ["url"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "network.http_check", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "network.listeners",
          description:
            "Return raw local TCP listening sockets using fixed /usr/sbin/lsof -nP -iTCP -sTCP:LISTEN argv. This is read-only but may reveal local process names and ports.",
          inputSchema: objectSchema(
            properties: [
              "timeout_ms": integerSchema(
                "Optional timeout in milliseconds. Defaults to 10000."),
              "max_output_bytes": integerSchema(
                "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "network.listeners", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
    ]
  }

  private static func objectSchema(
    properties: [String: JSONValue] = [:],
    required: [String] = []
  ) -> JSONValue {
    var object: [String: JSONValue] = [
      "type": .string("object"),
      "properties": .object(properties),
      "additionalProperties": .bool(false),
    ]
    if !required.isEmpty {
      object["required"] = .array(required.map { .string($0) })
    }
    return .object(object)
  }

  private static func stringSchema(_ description: String) -> JSONValue {
    .object(["type": .string("string"), "description": .string(description)])
  }

  private static func integerSchema(_ description: String) -> JSONValue {
    .object(["type": .string("integer"), "description": .string(description)])
  }

  private static func boolSchema(_ description: String) -> JSONValue {
    .object(["type": .string("boolean"), "description": .string(description)])
  }

}
