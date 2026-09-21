import Foundation
import GameKit
import UIKit

/// Game Center, as a thin layer over what the game already knows.
///
/// The server already derives every career stat and achievement from match history
/// (backend/src/routes/users.ts), so nothing here invents data or keeps score of its own: after the
/// app fetches the profile it tells Game Center what the server says. That makes it safe to run as
/// often as is convenient — the "what is worth reporting" decisions live in `GameCenterProgress`
/// and are pure functions of the server's numbers and what was last reported.
@MainActor
final class GameCenterManager: ObservableObject {
    static let shared = GameCenterManager()

    enum Status: Equatable {
        /// Authentication hasn't answered yet.
        case unknown
        /// Not signed in to Game Center on this device, and nothing is offering to.
        case signedOut
        /// Game Center has a sign-in sheet ready; it is shown when the player asks for it.
        case needsSignIn
        /// An Apple Account that can't take part (a child account).
        case restricted
        case connected(alias: String)
    }

    @Published private(set) var status: Status = .unknown

    /// Scores and achievements appear on public leaderboards under the player's Game Center name,
    /// so sharing is theirs to switch off. On by default: signing in to Game Center is already the
    /// opt-in, and a switch that starts off would mean almost nobody ever showed up on a board.
    @Published var isSharingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isSharingEnabled, forKey: Keys.sharing)
            if isSharingEnabled { Task { await syncFromServer(force: true) } }
        }
    }

    var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    private enum Keys {
        static let sharing = "gameCenterSharingEnabled"
        static func scores(_ scope: String) -> String { "gameCenter.scores.\(scope)" }
        static func achievements(_ scope: String) -> String { "gameCenter.achievements.\(scope)" }
    }

    private var authenticationStarted = false
    private var pendingSignInController: UIViewController?
    private var isSyncing = false
    private var lastSyncAt: Date = .distantPast

    private init() {
        isSharingEnabled = UserDefaults.standard.object(forKey: Keys.sharing) as? Bool ?? true
    }

    // MARK: - Signing in

    /// Starts Game Center authentication. Deliberately not called from app launch: the terms and
    /// rules gates come first, and nothing about Game Center should appear in front of them.
    func startAuthenticationIfNeeded() {
        guard !authenticationStarted else { return }
        authenticationStarted = true

        // The handler can fire several times (sign in, sign out, account switch), so it only ever
        // updates state and never presents anything itself.
        GKLocalPlayer.local.authenticateHandler = { [weak self] viewController, error in
            Task { @MainActor in
                self?.handleAuthentication(viewController: viewController, error: error)
            }
        }
    }

    private func handleAuthentication(viewController: UIViewController?, error: Error?) {
        if let viewController {
            pendingSignInController = viewController
            status = .needsSignIn
            return
        }

        let player = GKLocalPlayer.local
        guard player.isAuthenticated else {
            pendingSignInController = nil
            status = .signedOut
            if let error { print("[GameCenter] not signed in: \(error.localizedDescription)") }
            return
        }

        pendingSignInController = nil
        if player.isUnderage {
            // Child accounts get Game Center's own restrictions; never post their name and
            // scores to public boards from here.
            status = .restricted
            return
        }

        status = .connected(alias: player.displayName)
        Task { await syncFromServer(force: true) }
    }

    /// Shows the Game Center sign-in sheet that authentication handed back.
    func presentSignIn() {
        guard let controller = pendingSignInController else { return }
        Self.topViewController()?.present(controller, animated: true)
    }

    // MARK: - Reporting

    /// Fetches this account's profile and reports it. Throttled, because it is called from several
    /// places (launch, foreground, profile, end of match) that can easily fire close together.
    func syncFromServer(force: Bool = false) async {
        guard isSharingEnabled, isConnected, !isSyncing, AuthSession.shared.isAuthenticated else { return }
        guard force || Date().timeIntervalSince(lastSyncAt) > 30 else { return }

        isSyncing = true
        lastSyncAt = Date()
        defer { isSyncing = false }

        do {
            let profile = try await APIClient.shared.myProfile()
            await report(profile)
        } catch {
            print("[GameCenter] couldn't load the profile to report: \(error.localizedDescription)")
        }
    }

    /// Reports an already-loaded profile — what the Profile screen calls after its own fetch, so
    /// opening it doesn't cost a second request.
    func report(_ profile: UserProfile) async {
        guard isSharingEnabled, isConnected else { return }

        let scope = cacheScope()
        var lastScores = UserDefaults.standard.dictionary(forKey: Keys.scores(scope)) as? [String: Int] ?? [:]
        var lastAchievements = UserDefaults.standard.dictionary(forKey: Keys.achievements(scope)) as? [String: Double] ?? [:]

        // --- Leaderboards: lifetime totals, best score kept ---
        let stats = profile.stats
        let scoreUpdates = GameCenterProgress.scoreUpdates(
            [
                GCScoreReading(sort: "wins", score: stats.wins),
                GCScoreReading(sort: "catches", score: stats.catchesMade),
                GCScoreReading(sort: "matches", score: stats.matchesPlayed),
                GCScoreReading(sort: "playtime", score: stats.minutesPlayed),
            ],
            lastSubmitted: lastScores
        )
        for update in scoreUpdates {
            do {
                try await GKLeaderboard.submitScore(
                    update.score, context: 0, player: GKLocalPlayer.local, leaderboardIDs: [update.leaderboardID]
                )
                lastScores[update.leaderboardID] = update.score
            } catch {
                print("[GameCenter] score for \(update.leaderboardID) failed: \(error.localizedDescription)")
            }
        }

        // --- Achievements: progress toward each goal ---
        let updates = GameCenterProgress.achievementUpdates(
            profile.achievements.map { GCAchievementReading(key: $0.id, progress: $0.progress, goal: $0.goal) },
            lastReported: lastAchievements
        )
        if !updates.isEmpty {
            // The first report from this device is a backfill of things already earned; showing a
            // banner for each would be a burst of "achievement unlocked" for nothing just happened.
            let isBackfill = lastAchievements.isEmpty
            let achievements = updates.map { update -> GKAchievement in
                let achievement = GKAchievement(identifier: update.id)
                achievement.percentComplete = update.percent
                achievement.showsCompletionBanner = !isBackfill
                return achievement
            }
            do {
                try await GKAchievement.report(achievements)
                for update in updates { lastAchievements[update.id] = update.percent }
            } catch {
                print("[GameCenter] achievements failed: \(error.localizedDescription)")
            }
        }

        UserDefaults.standard.set(lastScores, forKey: Keys.scores(scope))
        UserDefaults.standard.set(lastAchievements, forKey: Keys.achievements(scope))
    }

    /// What was last reported is remembered per Game Center player AND per app account: someone
    /// signing a second account in on the same device must not be treated as already reported.
    private func cacheScope() -> String {
        let player = GKLocalPlayer.local.gamePlayerID
        let account = AuthSession.shared.currentUser?.id ?? "anonymous"
        return "\(player).\(account)"
    }

    // MARK: - Presenting

    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
