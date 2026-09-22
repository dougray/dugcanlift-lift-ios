import Foundation
import LiftKit
import WatchConnectivity
import LiftSync

/// WatchConnectivity plumbing, kept away from the domain so the reconciliation
/// rules stay testable without a paired device.
final class PhoneSyncTransport: NSObject {

    var onEnvelope: ((SyncEnvelope) -> Void)?
    var onReachabilityChange: ((Bool) -> Void)?
    var onApplicationContext: (([String: Any]) -> Void)?

    private let session: WCSession?
    /// Written from WatchConnectivity's delegate callbacks, which arrive on a
    /// background queue Apple does not promise is one serial queue, hence
    /// the lock.
    private var reachability = ReachabilityTracker()
    private let reachabilityLock = NSLock()

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
        guard let session else { return }
        guard let body = try? envelope.messageBody() else { return }
        // `transferUserInfo` rather than `sendMessage`: it is queued by the OS
        // and delivered once the phone is reachable, surviving both the watch
        // app being suspended between sets and it being terminated outright —
        // which is the entire point of using it over `sendMessage`. Gating
        // this call on `session.isReachable` (as this used to) would defeat
        // that: the whole reason to prefer `transferUserInfo` is that it does
        // *not* need the counterpart reachable right now.
        session.transferUserInfo(body)
    }

    /// The same delivery, with a fast path. `sendMessage` reaches a phone
    /// that is awake right now in a fraction of the time `transferUserInfo`
    /// takes, which matters for a plan request made as the app opens — the
    /// lifter is looking at the screen waiting for an answer. Anything else
    /// falls back to the queue, so being out of range costs latency rather
    /// than the request.
    func sendNow(_ envelope: SyncEnvelope) {
        guard let session else { return }
        guard let body = try? envelope.messageBody() else { return }
        guard session.isReachable else {
            session.transferUserInfo(body)
            return
        }
        session.sendMessage(body, replyHandler: nil) { _ in
            session.transferUserInfo(body)
        }
    }
}

extension PhoneSyncTransport: WCSessionDelegate {

    // Both report reachability, and when activation already finds the phone
    // reachable the second reports the same value again. Passing both on
    // flushed the outbox and asked for a plan twice on every launch, so only
    // a change is reported (`ReachabilityTracker`).
    func session(_ session: WCSession,
                 activationDidCompleteWith state: WCSessionActivationState,
                 error: Error?) {
        reportReachability(session.isReachable)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        reportReachability(session.isReachable)
    }

    private func reportReachability(_ reachable: Bool) {
        reachabilityLock.lock()
        let changed = reachability.update(reachable)
        reachabilityLock.unlock()
        guard let changed else { return }
        onReachabilityChange?(changed)
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
