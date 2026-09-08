import Foundation

/// A GPS-tracked Run or Hike, recorded on the watch.
///
/// Mirrors `WorkoutDraft`'s shape: a value type the watch owns, reconciled by
/// `revision` rather than wall-clock time, which is not trustworthy across
/// two devices.
public struct OutdoorActivity: Identifiable, Codable, Equatable, Sendable {

    public private(set) var id: UUID
    public private(set) var activityType: OutdoorActivityType
    public private(set) var startedAt: Date
    public private(set) var endedAt: Date?
    public private(set) var distanceMeters: Double
    public private(set) var elevationGainMeters: Double
    public private(set) var routePoints: [RoutePoint]

    /// Starts at 1 and increases by one per accepted edit. Never decreases.
    public private(set) var revision: Int
    public private(set) var updatedAt: Date

    public init(
        id: UUID = UUID(),
        activityType: OutdoorActivityType,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        distanceMeters: Double = 0,
        elevationGainMeters: Double = 0,
        routePoints: [RoutePoint] = [],
        revision: Int = 1,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.activityType = activityType
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.distanceMeters = distanceMeters
        self.elevationGainMeters = elevationGainMeters
        self.routePoints = routePoints
        self.revision = max(1, revision)
        self.updatedAt = updatedAt ?? startedAt
    }

    public var isFinished: Bool { endedAt != nil }

    // MARK: - Edits
    //
    // Every mutation that actually changes something goes through `commit`, so
    // there is exactly one place where the revision can advance. A rejected
    // edit leaves the revision alone — otherwise the phone would see a bump
    // with no corresponding change and re-sync for nothing.

    private mutating func commit(_ now: Date) {
        revision += 1
        updatedAt = now
    }

    /// Marks the activity finished. No-op (and no revision bump) if it was
    /// already finished — matches `WorkoutDraft.finish(at:)`.
    @discardableResult
    public mutating func finish(at date: Date = Date()) -> Bool {
        guard endedAt == nil else { return false }
        endedAt = date
        commit(date)
        return true
    }
}

// MARK: - Store

/// Revision-ordered storage for outdoor activities held on this device.
///
/// Delivery over WatchConnectivity is neither ordered nor exactly-once, so the
/// only safe merge rule is "highest revision wins" — which also makes replay
/// harmless. Mirrors `WorkoutStore` exactly, substituting `OutdoorActivity`
/// for `WorkoutDraft`.
public struct OutdoorActivityStore: Equatable, Sendable {

    private var activities: [UUID: OutdoorActivity] = [:]

    public init(_ activities: [OutdoorActivity] = []) {
        for activity in activities { self.activities[activity.id] = activity }
    }

    public var count: Int { activities.count }

    public var all: [OutdoorActivity] {
        activities.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func activity(_ id: UUID) -> OutdoorActivity? { activities[id] }

    @discardableResult
    public mutating func apply(_ snapshot: OutdoorActivity) -> ReconcileOutcome {
        guard let existing = activities[snapshot.id] else {
            activities[snapshot.id] = snapshot
            return .inserted
        }
        if snapshot.revision > existing.revision {
            activities[snapshot.id] = snapshot
            return .accepted
        }
        return snapshot.revision == existing.revision ? .idempotent : .ignored
    }

    /// Local edits bypass reconciliation — this device is the author.
    public mutating func store(_ activity: OutdoorActivity) {
        activities[activity.id] = activity
    }

    public mutating func remove(_ id: UUID) {
        activities.removeValue(forKey: id)
    }
}
