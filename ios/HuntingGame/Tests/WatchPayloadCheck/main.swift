import Foundation

// A standalone check of the phone <-> Watch contract in Shared/WatchSyncPayload.swift.
// Run by .github/workflows/watch-check.yml as:
//   swiftc Shared/WatchSyncPayload.swift Tests/WatchPayloadCheck/main.swift -o payloadcheck && ./payloadcheck
//
// It exists because the payload is the one part of the Watch app that can break silently: the
// phone and the Watch update on their own schedules, and WatchConnectivity throws away anything
// that isn't a plain property list. So this verifies, on every run, that
//   - a full snapshot survives the trip through the dictionary form WatchConnectivity carries,
//   - that dictionary really is a valid property list,
//   - a NEW Watch still understands snapshots from an OLD phone (missing keys -> defaults), and
//   - an OLD Watch still finds every key it requires in a snapshot from a NEW phone.

var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() { print("  ok    \(message)") } else { print("  FAIL  \(message)"); failures += 1 }
}

// A snapshot with every field populated, so nothing can be silently dropped in a round trip.
let full = WatchGameSnapshot(
    isActive: true,
    gameCode: "K7Q2",
    roleRaw: "RUNNER",
    arrestCode: "4821",
    isCaught: false,
    nearestDistanceMeters: 23,
    nearestBearingDegrees: 141.5,
    inventoryRaw: ["INVISIBILITY_10MIN", "EMP_JAMMER", "EMP_JAMMER"],
    isRadarJammed: true,
    visibleRunners: [WatchRunnerBlip(id: "r1", username: "alex")],
    updatedAt: Date(timeIntervalSince1970: 1_790_000_000),
    hearts: 2,
    maxHearts: 3,
    modeRaw: "INFECTION",
    headingDegrees: 271.25,
    blips: [
        WatchBlip(id: "h1", username: "mira", distanceMeters: 23, bearingDegrees: 141.5),
        WatchBlip(id: "h2", username: "jonas", distanceMeters: 61, bearingDegrees: 12),
    ],
    matchEndsAt: Date(timeIntervalSince1970: 1_790_001_800),
    isJailed: true,
    isOut: false,
    eliminationReason: "",
    jailArrivalRemaining: 95,
    jailEscapeCountdown: 8,
    bailActive: true,
    bailRemainingSeconds: 6,
    zoneOutside: true,
    zoneReason: "ZONE",
    zoneRadiusMeters: 340,
    buffs: [WatchBuff(raw: "ADRENALINE", remainingSeconds: 41)],
    incomingCatch: WatchCatchRequest(requestId: "req-1", hunterUsername: "mira"),
    pendingCatchTargetName: "alex",
    denyConfirm: WatchDenyConfirm(requestId: "req-2", runnerUsername: "alex"),
    notice: "Runner is too far away",
    runnersFree: 3,
    runnersJailed: 1,
    huntersCount: 2
)

print("Dictionary form (what WatchConnectivity carries)")
let dict = full.dictionary
check(WatchGameSnapshot(dictionary: dict) == full, "a full snapshot round-trips unchanged")
check((try? PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)) != nil,
      "the dictionary is a valid property list (WatchConnectivity rejects anything else)")

let idleDict = WatchGameSnapshot.idle.dictionary
check(WatchGameSnapshot(dictionary: idleDict) == WatchGameSnapshot.idle, "the idle snapshot round-trips")
check((try? PropertyListSerialization.data(fromPropertyList: idleDict, format: .binary, options: 0)) != nil,
      "the idle dictionary (optionals omitted) is a valid property list")

print("JSON form (the shared App Group the complication reads)")
if let data = try? JSONEncoder().encode(full), let back = try? JSONDecoder().decode(WatchGameSnapshot.self, from: data) {
    check(back == full, "a full snapshot round-trips through JSON")
} else {
    check(false, "a full snapshot round-trips through JSON")
}

print("New Watch, old phone (1.0.0 sent none of the new keys)")
let oldPhoneKeys: [String: Any] = [
    "isActive": true, "gameCode": "K7Q2", "roleRaw": "HUNTER", "arrestCode": "1111", "isCaught": false,
    "inventoryRaw": ["EMP_JAMMER"], "isRadarJammed": false,
    "visibleRunners": [["id": "r1", "username": "alex"]],
    "updatedAt": 1_790_000_000.0, "nearestDistanceMeters": 40, "nearestBearingDegrees": 90.0,
]
if let fromOld = WatchGameSnapshot(dictionary: oldPhoneKeys) {
    check(fromOld.hearts == 0 && fromOld.maxHearts == 0, "hearts default to 0 (the Watch hides the hearts row)")
    check(fromOld.blips.isEmpty && fromOld.buffs.isEmpty, "list fields default to empty")
    check(fromOld.incomingCatch == nil && fromOld.denyConfirm == nil && fromOld.pendingCatchTargetName == nil,
          "catch fields default to nil")
    check(!fromOld.isJailed && !fromOld.isOut && !fromOld.zoneOutside && !fromOld.bailActive, "status flags default to false")
    check(fromOld.nearestBlip?.distanceMeters == 40, "nearestBlip falls back to the 1.0.0 single reading")
    check(fromOld.visibleRunners.first?.username == "alex", "the 1.0.0 runner list is still read")
} else {
    check(false, "an old phone's dictionary is still understood")
}

print("Old Watch, new phone (1.0.0 requires exactly these keys)")
let required: [(String, (Any) -> Bool)] = [
    ("isActive", { $0 is Bool }), ("gameCode", { $0 is String }), ("roleRaw", { $0 is String }),
    ("arrestCode", { $0 is String }), ("isCaught", { $0 is Bool }), ("inventoryRaw", { $0 is [String] }),
    ("isRadarJammed", { $0 is Bool }), ("updatedAt", { $0 is TimeInterval }),
]
for (key, isRightType) in required {
    check(dict[key].map(isRightType) ?? false, "key '\(key)' is present with the type Watch 1.0.0 expects")
}
check((dict["visibleRunners"] as? [[String: Any]])?.first?["username"] as? String == "alex",
      "the 1.0.0 runner list is still filled in")

print("Old snapshot already stored in the App Group (JSON written by 1.0.0)")
let oldJSON = """
{"isActive":true,"gameCode":"AB12","roleRaw":"RUNNER","arrestCode":"9999","isCaught":false,
 "nearestDistanceMeters":30,"nearestBearingDegrees":10,"inventoryRaw":[],"isRadarJammed":false,
 "visibleRunners":[],"updatedAt":800000000}
"""
if let decoded = try? JSONDecoder().decode(WatchGameSnapshot.self, from: Data(oldJSON.utf8)) {
    check(decoded.gameCode == "AB12" && decoded.hearts == 0, "a 1.0.0 JSON blob still decodes, with defaults for new fields")
} else {
    check(false, "a 1.0.0 JSON blob still decodes")
}

print("Urgent changes bypass the phone's throttle")
var later = full
later.updatedAt = later.updatedAt.addingTimeInterval(1.5)
later.nearestDistanceMeters = 20
check(!later.isUrgentChange(from: full), "a plain distance/time tick is NOT urgent")
var hit = full; hit.hearts = 1
check(hit.isUrgentChange(from: full), "losing a heart is urgent")
var request = full; request.incomingCatch = nil
check(request.isUrgentChange(from: full), "a catch request appearing or clearing is urgent")
var zone = full; zone.zoneOutside = false
check(zone.isUrgentChange(from: full), "leaving or entering the zone is urgent")

print("Actions (Watch -> phone)")
let actions: [WatchActionMessage] = [
    .init(type: .usePowerUp, powerUpTypeRaw: "EMP_JAMMER"),
    .init(type: .attemptCatch, targetRunnerId: "r1", arrestCode: "1234"),
    .init(type: .requestCatch, targetRunnerId: "r1"),
    .init(type: .cancelCatchRequest), .init(type: .acceptCatch), .init(type: .denyCatch), .init(type: .acknowledgeDeny),
]
for action in actions {
    let back = WatchActionMessage(dictionary: action.dictionary)
    check(back?.type == action.type && back?.targetRunnerId == action.targetRunnerId
            && back?.powerUpTypeRaw == action.powerUpTypeRaw && back?.arrestCode == action.arrestCode,
          "action \(action.type.rawValue) round-trips")
    check((try? PropertyListSerialization.data(fromPropertyList: action.dictionary, format: .binary, options: 0)) != nil,
          "action \(action.type.rawValue) is a valid property list")
}
check(WatchActionMessage(dictionary: ["type": "SOMETHING_FROM_THE_FUTURE"]) == nil,
      "an action type this build doesn't know is ignored, not crashed on")

print(failures == 0 ? "\nALL PAYLOAD CHECKS PASSED" : "\n\(failures) PAYLOAD CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
