import XCTest

/// The in-house rule (LIFT superproject,
/// `docs/superpowers/specs/2026-10-06-in-house-runtime-design.md`): at runtime
/// LIFT makes no request to any server. iOS has no internet permission to
/// withhold, so this reads the shipped source -- every Swift file under
/// `Sources/`: the app, the share extension, `Shared` and `Widgets`, and every
/// JavaScript file there (Safari runs `RecipePage.js` on the shared page) --
/// plus the watch app's, and fails on any API that makes one. Comments are
/// stripped first, so prose naming an API to explain its absence does not trip
/// it.
///
/// project.yml: `Lift` is `Sources/App` + `Sources/Shared`, `LiftWidgets` is
/// `Sources/Widgets`, `LiftShare` is `Sources/ShareExtension` plus files from
/// `Shared`. The watch lives outside `Sources/`: `LiftWatch` is
/// `Watch/LiftWatch` and links `Watch/LiftWatchKit`'s `LiftKit` and `LiftSync`,
/// and `Lift` itself links `LiftSync`. So the walk covers `Sources/`,
/// `Watch/LiftWatch` and `Watch/LiftWatchKit/Sources` -- not the package's
/// tests, which ship in nothing.
final class NoNetworkTests: XCTestCase {

    static let forbidden = ["URLSession", "URLRequest", "NWConnection",
                            "import Network", "import MapKit", "import WebKit", "AsyncImage("]

    /// What would make a request from JavaScript Safari runs for LIFT. `import(`
    /// is a dynamic import, which fetches a module.
    static let forbiddenInJS = ["fetch(", "XMLHttpRequest", "WebSocket", "sendBeacon", "import("]

    static func offences(in code: String, forbidden: [String] = forbidden) -> [String] {
        // Line comments go first: a block comment opening inside a line comment
        // (`// see /* note`) must not delete real code up to a later `*/`.
        // Stripping in this order can only leave comment text behind, which
        // fails loudly rather than hiding a call.
        var stripped = code.replacingOccurrences(of: "//[^\n]*", with: "",
                                                 options: .regularExpression)
        stripped = stripped.replacingOccurrences(of: "/\\*[\\s\\S]*?\\*/", with: "",
                                                 options: .regularExpression)
        return forbidden.filter { stripped.contains($0) }
    }

    func testTheScannerCatchesCodeAndIgnoresComments() {
        XCTAssertEqual(Self.offences(in: "let s = URLSession.shared"), ["URLSession"])
        XCTAssertEqual(Self.offences(in: "// URLSession is not used here\nlet x = 1"), [])
        XCTAssertEqual(Self.offences(in: "/* import MapKit */\nimport SwiftUI"), [])
        XCTAssertEqual(Self.offences(in: "import MapKit\n"), ["import MapKit"])
        // AsyncImage fetches a URL, so it is as much a request as URLSession.
        XCTAssertEqual(Self.offences(in: "let i = AsyncImage(url: u)"), ["AsyncImage("])
        // A `/*` inside a line comment must not swallow the real code after it.
        XCTAssertEqual(Self.offences(in: "// see /* note\nlet s = URLSession.shared\n// */"), ["URLSession"])
    }

    func testTheScannerCatchesJavaScriptAndIgnoresItsComments() {
        XCTAssertEqual(Self.offences(in: "fetch(document.URL).then(f);", forbidden: Self.forbiddenInJS), ["fetch("])
        XCTAssertEqual(Self.offences(in: "// no fetch( here\n/* new XMLHttpRequest() */\nvar a = 1;",
                                     forbidden: Self.forbiddenInJS), [])
    }

    /// Every folder shipped Swift is compiled from, relative to the repo root.
    static let shippedRoots = ["Sources", "Watch/LiftWatch", "Watch/LiftWatchKit/Sources"]

    func testLiftMakesNoRequest() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let all = Self.shippedRoots.flatMap { folder in
            FileManager.default.enumerator(at: root.appendingPathComponent(folder),
                                           includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL } ?? []
        }
        let files = all.filter { $0.pathExtension == "swift" }
        let scripts = all.filter { $0.pathExtension == "js" }
        XCTAssertGreaterThan(files.count, 20, "found too little source to check under \(root.path)")
        // The share extension and the widget are shipped code too; a scan that
        // missed either folder would pass while it was free to make a request.
        XCTAssertTrue(files.contains { $0.pathComponents.contains("ShareExtension") },
                      "no file under Sources/ShareExtension was scanned")
        XCTAssertTrue(files.contains { $0.pathComponents.contains("Widgets") },
                      "no file under Sources/Widgets was scanned")
        // The watch app, and the wire types both the watch and this app compile.
        XCTAssertTrue(files.contains { $0.pathComponents.contains("LiftWatch") },
                      "no file under Watch/LiftWatch was scanned")
        XCTAssertTrue(files.contains { $0.pathComponents.contains("LiftSync") },
                      "no file under Watch/LiftWatchKit/Sources/LiftSync was scanned")
        // Safari runs this one on whatever page the lifter shares.
        XCTAssertTrue(scripts.contains { $0.lastPathComponent == "RecipePage.js" },
                      "RecipePage.js was not scanned")
        var found: [String] = []
        for file in files {
            found += Self.offences(in: try String(contentsOf: file, encoding: .utf8))
                .map { "\(file.lastPathComponent): \($0)" }
        }
        for file in scripts {
            found += Self.offences(in: try String(contentsOf: file, encoding: .utf8), forbidden: Self.forbiddenInJS)
                .map { "\(file.lastPathComponent): \($0)" }
        }
        XCTAssertEqual(found, [], "a network API in shipped source -- see the in-house rule")
    }
}
