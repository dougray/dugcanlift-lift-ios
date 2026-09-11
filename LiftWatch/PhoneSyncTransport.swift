import Foundation
import LiftKit
import WatchConnectivity

/// WatchConnectivity plumbing, kept away from the domain so the reconciliation
/// rules stay testable without a paired device.
final class PhoneSyncTransport: NSObject {

    var onEnvelope: ((SyncEnvelope) -> Void)?
    var onReachabilityChange: ((Bool) -> Void)?
    var onApplicationContext: (([String: Any]) -> Void)?

    private let session: WCSession?

    init(session: WCSession? = WCSession.isSupported() ? .default : nil) {
        self.session = session
        super.init()
        session?.delegate = self
    }

    var isReachable: Bool { session?.isReachable ?? false }

    func activate() {
        session?.activate()
    }

    /// `WCSession.receivedApplicationContext` holds the last context the
    /// phone pushed even if it arrived while this delegate wasn't yet set
    /// (e.g. before `activate()`'s callback fires) — Apple's API returns an
    /// **empty dictionary**, not `nil`, when nothing has ever been received,
    /// so that case is normalized to `nil` here.
    func latestApplicationContext() -> [String: Any]? {
        guard let context = session?.receivedApplicationContext, !context.isEmpty else { return nil }
        return context
    }

    func send(_ envelope: SyncEnvelope) {
        guard let session, session.isReachable else { return }
        guard let body = try? envelope.messageBody() else { return }
        // `transferUserInfo` rather than `sendMessage`: it is queued by the OS
        // and survives the app being suspended between sets.
        session.transferUserInfo(body)
    }
}

extension PhoneSyncTransport: WCSessionDelegate {

    func session(_ session: WCSession,
                 activationDidCompleteWith state: WCSessionActivationState,
                 error: Error?) {
        onReachabilityChange?(session.isReachable)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        onReachabilityChange?(session.isReachable)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        deliver(userInfo)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        deliver(message)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        onApplicationContext?(applicationContext)
    }

    private func deliver(_ body: [String: Any]) {
        guard let envelope = try? SyncEnvelope(messageBody: body) else { return }
        onEnvelope?(envelope)
    }
}
