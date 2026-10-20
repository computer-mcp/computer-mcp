// swift-tools-version: 6.2

import PackageDescription

let subprocessDependency: Package.Dependency =
  .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "0.4.0")

let cryptoDependency: Package.Dependency =
  .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2")

let tomlDependency: Package.Dependency =
  .package(url: "https://github.com/mattt/swift-toml.git", from: "2.0.0")

let grdbDependency: Package.Dependency =
  .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0")

let nioDependency: Package.Dependency =
  .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.0")

// FilePath comes from the System framework on Apple platforms and from swift-system elsewhere.
let systemDependency: Package.Dependency =
  .package(url: "https://github.com/apple/swift-system.git", from: "1.7.2")

let loggingDependency: Package.Dependency =
  .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0")

let mcpDependency: Package.Dependency =
  .package(url: "https://github.com/computer-mcp/swift-sdk.git", exact: "0.13.1-computer-mcp.1")

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
        "ComputerMCPCore", "ComputerMCPPlatformPOSIX",
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
        "ComputerMCPConfiguration", "ComputerMCPTunnels",
      ],
      path: "Tests/ComputerMCPTestSupport"),
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
    .testTarget(name: "ComputerMCPPlatformTests", dependencies: ["ComputerMCPPlatform"]),
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
      .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.0"),
      loggingDependency,
      nioDependency,
      subprocessDependency,
      cryptoDependency,
      grdbDependency,
      .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
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
        name: "ComputerMCPMacOS",
        dependencies: [
          "ComputerMCPDownstream",
          "ComputerMCP", "ComputerMCPConfiguration", "ComputerMCPCore", "ComputerMCPPlatform",
          "ComputerMCPPersistence", "ComputerMCPPlatformDarwin", "ComputerMCPProcess",
          "ComputerMCPTransport",
          "ComputerMCPTunnels", "ComputerMCPToolKit",
        ]
      ),
      .target(
        name: "ComputerMCP",
        dependencies: [
          "ComputerMCPDownstream",
          "ComputerMCPConfiguration",
          "ComputerMCPCore",
          "ComputerMCPPersistence",
          "ComputerMCPPlatform",
          "ComputerMCPPlatformDarwin",
          "ComputerMCPPlatformPOSIX",
          "ComputerMCPProcess",
          "ComputerMCPToolKit",
          "ComputerMCPTransport",
          "ComputerMCPTunnels",
          .product(name: "MCP", package: "swift-sdk"),
          .product(name: "GRDB", package: "GRDB.swift"),
          .product(name: "Logging", package: "swift-log"),
          .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
          .product(name: "NIOCore", package: "swift-nio"),
          .product(name: "NIOHTTP1", package: "swift-nio"),
          .product(name: "NIOPosix", package: "swift-nio"),
          .product(name: "Subprocess", package: "swift-subprocess"),
          .product(name: "TOML", package: "swift-toml"),
          .product(name: "Yams", package: "Yams"),
        ],
        exclude: ["ComputerMCP.docc"]
      ),
      .executableTarget(
        name: "computer-mcp",
        dependencies: [
          "ComputerMCP",
          "ComputerMCPMacOS",
          "ComputerMCPConfiguration",
          "ComputerMCPCore",
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
          "ComputerMCPDownstream",
          "ComputerMCP", "ComputerMCPMacOS", "ComputerMCPConfiguration", "ComputerMCPCore",
          "ComputerMCPPlatform",
          "ComputerMCPPlatformDarwin", "ComputerMCPProcess",
          "ComputerMCPTransport",
          "ComputerMCPTunnels",
        ],
        resources: [
          .process("Resources")
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
        name: "ComputerMCPTests",
        dependencies: [
          "ComputerMCPDownstream",
          "ComputerMCP", "ComputerMCPMacOS", "ComputerMCPConfiguration", "ComputerMCPCore",
          "ComputerMCPPlatform",
          "ComputerMCPPersistence", "ComputerMCPPlatformDarwin", "ComputerMCPPlatformPOSIX",
          "ComputerMCPProcess",
          "ComputerMCPToolKit",
          "ComputerMCPTransport",
          "ComputerMCPTunnels",
          "ComputerMCPTestSupport",
          .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
        ],
        resources: [.copy("Fixtures")]
      ),
      .testTarget(
        name: "ComputerMCPAppTests",
        dependencies: [
          "ComputerMCPApp", "ComputerMCP", "ComputerMCPMacOS", "ComputerMCPConfiguration",
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
      tomlDependency, loggingDependency, mcpDependency,
    ],
    targets: neutralTargets
  )
#else
  #error("Computer MCP supports package manifests on macOS and Linux.")
#endif
