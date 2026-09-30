# Product identity

Computer MCP lets ChatGPT use your local tools. It is a direct capability and
execution plane between ChatGPT or another compatible MCP client and your
computers. The signed desktop App runs on macOS 14 or later.

## Product model

- **Direct:** a client can invoke an authorized local capability and use its
  structured result without starting a Codex task.
- **Local:** registered tools execute in the selected host's environment.
  Authentication, application installation and vendor accounts remain with
  their owners. A remote connection does not move execution into the cloud.
- **Composable:** typed builtins, verified CLI projections, downstream MCP,
  Skills and Computer Use can participate in the same client-led workflow.
  Skills supply instructions; authorized tools perform execution.
- **Multi-computer:** connect each computer's gateway to the client and select
  the intended host connection, then a workspace on that host. Each gateway
  retains its own registrations, credentials, policy, approvals and audit.
  Workspace IDs are host-scoped. This is not a shared filesystem or automatic
  cross-host task migration; availability depends on the client's connection
  support and each host staying online.
- **Governed:** the host binds a request to its caller, profile, capability and
  workspace before dispatch. Authorization, action consent, operating-system
  permissions and vendor permissions are distinct boundaries.

```text
ChatGPT / compatible MCP client
    ├── Computer MCP on Mac A → authorized local capabilities / workspaces
    └── Computer MCP on Mac B → authorized local capabilities / workspaces
```

[Gateway](Gateway.md) owns routing and transports;
[Runtime](Runtime.md) owns lifetime and failure semantics;
[Security and Privacy](SecurityAndPrivacy.md) owns the trust model. Full Access
permits execution as the local user; a workspace is context, not an OS sandbox.
Unknown write outcomes do not authorize automatic replay.

## Codex relationship

Codex is optional. Its independent plugin supplies App Server and Exec
integration alongside other local capabilities. Codex can also be a client of
Computer MCP. Neither relationship grants implicit authority to the other.
The adapter owns its runtimes; it cannot stop an unrelated Desktop, IDE or CLI
session. Native Codex configuration, authentication and action approvals remain
Codex-owned. The host owns caller admission, its own approvals and audit.

Computer MCP provides capabilities for an orchestrating client. Agent memory,
proactive scheduling and a hosted cloud computer are separate product concerns.
The [product comparison](../Reference/ProductComparison.md) explains the fit
alongside OpenAI Dots and Codex Remote, with dated official sources.

## Family and public identity

Computer MCP is the master brand. First-party plugins identify their integration
under that family while retaining their own manifests, technical contracts and
release sequences. An integration is not a claim of vendor endorsement.
The MCP Swift SDK fork is a dependency with its own upstream identity.

[BRAND.md](../../Assets/Brand/BRAND.md) owns visual and verbal application.
[brand.json](../../Assets/Brand/brand.json) holds machine-readable stable facts.
The website owns its layout, not a separate product or brand definition.
