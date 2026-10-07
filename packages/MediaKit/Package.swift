// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MediaKit", targets: ["MediaKit"])],
    targets: [
        .target(name: "MediaKit"),
        .testTarget(name: "MediaKitTests", dependencies: ["MediaKit"])
    ]
)
