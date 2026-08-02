// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "computer-mcp-validation",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(
      name: "computer-mcp-validate",
      targets: ["ComputerMCPValidationCLI"]
    )
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.0"),
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
  ],
  targets: [
    .target(
      name: "ComputerMCPValidation",
      dependencies: [],
      resources: [.process("Cases")]
    ),
    .executableTarget(
      name: "ComputerMCPValidationCLI",
      dependencies: [
        "ComputerMCPValidation",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "MCP", package: "swift-sdk"),
      ]
    ),
    .testTarget(
      name: "ComputerMCPValidationTests",
      dependencies: [
        "ComputerMCPValidation"
      ]
    ),
  ]
)
