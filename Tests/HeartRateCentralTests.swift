import XCTest
@testable import Lift

/// The parts of the Bluetooth path that need no radio. The radio itself
/// (`HeartRateCentral`) is a thin shell over these and is not unit-testable.
final class HeartRateCentralTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    // MARK: - Scan results

    func testAScanResultIsKeptOncePerIdentifier() {
        var list: [DiscoveredDevice] = []
        list = HeartRateScan.merged(list, id: a, name: "Polar H10", rssi: -60)
        list = HeartRateScan.merged(list, id: b, name: "Wahoo TICKR", rssi: -70)
        list = HeartRateScan.merged(list, id: a, name: "Polar H10", rssi: -55)
        XCTAssertEqual(list.map(\.id), [a, b])
        XCTAssertEqual(list[0].rssi, -55, "the newest signal wins")
    }

    func testAMissingOrBlankNameReadsHeartRateDevice() {
        XCTAssertEqual(HeartRateScan.displayName(nil), "Heart rate device")
        XCTAssertEqual(HeartRateScan.displayName(""), "Heart rate device")
        XCTAssertEqual(HeartRateScan.displayName("   "), "Heart rate device")
        XCTAssertEqual(HeartRateScan.displayName(" Polar H10 "), "Polar H10")
        let list = HeartRateScan.merged([], id: a, name: nil, rssi: nil)
        XCTAssertEqual(list.first?.name, "Heart rate device")
    }

    func testARealNameReplacesTheFallbackButNeverTheOtherWayRound() {
        var list = HeartRateScan.merged([], id: a, name: nil, rssi: -60)
        list = HeartRateScan.merged(list, id: a, name: "Polar H10", rssi: -60)
        XCTAssertEqual(list.map(\.name), ["Polar H10"])
        list = HeartRateScan.merged(list, id: a, name: nil, rssi: -60)
        XCTAssertEqual(list.map(\.name), ["Polar H10"])
    }

    func testTheListHoldsFirstSeenOrder() {
        var list: [DiscoveredDevice] = []
        for id in [c, a, b, a, c] { list = HeartRateScan.merged(list, id: id, name: "x", rssi: nil) }
        XCTAssertEqual(list.map(\.id), [c, a, b])
    }

    // MARK: - In range, in the order added

    func testInRangeIsInTheOrderAddedNotTheOrderSeen() {
        let added = [
            AddedHeartRateDevice(id: a, name: "A"),
            AddedHeartRateDevice(id: b, name: "B"),
            AddedHeartRateDevice(id: c, name: "C"),
        ]
        // Discovery order was c, then b; added order is a, b, c.
        let result = HeartRateRange.inRange(added, seen: [c, b])
        XCTAssertEqual(result.map(\.id), [b, c])
    }

    func testInRangeNeverIncludesADeviceNobodyAdded() {
        let added = [AddedHeartRateDevice(id: a, name: "A")]
        XCTAssertEqual(HeartRateRange.inRange(added, seen: [b, c]), [])
        XCTAssertEqual(HeartRateRange.inRange([], seen: [a]), [])
    }

    func testInRangeKeepsAnAddedDeviceOnceEvenIfListedTwice() {
        let added = [AddedHeartRateDevice(id: a, name: "A"), AddedHeartRateDevice(id: a, name: "A again")]
        XCTAssertEqual(HeartRateRange.inRange(added, seen: [a]).map(\.name), ["A"])
    }

    func testInRangeFeedsAutomaticInTheOrderAdded() {
        let added = [AddedHeartRateDevice(id: a, name: "A"), AddedHeartRateDevice(id: b, name: "B")]
        let near = HeartRateRange.inRange(added, seen: [b, a])
        XCTAssertEqual(HeartRateSourcePicker.pick(.automatic, addedInRange: near, watchAvailable: true),
                       .device(a, name: "A"))
    }

    // MARK: - Stored setting and device list

    func testTheSettingRoundTripsThroughItsStoredString() {
        for setting: HeartRateSetting in [.automatic, .off, .watch, .device(a)] {
            XCTAssertEqual(HeartRateStorage.setting(from: HeartRateStorage.string(for: setting)), setting)
        }
    }

    func testACorruptEmptyOrUnknownSettingIsAutomatic() {
        XCTAssertEqual(HeartRateStorage.setting(from: ""), .automatic)
        XCTAssertEqual(HeartRateStorage.setting(from: "not json"), .automatic)
        XCTAssertEqual(HeartRateStorage.setting(from: "{}"), .automatic)
        XCTAssertEqual(HeartRateStorage.setting(from: #"{"somethingNew":{}}"#), .automatic)
        XCTAssertEqual(HeartRateStorage.setting(from: #"{"device":{"_0":"not-a-uuid"}}"#), .automatic)
        XCTAssertEqual(HeartRateStorage.setting(from: "\u{0}\u{1}"), .automatic)
    }

    func testTheDefaultStoredStringIsAutomatic() {
        XCTAssertEqual(HeartRateStorage.setting(from: HeartRateStorage.defaultSetting), .automatic)
    }

    func testTheDeviceListRoundTripsInOrder() {
        let list = [AddedHeartRateDevice(id: b, name: "B"), AddedHeartRateDevice(id: a, name: "A")]
        XCTAssertEqual(HeartRateStorage.devices(from: HeartRateStorage.string(for: list)), list)
    }

    func testACorruptEmptyOrUnknownDeviceListIsEmpty() {
        XCTAssertEqual(HeartRateStorage.devices(from: ""), [])
        XCTAssertEqual(HeartRateStorage.devices(from: "[]"), [])
        XCTAssertEqual(HeartRateStorage.devices(from: "garbage"), [])
        XCTAssertEqual(HeartRateStorage.devices(from: #"{"a":1}"#), [])
        XCTAssertEqual(HeartRateStorage.devices(from: #"[{"id":"nope","name":"x"}]"#), [])
        XCTAssertEqual(HeartRateStorage.devices(from: HeartRateStorage.defaultDevices), [])
    }

    func testAddingTheSameDeviceTwiceKeepsOneRowInItsFirstPlace() {
        var list = [AddedHeartRateDevice(id: a, name: "A")]
        list = HeartRateStorage.adding(AddedHeartRateDevice(id: b, name: "B"), to: list)
        list = HeartRateStorage.adding(AddedHeartRateDevice(id: a, name: "A renamed"), to: list)
        XCTAssertEqual(list.map(\.id), [a, b])
        XCTAssertEqual(list.first?.name, "A renamed")
    }

    func testRemovingTheChosenDeviceFallsBackToAutomatic() {
        XCTAssertEqual(HeartRateStorage.setting(.device(a), afterRemoving: a), .automatic)
        XCTAssertEqual(HeartRateStorage.setting(.device(a), afterRemoving: b), .device(a))
        XCTAssertEqual(HeartRateStorage.setting(.off, afterRemoving: a), .off)
    }

    // MARK: - Reconnecting, on the same device only

    private var both: [AddedHeartRateDevice] {
        [AddedHeartRateDevice(id: a, name: "A"), AddedHeartRateDevice(id: b, name: "B")]
    }
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testADropWhileRecordingReconnectsTheSameDevice() {
        var reconnect = HeartRateReconnect()
        reconnect.begin(a, among: both)
        XCTAssertEqual(reconnect.onDisconnect(of: a), a)
    }

    func testADropOfAnotherDeviceIsLeftAlone() {
        var reconnect = HeartRateReconnect()
        reconnect.begin(a, among: both)
        XCTAssertNil(reconnect.onDisconnect(of: b))
    }

    func testNothingReconnectsBeforeARunBeginsOrAfterItEnds() {
        var reconnect = HeartRateReconnect()
        XCTAssertNil(reconnect.onDisconnect(of: a))
        reconnect.begin(a, among: both)
        reconnect.end()
        XCTAssertNil(reconnect.onDisconnect(of: a))
    }

    func testBeginningAnotherDeviceMidRunIsRefused() {
        var reconnect = HeartRateReconnect()
        reconnect.begin(a, among: both)
        reconnect.begin(b, among: both)
        XCTAssertEqual(reconnect.target, a, "one source per run")
        XCTAssertNil(reconnect.onDisconnect(of: b))
        XCTAssertEqual(reconnect.onDisconnect(of: a), a)
    }

    func testALongDropHidesTheNumberWhileTheReconnectKeepsTargetingTheSameDevice() {
        var reconnect = HeartRateReconnect()
        reconnect.begin(a, among: both)
        let last = (bpm: 142, at: t0)
        XCTAssertEqual(LiveHeartRate.shown(last: last, now: t0 + 5), 142)
        // The strap drops and stays gone for 12 s: the number hides...
        XCTAssertNil(LiveHeartRate.shown(last: last, now: t0 + 12))
        // ...and every attempt, however late, is for the same strap.
        XCTAssertEqual(reconnect.onDisconnect(of: a), a)
        XCTAssertEqual(reconnect.onDisconnect(of: a), a)
        XCTAssertEqual(reconnect.target, a)
        // It comes back: the number shows again from the new reading.
        XCTAssertEqual(LiveHeartRate.shown(last: (bpm: 138, at: t0 + 13), now: t0 + 14), 138)
    }

    func testAnIdNobodyAddedIsNeverConnected() {
        var reconnect = HeartRateReconnect()
        reconnect.begin(c, among: both)
        XCTAssertNil(reconnect.target)
        XCTAssertNil(reconnect.onDisconnect(of: c))
        reconnect.begin(c, among: [])
        XCTAssertNil(reconnect.target)
        // A refused id does not use up the run's one source.
        reconnect.begin(a, among: both)
        XCTAssertEqual(reconnect.target, a)
    }

    func testAFailedAttemptWaitsTwoSecondsThenFiveAndStaysOnTheSameDevice() {
        var reconnect = HeartRateReconnect()
        reconnect.begin(a, among: both)
        let first = reconnect.onFailure(of: a)
        XCTAssertEqual(first?.id, a)
        XCTAssertEqual(first?.delay, .seconds(2))
        XCTAssertEqual(reconnect.onFailure(of: a)?.delay, .seconds(5))
        XCTAssertEqual(reconnect.onFailure(of: a)?.delay, .seconds(5))
        XCTAssertNil(reconnect.onFailure(of: b), "another device is never retried")
        reconnect.connected()
        XCTAssertEqual(reconnect.onFailure(of: a)?.delay, .seconds(2))
    }

    func testNoRetryAfterTheRunEnds() {
        var reconnect = HeartRateReconnect()
        reconnect.begin(a, among: both)
        reconnect.end()
        XCTAssertNil(reconnect.onFailure(of: a))
    }

    // MARK: - What the add sheet says

    func testTheSheetSaysWhyItIsEmptyWhenThePersonCanFixIt() {
        XCTAssertEqual(HeartRateRadioState.unauthorized.emptyListMessage,
                       "Bluetooth is off for LIFT. Turn it on in the Settings app.")
        XCTAssertEqual(HeartRateRadioState.poweredOff.emptyListMessage,
                       "Bluetooth is turned off. Turn it on to look for heart rate devices.")
        XCTAssertFalse(HeartRateRadioState.unauthorized.isLooking)
        XCTAssertFalse(HeartRateRadioState.poweredOff.isLooking)
    }

    func testAnUnsettledOrWorkingRadioIsStillLooking() {
        for state: HeartRateRadioState in [.poweredOn, .unknown, .resetting] {
            XCTAssertEqual(state.emptyListMessage, "Looking for heart rate devices…")
            XCTAssertTrue(state.isLooking)
        }
    }
}
