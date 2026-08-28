import Foundation

// Compiled into the HuntingGame (iPhone) target, HuntingGameWatch target,
// and HuntingGameWatchWidgets target. Deliberately uses only primitive/raw
// types (no PlayerRole/PowerUpType enums from Sources/Models) so it stays
// self-contained across all three targets without cross-target model imports.

/// A minimal, catch-relevant view of one runner, sent to the Watch only when
/// the wearer is a hunter — enough to pick a target without shipping the
/// full `PlayerState` shape across to a second target group.
public struct WatchRunnerBlip: Codable, Equatable, Identifiable {
    public var id: String
    public var username: String

    public init(id: String, username: String) {
        self.id = id
        self.username = username
    }

    public var dictionary: [String: Any] { ["id": id, "username": username] }

    public init?(dictionary: [String: Any]) {
        guard let id = dictionary["id"] as? String, let username = dictionary["username"] as? String else { return nil }
        self.id = id
        self.username = username
    }
}

/// The live game snapshot the phone pushes to the Watch over WatchConnectivity.
/// Sent via `updateApplicationContext` (always-latest, delivered even if the
/// watch app isn't foreground/reachable right now) so the watch HUD and its
/// complication are never more than one relay behind the phone's socket state.
public struct WatchGameSnapshot: Codable, Equatable {
    public var isActive: Bool
    public var gameCode: String
    public var roleRaw: String
    public var arrestCode: String
    public var isCaught: Bool
    public var nearestDistanceMeters: Int?
    public var nearestBearingDegrees: Double?
    public var inventoryRaw: [String]
    public var isRadarJammed: Bool
    public var visibleRunners: [WatchRunnerBlip]
    public var updatedAt: Date

    public init(
        isActive: Bool,
        gameCode: String,
        roleRaw: String,
        arrestCode: String,
        isCaught: Bool,
        nearestDistanceMeters: Int?,
        nearestBearingDegrees: Double?,
        inventoryRaw: [String],
        isRadarJammed: Bool,
        visibleRunners: [WatchRunnerBlip] = [],
        updatedAt: Date
    ) {
        self.isActive = isActive
        self.gameCode = gameCode
        self.roleRaw = roleRaw
        self.arrestCode = arrestCode
        self.isCaught = isCaught
        self.nearestDistanceMeters = nearestDistanceMeters
        self.nearestBearingDegrees = nearestBearingDegrees
        self.inventoryRaw = inventoryRaw
        self.isRadarJammed = isRadarJammed
        self.visibleRunners = visibleRunners
        self.updatedAt = updatedAt
    }

    public static let idle = WatchGameSnapshot(
        isActive: false,
        gameCode: "",
        roleRaw: "",
        arrestCode: "",
        isCaught: false,
        nearestDistanceMeters: nil,
        nearestBearingDegrees: nil,
        inventoryRaw: [],
        isRadarJammed: false,
        visibleRunners: [],
        updatedAt: .distantPast
    )

    /// A plist-compatible dictionary — required by WatchConnectivity's
    /// `updateApplicationContext`/`sendMessage`, which reject non-plist
    /// values. Optional fields are omitted entirely rather than stored as
    /// `nil`, since a boxed `Optional.none` isn't plist-compatible either.
    public var dictionary: [String: Any] {
        var dict: [String: Any] = [
            "isActive": isActive,
            "gameCode": gameCode,
            "roleRaw": roleRaw,
            "arrestCode": arrestCode,
            "isCaught": isCaught,
            "inventoryRaw": inventoryRaw,
            "isRadarJammed": isRadarJammed,
            "visibleRunners": visibleRunners.map(\.dictionary),
            "updatedAt": updatedAt.timeIntervalSince1970,
        ]
        if let nearestDistanceMeters { dict["nearestDistanceMeters"] = nearestDistanceMeters }
        if let nearestBearingDegrees { dict["nearestBearingDegrees"] = nearestBearingDegrees }
        return dict
    }

    public init?(dictionary: [String: Any]) {
        guard
            let isActive = dictionary["isActive"] as? Bool,
            let gameCode = dictionary["gameCode"] as? String,
            let roleRaw = dictionary["roleRaw"] as? String,
            let arrestCode = dictionary["arrestCode"] as? String,
            let isCaught = dictionary["isCaught"] as? Bool,
            let inventoryRaw = dictionary["inventoryRaw"] as? [String],
            let isRadarJammed = dictionary["isRadarJammed"] as? Bool,
            let updatedAtInterval = dictionary["updatedAt"] as? TimeInterval
        else { return nil }

        self.isActive = isActive
        self.gameCode = gameCode
        self.roleRaw = roleRaw
        self.arrestCode = arrestCode
        self.isCaught = isCaught
        self.nearestDistanceMeters = dictionary["nearestDistanceMeters"] as? Int
        self.nearestBearingDegrees = dictionary["nearestBearingDegrees"] as? Double
        self.inventoryRaw = inventoryRaw
        self.isRadarJammed = isRadarJammed
        self.visibleRunners = (dictionary["visibleRunners"] as? [[String: Any]] ?? []).compactMap(WatchRunnerBlip.init(dictionary:))
        self.updatedAt = Date(timeIntervalSince1970: updatedAtInterval)
    }
}

/// An action the Watch sends back to the phone — the phone owns the actual
/// socket connection, so the watch never talks to the backend directly, it
/// just relays intent through WatchConnectivity.
public enum WatchActionType: String, Codable {
    case usePowerUp = "USE_POWERUP"
    case attemptCatch = "ATTEMPT_CATCH"
}

public struct WatchActionMessage: Codable {
    public var type: WatchActionType
    public var powerUpTypeRaw: String?
    public var targetRunnerId: String?
    public var arrestCode: String?

    public init(type: WatchActionType, powerUpTypeRaw: String? = nil, targetRunnerId: String? = nil, arrestCode: String? = nil) {
        self.type = type
        self.powerUpTypeRaw = powerUpTypeRaw
        self.targetRunnerId = targetRunnerId
        self.arrestCode = arrestCode
    }

    public var dictionary: [String: Any] {
        var dict: [String: Any] = ["type": type.rawValue]
        if let powerUpTypeRaw { dict["powerUpTypeRaw"] = powerUpTypeRaw }
        if let targetRunnerId { dict["targetRunnerId"] = targetRunnerId }
        if let arrestCode { dict["arrestCode"] = arrestCode }
        return dict
    }

    public init?(dictionary: [String: Any]) {
        guard
            let rawType = dictionary["type"] as? String,
            let type = WatchActionType(rawValue: rawType)
        else { return nil }
        self.type = type
        self.powerUpTypeRaw = dictionary["powerUpTypeRaw"] as? String
        self.targetRunnerId = dictionary["targetRunnerId"] as? String
        self.arrestCode = dictionary["arrestCode"] as? String
    }
}

/// Same-device handoff between the Watch app and its complication extension —
/// WatchConnectivity is phone<->watch only, so the two targets that live on
/// the watch itself share this App Group container instead.
public enum WatchAppGroup {
    public static let identifier = "group.com.huntinggame.app.watch"
    public static let snapshotKey = "latestGameSnapshot"

    public static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }

    public static func writeSnapshot(_ snapshot: WatchGameSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        sharedDefaults?.set(data, forKey: snapshotKey)
    }

    public static func readSnapshot() -> WatchGameSnapshot {
        guard
            let data = sharedDefaults?.data(forKey: snapshotKey),
            let snapshot = try? JSONDecoder().decode(WatchGameSnapshot.self, from: data)
        else { return .idle }
        return snapshot
    }
}
