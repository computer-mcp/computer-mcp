// swift-tools-version: 6.2

import PackageDescription

let subprocessDependency: Package.Dependency =
  .package(url: "https://github.com/swiftlang/swift-subprocess.git", .upToNextMinor(from: "1.0.2"))

let cryptoDependency: Package.Dependency =
  .package(url: "https://github.com/apple/swift-crypto.git", .upToNextMinor(from: "4.5.2"))

let tomlDependency: Package.Dependency =
  .package(url: "https://github.com/mattt/swift-toml.git", from: "2.0.0")

let yamsDependency: Package.Dependency =
  .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2")

let grdbDependency: Package.Dependency =
  .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1")

let nioDependency: Package.Dependency =
  .package(url: "https://github.com/apple/swift-nio.git", .upToNextMinor(from: "2.101.2"))

// FilePath comes from the System framework on Apple platforms and from swift-system elsewhere.
let systemDependency: Package.Dependency =
  .package(url: "https://github.com/apple/swift-system.git", from: "1.7.2")

let loggingDependency: Package.Dependency =
  .package(url: "https://github.com/apple/swift-log.git", from: "1.14.0")

let mcpDependency: Package.Dependency =
  .package(url: "https://github.com/computer-mcp/swift-sdk.git", exact: "0.13.2-computer-mcp.1")

// Platform-neutral targets; they build on macOS and on Linux.
let neutralTargets: [Target] =
  [
    .target(
      name: "ComputerMCPCore",
      dependencies: [.product(name: "Crypto", package: "swift-crypto")]
    ),
    .target(name: "ComputerMCPPlatform", dependencies: ["ComputerMCPCore"]),
    .target(name: "ComputerMCPPlatformPOSIX", dependencies: ["ComputerMCPPlatform"]),
    .target(
      name: "ComputerMCPConfiguration",
      dependencies: [
        "ComputerMCPCore", "ComputerMCPPlatform", .product(name: "TOML", package: "swift-toml"),
      ]
    ),
    .target(
      name: "ComputerMCPPersistence",
      dependencies: [
        "ComputerMCPCore",
        .product(name: "GRDB", package: "GRDB.swift"),
      ]
    ),
    .target(
      name: "ComputerMCPProcess",
      dependencies: [
        "ComputerMCPConfiguration", "ComputerMCPCore", "ComputerMCPPlatform",
        "ComputerMCPPlatformPOSIX",
        .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
        .product(name: "Subprocess", package: "swift-subprocess"),
        .product(
          name: "SystemPackage", package: "swift-system", condition: .when(platforms: [.linux])),
      ]
    ),
    .target(
      name: "ComputerMCPToolKit",
      dependencies: [
        "ComputerMCPCore", "ComputerMCPConfiguration", "ComputerMCPPlatform",
        "ComputerMCPPlatformPOSIX", "ComputerMCPProcess",
      ]
    ),
    .target(
      name: "ComputerMCPToolsFiles",
      dependencies: [
        "ComputerMCPToolKit", "ComputerMCPCore", "ComputerMCPConfiguration", "ComputerMCPPlatform",
        .product(name: "Crypto", package: "swift-crypto"),
      ]),
    .testTarget(
      name: "ComputerMCPToolsFilesTests",
      dependencies: [
        "ComputerMCPToolsFiles", "ComputerMCPToolKit", "ComputerMCPCore",
        "ComputerMCPConfiguration", "ComputerMCPPlatform", "ComputerMCPTestSupport",
      ]),
    .target(
      name: "ComputerMCPToolsWorkspace",
      dependencies: [
        "ComputerMCPToolsFiles", "ComputerMCPToolKit", "ComputerMCPCore",
        "ComputerMCPConfiguration",
        .product(name: "TOML", package: "swift-toml"),
      ]),
    .testTarget(
      name: "ComputerMCPToolsWorkspaceTests",
      dependencies: [
        "ComputerMCPToolsWorkspace", "ComputerMCPToolsFiles", "ComputerMCPToolKit",
        "ComputerMCPCore", "ComputerMCPConfiguration", "ComputerMCPPlatform",
        "ComputerMCPTestSupport",
      ]),
    .target(
      name: "ComputerMCPToolsMCP",
      dependencies: [
        "ComputerMCPToolKit", "ComputerMCPCore", "ComputerMCPConfiguration",
        "ComputerMCPDownstream",
      ]),
    .testTarget(
      name: "ComputerMCPToolsMCPTests",
      dependencies: [
        "ComputerMCPToolsMCP", "ComputerMCPToolKit", "ComputerMCPCore",
        "ComputerMCPConfiguration", "ComputerMCPDownstream", "ComputerMCPTestSupport",
      ]),
    .target(
      name: "ComputerMCPToolsSystem",
      dependencies: [
        "ComputerMCPToolKit", "ComputerMCPCore", "ComputerMCPConfiguration", "ComputerMCPPlatform",
      ]),
    .testTarget(
      name: "ComputerMCPToolsSystemTests",
      dependencies: [
        "ComputerMCPToolsSystem", "ComputerMCPToolKit", "ComputerMCPCore",
        "ComputerMCPConfiguration", "ComputerMCPPlatform", "ComputerMCPTestSupport",
      ]),
    .target(
      name: "ComputerMCPToolsStructured",
      dependencies: [
        "ComputerMCPToolKit", "ComputerMCPCore", "ComputerMCPConfiguration", "ComputerMCPPlatform",
        .product(name: "TOML", package: "swift-toml"),
        .product(name: "Yams", package: "Yams"),
      ]),
    .testTarget(
      name: "ComputerMCPToolsStructuredTests",
      dependencies: [
        "ComputerMCPToolsStructured", "ComputerMCPToolKit", "ComputerMCPCore",
        "ComputerMCPConfiguration",
        "ComputerMCPPlatform", "ComputerMCPTestSupport",
      ]),
    .target(
      name: "ComputerMCPToolsSkills",
      dependencies: [
        "ComputerMCPToolKit", "ComputerMCPToolsStructured", "ComputerMCPCore",
        "ComputerMCPConfiguration",
      ]),
    .testTarget(
      name: "ComputerMCPToolsSkillsTests",
      dependencies: [
        "ComputerMCPToolsSkills", "ComputerMCPToolKit", "ComputerMCPCore",
        "ComputerMCPConfiguration",
        "ComputerMCPTestSupport",
      ]),
    .target(
      name: "ComputerMCPAuthorization",
      dependencies: [
        "ComputerMCPCore", .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
      ]),
    .testTarget(
      name: "ComputerMCPAuthorizationTests",
      dependencies: [
        "ComputerMCPAuthorization", "ComputerMCPCore",
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
      ]),
    .target(
      name: "ComputerMCPDelivery",
      dependencies: [
        "ComputerMCPCore", "ComputerMCPConfiguration", "ComputerMCPProcess",
        "ComputerMCPPlatformPOSIX", "ComputerMCPToolKit",
      ]),
    .testTarget(
      name: "ComputerMCPDeliveryTests",
      dependencies: [
        "ComputerMCPDelivery", "ComputerMCPCore", "ComputerMCPConfiguration",
        "ComputerMCPProcess", "ComputerMCPPlatformPOSIX", "ComputerMCPToolKit",
        "ComputerMCPTestSupport",
      ]),
    .target(
      name: "ComputerMCPToolsGit",
      dependencies: [
        "ComputerMCPToolKit", "ComputerMCPCore", "ComputerMCPConfiguration", "ComputerMCPPlatform",
      ]),
    .testTarget(
      name: "ComputerMCPToolsGitTests",
      dependencies: [
        "ComputerMCPToolsGit", "ComputerMCPToolKit", "ComputerMCPCore", "ComputerMCPConfiguration",
        "ComputerMCPPlatform", "ComputerMCPPlatformPOSIX", "ComputerMCPProcess",
        "ComputerMCPTestSupport",
      ]),
    .target(
      name: "ComputerMCPToolsCLI",
      dependencies: [
        "ComputerMCPToolKit", "ComputerMCPCore", "ComputerMCPConfiguration", "ComputerMCPProcess",
        "ComputerMCPPlatform", "ComputerMCPPlatformPOSIX",
        .product(name: "Crypto", package: "swift-crypto"),
      ]),
    .testTarget(
      name: "ComputerMCPToolsCLITests",
      dependencies: [
        "ComputerMCPToolsCLI", "ComputerMCPToolKit", "ComputerMCPCore", "ComputerMCPConfiguration",
        "ComputerMCPPlatform", "ComputerMCPPlatformPOSIX", "ComputerMCPProcess",
        "ComputerMCPTestSupport", .product(name: "Crypto", package: "swift-crypto"),
      ]),
    .target(
      name: "ComputerMCPToolsShell",
      dependencies: [
        "ComputerMCPToolKit", "ComputerMCPCore", "ComputerMCPConfiguration", "ComputerMCPProcess",
        "ComputerMCPPlatform",
      ]),
    .testTarget(
      name: "ComputerMCPToolsShellTests",
      dependencies: [
        "ComputerMCPToolsShell", "ComputerMCPToolKit", "ComputerMCPCore",
        "ComputerMCPConfiguration", "ComputerMCPPlatform", "ComputerMCPPlatformPOSIX",
        "ComputerMCPProcess", "ComputerMCPTestSupport",
      ]),
    .target(
      name: "ComputerMCPPlugins",
      dependencies: [
        "ComputerMCPCore", "ComputerMCPConfiguration", "ComputerMCPPlatform",
        "ComputerMCPPlatformPOSIX", "ComputerMCPDownstream",
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "TOML", package: "swift-toml"),
        .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
        .product(name: "Subprocess", package: "swift-subprocess"),
        .product(
          name: "SystemPackage", package: "swift-system", condition: .when(platforms: [.linux])),
      ]
    ),
    .testTarget(
      name: "ComputerMCPPluginsTests",
      dependencies: [
        "ComputerMCPPlugins", "ComputerMCPCore", "ComputerMCPConfiguration", "ComputerMCPPlatform",
        "ComputerMCPTestSupport", .product(name: "Crypto", package: "swift-crypto"),
      ],
      resources: [.copy("Fixtures")]
    ),
    .target(
      name: "ComputerMCPTransport",
      dependencies: [
        "ComputerMCPCore", "ComputerMCPConfiguration", "ComputerMCPPlatform",
        "ComputerMCPPlatformPOSIX",
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "MCP", package: "swift-sdk"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
      ]
    ),
    .target(
      name: "ComputerMCPDownstream",
      dependencies: [
        "ComputerMCPCore", "ComputerMCPConfiguration", "ComputerMCPPlatform",
        "ComputerMCPPlatformPOSIX", "ComputerMCPProcess", "ComputerMCPTransport",
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "MCP", package: "swift-sdk"),
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    .testTarget(
      name: "ComputerMCPDownstreamTests",
      dependencies: [
        "ComputerMCPDownstream", "ComputerMCPCore", "ComputerMCPConfiguration",
        "ComputerMCPPlatform",
        "ComputerMCPProcess", "ComputerMCPTestSupport",
        .product(name: "MCP", package: "swift-sdk"),
      ]
    ),
    .target(
      name: "ComputerMCPGateway",
      dependencies: [
        "ComputerMCPAuthorization",
        "ComputerMCPPlugins", "ComputerMCPToolsWorkspace", "ComputerMCPConfiguration",
        "ComputerMCPCore", "ComputerMCPPersistence", "ComputerMCPPlatform",
        "ComputerMCPPlatformPOSIX", "ComputerMCPProcess", "ComputerMCPDownstream",
        "ComputerMCPTransport", "ComputerMCPTunnels",
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "MCP", package: "swift-sdk"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
      ],
      exclude: ["ComputerMCPGateway.docc"]
    ),
    .testTarget(
      name: "ComputerMCPGatewayTests",
      dependencies: [
        "ComputerMCPAuthorization",
        "ComputerMCPConfiguration",
        "ComputerMCPCore",
        "ComputerMCPDownstream",
        "ComputerMCPGateway",
        "ComputerMCPPersistence",
        "ComputerMCPPlatform",
        "ComputerMCPPlatformPOSIX",
        "ComputerMCPPlugins",
        "ComputerMCPProcess",
        "ComputerMCPTestSupport",
        "ComputerMCPToolKit",
        "ComputerMCPToolsCLI",
        "ComputerMCPToolsFiles",
        "ComputerMCPToolsGit",
        "ComputerMCPToolsMCP",
        "ComputerMCPToolsShell",
        "ComputerMCPToolsSystem",
        "ComputerMCPToolsWorkspace",
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "MCP", package: "swift-sdk"),
        .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
      ]
    ),
    .target(
      name: "ComputerMCPControlPlane",
      dependencies: [
        "ComputerMCPAuthorization",
        "ComputerMCPGateway", "ComputerMCPPlugins", "ComputerMCPToolsWorkspace",
        "ComputerMCPDownstream", "ComputerMCPConfiguration", "ComputerMCPCore",
        "ComputerMCPPersistence", "ComputerMCPPlatform", "ComputerMCPPlatformPOSIX",
        "ComputerMCPProcess", "ComputerMCPTransport", "ComputerMCPTunnels",
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "MCP", package: "swift-sdk"),
      ]
    ),
    .testTarget(
      name: "ComputerMCPControlPlaneTests",
      dependencies: [
        "ComputerMCPAuthorization", "ComputerMCPConfiguration",
        "ComputerMCPDownstream", "ComputerMCPProcess",
        "ComputerMCPControlPlane", "ComputerMCPGateway", "ComputerMCPCore",
        "ComputerMCPPersistence", .product(name: "GRDB", package: "GRDB.swift"),
        "ComputerMCPPlatform", "ComputerMCPPlatformPOSIX", "ComputerMCPTunnels",
        "ComputerMCPTestSupport",
      ]
    ),
    .target(
      name: "ComputerMCPTunnels",
      dependencies: [
        "ComputerMCPCore", "ComputerMCPConfiguration", "ComputerMCPPlatform",
        "ComputerMCPProcess",
      ]
    ),
    .testTarget(
      name: "ComputerMCPTunnelsTests",
      dependencies: [
        "ComputerMCPTunnels", "ComputerMCPCore", "ComputerMCPConfiguration",
        "ComputerMCPPlatform", "ComputerMCPProcess", "ComputerMCPTestSupport",
      ]
    ),
    .target(
      name: "ComputerMCPTestSupport",
      dependencies: [
        "ComputerMCPCore", "ComputerMCPPlatform", "ComputerMCPProcess",
        "ComputerMCPConfiguration", "ComputerMCPTunnels", "ComputerMCPPlugins",
        .product(name: "Crypto", package: "swift-crypto"),
      ],
      path: "Tests/ComputerMCPTestSupport", resources: [.copy("Fixtures")]),
    .testTarget(
      name: "ComputerMCPTransportTests",
      dependencies: [
        "ComputerMCPTransport", "ComputerMCPCore", "ComputerMCPTestSupport",
        .product(name: "MCP", package: "swift-sdk"),
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    .testTarget(
      name: "ComputerMCPCoreTests", dependencies: ["ComputerMCPCore", "ComputerMCPTestSupport"]),
    .testTarget(
      name: "ComputerMCPPlatformTests",
      dependencies: ["ComputerMCPPlatform", "ComputerMCPTestSupport"]
    ),
    .testTarget(
      name: "ComputerMCPToolKitTests",
      dependencies: [
        "ComputerMCPToolKit", "ComputerMCPConfiguration", "ComputerMCPCore", "ComputerMCPPlatform",
        "ComputerMCPPlatformPOSIX", "ComputerMCPProcess", "ComputerMCPTestSupport",
      ]
    ),
    .testTarget(
      name: "ComputerMCPPlatformPOSIXTests",
      dependencies: ["ComputerMCPPlatform", "ComputerMCPPlatformPOSIX"]
    ),
    .testTarget(
      name: "ComputerMCPPersistenceTests",
      dependencies: [
        "ComputerMCPCore", "ComputerMCPPersistence", "ComputerMCPPlatformPOSIX",
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      resources: [.copy("Fixtures")]
    ),
    .testTarget(
      name: "ComputerMCPProcessTests",
      dependencies: [
        "ComputerMCPConfiguration", "ComputerMCPCore", "ComputerMCPPlatform",
        "ComputerMCPPlatformPOSIX", "ComputerMCPProcess", "ComputerMCPTestSupport",
        .product(name: "Subprocess", package: "swift-subprocess"),
      ]
    ),
    .testTarget(
      name: "ComputerMCPConfigurationTests",
      dependencies: [
        "ComputerMCPConfiguration", "ComputerMCPCore", "ComputerMCPPlatform",
        "ComputerMCPTestSupport",
      ]
    ),
  ]

#if os(macOS)
  let package = Package(
    name: "computer-mcp",
    defaultLocalization: "en",
    platforms: [
      .macOS(.v14)
    ],
    products: [
      .executable(
        name: "computer-mcp",
        targets: ["computer-mcp"]
      ),
      .executable(
        name: "ComputerMCPApp",
        targets: ["ComputerMCPApp"]
      ),
    ],
    dependencies: [
      .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
      loggingDependency,
      nioDependency,
      subprocessDependency,
      cryptoDependency,
      grdbDependency,
      yamsDependency,
      tomlDependency,
      systemDependency,
      mcpDependency,
    ],
    targets: neutralTargets + [
      .systemLibrary(name: "CSystemArchive"),
      .target(
        name: "ComputerMCPPlatformDarwin",
        dependencies: [
          "CSystemArchive", "ComputerMCPCore", "ComputerMCPPlatform", "ComputerMCPPlatformPOSIX",
        ]
      ),
      .target(
        name: "ComputerMCPComputerUse",
        dependencies: ["ComputerMCPCore", "ComputerMCPPlatform"]
      ),
      .testTarget(
        name: "ComputerMCPComputerUseTests",
        dependencies: [
          "ComputerMCPComputerUse", "ComputerMCPCore", "ComputerMCPPlatform",
          "ComputerMCPTestSupport",
        ]
      ),
      .target(
        name: "ComputerMCPMacOS",
        dependencies: [
          "ComputerMCPPlugins",
          "ComputerMCPComputerUse",
          "ComputerMCPToolsShell",
          "ComputerMCPToolsCLI",
          "ComputerMCPToolsGit",
          "ComputerMCPDelivery",
          "ComputerMCPToolsStructured",
          "ComputerMCPToolsSkills",
          "ComputerMCPToolsFiles",
          "ComputerMCPToolsWorkspace",
          "ComputerMCPToolsSystem",
          "ComputerMCPToolsMCP",
          "ComputerMCPDownstream",
          "ComputerMCPControlPlane", "ComputerMCPGateway", "ComputerMCPConfiguration",
          "ComputerMCPCore",
          "ComputerMCPPlatform",
          "ComputerMCPPersistence", "ComputerMCPPlatformDarwin", "ComputerMCPProcess",
          "ComputerMCPTransport",
          "ComputerMCPTunnels", "ComputerMCPToolKit",
        ]
      ),
      .executableTarget(
        name: "computer-mcp",
        dependencies: [
          "ComputerMCPPlugins", "ComputerMCPPlatformDarwin",
          "ComputerMCPToolsCLI",
          "ComputerMCPControlPlane", "ComputerMCPGateway",
          "ComputerMCPMacOS",
          "ComputerMCPConfiguration",
          "ComputerMCPCore",
          "ComputerMCPPersistence",
          "ComputerMCPPlatform",
          "ComputerMCPProcess",
          "ComputerMCPTransport",
          "ComputerMCPTunnels",
          .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]
      ),
      .executableTarget(
        name: "ComputerMCPApp",
        dependencies: [
          "ComputerMCPAuthorization",
          "ComputerMCPPlugins",
          "ComputerMCPComputerUse",
          "ComputerMCPToolsSkills",
          "ComputerMCPDownstream",
          "ComputerMCPControlPlane", "ComputerMCPGateway", "ComputerMCPMacOS",
          "ComputerMCPConfiguration",
          "ComputerMCPCore",
          "ComputerMCPPlatform",
          "ComputerMCPPlatformDarwin", "ComputerMCPProcess",
          "ComputerMCPTunnels",
        ],
        resources: [
          .process("Resources")
        ]
      ),
      .testTarget(
        name: "ComputerMCPMacOSTests",
        dependencies: [
          "computer-mcp",
          "ComputerMCPComputerUse",
          "ComputerMCPControlPlane",
          "ComputerMCPConfiguration",
          "ComputerMCPCore",
          "ComputerMCPDownstream",
          "ComputerMCPGateway",
          "ComputerMCPMacOS",
          "ComputerMCPPersistence",
          "ComputerMCPPlatform",
          "ComputerMCPPlatformDarwin",
          "ComputerMCPPlatformPOSIX",
          "ComputerMCPPlugins",
          "ComputerMCPProcess",
          "ComputerMCPTestSupport",
          "ComputerMCPToolKit",
          "ComputerMCPToolsCLI",
          "ComputerMCPToolsFiles",
          "ComputerMCPToolsSystem",
          "ComputerMCPToolsGit",
          "ComputerMCPDelivery",
          "ComputerMCPToolsMCP",
          "ComputerMCPToolsShell",
          "ComputerMCPToolsSkills",
          "ComputerMCPToolsStructured",
          "ComputerMCPToolsWorkspace",
          "ComputerMCPTransport",
          "ComputerMCPTunnels",
          .product(name: "Crypto", package: "swift-crypto"),
          .product(name: "GRDB", package: "GRDB.swift"),
          .product(name: "MCP", package: "swift-sdk"),
          .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
          .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ],
        resources: [.copy("Fixtures")]
      ),
      .testTarget(
        name: "ComputerMCPControlPlaneDarwinTests",
        dependencies: [
          "ComputerMCPControlPlane", "ComputerMCPComputerUse", "ComputerMCPGateway",
          "ComputerMCPCore", "ComputerMCPTransport", "ComputerMCPTestSupport",
        ]
      ),
      .testTarget(
        name: "ComputerMCPGatewayDarwinTests",
        dependencies: [
          "ComputerMCPCore",
          "ComputerMCPGateway",
          "ComputerMCPPlatform",
          "ComputerMCPProcess",
          "ComputerMCPTestSupport",
        ]
      ),
      .testTarget(
        name: "ComputerMCPPlatformDarwinTests",
        dependencies: [
          "ComputerMCPCore", "ComputerMCPPlatform", "ComputerMCPPlatformDarwin",
          "ComputerMCPTestSupport",
        ]
      ),
      .testTarget(
        name: "ComputerMCPToolsFilesDarwinTests",
        dependencies: [
          "ComputerMCPToolsFiles", "ComputerMCPToolKit", "ComputerMCPCore",
          "ComputerMCPConfiguration", "ComputerMCPPlatformDarwin", "ComputerMCPTestSupport",
        ]),
      .testTarget(
        name: "ComputerMCPToolsWorkspaceDarwinTests",
        dependencies: [
          "ComputerMCPToolsWorkspace", "ComputerMCPToolKit", "ComputerMCPCore",
          "ComputerMCPPlatform",
          "ComputerMCPConfiguration", "ComputerMCPPlatformDarwin", "ComputerMCPTestSupport",
        ]),
      .testTarget(
        name: "ComputerMCPToolsSystemDarwinTests",
        dependencies: [
          "ComputerMCPToolsSystem", "ComputerMCPToolKit", "ComputerMCPCore",
          "ComputerMCPConfiguration", "ComputerMCPPlatformDarwin", "ComputerMCPTestSupport",
        ]),
      .testTarget(
        name: "ComputerMCPToolsStructuredDarwinTests",
        dependencies: [
          "ComputerMCPToolsStructured",
          "ComputerMCPToolKit", "ComputerMCPCore",
          "ComputerMCPConfiguration", "ComputerMCPPlatformDarwin", "ComputerMCPTestSupport",
        ]),
      .testTarget(
        name: "ComputerMCPPluginsDarwinTests",
        dependencies: [
          "ComputerMCPPlugins", "ComputerMCPCore", "ComputerMCPConfiguration",
          "ComputerMCPPlatform",
          "ComputerMCPPlatformDarwin", "ComputerMCPProcess", "ComputerMCPTransport",
          "ComputerMCPTestSupport",
          .product(name: "MCP", package: "swift-sdk"),
        ]
      ),
      .testTarget(
        name: "ComputerMCPAppTests",
        dependencies: [
          "ComputerMCPAuthorization",
          "ComputerMCPPlugins",
          "ComputerMCPApp", "ComputerMCPControlPlane", "ComputerMCPGateway",
          "ComputerMCPMacOS",
          "ComputerMCPConfiguration",
          "ComputerMCPCore",
          "ComputerMCPPlatform", "ComputerMCPPlatformDarwin", "ComputerMCPProcess",
          "ComputerMCPTransport",
          "ComputerMCPTunnels",
          "ComputerMCPTestSupport",
        ]
      ),
    ]
  )
#elseif os(Linux)
  let package = Package(
    name: "computer-mcp",
    dependencies: [
      cryptoDependency, grdbDependency, nioDependency, subprocessDependency, systemDependency,
      tomlDependency, yamsDependency, loggingDependency, mcpDependency,
    ],
    targets: neutralTargets
  )
#else
  #error("Computer MCP supports package manifests on macOS and Linux.")
#endif
