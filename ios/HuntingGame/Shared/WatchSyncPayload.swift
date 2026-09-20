import Foundation

// Compiled into the HuntingGame (iPhone) target, HuntingGameWatch target,
// and HuntingGameWatchWidgets target. Deliberately uses only primitive/raw
// types (no PlayerRole/PowerUpType enums from Sources/Models) so it stays
// self-contained across all three targets without cross-target model imports.
//
// COMPATIBILITY: the phone and the Watch app update on their own schedules, so every pairing
// of old and new has to keep working. Everything added in Watch app 1.0.1 is therefore
// optional-with-a-default on BOTH decode paths (JSON for the shared App Group, and the plist
// dictionary WatchConnectivity carries): an old Watch simply ignores keys it doesn't know,
// and a new Watch fed by an old phone falls back to the defaults below.

/// A minimal view of one runner, kept in the payload for Watch builds that predate `WatchBlip`
/// (1.0.0 reads only this) — the phone still fills it so they keep working.
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

/// One player on the radar: a hunter for a runner, a runner for a hunter. The bearing is
/// ABSOLUTE (degrees clockwise from north, straight from the server) — the Watch subtracts the
/// player's heading itself, exactly as the iPhone radar does.
public struct WatchBlip: Codable, Equatable, Identifiable {
    public var id: String
    public var username: String
    public var distanceMeters: Int
    public var bearingDegrees: Double

    public init(id: String, username: String, distanceMeters: Int, bearingDegrees: Double) {
        self.id = id
        self.username = username
        self.distanceMeters = distanceMeters
        self.bearingDegrees = bearingDegrees
    }

    public var dictionary: [String: Any] {
        ["id": id, "username": username, "distanceMeters": distanceMeters, "bearingDegrees": bearingDegrees]
    }

    public init?(dictionary: [String: Any]) {
        guard
            let id = dictionary["id"] as? String,
            let username = dictionary["username"] as? String,
            let distance = dictionary["distanceMeters"] as? Int,
            let bearing = dictionary["bearingDegrees"] as? Double
        else { return nil }
        self.init(id: id, username: username, distanceMeters: distance, bearingDegrees: bearing)
    }
}

/// A power-up effect that's currently running, with the seconds it has left.
public struct WatchBuff: Codable, Equatable, Identifiable {
    public var raw: String
    public var remainingSeconds: Int
    public var id: String { raw }

    public init(raw: String, remainingSeconds: Int) {
        self.raw = raw
        self.remainingSeconds = remainingSeconds
    }

    public var dictionary: [String: Any] { ["raw": raw, "remainingSeconds": remainingSeconds] }

    public init?(dictionary: [String: Any]) {
        guard let raw = dictionary["raw"] as? String, let remaining = dictionary["remainingSeconds"] as? Int else { return nil }
        self.init(raw: raw, remainingSeconds: remaining)
    }
}

/// A hunter telling the wearer (a runner) "I caught you" — the wearer answers on their wrist.
public struct WatchCatchRequest: Codable, Equatable {
    public var requestId: String
    public var hunterUsername: String

    public init(requestId: String, hunterUsername: String) {
        self.requestId = requestId
        self.hunterUsername = hunterUsername
    }

    public var dictionary: [String: Any] { ["requestId": requestId, "hunterUsername": hunterUsername] }

    public init?(dictionary: [String: Any]) {
        guard let id = dictionary["requestId"] as? String, let name = dictionary["hunterUsername"] as? String else { return nil }
        self.init(requestId: id, hunterUsername: name)
    }
}

/// A runner told the wearer (a hunter) "that wasn't a catch"; the hunter says whether it was a slip.
public struct WatchDenyConfirm: Codable, Equatable {
    public var requestId: String
    public var runnerUsername: String

    public init(requestId: String, runnerUsername: String) {
        self.requestId = requestId
        self.runnerUsername = runnerUsername
    }

    public var dictionary: [String: Any] { ["requestId": requestId, "runnerUsername": runnerUsername] }

    public init?(dictionary: [String: Any]) {
        guard let id = dictionary["requestId"] as? String, let name = dictionary["runnerUsername"] as? String else { return nil }
        self.init(requestId: id, runnerUsername: name)
    }
}

/// The live game snapshot the phone pushes to the Watch over WatchConnectivity.
/// Sent via `updateApplicationContext` (always-latest, delivered even if the
/// watch app isn't foreground/reachable right now) so the watch HUD and its
/// complication are never more than one relay behind the phone's socket state.
public struct WatchGameSnapshot: Codable, Equatable {
    // --- Present since 1.0.0 (required on the wire) ---
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

    // --- Added in 1.0.1 (all optional on the wire) ---
    public var hearts: Int
    public var maxHearts: Int
    public var modeRaw: String
    /// Which way the player is facing, degrees from north — course over ground while moving
    /// (reliable with the phone in a pocket), the compass otherwise. Nil = unknown.
    public var headingDegrees: Double?
    public var blips: [WatchBlip]
    public var matchEndsAt: Date?
    public var isJailed: Bool
    public var isOut: Bool
    public var eliminationReason: String
    /// Seconds left to reach the jail after being caught; nil when not heading there.
    public var jailArrivalRemaining: Int?
    /// Seconds left to get back inside the jail after leaving it; nil when inside.
    public var jailEscapeCountdown: Int?
    public var bailActive: Bool
    public var bailRemainingSeconds: Int
    public var zoneOutside: Bool
    /// "ZONE" (the shrinking circle) or "BOUNDARY" (the drawn play area); "" when inside.
    public var zoneReason: String
    public var zoneRadiusMeters: Int?
    public var buffs: [WatchBuff]
    public var incomingCatch: WatchCatchRequest?
    /// Hunter side: who the wearer has just asked to confirm a catch, while waiting for an answer.
    public var pendingCatchTargetName: String?
    public var denyConfirm: WatchDenyConfirm?
    /// A short message from the phone ("Runner is too far away") — shown once, briefly.
    public var notice: String
    public var runnersFree: Int
    public var runnersJailed: Int
    public var huntersCount: Int

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
        updatedAt: Date,
        hearts: Int = 0,
        maxHearts: Int = 0,
        modeRaw: String = "",
        headingDegrees: Double? = nil,
        blips: [WatchBlip] = [],
        matchEndsAt: Date? = nil,
        isJailed: Bool = false,
        isOut: Bool = false,
        eliminationReason: String = "",
        jailArrivalRemaining: Int? = nil,
        jailEscapeCountdown: Int? = nil,
        bailActive: Bool = false,
        bailRemainingSeconds: Int = 0,
        zoneOutside: Bool = false,
        zoneReason: String = "",
        zoneRadiusMeters: Int? = nil,
        buffs: [WatchBuff] = [],
        incomingCatch: WatchCatchRequest? = nil,
        pendingCatchTargetName: String? = nil,
        denyConfirm: WatchDenyConfirm? = nil,
        notice: String = "",
        runnersFree: Int = 0,
        runnersJailed: Int = 0,
        huntersCount: Int = 0
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
        self.hearts = hearts
        self.maxHearts = maxHearts
        self.modeRaw = modeRaw
        self.headingDegrees = headingDegrees
        self.blips = blips
        self.matchEndsAt = matchEndsAt
        self.isJailed = isJailed
        self.isOut = isOut
        self.eliminationReason = eliminationReason
        self.jailArrivalRemaining = jailArrivalRemaining
        self.jailEscapeCountdown = jailEscapeCountdown
        self.bailActive = bailActive
        self.bailRemainingSeconds = bailRemainingSeconds
        self.zoneOutside = zoneOutside
        self.zoneReason = zoneReason
        self.zoneRadiusMeters = zoneRadiusMeters
        self.buffs = buffs
        self.incomingCatch = incomingCatch
        self.pendingCatchTargetName = pendingCatchTargetName
        self.denyConfirm = denyConfirm
        self.notice = notice
        self.runnersFree = runnersFree
        self.runnersJailed = runnersJailed
        self.huntersCount = huntersCount
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

    // MARK: - Convenience

    public var isRunner: Bool { roleRaw == "RUNNER" }
    public var isHunter: Bool { roleRaw == "HUNTER" }
    public var isSpectator: Bool { roleRaw == "SPECTATOR" }

    /// The blip to lead with, nearest first — falls back to the 1.0.0 single-reading fields
    /// when an old phone sent no `blips` at all.
    public var nearestBlip: WatchBlip? {
        if let first = blips.min(by: { $0.distanceMeters < $1.distanceMeters }) { return first }
        guard let distance = nearestDistanceMeters else { return nil }
        return WatchBlip(id: "nearest", username: "", distanceMeters: distance, bearingDegrees: nearestBearingDegrees ?? 0)
    }

    /// True when `self` differs from `other` in something the wearer must see promptly — the
    /// phone uses it to bypass its send throttle, so a catch request or a lost heart reaches the
    /// wrist immediately instead of on the next 1.5 s tick.
    public func isUrgentChange(from other: WatchGameSnapshot) -> Bool {
        isActive != other.isActive
            || isCaught != other.isCaught
            || isJailed != other.isJailed
            || isOut != other.isOut
            || hearts != other.hearts
            || bailActive != other.bailActive
            || zoneOutside != other.zoneOutside
            || incomingCatch != other.incomingCatch
            || pendingCatchTargetName != other.pendingCatchTargetName
            || denyConfirm != other.denyConfirm
            || notice != other.notice
    }

    // MARK: - Codable (tolerant of snapshots written by older builds)

    private enum CodingKeys: String, CodingKey {
        case isActive, gameCode, roleRaw, arrestCode, isCaught, nearestDistanceMeters, nearestBearingDegrees
        case inventoryRaw, isRadarJammed, visibleRunners, updatedAt
        case hearts, maxHearts, modeRaw, headingDegrees, blips, matchEndsAt, isJailed, isOut, eliminationReason
        case jailArrivalRemaining, jailEscapeCountdown, bailActive, bailRemainingSeconds, zoneOutside, zoneReason
        case zoneRadiusMeters, buffs, incomingCatch, pendingCatchTargetName, denyConfirm, notice
        case runnersFree, runnersJailed, huntersCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isActive = try c.decode(Bool.self, forKey: .isActive)
        gameCode = try c.decode(String.self, forKey: .gameCode)
        roleRaw = try c.decode(String.self, forKey: .roleRaw)
        arrestCode = try c.decode(String.self, forKey: .arrestCode)
        isCaught = try c.decode(Bool.self, forKey: .isCaught)
        nearestDistanceMeters = try c.decodeIfPresent(Int.self, forKey: .nearestDistanceMeters)
        nearestBearingDegrees = try c.decodeIfPresent(Double.self, forKey: .nearestBearingDegrees)
        inventoryRaw = try c.decode([String].self, forKey: .inventoryRaw)
        isRadarJammed = try c.decode(Bool.self, forKey: .isRadarJammed)
        visibleRunners = try c.decodeIfPresent([WatchRunnerBlip].self, forKey: .visibleRunners) ?? []
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)

        hearts = try c.decodeIfPresent(Int.self, forKey: .hearts) ?? 0
        maxHearts = try c.decodeIfPresent(Int.self, forKey: .maxHearts) ?? 0
        modeRaw = try c.decodeIfPresent(String.self, forKey: .modeRaw) ?? ""
        headingDegrees = try c.decodeIfPresent(Double.self, forKey: .headingDegrees)
        blips = try c.decodeIfPresent([WatchBlip].self, forKey: .blips) ?? []
        matchEndsAt = try c.decodeIfPresent(Date.self, forKey: .matchEndsAt)
        isJailed = try c.decodeIfPresent(Bool.self, forKey: .isJailed) ?? false
        isOut = try c.decodeIfPresent(Bool.self, forKey: .isOut) ?? false
        eliminationReason = try c.decodeIfPresent(String.self, forKey: .eliminationReason) ?? ""
        jailArrivalRemaining = try c.decodeIfPresent(Int.self, forKey: .jailArrivalRemaining)
        jailEscapeCountdown = try c.decodeIfPresent(Int.self, forKey: .jailEscapeCountdown)
        bailActive = try c.decodeIfPresent(Bool.self, forKey: .bailActive) ?? false
        bailRemainingSeconds = try c.decodeIfPresent(Int.self, forKey: .bailRemainingSeconds) ?? 0
        zoneOutside = try c.decodeIfPresent(Bool.self, forKey: .zoneOutside) ?? false
        zoneReason = try c.decodeIfPresent(String.self, forKey: .zoneReason) ?? ""
        zoneRadiusMeters = try c.decodeIfPresent(Int.self, forKey: .zoneRadiusMeters)
        buffs = try c.decodeIfPresent([WatchBuff].self, forKey: .buffs) ?? []
        incomingCatch = try c.decodeIfPresent(WatchCatchRequest.self, forKey: .incomingCatch)
        pendingCatchTargetName = try c.decodeIfPresent(String.self, forKey: .pendingCatchTargetName)
        denyConfirm = try c.decodeIfPresent(WatchDenyConfirm.self, forKey: .denyConfirm)
        notice = try c.decodeIfPresent(String.self, forKey: .notice) ?? ""
        runnersFree = try c.decodeIfPresent(Int.self, forKey: .runnersFree) ?? 0
        runnersJailed = try c.decodeIfPresent(Int.self, forKey: .runnersJailed) ?? 0
        huntersCount = try c.decodeIfPresent(Int.self, forKey: .huntersCount) ?? 0
    }

    // MARK: - WatchConnectivity dictionary form

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
            "hearts": hearts,
            "maxHearts": maxHearts,
            "modeRaw": modeRaw,
            "blips": blips.map(\.dictionary),
            "isJailed": isJailed,
            "isOut": isOut,
            "eliminationReason": eliminationReason,
            "bailActive": bailActive,
            "bailRemainingSeconds": bailRemainingSeconds,
            "zoneOutside": zoneOutside,
            "zoneReason": zoneReason,
            "buffs": buffs.map(\.dictionary),
            "notice": notice,
            "runnersFree": runnersFree,
            "runnersJailed": runnersJailed,
            "huntersCount": huntersCount,
        ]
        if let nearestDistanceMeters { dict["nearestDistanceMeters"] = nearestDistanceMeters }
        if let nearestBearingDegrees { dict["nearestBearingDegrees"] = nearestBearingDegrees }
        if let headingDegrees { dict["headingDegrees"] = headingDegrees }
        if let matchEndsAt { dict["matchEndsAt"] = matchEndsAt.timeIntervalSince1970 }
        if let jailArrivalRemaining { dict["jailArrivalRemaining"] = jailArrivalRemaining }
        if let jailEscapeCountdown { dict["jailEscapeCountdown"] = jailEscapeCountdown }
        if let zoneRadiusMeters { dict["zoneRadiusMeters"] = zoneRadiusMeters }
        if let incomingCatch { dict["incomingCatch"] = incomingCatch.dictionary }
        if let pendingCatchTargetName { dict["pendingCatchTargetName"] = pendingCatchTargetName }
        if let denyConfirm { dict["denyConfirm"] = denyConfirm.dictionary }
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

        self.hearts = dictionary["hearts"] as? Int ?? 0
        self.maxHearts = dictionary["maxHearts"] as? Int ?? 0
        self.modeRaw = dictionary["modeRaw"] as? String ?? ""
        self.headingDegrees = dictionary["headingDegrees"] as? Double
        self.blips = (dictionary["blips"] as? [[String: Any]] ?? []).compactMap(WatchBlip.init(dictionary:))
        self.matchEndsAt = (dictionary["matchEndsAt"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
        self.isJailed = dictionary["isJailed"] as? Bool ?? false
        self.isOut = dictionary["isOut"] as? Bool ?? false
        self.eliminationReason = dictionary["eliminationReason"] as? String ?? ""
        self.jailArrivalRemaining = dictionary["jailArrivalRemaining"] as? Int
        self.jailEscapeCountdown = dictionary["jailEscapeCountdown"] as? Int
        self.bailActive = dictionary["bailActive"] as? Bool ?? false
        self.bailRemainingSeconds = dictionary["bailRemainingSeconds"] as? Int ?? 0
        self.zoneOutside = dictionary["zoneOutside"] as? Bool ?? false
        self.zoneReason = dictionary["zoneReason"] as? String ?? ""
        self.zoneRadiusMeters = dictionary["zoneRadiusMeters"] as? Int
        self.buffs = (dictionary["buffs"] as? [[String: Any]] ?? []).compactMap(WatchBuff.init(dictionary:))
        self.incomingCatch = (dictionary["incomingCatch"] as? [String: Any]).flatMap(WatchCatchRequest.init(dictionary:))
        self.pendingCatchTargetName = dictionary["pendingCatchTargetName"] as? String
        self.denyConfirm = (dictionary["denyConfirm"] as? [String: Any]).flatMap(WatchDenyConfirm.init(dictionary:))
        self.notice = dictionary["notice"] as? String ?? ""
        self.runnersFree = dictionary["runnersFree"] as? Int ?? 0
        self.runnersJailed = dictionary["runnersJailed"] as? Int ?? 0
        self.huntersCount = dictionary["huntersCount"] as? Int ?? 0
    }
}

/// An action the Watch sends back to the phone — the phone owns the actual
/// socket connection, so the watch never talks to the backend directly, it
/// just relays intent through WatchConnectivity.
public enum WatchActionType: String, Codable {
    case usePowerUp = "USE_POWERUP"
    /// Legacy arrest-code catch, sent by Watch 1.0.0. The phone still honours it; 1.0.1 uses
    /// `requestCatch` instead, like the iPhone app does.
    case attemptCatch = "ATTEMPT_CATCH"
    case requestCatch = "REQUEST_CATCH"
    case cancelCatchRequest = "CANCEL_CATCH_REQUEST"
    case acceptCatch = "ACCEPT_CATCH"
    case denyCatch = "DENY_CATCH"
    case acknowledgeDeny = "ACK_DENY"
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

/// Same-device handoff between the iPhone app and its home-screen widget extension
/// (`HuntingGameHomeWidget` in Widgets/HuntingGameWidgets/) — no WatchConnectivity relay
/// needed since both run on the same phone, just a shared App Group container, same
/// pattern as `WatchAppGroup` above but scoped to a different pair of targets.
public enum PhoneWidgetAppGroup {
    public static let identifier = "group.com.huntinggame.app.widget"
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
