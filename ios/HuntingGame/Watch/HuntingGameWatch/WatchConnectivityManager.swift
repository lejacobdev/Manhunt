import Foundation
import WatchConnectivity
import WidgetKit

/// The Watch side of the companion link. Receives the phone's game
/// snapshot via `updateApplicationContext` (so the latest state is always
/// there even if the watch app was backgrounded when it arrived), mirrors it
/// into the App Group container for the complication, and sends action
/// intents (use a power-up, attempt a catch) back to the phone.
final class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()

    @Published private(set) var snapshot: WatchGameSnapshot = WatchAppGroup.readSnapshot()
    @Published private(set) var isReachable: Bool = false

    override private init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func send(_ action: WatchActionMessage) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        if session.isReachable {
            session.sendMessage(action.dictionary, replyHandler: nil) { error in
                print("[WatchConnectivityManager] sendMessage failed: \(error.localizedDescription)")
            }
        } else {
            // Queued, best-effort delivery for when the phone next becomes reachable.
            session.transferUserInfo(action.dictionary)
        }
    }

    private func apply(_ newSnapshot: WatchGameSnapshot) {
        snapshot = newSnapshot
        WatchAppGroup.writeSnapshot(newSnapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

extension WatchConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            self?.isReachable = session.isReachable
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
