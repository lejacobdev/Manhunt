import Foundation

enum PlayerRole: String, Codable, CaseIterable, Identifiable, Hashable {
    case hunter = "HUNTER"
    case runner = "RUNNER"
    case supervisor = "SUPERVISOR"
    case spectator = "SPECTATOR"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hunter: return "Hunter"
        case .runner: return "Runner"
        case .supervisor: return "Supervisor"
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
        case .invisibility: return 600
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
    let radarIntervalSec: Int
    let boundsPolygon: [Coordinate]
    let extractionPoint: Coordinate?
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
    var inventory: [PowerUpType]

    static func == (lhs: PlayerState, rhs: PlayerState) -> Bool {
        lhs.id == rhs.id && lhs.lat == rhs.lat && lhs.lng == rhs.lng && lhs.isCaught == rhs.isCaught
            && lhs.isExtracted == rhs.isExtracted && lhs.battery == rhs.battery
    }
}

/// The Standard-mode shrinking safe zone — mirrors backend ZoneService.ZoneState.
struct ZoneUpdate: Codable {
    let center: Coordinate
    let radiusMeters: Double
    let fullRadiusMeters: Double
    let finalRadiusMeters: Double
    let progress: Double
}

struct DecoyBlip: Codable, Identifiable {
    var id: String { "\(lat)-\(lng)" }
    let lat: Double
    let lng: Double
    let isDecoy: Bool
}

struct CompassUpdate: Codable {
    let distanceMeters: Int
    let bearingDegrees: Double
}

struct RadarBroadcast: Codable {
    let runners: [PlayerState]
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
