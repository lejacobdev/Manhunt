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

    var tagLabel: String { "\(username)#\(userTag)" }
}

struct Friendship: Codable, Identifiable {
    let id: String
    let status: String
}
