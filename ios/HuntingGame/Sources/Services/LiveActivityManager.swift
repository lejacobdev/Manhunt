import ActivityKit
import Foundation

/// Owns the app's single Live Activity: a runner's real-time "nearest hunter"
/// threat readout, mirrored to the Lock Screen and Dynamic Island so a player
/// can glance at their phone (or a Watch/AirPods-adjacent glance) without
/// unlocking into the app. Only runners start one — hunters already see the
/// full radar in-app and don't need a standing threat broadcast.
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var activity: Activity<HuntingGameAttributes>?
    private var lastPushedAt: Date = .distantPast
    /// Live Activity updates are budget-limited by the system; coalesce bursts
    /// of compass ticks (which can arrive every couple of seconds) into this cadence.
    private let minPushInterval: TimeInterval = 4.0

    private init() {}

    var isRunning: Bool { activity != nil }

    func start(gameCode: String, role: PlayerRole) {
        guard role == .runner else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("[LiveActivityManager] Live Activities are disabled for this app in Settings.")
            return
        }
        guard activity == nil else { return }

        let attributes = HuntingGameAttributes(gameCode: gameCode, userRole: role.rawValue)
        let initialState = HuntingGameAttributes.ContentState(
            distanceMeters: 0,
            nearestHunterBearing: 0,
            isRadarActive: false,
            dangerLevel: "SAFE"
        )

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil),
                pushType: nil
            )
        } catch {
            print("[LiveActivityManager] failed to start: \(error.localizedDescription)")
        }
    }

    func update(distanceMeters: Int, bearingDegrees: Double) {
        guard let activity else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPushedAt) >= minPushInterval else { return }
        lastPushedAt = now

        let state = HuntingGameAttributes.ContentState(
            distanceMeters: distanceMeters,
            nearestHunterBearing: bearingDegrees,
            isRadarActive: true,
            dangerLevel: ADATheme.dangerLabel(distanceMeters: distanceMeters)
        )

        Task {
            await activity.update(.init(state: state, staleDate: Date().addingTimeInterval(30)))
        }
    }

    func markCaught() {
        guard let activity else { return }
        let finalState = HuntingGameAttributes.ContentState(
            distanceMeters: 0,
            nearestHunterBearing: 0,
            isRadarActive: false,
            dangerLevel: "CRITICAL"
        )
        Task {
            await activity.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .after(.now.advanced(by: 5)))
        }
        self.activity = nil
    }

    func end() {
        guard let activity else { return }
        Task {
            await activity.end(activity.content, dismissalPolicy: .immediate)
        }
        self.activity = nil
    }
}
