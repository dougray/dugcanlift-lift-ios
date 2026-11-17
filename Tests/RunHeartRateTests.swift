import XCTest
@testable import Lift

final class RunHeartRateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let strap = AddedHeartRateDevice(id: UUID(), name: "Polar H10")
    private let band = AddedHeartRateDevice(id: UUID(), name: "Wahoo TICKR")

    // MARK: - The Bluetooth measurement

    func testAnEightBitReading() {
        XCTAssertEqual(HeartRateMeasurement.bpm(from: Data([0x00, 72])), 72)
    }

    func testASixteenBitReadingIsLittleEndian() {
        XCTAssertEqual(HeartRateMeasurement.bpm(from: Data([0x01, 0x2C, 0x01])), 300)
    }

    func testASixteenBitFlagWithOneByteIsNoReading() {
        XCTAssertNil(HeartRateMeasurement.bpm(from: Data([0x01, 0x2C])))
    }

    func testZeroIsNoReading() {
        XCTAssertNil(HeartRateMeasurement.bpm(from: Data([0x00, 0])))
        XCTAssertNil(HeartRateMeasurement.bpm(from: Data([0x01, 0, 0])))
    }

    func testEmptyAndShortDataAreNoReading() {
        XCTAssertNil(HeartRateMeasurement.bpm(from: Data()))
        XCTAssertNil(HeartRateMeasurement.bpm(from: Data([0x00])))
    }

    func testOtherFlagBitsDoNotChangeTheWidth() {
        // Bit 4 (energy expended) set, bit 0 clear: still one byte of bpm.
        XCTAssertEqual(HeartRateMeasurement.bpm(from: Data([0x08, 65, 0xFF, 0xFF])), 65)
    }

    // MARK: - Choosing a source

    func testAutomaticNeverPicksAnUnaddedDevice() {
        // Nothing added, no watch: whatever else is advertising nearby, nil.
        XCTAssertNil(HeartRateSourcePicker.pick(.automatic, addedInRange: [], watchAvailable: false))
    }

    func testAutomaticPrefersAnAddedDeviceOverTheWatch() {
        let source = HeartRateSourcePicker.pick(.automatic, addedInRange: [strap], watchAvailable: true)
        XCTAssertEqual(source, .device(strap.id, name: "Polar H10"))
    }

    func testAutomaticTakesTheFirstAddedInTheOrderAdded() {
        let source = HeartRateSourcePicker.pick(.automatic, addedInRange: [band, strap], watchAvailable: false)
        XCTAssertEqual(source, .device(band.id, name: "Wahoo TICKR"))
    }

    func testAutomaticFallsBackToTheWatch() {
        XCTAssertEqual(HeartRateSourcePicker.pick(.automatic, addedInRange: [], watchAvailable: true), .watch)
    }

    func testAChosenDeviceOutOfRangeIsNilNotTheWatch() {
        let source = HeartRateSourcePicker.pick(.device(strap.id), addedInRange: [band], watchAvailable: true)
        XCTAssertNil(source)
    }

    func testAChosenDeviceInRange() {
        let source = HeartRateSourcePicker.pick(.device(band.id), addedInRange: [strap, band], watchAvailable: true)
        XCTAssertEqual(source, .device(band.id, name: "Wahoo TICKR"))
    }

    func testWatchOnlyWhenAvailable() {
        XCTAssertEqual(HeartRateSourcePicker.pick(.watch, addedInRange: [strap], watchAvailable: true), .watch)
        XCTAssertNil(HeartRateSourcePicker.pick(.watch, addedInRange: [strap], watchAvailable: false))
    }

    func testOffIsNil() {
        XCTAssertNil(HeartRateSourcePicker.pick(.off, addedInRange: [strap], watchAvailable: true))
    }

    func testTheSettingRoundTripsThroughJSON() throws {
        for setting in [HeartRateSetting.automatic, .off, .watch, .device(strap.id)] {
            let data = try JSONEncoder().encode(setting)
            XCTAssertEqual(try JSONDecoder().decode(HeartRateSetting.self, from: data), setting)
        }
    }

    // MARK: - Stale readings

    func testAReadingIsShownUnderTenSeconds() {
        XCTAssertEqual(LiveHeartRate.shown(last: (bpm: 150, at: start), now: start.addingTimeInterval(9.9)), 150)
    }

    func testAReadingOverTenSecondsOldIsHidden() {
        XCTAssertNil(LiveHeartRate.shown(last: (bpm: 150, at: start), now: start.addingTimeInterval(10.1)))
    }

    func testNoReadingYetShowsNothing() {
        XCTAssertNil(LiveHeartRate.shown(last: nil, now: start))
    }

    // MARK: - The run's summary

    func testSummaryIsMeanAndMax() {
        XCTAssertEqual(RunHeartRateSummary.of([140, 141, 142]), RunHeartRateSummary(averageBpm: 141, maxBpm: 142))
    }

    func testSummaryMeanRoundsHalfUp() {
        // 141.5 -> 142; not banker's rounding to 142 by luck, so also check 140.5.
        XCTAssertEqual(RunHeartRateSummary.of([141, 142])?.averageBpm, 142)
        XCTAssertEqual(RunHeartRateSummary.of([140, 141])?.averageBpm, 141)
    }

    func testNoReadingsIsNoSummary() {
        XCTAssertNil(RunHeartRateSummary.of([]))
    }

    // MARK: - The session

    @MainActor
    func testADroppedSourceIsReconnectedNotSwapped() {
        let session = RunHeartRateSession(begin: .device(strap.id, name: "Polar H10"))
        session.receive(150, at: start)
        // The strap goes quiet for a minute, then comes back.
        session.receive(152, at: start.addingTimeInterval(60))
        XCTAssertEqual(session.source, .device(strap.id, name: "Polar H10"))
        XCTAssertEqual(session.readings, [150, 152])
    }

    @MainActor
    func testEndingGivesTheSummaryAndAStoppedSessionIgnoresReadings() {
        let session = RunHeartRateSession(begin: .watch)
        session.receive(140, at: start)
        session.receive(142, at: start.addingTimeInterval(1))
        XCTAssertEqual(session.end(), RunHeartRateSummary(averageBpm: 141, maxBpm: 142))
        session.receive(200, at: start.addingTimeInterval(2))
        XCTAssertEqual(session.readings, [140, 142])
    }

    @MainActor
    func testASessionWithNoSourceKeepsNothing() {
        let session = RunHeartRateSession(begin: nil)
        session.receive(150, at: start)
        XCTAssertTrue(session.readings.isEmpty)
        XCTAssertNil(session.end())
    }

    @MainActor
    func testTheLatestReadingIsRecordedForTheStaleRule() {
        let session = RunHeartRateSession(begin: .watch)
        XCTAssertNil(session.shown(now: start))
        session.receive(150, at: start)
        XCTAssertEqual(session.shown(now: start.addingTimeInterval(5)), 150)
        XCTAssertNil(session.shown(now: start.addingTimeInterval(11)))
    }

    @MainActor
    func testAZeroOrNegativeReadingIsIgnored() {
        let session = RunHeartRateSession(begin: .watch)
        session.receive(0, at: start)
        session.receive(-3, at: start)
        XCTAssertTrue(session.readings.isEmpty)
    }
}
