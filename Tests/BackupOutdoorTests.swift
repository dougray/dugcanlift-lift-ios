import XCTest
import SwiftData
import LiftCore
@testable import Lift

/// Runs, walks and hikes in the backup file, against coach/BACKUP-FORMAT.md
/// `outdoor[]`.
///
/// `web-backup-outdoor.json` was written by LIFT web's own `outdoor.js
/// toBackup`, over the finished activities in its outdoor-share-input fixture.
/// It is the test that proves this app reads what the web writes rather than
/// agreeing with itself. Do not regenerate it from this code.
final class BackupOutdoorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        clearDefaults()
    }

    override func tearDown() {
        clearDefaults()
        super.tearDown()
    }

    private func clearDefaults() {
        UserDefaults.standard.removeObject(forKey: BackupStore.foreignDataKey)
        UserDefaults.standard.removeObject(forKey: BackupStore.foreignExtKey)
    }

    private func makeContext() -> ModelContext {
        ModelContext(LiftStore.makeContainer(inMemory: true))
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"),
                                "fixture \(name).json is not in the test bundle")
        return try Data(contentsOf: url)
    }

    private func file(_ data: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["v": 1, "app": "lift", "saved": "2026-09-16", "data": data])
    }

    private func activities(_ context: ModelContext) throws -> [OutdoorActivity] {
        try context.fetch(FetchDescriptor<OutdoorActivity>(sortBy: [SortDescriptor(\.startedAt)]))
    }

    private func outdoorSection(_ backup: Data) throws -> [[String: Any]] {
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: backup) as? [String: Any])
        let data = try XCTUnwrap(root["data"] as? [String: Any])
        return try XCTUnwrap(data["outdoor"] as? [[String: Any]])
    }

    // MARK: - Interop

    func testAWebBackupRestoresEveryFinishedActivity() throws {
        let context = makeContext()
        let result = BackupStore.restore(context: context, from: try fixture("web-backup-outdoor"))
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.added, 3)

        let stored = try activities(context)
        XCTAssertEqual(stored.map(\.activityType), [.run, .walk, .run])
        XCTAssertEqual(stored.map { $0.routePoints.count }, [60, 12, 400])
        XCTAssertEqual(stored.map(\.distanceMeters), [10001.4, 299.7, 2794.6])
        XCTAssertEqual(stored.map(\.elevationGainMeters), [0, 0, 36.7])
        XCTAssertTrue(stored.allSatisfy { $0.healthKitUUID == nil }, "a restore never claims a Health export")

        let longRun = stored[0]
        XCTAssertEqual(longRun.startedAt, Date(timeIntervalSince1970: 1_789_000_000))
        XCTAssertEqual(longRun.duration, 3000)
        XCTAssertEqual(longRun.id, BackupStore.recordID("run-long"), "a non-UUID id derives a stable UUID")
        let second = longRun.routePoints[1]
        XCTAssertEqual(second.latitude, 30.301524)
        XCTAssertEqual(second.longitude, -97.8)
        XCTAssertEqual(second.recordedAt, Date(timeIntervalSince1970: 1_789_000_060))
        XCTAssertEqual(second.horizontalAccuracyMeters, 9)
        XCTAssertLessThan(second.verticalAccuracyMeters, 0, "a null altitude is CoreLocation's invalid altitude")

        let loop = stored[2]
        XCTAssertEqual(loop.routePoints.first?.altitudeMeters, 150)
        XCTAssertGreaterThanOrEqual(loop.routePoints.first?.verticalAccuracyMeters ?? -1, 0)
        XCTAssertEqual(loop.routePoints.last?.recordedAt, Date(timeIntervalSince1970: 1_789_260_796))
    }

    func testRestoringTheSameFileTwiceAddsNothing() throws {
        let context = makeContext()
        let data = try fixture("web-backup-outdoor")
        XCTAssertEqual(BackupStore.restore(context: context, from: data).added, 3)
        XCTAssertEqual(BackupStore.restore(context: context, from: data).added, 0)
        XCTAssertEqual(try activities(context).count, 3)
    }

    // MARK: - Round trip

    func testAnIOSActivityRoundTripsThroughTheFile() throws {
        let source = makeContext()
        let start = Date(timeIntervalSince1970: 1_789_500_000)
        let activity = OutdoorActivity(activityType: .hike, startedAt: start)
        activity.endedAt = start.addingTimeInterval(3600)
        activity.distanceMeters = 5123.4
        activity.elevationGainMeters = 210.5
        activity.activeCalories = 480
        activity.healthKitUUID = UUID()
        activity.routePoints = [
            RoutePoint(latitude: 47.6, longitude: -122.3, altitudeMeters: 20, recordedAt: start,
                       horizontalAccuracyMeters: 5, verticalAccuracyMeters: 4),
            RoutePoint(latitude: 47.61, longitude: -122.31, altitudeMeters: 0, recordedAt: start.addingTimeInterval(30),
                       horizontalAccuracyMeters: 8, verticalAccuracyMeters: -1)
        ]
        source.insert(activity)

        let unfinished = OutdoorActivity(activityType: .run, startedAt: start.addingTimeInterval(7200))
        source.insert(unfinished)
        try source.save()

        let backup = try BackupStore.build(context: source)
        let section = try outdoorSection(backup)
        XCTAssertEqual(section.count, 1, "a recording still in progress is never written")
        let record = section[0]
        XCTAssertEqual(record["activityType"] as? String, "HIKE")
        XCTAssertEqual(record["startedAtEpochMs"] as? Int, 1_789_500_000_000)
        XCTAssertEqual(record["endedAtEpochMs"] as? Int, 1_789_503_600_000)
        let points = try XCTUnwrap(record["routePoints"] as? [[String: Any]])
        XCTAssertEqual(points[0]["altitudeMeters"] as? Double, 20)
        XCTAssertTrue(points[1]["altitudeMeters"] is NSNull, "an unmeasured altitude is written as null")
        XCTAssertEqual(Set(points[0].keys),
                       ["latitude", "longitude", "altitudeMeters", "recordedAtEpochMs", "horizontalAccuracyMeters"])

        UserDefaults.standard.removeObject(forKey: BackupStore.foreignDataKey)
        let target = makeContext()
        XCTAssertEqual(BackupStore.restore(context: target, from: backup).added, 1)
        let restored = try XCTUnwrap(try activities(target).first)
        XCTAssertEqual(restored.id, activity.id)
        XCTAssertEqual(restored.activityType, .hike)
        XCTAssertEqual(restored.startedAt, start)
        XCTAssertEqual(restored.endedAt, activity.endedAt)
        XCTAssertEqual(restored.distanceMeters, 5123.4)
        XCTAssertEqual(restored.elevationGainMeters, 210.5)
        XCTAssertEqual(restored.activeCalories, 480)
        XCTAssertNil(restored.healthKitUUID, "exported on that phone says nothing about Health on this one")
        XCTAssertEqual(restored.routePoints.map(\.latitude), [47.6, 47.61])
        XCTAssertEqual(restored.routePoints.map(\.recordedAt), activity.routePoints.map(\.recordedAt))
        XCTAssertEqual(restored.routePoints[0].altitudeMeters, 20)
        XCTAssertLessThan(restored.routePoints[1].verticalAccuracyMeters, 0)
    }

    // MARK: - Ids and rules

    func testIdsDifferingOnlyInCaseDoNotDuplicate() throws {
        let context = makeContext()
        let id = UUID()
        let existing = OutdoorActivity(activityType: .run, startedAt: Date(timeIntervalSince1970: 1_789_000_000))
        existing.id = id
        existing.endedAt = existing.startedAt.addingTimeInterval(600)
        context.insert(existing)
        try context.save()

        func record(_ id: String) -> [String: Any] {
            ["id": id, "activityType": "RUN", "startedAtEpochMs": 1_789_000_000_000,
             "endedAtEpochMs": 1_789_000_600_000, "distanceMeters": 1000, "elevationGainMeters": 0,
             "routePoints": []]
        }
        let other = UUID().uuidString
        let data = try file(["outdoor": [record(id.uuidString.lowercased()),
                                         record(other.lowercased()),
                                         record(other.uppercased())]])
        XCTAssertEqual(BackupStore.restore(context: context, from: data).added, 1,
                       "the phone's own id in lower case is the same activity, and so is a repeat in the file")
        XCTAssertEqual(try activities(context).count, 2)
    }

    func testUnfinishedUnknownAndIdlessRecordsAreSkipped() throws {
        let context = makeContext()
        let base: [String: Any] = ["activityType": "WALK", "startedAtEpochMs": 1_789_000_000_000,
                                   "endedAtEpochMs": 1_789_000_600_000]
        var unfinished = base; unfinished["id"] = "a"; unfinished["endedAtEpochMs"] = NSNull()
        var unknown = base; unknown["id"] = "b"; unknown["activityType"] = "SWIM"
        let idless = base
        var noDistance = base
        noDistance["id"] = "c"
        noDistance["routePoints"] = [
            ["latitude": 30.0, "longitude": -97.0, "altitudeMeters": NSNull(), "recordedAtEpochMs": 1_789_000_000_000, "horizontalAccuracyMeters": 5],
            ["latitude": 30.001, "longitude": -97.0, "altitudeMeters": NSNull(), "recordedAtEpochMs": 1_789_000_060_000, "horizontalAccuracyMeters": 5],
            ["latitude": "x", "longitude": -97.0]
        ]

        let data = try file(["outdoor": [unfinished, unknown, idless, noDistance]])
        XCTAssertEqual(BackupStore.restore(context: context, from: data).added, 1)
        let walk = try XCTUnwrap(try activities(context).first)
        XCTAssertEqual(walk.routePoints.count, 2, "a point without a numeric position is dropped")
        XCTAssertEqual(walk.distanceMeters, 111.2, accuracy: 0.1, "a missing distance is measured from the route")
        XCTAssertEqual(walk.elevationGainMeters, 0)
    }

    // MARK: - A copy an earlier build preserved

    /// Before this build, a restored `outdoor` section was kept as foreign data
    /// and written back out untouched. It must reach the store, not vanish now
    /// that `outdoor` is written from the store.
    func testAPreservedSectionIsStoredAtTheNextSave() throws {
        let context = makeContext()
        let web = try outdoorSection(try fixture("web-backup-outdoor"))
        let preserved = try JSONSerialization.data(withJSONObject: ["outdoor": web, "routines": [["id": "r1"]]])
        UserDefaults.standard.set(preserved, forKey: BackupStore.foreignDataKey)

        let backup = try BackupStore.build(context: context)

        XCTAssertEqual(try activities(context).count, 3, "the preserved activities are now the phone's own")
        XCTAssertEqual(try outdoorSection(backup).count, 3)
        let remaining = BackupStore.storedForeignData()
        XCTAssertNil(remaining["outdoor"], "no longer held as foreign data")
        XCTAssertNotNil(remaining["routines"], "other preserved sections are left alone")

        _ = try BackupStore.build(context: context)
        XCTAssertEqual(try activities(context).count, 3, "absorbing is idempotent")
    }

    func testAPreservedSectionIsStoredAtTheNextRestore() throws {
        let context = makeContext()
        let web = try outdoorSection(try fixture("web-backup-outdoor"))
        let preserved = try JSONSerialization.data(withJSONObject: ["outdoor": web])
        UserDefaults.standard.set(preserved, forKey: BackupStore.foreignDataKey)

        let result = BackupStore.restore(context: context, from: try file(["food": []]))
        XCTAssertTrue(result.ok)
        XCTAssertEqual(try activities(context).count, 3)
        XCTAssertNil(BackupStore.storedForeignData()["outdoor"])
    }
}
