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
