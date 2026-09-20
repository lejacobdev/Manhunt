import Foundation
import WatchConnectivity
import WidgetKit

/// The Watch side of the companion link. Receives the phone's game
/// snapshot via `updateApplicationContext` (so the latest state is always
/// there even if the watch app was backgrounded when it arrived), mirrors it
/// into the App Group container for the complication, and sends action
/// intents (use a power-up, request a catch, answer one) back to the phone.
final class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()

    @Published private(set) var snapshot: WatchGameSnapshot = WatchAppGroup.readSnapshot()
    @Published private(set) var isReachable: Bool = false

    /// Simulator screenshots / debugging: a fixed snapshot that nothing overwrites.
    private var isPreview = false
    private var staleTimer: Timer?

    /// How long an "active" snapshot may go without an update before the Watch stops trusting it.
    /// The phone pushes at least every 1.5s during a match, so two minutes of silence means the
    /// match is over or the phone app is gone — not that the wearer is still mid-chase.
    private let staleAfter: TimeInterval = 120

    override private init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()

        staleTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.expireIfStale()
        }
    }

    /// Sends an action to the phone. Returns false when it couldn't be delivered *right now*.
    ///
    /// Deliberately no fallback queue: this used to `transferUserInfo` when the phone wasn't
    /// reachable, but a catch or a power-up delivered minutes late is worse than one that visibly
    /// failed — the wearer thinks it happened and it either did much later or never. The UI turns
    /// a `false` into a haptic and a message instead.
    @discardableResult
    func send(_ action: WatchActionMessage) -> Bool {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return false }

        session.sendMessage(action.dictionary, replyHandler: nil) { error in
            print("[WatchConnectivityManager] sendMessage failed: \(error.localizedDescription)")
        }
        return true
    }

    #if DEBUG
    /// Shows `preview` and stops listening to the phone, so a simulator screenshot of a scenario
    /// isn't replaced by real (or empty) data a moment later.
    func applyPreview(_ preview: WatchGameSnapshot) {
        isPreview = true
        snapshot = preview
    }
    #endif

    private func apply(_ newSnapshot: WatchGameSnapshot) {
        guard !isPreview else { return }
        snapshot = newSnapshot
        WatchAppGroup.writeSnapshot(newSnapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func expireIfStale() {
        guard !isPreview, snapshot.isActive, Date().timeIntervalSince(snapshot.updatedAt) > staleAfter else { return }
        apply(.idle)
    }
}

extension WatchConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        // A context that arrived while the Watch app wasn't running is waiting on the session
        // rather than being redelivered, so pick it up explicitly on launch.
        let waiting = session.receivedApplicationContext
        DispatchQueue.main.async { [weak self] in
            self?.isReachable = session.isReachable
            if !waiting.isEmpty, let latest = WatchGameSnapshot(dictionary: waiting) {
                self?.apply(latest)
            }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { [weak self] in
            self?.isReachable = session.isReachable
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let newSnapshot = WatchGameSnapshot(dictionary: applicationContext) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.apply(newSnapshot)
        }
    }
}
