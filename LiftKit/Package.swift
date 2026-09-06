// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LiftKit",
    platforms: [.watchOS(.v10), .iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LiftKit", targets: ["LiftKit"])
    ],
    targets: [
        .target(name: "LiftKit"),
        .testTarget(name: "LiftKitTests", dependencies: ["LiftKit"])
    ]
)
