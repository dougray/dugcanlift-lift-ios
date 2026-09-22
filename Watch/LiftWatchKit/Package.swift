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
        // The watch app's domain: everything the watch runs that needs no
        // watchOS framework. The watch app links this one.
        .library(name: "LiftKit", targets: ["LiftKit"]),
        // The WatchConnectivity wire types (SyncEnvelope, WorkoutPlan,
        // RecentFoodsSnapshot), compiled once for both ends: the watch gets
        // them through LiftKit, and the iPhone app links this product alone,
        // so it takes on none of the watch's domain or its 634 KB food
        // library. Nothing here may depend on LiftKit.
        .library(name: "LiftSync", targets: ["LiftSync"])
    ],
    targets: [
        .target(name: "LiftSync"),
        .target(name: "LiftKit", dependencies: ["LiftSync"],
                resources: [.copy("Resources/foods.json")]),
        .testTarget(name: "LiftSyncTests", dependencies: ["LiftSync"]),
        .testTarget(name: "LiftKitTests", dependencies: ["LiftKit", "LiftSync"])
    ]
)
