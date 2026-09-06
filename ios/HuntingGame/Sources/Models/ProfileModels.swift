import Foundation

/// Career totals for one account, computed server-side from match history — see
/// backend/src/routes/users.ts. Nothing here is stored per-user; it's all derived, so it
/// can never drift out of sync with the matches actually played.
struct ProfileStats: Codable, Equatable {
    let matchesPlayed: Int
    let wins: Int
    let matchesAsHunter: Int
    let matchesAsRunner: Int
    let catchesMade: Int
    let timesCaught: Int
    let extractions: Int
    let timesEliminated: Int
    let matchesHosted: Int
    let powerUpsCollected: Int
    let gamblesWon: Int
    let gamblesLost: Int
    let minutesPlayed: Int

    var winRatePercent: Int {
        guard matchesPlayed > 0 else { return 0 }
        return Int((Double(wins) / Double(matchesPlayed) * 100).rounded())
    }

    /// "4h 12m" / "12m" — minutes alone stops reading as a number past an hour or two.
    var playtimeLabel: String {
        let hours = minutesPlayed / 60
        let minutes = minutesPlayed % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

struct Achievement: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let description: String
    /// SF Symbol name, chosen server-side so the whole roster lives in one place.
    let icon: String
    let goal: Int
    let progress: Int
    let unlocked: Bool

    var fractionComplete: Double {
        guard goal > 0 else { return 0 }
        return min(1, Double(progress) / Double(goal))
    }
}

/// The account a profile belongs to. Distinct from `AppUser` because a profile carries
/// `createdAt` (for "playing since") that the friend/search endpoints don't return.
struct ProfileUser: Codable, Identifiable, Equatable {
    let id: String
    let username: String
    let userTag: String
    let avatarUrl: String?
    let createdAt: String
    let isOnline: Bool?

    var tagLabel: String { "\(username)#\(userTag)" }

    var memberSinceLabel: String? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: createdAt) ?? ISO8601DateFormatter().date(from: createdAt) else { return nil }
        let display = DateFormatter()
        display.dateFormat = "MMMM yyyy"
        return display.string(from: date)
    }
}

struct UserProfile: Codable, Equatable {
    let user: ProfileUser
    let stats: ProfileStats
    let achievements: [Achievement]

    var unlockedAchievements: [Achievement] { achievements.filter(\.unlocked) }
}

// MARK: - Leaderboard

enum LeaderboardSort: String, Codable, CaseIterable, Identifiable {
    case wins, catches, extractions, matches, playtime

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wins: return "WINS"
        case .catches: return "CATCHES"
        case .extractions: return "ESCAPES"
        case .matches: return "MATCHES"
        case .playtime: return "PLAYTIME"
        }
    }
}

struct LeaderboardEntry: Codable, Identifiable, Equatable {
    let rank: Int
    let user: AppUser
    let matchesPlayed: Int
    let wins: Int
    let winRatePercent: Int
    let catchesMade: Int
    let extractions: Int
    let minutesPlayed: Int

    var id: String { user.id }

    /// "12h 15m" / "45m" — matches ProfileStats.playtimeLabel's formatting so the same
    /// number reads identically whether you're seeing it on a profile or the leaderboard.
    var playtimeLabel: String {
        let hours = minutesPlayed / 60
        let minutes = minutesPlayed % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    /// The raw sortable number for a given category — playtime intentionally isn't here
    /// (minutes as a bare integer reads badly at scale); see `displayValue(for:)` for what
    /// the row actually shows.
    func value(for sort: LeaderboardSort) -> Int {
        switch sort {
        case .wins: return wins
        case .catches: return catchesMade
        case .extractions: return extractions
        case .matches: return matchesPlayed
        case .playtime: return minutesPlayed
        }
    }

    func displayValue(for sort: LeaderboardSort) -> String {
        sort == .playtime ? playtimeLabel : "\(value(for: sort))"
    }
}

struct Leaderboard: Codable, Equatable {
    let sort: LeaderboardSort
    let entries: [LeaderboardEntry]
    /// The signed-in player's own standing, present even when they fall outside the top
    /// 100 shown in `entries` — nil only if they haven't finished a single match yet.
    let me: LeaderboardEntry?
}
