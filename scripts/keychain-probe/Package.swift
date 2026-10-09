// swift-tools-version: 6.0
import PackageDescription

// Release gate only: links the production MediaKit credential store.
let package = Package(
  name: "KeychainProbe",
  platforms: [.macOS(.v14)],
  dependencies: [.package(path: "../../packages/MediaKit")],
  targets: [.executableTarget(name: "KeychainProbe", dependencies: ["MediaKit"])]
)
