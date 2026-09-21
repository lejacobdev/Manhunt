import Foundation

/// Which ways in exist for the signed-in account: the two providers, plus whether a password is set.
/// The account screen needs all three to know what it may offer to unlink (see
/// backend `services/ProviderAccounts.ts` — the last way in can't be removed).
struct AccountConnections: Codable, Equatable {
    var apple: Bool
    var gamecenter: Bool
    var hasPassword: Bool

    /// Everything that could be used to sign in, counted. Used to explain *why* an unlink is
    /// unavailable before the server has to refuse it.
    var signInMethodCount: Int {
        [apple, gamecenter, hasPassword].filter { $0 }.count
    }
}

/// GET /users/me/account
struct AccountOverview: Codable, Equatable {
    var user: AppUser
    var connections: AccountConnections
    var nameChangeCooldownDays: Int
    /// ISO-8601, or nil when the name can be changed right now. Kept as text and parsed on demand,
    /// the way every other date in this app is (the API writes fractional seconds).
    var nextNameChangeAt: String?

    var nextNameChangeDate: Date? {
        guard let nextNameChangeAt else { return nil }
        return Self.parse(nextNameChangeAt)
    }

    /// True when the cooldown has not elapsed. Derived from the date rather than trusted as a flag
    /// so a screen left open overnight stops blocking by itself.
    var isNameChangeOnCooldown: Bool {
        guard let date = nextNameChangeDate else { return false }
        return date > Date()
    }

    static func parse(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}

/// What the two provider sign-in endpoints can answer: either a session, or "tell us what to call
/// you first" with a short-lived ticket to finish with.
enum ProviderSignInOutcome {
    case signedIn(token: String, user: AppUser)
    case needsUsername(ticket: String)
}

/// The sign-in methods a person can add to an account, as the API names them in its paths.
enum AccountProvider: String, CaseIterable, Identifiable {
    case apple
    case gamecenter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return "Apple"
        case .gamecenter: return "Game Center"
        }
    }

    /// SF Symbol. Apple's guidelines reserve the Apple logo for Apple's own button, so the
    /// connected-accounts row uses a neutral mark instead of pretending to be one.
    var icon: String {
        switch self {
        case .apple: return "apple.logo"
        case .gamecenter: return "gamecontroller.fill"
        }
    }

    func isLinked(in connections: AccountConnections) -> Bool {
        switch self {
        case .apple: return connections.apple
        case .gamecenter: return connections.gamecenter
        }
    }
}
