// swift-tools-version: 6.2

import PackageDescription

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
    .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.0"),
    .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "0.4.0"),
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
    .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
    .package(url: "https://github.com/mattt/swift-toml.git", from: "2.0.0"),
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    .package(
      url: "https://github.com/swift-library/swift-codex.git",
      exact: "0.1.2"
    ),
  ],
  targets: [
    .target(
      name: "ComputerMCP",
      dependencies: [
        .product(name: "MCP", package: "swift-sdk"),
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "Subprocess", package: "swift-subprocess"),
        .product(name: "TOML", package: "swift-toml"),
        .product(name: "Yams", package: "Yams"),
        .product(name: "CodexAppServerClient", package: "swift-codex"),
        .product(name: "CodexAppServerProtocol", package: "swift-codex"),
        .product(name: "CodexAppServerStdio", package: "swift-codex"),
        .product(name: "CodexExec", package: "swift-codex"),
        .product(name: "CodexMCP", package: "swift-codex"),
      ]
    ),
    .executableTarget(
      name: "computer-mcp",
      dependencies: [
        "ComputerMCP",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .executableTarget(
      name: "ComputerMCPApp",
      dependencies: ["ComputerMCP"],
      resources: [
        .process("Resources")
      ]
    ),
    .testTarget(
      name: "ComputerMCPTests",
      dependencies: ["ComputerMCP"]
    ),
    .testTarget(
      name: "ComputerMCPAppTests",
      dependencies: ["ComputerMCPApp", "ComputerMCP"]
    ),
  ]
)
