import Foundation

// Foundation only, on purpose: no GameKit, no app types. That is what lets
// Tests/GameCenterCheck compile this file on its own in CI and prove the logic below, which is
// the part of Game Center that can be wrong without anything visibly breaking.

/// Every Game Center identifier the app knows about. Mirrors GameCenter/catalog.json, which is
/// what scripts/gamecenter-setup.mjs creates in App Store Connect; Tests/GameCenterCheck fails if
/// the two ever disagree. Vendor identifiers can never be renamed once created, so these are
/// deliberately boring and stable.
enum GameCenterCatalog {
    static let leaderboardPrefix = "hg.leaderboard."
    static let achievementPrefix = "hg.achievement."

    /// The server's leaderboard sort keys (LeaderboardSort), one Game Center leaderboard each.
    static let leaderboardSorts = ["wins", "catches", "matches", "playtime"]

    /// The server's achievement ids (backend buildAchievements), one Game Center achievement each.
    static let achievementKeys = [
        "first_catch", "catches_10", "catches_50", "catches_100",
        "wins_1", "wins_10", "wins_25",
        "matches_10", "matches_50",
        "host_5", "powerups_20", "marathon_120",
        "hunter_10", "runner_10",
    ]

    static func leaderboardID(forSort sort: String) -> String? {
        leaderboardSorts.contains(sort) ? leaderboardPrefix + sort : nil
    }

    static func achievementID(forKey key: String) -> String? {
        achievementKeys.contains(key) ? achievementPrefix + key : nil
    }
}

/// One achievement as the server reports it.
struct GCAchievementReading: Equatable {
    let key: String
    let progress: Int
    let goal: Int
}

/// One lifetime total as the server reports it, for the leaderboard with the same sort key.
struct GCScoreReading: Equatable {
    let sort: String
    let score: Int
}

struct GCAchievementUpdate: Equatable {
    let id: String
    let percent: Double
}

struct GCScoreUpdate: Equatable {
    let leaderboardID: String
    let score: Int
}

/// Decides what is worth telling Game Center. Everything here is a pure function of what the
/// server says now and what was last reported, so it can be run any number of times — after every
/// profile load, every match, every app launch — without ever going backwards or repeating itself.
enum GameCenterProgress {
    /// Game Center wants 0...100, and reaching the goal must read as exactly 100 (which is what
    /// unlocks the achievement and shows the banner), not 99.99 from floating point.
    static func percent(progress: Int, goal: Int) -> Double {
        guard goal > 0 else { return 0 }
        if progress >= goal { return 100 }
        return max(0, Double(progress) / Double(goal) * 100)
    }

    /// Achievements that have moved forward since `lastReported`, restricted to the ones the
    /// catalogue (and therefore App Store Connect) actually has. A server that grows a new
    /// achievement before the app learns about it must not spam Game Center with unknown ids.
    static func achievementUpdates(
        _ readings: [GCAchievementReading],
        lastReported: [String: Double]
    ) -> [GCAchievementUpdate] {
        readings.compactMap { reading in
            guard let id = GameCenterCatalog.achievementID(forKey: reading.key) else { return nil }
            let now = percent(progress: reading.progress, goal: reading.goal)
            let before = lastReported[id] ?? -1
            // Strictly greater: an unchanged value is not news, and 0% on a brand-new achievement
            // is not worth a network call either — Game Center already shows it as locked.
            guard now > before, now > 0 else { return nil }
            return GCAchievementUpdate(id: id, percent: now)
        }
    }

    /// Leaderboard scores that have gone up. Leaderboards keep the best score, so anything not
    /// higher than what was already submitted would be ignored server-side anyway — skipping it
    /// saves the call. Zero is never submitted: it would put a brand-new player on a board they
    /// have not earned a place on.
    static func scoreUpdates(
        _ readings: [GCScoreReading],
        lastSubmitted: [String: Int]
    ) -> [GCScoreUpdate] {
        readings.compactMap { reading in
            guard let id = GameCenterCatalog.leaderboardID(forSort: reading.sort) else { return nil }
            guard reading.score > 0, reading.score > (lastSubmitted[id] ?? 0) else { return nil }
            return GCScoreUpdate(leaderboardID: id, score: reading.score)
        }
    }
}
