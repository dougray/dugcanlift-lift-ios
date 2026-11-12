import XCTest
@testable import Lift

/// Street maps link MapLibre, which is a network-capable binary and a large
/// one. Only the app target may link `LiftMap` / `LiftMapCore`: the widget, the
/// share extension, the watch app and the test bundle must not, so a widget
/// never carries a map renderer and an extension never carries the download
/// code. Read from `project.yml`, the source of truth for targets.
final class MapTargetsTests: XCTestCase {

    /// The text of one top-level entry under `targets:`, up to the next one.
    static func targetBlocks(in yml: String) -> [String: String] {
        var blocks: [String: String] = [:]
        var inTargets = false
        var current: String?
        var lines: [String] = []
        func flush() { if let current { blocks[current] = lines.joined(separator: "\n") } }
        for line in yml.components(separatedBy: "\n") {
            if line.hasPrefix("targets:") { inTargets = true; continue }
            if inTargets, let first = line.first, first != " ", first != "#" {
                flush(); current = nil; lines = []; inTargets = false   // `schemes:` etc.
                continue
            }
            guard inTargets else { continue }
            if line.hasPrefix("  "), !line.hasPrefix("   "), line.hasSuffix(":"),
               !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                flush()
                current = line.trimmingCharacters(in: .whitespaces).dropLast().description
                lines = []
            } else {
                lines.append(line)
            }
        }
        flush()
        return blocks
    }

    private func targets() throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let yml = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        return Self.targetBlocks(in: yml)
    }

    /// Product names a target lists, comments stripped.
    private func products(_ block: String) -> [String] {
        block.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "#.*", with: "", options: .regularExpression) }
            .compactMap { line -> String? in
                let t = line.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("product:") ? String(t.dropFirst("product:".count)).trimmingCharacters(in: .whitespaces) : nil
            }
    }

    func testTheScannerReadsTargets() throws {
        let found = try targets()
        for name in ["Lift", "LiftWidgets", "LiftShare", "LiftWatch", "LiftTests"] {
            XCTAssertNotNil(found[name], "no target \(name) found in project.yml")
        }
    }

    func testOnlyTheAppLinksTheMap() throws {
        let found = try targets()
        let app = try XCTUnwrap(found["Lift"])
        XCTAssertTrue(products(app).contains("LiftMap"), "Lift does not link LiftMap")
        XCTAssertTrue(products(app).contains("LiftMapCore"), "Lift does not link LiftMapCore")
        for (name, block) in found where name != "Lift" {
            let linked = products(block).filter { $0.hasPrefix("LiftMap") }
            XCTAssertEqual(linked, [], "\(name) must not link \(linked)")
        }
    }

    func testTheKitIsPinnedToTheMapRelease() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let yml = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(yml.contains("exactVersion: 1.18.0"))
    }

    /// The share extension and the widget compile no file that imports the map.
    func testNoExtensionSourceImportsTheMap() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        for folder in ["Sources/Widgets", "Sources/ShareExtension", "Watch/LiftWatch", "Sources/Shared"] {
            let files = (FileManager.default.enumerator(at: root.appendingPathComponent(folder),
                                                        includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "swift" }
            XCTAssertFalse(files.isEmpty, "nothing scanned under \(folder)")
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                XCTAssertFalse(text.contains("import LiftMap"), "\(file.lastPathComponent) imports the map")
            }
        }
    }

    /// The licenses the app must carry for the maps, and the screen that shows them.
    func testTheMapLicensesAreBundledAndReachable() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Resources/MapLicenses.txt"),
                              encoding: .utf8)
        XCTAssertTrue(text.contains("BSD 2-Clause License"))
        XCTAssertTrue(text.contains("Copyright (c) 2021 MapLibre contributors"))
        XCTAssertTrue(text.contains("SIL OPEN FONT LICENSE Version 1.1"))
        XCTAssertTrue(text.contains("OpenStreetMap contributors"))
        XCTAssertTrue(text.contains("OpenFreeMap"))
        let settings = try String(contentsOf: root.appendingPathComponent("Sources/App/SettingsView.swift"),
                                  encoding: .utf8)
        XCTAssertTrue(settings.contains("MapLicenseView()"), "Settings does not link the map licenses")
        XCTAssertNotNil(Bundle.main.url(forResource: MapLicenseView.fileName, withExtension: "txt"),
                        "MapLicenses.txt is not in the app bundle")
    }
}
