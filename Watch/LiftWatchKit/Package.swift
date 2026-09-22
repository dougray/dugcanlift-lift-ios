// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    // Not "LiftKit": this app also depends on dugcanlift-kit, whose package
    // is named LiftKit too, and Xcode treats a local package with a remote
    // package's name as an override of it and refuses to resolve ("unable to
    // override package 'LiftKit' because its identity 'dugcanlift-kit'
    // doesn't match override's identity"). The product and module stay
    // LiftKit, so the watch app's imports do not change.
    name: "LiftWatchKit",
    platforms: [.watchOS(.v10), .iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LiftKit", targets: ["LiftKit"])
    ],
    targets: [
        .target(name: "LiftKit", resources: [.copy("Resources/foods.json")]),
        .testTarget(name: "LiftKitTests", dependencies: ["LiftKit"])
    ]
)
