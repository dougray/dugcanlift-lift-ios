// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LiftKit",
    platforms: [.watchOS(.v10), .iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LiftKit", targets: ["LiftKit"])
    ],
    targets: [
        .target(name: "LiftKit", resources: [.copy("Resources/foods.json")]),
        .testTarget(name: "LiftKitTests", dependencies: ["LiftKit"])
    ]
)
