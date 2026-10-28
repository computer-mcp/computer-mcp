// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "WorktreeFixture",
  targets: [
    .target(name: "WorktreeFixture"),
    .testTarget(name: "WorktreeFixtureTests", dependencies: ["WorktreeFixture"]),
  ])
