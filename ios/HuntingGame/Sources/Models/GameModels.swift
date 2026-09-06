import Foundation

enum PlayerRole: String, Codable, CaseIterable, Identifiable, Hashable {
    case hunter = "HUNTER"
    case runner = "RUNNER"
    case spectator = "SPECTATOR"

    var id: String { rawValue }

    /// Decoding a JSON array is all-or-nothing, so a single row carrying a role this
    /// build doesn't know would otherwise abort the whole response and blank an entire
    /// screen. That isn't hypothetical: every game hosted before the SUPERVISOR role
    /// was removed still has `role = "SUPERVISOR"` in the database until that
    /// migration is deployed. Fall back to the non-playing observer role instead —
    /// the same value the migration remaps those rows to.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PlayerRole(rawValue: raw) ?? .spectator
    }

    var displayName: String {
        switch self {
        case .hunter: return "Hunter"
        case .runner: return "Runner"
        case .spectator: return "Spectator"
        }
    }
}

enum GameMode: String, Codable, CaseIterable, Identifiable, Hashable {
    case standard = "STANDARD"
    case infection = "INFECTION"
    case squad = "SQUAD"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "Standard Manhunt"
        case .infection: return "Infection"
        case .squad: return "Squad vs Squad"
        }
    }
}

enum GameStatus: String, Codable {
    case lobby = "LOBBY"
    case active = "ACTIVE"
    case paused = "PAUSED"
    case ended = "ENDED"
}

enum PowerUpType: String, Codable, CaseIterable, Identifiable, Hashable {
    case invisibility = "INVISIBILITY_10MIN"
    case ghostDecoy = "GHOST_DECOY"
    case empJammer = "EMP_JAMMER"
    case thermalVision = "THERMAL_VISION"
    case adrenaline = "ADRENALINE"
    case safeZoneFlare = "SAFE_ZONE_FLARE"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .invisibility: return "Invisibility"
        case .ghostDecoy: return "Ghost Decoy"
        case .empJammer: return "EMP Jammer"
        case .thermalVision: return "Thermal Vision"
        case .adrenaline: return "Adrenaline"
        case .safeZoneFlare: return "Safe Zone Flare"
        }
    }

    var iconName: String {
        switch self {
        case .invisibility: return "eye.slash.fill"
        case .ghostDecoy: return "person.3.sequence.fill"
        case .empJammer: return "bolt.slash.fill"
        case .thermalVision: return "eye.trianglebadge.exclamationmark"
        case .adrenaline: return "bolt.heart.fill"
        case .safeZoneFlare: return "flame.fill"
        }
    }

    var durationSeconds: Int {
        switch self {
        // Raw value/display name still say "10MIN" — see the matching backend constant
        // for why that's not being renamed along with the actual duration.
        case .invisibility: return 60
        case .ghostDecoy: return 180
        case .empJammer: return 60
        case .thermalVision: return 45
        case .adrenaline: return 90
        case .safeZoneFlare: return 90
        }
    }
}

struct Coordinate: Codable, Equatable {
    let lat: Double
    let lng: Double
}

/// Mirrors backend GameService.GameSettings — the immutable configuration
/// chosen when a session was created.
struct GameSettings: Codable, Equatable {
    let durationMinutes: Int
    let boundsPolygon: [Coordinate]
    let extractionPoint: Coordinate?
    /// Optional/absent on sessions created before this feature shipped.
    let jailEnabled: Bool?
    let jailPolygon: [Coordinate]?
    let gamblingEnabled: Bool?
    /// Absent decodes as disabled — off by default. Labeled BETA in the UI: the
    /// accuracy/motion/speed/teleport checks are new enough that a false-positive
    /// rejection can look like a frozen radar, so it's opt-in rather than on by default.
    let antiCheatEnabled: Bool?
}

struct GameSession: Codable, Identifiable {
    let id: String
    let code: String
    let status: GameStatus
    let mode: GameMode
    let hostId: String
    let startedAt: String?
    let endedAt: String?
    let settings: GameSettings
}

struct GamePlayer: Codable, Identifiable {
    let id: String
    let sessionId: String
    let userId: String
    let role: PlayerRole
    let squad: String?
    let isCaught: Bool
    let arrestCode: String
    let hearts: Int
}

/// Live, in-memory state broadcast over the socket for every player in a room.
struct PlayerState: Codable, Identifiable, Equatable {
    let id: String
    let userId: String
    let username: String
    var role: PlayerRole
    var squad: String?
    var lat: Double
    var lng: Double
    var speed: Double
    var accuracy: Double
    var battery: Int
    var isMovingOnFoot: Bool
    var arrestCode: String
    var isCaught: Bool
    var isExtracted: Bool
    var isJailed: Bool
    var isOut: Bool
    var hearts: Int
    var inventory: [PowerUpType]

    static func == (lhs: PlayerState, rhs: PlayerState) -> Bool {
        lhs.id == rhs.id && lhs.lat == rhs.lat && lhs.lng == rhs.lng && lhs.isCaught == rhs.isCaught
            && lhs.isExtracted == rhs.isExtracted && lhs.battery == rhs.battery
            && lhs.isJailed == rhs.isJailed && lhs.isOut == rhs.isOut && lhs.hearts == rhs.hearts
    }
}

/// The runner's response to a hunter's catch request, or the hunter's own "is this
/// accidental?" follow-up — both carry the same `requestId` so a hunter with more than
/// one pending request out (to different runners) can tell them apart.
struct CatchRequest: Identifiable, Equatable {
    let requestId: String
    let hunterId: String
    let hunterUsername: String
    var id: String { requestId }
}

/// Hunter-side prompt shown after a runner taps "No, that wasn't a catch."
struct DenyConfirmRequest: Identifiable, Equatable {
    let requestId: String
    let runnerUsername: String
    var id: String { requestId }
}

enum GambleChoice: String {
    case heads
    case tails
}

/// One round of a gamble duel, as resolved by the server — both the hunter's and runner's
/// clients animate their coin to the same `result`. Hearts lost here are real and
/// persistent on both sides; the duel runs round after round until one of them hits zero.
struct GambleResult: Codable, Equatable {
    let hunterId: String
    let runnerId: String
    let gambleChoice: String
    let result: String
    let heartsLostBy: String
    let hunterHeartsRemaining: Int
    let runnerHeartsRemaining: Int
    /// 1-based round number within this duel.
    let round: Int
    /// False on the round that emptied someone's hearts — that player is eliminated.
    let continues: Bool
}

/// The shrinking play zone's current circle, pushed periodically by the server. Outside it
/// is the same slow heart drain as outside the outer boundary.
struct ZoneUpdate: Codable, Equatable {
    let center: Coordinate
    let radiusMeters: Double
    let fullRadiusMeters: Double
    let finalRadiusMeters: Double
    /// 0 at match start, 1 when fully contracted at match end.
    let progress: Double
}

/// A live SAFE_ZONE_FLARE bubble — no catch can be made against a runner standing in one.
struct ActiveSafeZone: Equatable {
    let lat: Double
    let lng: Double
    let radiusMeters: Double
    let expiresAt: Date
}

struct DecoyBlip: Codable, Identifiable {
    var id: String { "\(lat)-\(lng)" }
    let lat: Double
    let lng: Double
    let isDecoy: Bool
}

/// One hunter's bearing/distance from the runner's own position, as computed server-side.
struct HunterBearing: Codable, Identifiable {
    let hunterId: String
    let username: String
    let distanceMeters: Int
    let bearingDegrees: Double
    var id: String { hunterId }
}

struct CompassUpdate: Codable {
    /// The nearest hunter's distance/bearing — kept alongside `hunters` (equal to its
    /// first, closest entry) for the Watch app and Live Activity, which only ever show one.
    let distanceMeters: Int
    let bearingDegrees: Double
    /// Every currently-visible hunter, nearest first. Absent decodes as empty rather than
    /// failing — a defensive fallback, not an expected shape from this server.
    let hunters: [HunterBearing]

    enum CodingKeys: String, CodingKey { case distanceMeters, bearingDegrees, hunters }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        distanceMeters = try container.decode(Int.self, forKey: .distanceMeters)
        bearingDegrees = try container.decode(Double.self, forKey: .bearingDegrees)
        hunters = try container.decodeIfPresent([HunterBearing].self, forKey: .hunters) ?? []
    }
}

/// One runner's bearing/distance from a hunter's own position — the hunter-side mirror of
/// `HunterBearing`, computed the same way but from the opposite direction.
struct RunnerBearing: Codable, Identifiable {
    let runnerId: String
    let username: String
    let distanceMeters: Int
    let bearingDegrees: Double
    var id: String { runnerId }
}

struct RadarBroadcast: Codable {
    let runners: [PlayerState]
    /// Absent from an older/never-updated server payload decodes as nil, not a decode
    /// failure — see `GameViewModel.visibleRunnerBearings`, which treats nil as empty.
    let runnerBearings: [RunnerBearing]?
    let decoys: [DecoyBlip]?
    let jammed: Bool
}

struct PowerUpSpawn: Codable, Identifiable {
    let id: String
    let sessionId: String
    let type: PowerUpType
    let latitude: Double
    let longitude: Double
    let expiresAt: String
}

struct AppUser: Codable, Identifiable, Equatable {
    let id: String
    let username: String
    let userTag: String
    let avatarUrl: String?
    /// Only populated by GET /friends (a live presence read); absent (nil) from search
    /// results and other endpoints that don't compute it.
    var isOnline: Bool?

    var tagLabel: String { "\(username)#\(userTag)" }
}

struct Friendship: Codable, Identifiable {
    let id: String
    let status: String
}

/// A pending friend request, either received or sent — mirrors the trimmed
/// (no passwordHash) shape returned by GET /friends/requests/incoming|outgoing.
struct FriendRequest: Codable, Identifiable {
    let id: String
    let createdAt: String
    let from: AppUser?
    let to: AppUser?

    var otherUser: AppUser { from ?? to ?? AppUser(id: "", username: "?", userTag: "0000", avatarUrl: nil, isOnline: nil) }
}

/// A durable invite to join a friend's lobby — mirrors GameInvite's REST/socket payload shape.
struct GameInvite: Codable, Identifiable {
    let id: String
    let sessionCode: String
    let mode: GameMode
    let fromUserId: String
    let fromUsername: String
    let createdAt: String
}

/// One buffered GPS fix from GET /games/:code/replay's per-player track.
struct ReplayTrackPoint: Codable {
    let lat: Double
    let lng: Double
    let accuracy: Double
    let speed: Double?
    let timestamp: String
}

struct ReplayPlayer: Codable, Identifiable {
    let gamePlayerId: String
    let username: String
    let role: PlayerRole
    let track: [ReplayTrackPoint]

    var id: String { gamePlayerId }
}

/// Full post-game (or in-progress) playback data for a match.
struct MatchReplay: Codable {
    let startedAt: String?
    let endedAt: String?
    let players: [ReplayPlayer]
}

/// One row of GET /games/history/mine — a past match this player took part in.
/// Only the fields this app actually uses are declared; Decodable ignores the rest.
struct HistoryEntry: Codable, Identifiable {
    let id: String
    let role: PlayerRole
    let isCaught: Bool
    let isExtracted: Bool
    let joinedAt: String
    let session: GameSession
}
