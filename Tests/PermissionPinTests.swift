import XCTest

/// What LIFT on iPhone, its extensions and its Apple Watch app may ask iOS for,
/// pinned against the public privacy policy.
///
/// `www.dugcanlift.com/app/privacy/` (`dugcanlift-site/app-privacy.md`) tells
/// people exactly what each version touches, in these sections:
///
/// - "Location: recording runs, walks and hikes" -- iPhone: while in use only,
///   "never for 'Always'", carrying on with the phone locked; Apple Watch: only
///   while recording, with a workout session to keep GPS on.
/// - "Health Connect and Apple Health" -- iPhone reads steps and bodyweight and
///   writes workouts and outdoor activities; the watch reads heart rate and
///   active energy during a strength session and writes workouts.
/// - "Camera" -- iPhone: barcode scanning only.
/// - "Notifications (iPhone)" -- the end of a rest, scheduled on the phone (no
///   Info.plist key: iOS asks at `requestAuthorization`).
/// - "Progress photos (iPhone)" -- the system photo picker, which needs no
///   photo-library key, so there must not be one.
/// - "The watch apps" -- Apple Watch.
///
/// iOS's answer to an Android permission list is three things, and this pins
/// each one to an explicit list: every `NS…UsageDescription` key (iOS refuses a
/// protected resource to an app without its purpose string, so these keys *are*
/// what LIFT can ask for), the background modes, and every entitlement.
///
/// **A change here fails the build until someone has updated the privacy page
/// to match.** That page is public copy and Doug reviews it, so update
/// `app-privacy.md` first, then the list below -- never the list alone.
///
/// Usage keys and background modes are read from the *built* bundles at
/// runtime -- the test host is Lift.app, its extensions are in `PlugIns/` and
/// the watch app is embedded at `Watch/LiftWatch.app` -- which catches a key
/// however it got there: project.yml's `info.properties`, an `INFOPLIST_KEY_`
/// build setting, or a hand-edited plist. Entitlements are read from the files
/// xcodegen renders from project.yml (`make app-test` runs `xcodegen generate`
/// first) and the tracked `Lift-free.entitlements`, since a simulator build
/// does not expose its signed entitlements to a test.
final class PermissionPinTests: XCTestCase {

    struct BundlePin: Equatable {
        var usageDescriptions: Set<String> = []
        var backgroundModes: [String] = []
        var watchBackgroundModes: [String] = []
    }

    static let bundles: [String: BundlePin] = [
        "Lift.app": BundlePin(
            usageDescriptions: [
                // "Health Connect and Apple Health" > "iPhone — Apple Health".
                "NSHealthShareUsageDescription",
                "NSHealthUpdateUsageDescription",
                // "Camera" > "The iPhone app": barcodes only.
                "NSCameraUsageDescription",
                // "Location" > "iPhone": while in use, never Always -- so no
                // NSLocationAlwaysAndWhenInUseUsageDescription.
                "NSLocationWhenInUseUsageDescription",
            ],
            // `location` is "A recording you start keeps going with the phone
            // locked". `processing` comes with project.yml's
            // BGTaskSchedulerPermittedIdentifiers (com.dugcanlift.lift.healthsync)
            // for a background HealthKit sync.
            backgroundModes: ["processing", "location"]),
        // Neither extension asks for anything: the widget reads the App Group
        // store, and the share extension reads only what the share sheet hands it.
        "PlugIns/LiftShare.appex": BundlePin(),
        "PlugIns/LiftWidgets.appex": BundlePin(),
        // "Health Connect and Apple Health" > "Apple Watch", "Location" >
        // "Apple Watch" and "The watch apps".
        "Watch/LiftWatch.app": BundlePin(
            usageDescriptions: [
                "NSHealthShareUsageDescription",
                "NSHealthUpdateUsageDescription",
                "NSLocationWhenInUseUsageDescription",
            ],
            backgroundModes: ["location"],
            watchBackgroundModes: ["location", "workout-processing"]),
    ]

    /// project.yml's `entitlements.properties`, file by file, plus the tracked
    /// free-team variant `make device-build` signs the app with.
    static let entitlements: [String: NSDictionary] = [
        "Lift.entitlements": [
            "com.apple.security.application-groups": ["group.com.dugcanlift.lift"],
            "com.apple.developer.healthkit": true,
            "com.apple.developer.healthkit.access": [String](),
            "com.apple.developer.associated-domains": ["applinks:www.dugcanlift.com"],
        ],
        "Lift-free.entitlements": [
            "com.apple.security.application-groups": ["group.com.dugcanlift.lift"],
            "com.apple.developer.healthkit": true,
            "com.apple.developer.healthkit.access": [String](),
        ],
        "LiftWidgets.entitlements": [
            "com.apple.security.application-groups": ["group.com.dugcanlift.lift"],
        ],
        "LiftShare.entitlements": [
            "com.apple.security.application-groups": ["group.com.dugcanlift.lift"],
        ],
        "LiftWatch.entitlements": [
            "com.apple.developer.healthkit": true,
            "com.apple.developer.healthkit.access": [String](),
        ],
    ]

    static let page = "dugcanlift-site/app-privacy.md (\"Location\", \"Health Connect and Apple Health\", \"Camera\", \"Notifications (iPhone)\", \"Progress photos (iPhone)\", \"The watch apps\")"

    static func pin(ofInfo info: [String: Any]) -> BundlePin {
        BundlePin(usageDescriptions: Set(info.keys.filter { $0.hasPrefix("NS") && $0.contains("UsageDescription") }),
                  backgroundModes: info["UIBackgroundModes"] as? [String] ?? [],
                  watchBackgroundModes: info["WKBackgroundModes"] as? [String] ?? [])
    }

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    func testTheHostIsTheShippedApp() {
        // Everything below reads Bundle.main as Lift.app; a test bundle that
        // stopped being hosted would quietly read its own Info.plist instead.
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.dugcanlift.lift")
        XCTAssertEqual(Bundle.main.bundleURL.lastPathComponent, "Lift.app")
    }

    func testEveryBuiltBundleAsksForExactlyWhatThePrivacyPageSays() throws {
        let app = Bundle.main.bundleURL
        func children(_ folder: String, _ ext: String) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(
                at: app.appendingPathComponent(folder), includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == ext }.map { "\(folder)/\($0.lastPathComponent)" }
        }
        let found = ["Lift.app"] + children("PlugIns", "appex") + children("Watch", "app")
        // A new extension, or a watch app under another name, is a new bundle
        // with its own Info.plist, so it must be pinned before it can ship.
        XCTAssertEqual(Set(found), Set(Self.bundles.keys), "the set of shipped bundles changed -- pin it, and check \(Self.page)")

        for name in found {
            let url = name == "Lift.app" ? app : app.appendingPathComponent(name)
            let info = try XCTUnwrap(Bundle(url: url)?.infoDictionary, "no Info.plist in \(name)")
            XCTAssertEqual(Self.pin(ofInfo: info), Self.bundles[name],
                           "\(name) asks iOS for something new. Update \(Self.page) first, then this pin.")
        }
    }

    func testEntitlementsAreExactlyWhatThePrivacyPageSays() throws {
        let config = Self.repoRoot.appendingPathComponent("Config")
        let files = try FileManager.default.contentsOfDirectory(at: config, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "entitlements" }
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), Set(Self.entitlements.keys),
                       "the set of entitlements files changed (did `xcodegen generate` run?) -- pin it, and check \(Self.page)")
        for file in files {
            let parsed = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil)
            let actual = try XCTUnwrap(parsed as? NSDictionary, "\(file.lastPathComponent) is not a dictionary")
            XCTAssertEqual(actual, Self.entitlements[file.lastPathComponent],
                           "\(file.lastPathComponent) changed. Update \(Self.page) first, then this pin.")
        }
    }

    /// project.yml names every entitlements file it renders or signs with, so a
    /// target that points somewhere outside Config/ cannot dodge the check above.
    func testProjectYmlNamesOnlyThePinnedEntitlementsFiles() throws {
        let yml = try String(contentsOf: Self.repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        let named = yml.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), trimmed.hasSuffix(".entitlements"),
                  let path = trimmed.split(separator: ":", maxSplits: 1).last else { return nil }
            return path.trimmingCharacters(in: .whitespaces)
        }
        XCTAssertEqual(Set(named), Set(Self.entitlements.keys.map { "Config/\($0)" }))
    }

    func testTheReaderSeesAUsageKey() {
        // The filter above must actually find one, or every pin passes for nothing.
        let pin = Self.pin(ofInfo: ["NSCameraUsageDescription": "x", "NSLocationTemporaryUsageDescriptionDictionary": [:],
                                    "NSSupportsLiveActivities": true, "UIBackgroundModes": ["location"],
                                    "WKBackgroundModes": ["workout-processing"]])
        XCTAssertEqual(pin, BundlePin(usageDescriptions: ["NSCameraUsageDescription", "NSLocationTemporaryUsageDescriptionDictionary"],
                                      backgroundModes: ["location"], watchBackgroundModes: ["workout-processing"]))
    }
}
