import XCTest
import SwiftData
import LiftCore
import LiftSync
@testable import Lift

/// Heart rate per set on the iPhone: what an Apple Watch measured during a
/// session it ran, kept beside the store (`WorkoutHeartRates`), written by
/// `WatchSessionImporter`, and carried in the backup.
///
/// Every store and every defaults suite here is the test's own. `.shared` is
/// the test host's file, which is LIFT's, and the importer sweeps the file
/// against the store it is handed -- an in-memory one here -- so a test that
/// took it would empty the installed app's.
@MainActor
final class WorkoutHeartRatesTests: XCTestCase {

    private func makeContext() -> ModelContext {
        ModelContext(LiftStore.makeContainer(inMemory: true))
    }

    private func isolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "WorkoutHeartRatesTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func isolatedHeartRates(_ name: String = #function) -> WorkoutHeartRateStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkoutHeartRatesTests.\(name).\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return WorkoutHeartRateStore(url: url)
    }

    private let started = Date(timeIntervalSince1970: 1_789_891_200)
    private let now = Date(timeIntervalSince1970: 1_789_894_800)

    private func envelope(id: UUID = UUID(), revision: Int = 2, figures: [Int?] = [142, nil],
                          reps: Int = 5,
                          pair: SessionHeartRate? = SessionHeartRate(averageBpm: 117.6, maxBpm: 156)
    ) -> SyncEnvelope {
        SyncEnvelope(
            event: .sessionFinished, workoutID: id, revision: revision,
            updatedAt: now, origin: .watchOS,
            session: FinishedSession(
                name: "Upper A", performedOn: DayKey.make(from: started),
                startedAt: started, finishedAt: now,
                exercises: [PerformedExercise(
                    name: "Bench Press", equipment: "barbell",
                    sets: figures.map {
                        PerformedSet(weightKg: 80, reps: reps, completedAt: started, maxBpm: $0)
                    }
                )]
            ),
            heartRate: pair
        )
    }

    private func sets(in context: ModelContext) throws -> [SetEntry] {
        let day = try XCTUnwrap(try context.fetch(FetchDescriptor<WorkoutDay>()).first)
        return day.orderedExercises.flatMap(\.orderedSets)
    }

    // MARK: - Storing a session

    func testEachFigureIsKeptUnderItsSetAndThePairUnderItsDay() throws {
        let context = makeContext()
        let heartRates = isolatedHeartRates()
        let sent = envelope()

        XCTAssertEqual(WatchSessionImporter.apply(sent, in: context, now: now,
                                                  defaults: isolatedDefaults(),
                                                  heartRates: heartRates), .stored)

        let stored = try sets(in: context)
        XCTAssertEqual(stored.map { heartRates.rates.maxBpm(of: $0.id) }, [142, nil])
        let day = try XCTUnwrap(stored.first?.exercise?.day)
        XCTAssertEqual(heartRates.rates.sessions(on: day.id),
                       [WorkoutHeartRates.Session(sessionID: sent.workoutID,
                                                  averageBpm: 117.6, maxBpm: 156)])
        // And on disk, for the next launch.
        XCTAssertEqual(WorkoutHeartRateStore(url: heartRates.url).rates, heartRates.rates)
    }

    func testASessionWithNoHeartRateWritesNoFile() throws {
        // A watch off the wrist, Health's heart rate turned off: the session
        // logs as before, and nothing reads zero because nothing is there.
        let context = makeContext()
        let heartRates = isolatedHeartRates()
        WatchSessionImporter.apply(envelope(figures: [nil, nil], pair: nil), in: context, now: now,
                                   defaults: isolatedDefaults(), heartRates: heartRates)

        XCTAssertEqual(try sets(in: context).count, 2)
        XCTAssertTrue(heartRates.rates.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: heartRates.url.path))
    }

    func testANewerRevisionsFiguresReplaceTheOnesItsRowsReplaced() throws {
        let context = makeContext()
        let defaults = isolatedDefaults()
        let heartRates = isolatedHeartRates()
        let id = UUID()
        WatchSessionImporter.apply(envelope(id: id, revision: 2), in: context, now: now,
                                   defaults: defaults, heartRates: heartRates)
        let before = try sets(in: context).map(\.id)

        XCTAssertEqual(WatchSessionImporter.apply(
            envelope(id: id, revision: 3, figures: [nil, 150], reps: 6,
                     pair: SessionHeartRate(averageBpm: 120, maxBpm: 160)),
            in: context, now: now, defaults: defaults, heartRates: heartRates), .stored)

        let after = try sets(in: context)
        XCTAssertEqual(after.map { heartRates.rates.maxBpm(of: $0.id) }, [nil, 150])
        for old in before { XCTAssertNil(heartRates.rates.maxBpm(of: old)) }
        let day = try XCTUnwrap(after.first?.exercise?.day)
        XCTAssertEqual(heartRates.rates.sessions(on: day.id).map(\.maxBpm), [160],
                       "one pair per session, not one per revision")
    }

    func testAConflictKeepsThePhonesRowsAndTheirFigures() throws {
        let context = makeContext()
        let defaults = isolatedDefaults()
        let heartRates = isolatedHeartRates()
        let id = UUID()
        WatchSessionImporter.apply(envelope(id: id, revision: 2), in: context, now: now,
                                   defaults: defaults, heartRates: heartRates)
        let first = try XCTUnwrap(try sets(in: context).first)
        // The lifter corrects the weight here. A figure belongs to the set,
        // so it stays.
        first.weightKg = 82.5
        try context.save()

        XCTAssertEqual(WatchSessionImporter.apply(
            envelope(id: id, revision: 3, figures: [99, 99]),
            in: context, now: now, defaults: defaults, heartRates: heartRates), .conflict)
        XCTAssertEqual(heartRates.rates.maxBpm(of: first.id), 142)
    }

    func testADeletedSetsFigureIsSweptByTheNextImport() throws {
        let context = makeContext()
        let defaults = isolatedDefaults()
        let heartRates = isolatedHeartRates()
        WatchSessionImporter.apply(envelope(), in: context, now: now,
                                   defaults: defaults, heartRates: heartRates)
        let doomed = try XCTUnwrap(try sets(in: context).first)
        let doomedID = doomed.id
        doomed.exercise?.sets.removeAll { $0.id == doomedID }
        context.delete(doomed)
        try context.save()

        WatchSessionImporter.apply(envelope(), in: context, now: now,
                                   defaults: defaults, heartRates: heartRates)

        XCTAssertNil(heartRates.rates.maxBpm(of: doomedID))
        XCTAssertEqual(heartRates.rates.sets.count, 1, "the second session's own figure")
    }

    func testAZeroIsNeverKept() {
        var rates = WorkoutHeartRates()
        let set = UUID()
        rates.setMaxBpm(0, for: set)
        XCTAssertNil(rates.maxBpm(of: set))
        rates.setSession(WorkoutHeartRates.Session(sessionID: set, averageBpm: 0, maxBpm: 150),
                         sessionID: set, on: UUID())
        XCTAssertTrue(rates.isEmpty)
    }

    func testAFileWithOneBadEntryKeepsTheRest() throws {
        let good = UUID()
        let json = #"{"sets":{"\#(good.uuidString)":142,"not-a-set":150,"\#(UUID().uuidString)":0}}"#
        let rates = try JSONDecoder().decode(WorkoutHeartRates.self, from: Data(json.utf8))
        XCTAssertEqual(rates.sets, [good.uuidString: 142])
    }

    // MARK: - The backup

    func testABackupCarriesEveryFigureAndPairAndRestoresThem() throws {
        let source = makeContext()
        let sourceRates = isolatedHeartRates()
        let sent = envelope()
        WatchSessionImporter.apply(sent, in: source, now: now,
                                   defaults: isolatedDefaults(), heartRates: sourceRates)
        let backup = try BackupStore.build(context: source, defaults: isolatedDefaults(),
                                           heartRates: sourceRates)

        // On the set, under the wire's name; the pair under ext.ios.
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: backup) as? [String: Any])
        let workout = try XCTUnwrap(((root["data"] as? [String: Any])?["workouts"] as? [[String: Any]])?.first)
        let rows = try XCTUnwrap((workout["exercises"] as? [[String: Any]])?.first?["sets"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["maxBpm"] as? Int }, [142, nil])
        XCTAssertTrue(rows[1]["maxBpm"] == nil, "absent, never 0 or null")
        let ios = try XCTUnwrap((root["ext"] as? [String: Any])?["ios"] as? [String: Any])
        let dayExtras = try XCTUnwrap((ios["workouts"] as? [String: Any])?[workout["id"] as! String] as? [String: Any])
        let pairs = try XCTUnwrap(dayExtras["heartRate"] as? [[String: Any]])
        XCTAssertEqual(pairs.first?["maxBpm"] as? Double, 156)

        let target = makeContext()
        let targetRates = isolatedHeartRates("restored")
        _ = BackupStore.restore(context: target, from: backup, defaults: isolatedDefaults("restored"),
                                heartRates: targetRates)
        XCTAssertEqual(targetRates.rates, sourceRates.rates)
        XCTAssertEqual(try sets(in: target).map { targetRates.rates.maxBpm(of: $0.id) }, [142, nil])
    }

    func testABackupWithNoHeartRateRestoresUnchangedAndWritesNoFile() throws {
        // Every file written before this, and every file from a phone whose
        // sessions were all logged on the phone.
        let source = makeContext()
        let day = WorkoutDay(date: started, name: "Push")
        source.insert(day)
        let exercise = ExerciseEntry(exerciseRefID: "bench", name: "Bench Press", orderIndex: 0)
        exercise.sets = [SetEntry(orderIndex: 0, weightKg: 80, reps: 5)]
        day.exercises.append(exercise)
        try source.save()
        let backup = try BackupStore.build(context: source, defaults: isolatedDefaults(),
                                           heartRates: isolatedHeartRates())
        XCTAssertFalse(String(decoding: backup, as: UTF8.self).contains("maxBpm"))
        XCTAssertFalse(String(decoding: backup, as: UTF8.self).contains("heartRate"))

        let target = makeContext()
        let targetRates = isolatedHeartRates("restored")
        let result = BackupStore.restore(context: target, from: backup,
                                         defaults: isolatedDefaults("restored"),
                                         heartRates: targetRates)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(try sets(in: target).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetRates.url.path))
    }

    func testAFigureThatIsNotAPositiveWholeNumberRestoresAsNone() throws {
        let setIDs = (0..<5).map { _ in UUID() }
        let junk: [Any] = [0, -3, 141.5, "fast", true]
        let file: [String: Any] = [
            "v": 1, "app": "lift", "saved": "2026-09-20",
            "data": ["workouts": [[
                "id": UUID().uuidString, "date": "2026-09-20", "name": "Push", "note": "",
                "startedAt": 1_789_891_200_000,
                "exercises": [[
                    "id": UUID().uuidString, "name": "Bench Press", "equipment": "", "note": "",
                    "sets": zip(setIDs, junk).map { id, value -> [String: Any] in
                        ["id": id.uuidString, "reps": 5, "weightLb": 135, "maxBpm": value]
                    } + [["id": UUID().uuidString, "reps": 5, "weightLb": 135, "maxBpm": 142.0]]
                ]]
            ]]]
        ]
        let target = makeContext()
        let rates = isolatedHeartRates()
        _ = BackupStore.restore(context: target,
                                from: try JSONSerialization.data(withJSONObject: file),
                                defaults: isolatedDefaults(), heartRates: rates)
        XCTAssertEqual(try sets(in: target).count, 6, "every set arrives")
        XCTAssertEqual(try sets(in: target).compactMap { rates.rates.maxBpm(of: $0.id) }, [142])
    }
}
