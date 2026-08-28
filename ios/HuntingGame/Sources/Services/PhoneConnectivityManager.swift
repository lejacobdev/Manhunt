import Foundation
import WatchConnectivity

/// The phone side of the Watch companion link. The phone remains the single
/// source of truth — it owns the JWT session and the live Socket.IO
/// connection — and simply relays a lightweight snapshot of game state out
/// to the Watch, and relays action intents (use a power-up, attempt a catch)
/// back from the Watch into the existing GameViewModel/SocketService flow.
final class PhoneConnectivityManager: NSObject, ObservableObject {
    static let shared = PhoneConnectivityManager()

    /// Set by GameViewModel while a match is active; called when the Watch sends an action.
    var onAction: ((WatchActionMessage) -> Void)?

    private var lastSentSnapshot: WatchGameSnapshot = .idle
    private var lastSentAt: Date = .distantPast
    private let minSendInterval: TimeInterval = 1.5

    override private init() {
        super.init()
        activate()
    }

    private func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Pushes a new snapshot to the Watch, throttled so a burst of socket
    /// ticks doesn't spam WatchConnectivity's application context — except
    /// for activity/caught-state transitions, which always go out immediately.
    func send(_ snapshot: WatchGameSnapshot) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }

        let isStateTransition = snapshot.isActive != lastSentSnapshot.isActive || snapshot.isCaught != lastSentSnapshot.isCaught
        let now = Date()
        guard isStateTransition || now.timeIntervalSince(lastSentAt) >= minSendInterval else { return }

        lastSentSnapshot = snapshot
        lastSentAt = now
        do {
            try WCSession.default.updateApplicationContext(snapshot.dictionary)
        } catch {
            print("[PhoneConnectivityManager] failed to push context: \(error.localizedDescription)")
        }
    }

    /// Immediately clears the Watch's state (game ended, left the match, signed out).
    func sendIdle() {
        send(.idle)
    }
}

extension PhoneConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            print("[PhoneConnectivityManager] activation failed: \(error.localizedDescription)")
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate for a newly paired Watch, per Apple's guidance for multi-watch support.
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let action = WatchActionMessage(dictionary: message) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onAction?(action)
        }
    }
}
