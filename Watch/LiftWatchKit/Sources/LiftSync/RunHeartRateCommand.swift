import Foundation

/// Phone -> watch on path B's mirrored workout session, the reverse of
/// `RunHeartRatePayload`. Contract: `Watch/contracts/run-heart-rate-command.schema.json`,
/// `{"command":"stop"}`.
///
/// The phone sends `stop` at Finish or Cancel, before it ends the mirrored
/// session, so the watch's relay ends (and discards its workout) even if the
/// session's end never reaches the watch.
public enum RunHeartRateCommand: String, Codable, CaseIterable, Sendable {
    case stop

    private struct Wire: Codable {
        let command: RunHeartRateCommand
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(Wire(command: self))
    }

    /// The command in `data`, or nil for anything else -- a reading, garbage,
    /// or a command this build does not know. Never throws.
    public static func decode(_ data: Data) -> RunHeartRateCommand? {
        (try? JSONDecoder().decode(Wire.self, from: data))?.command
    }

    /// Whether a delivery holds a `stop`.
    public static func containsStop(_ data: [Data]) -> Bool {
        data.contains { decode($0) == .stop }
    }
}
