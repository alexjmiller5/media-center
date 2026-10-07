// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MediaKit",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [.library(name: "MediaKit", targets: ["MediaKit"])],
  targets: [
    .target(name: "MediaKit", resources: [.process("Resources")]),
    .testTarget(name: "MediaKitTests", dependencies: ["MediaKit"], resources: [.process("Fixtures")]),
  ]
)
