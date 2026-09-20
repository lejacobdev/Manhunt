#if DEBUG
import Foundation

/// Fixed game states for the simulator, so every screen can be looked at (and screenshotted by
/// .github/workflows/watch-check.yml) without a phone, a server or a match in progress.
/// Compiled into Debug builds only — a release build contains none of this.
///
///   xcrun simctl launch <watch-sim> com.huntinggame.app.watchkitapp -WatchScenario runner_close
///   ... -WatchScenario runner_gear -WatchPage gear
enum WatchPreviewScenarios {
    /// Applies the launch scenario, if one was asked for, and returns the page to open on.
    static func applyLaunchArguments(to manager: WatchConnectivityManager) -> WatchPage? {
        let args = ProcessInfo.processInfo.arguments
        guard
            let flag = args.firstIndex(of: "-WatchScenario"), args.indices.contains(flag + 1),
            let scenario = snapshot(named: args[flag + 1])
        else { return nil }

        manager.applyPreview(scenario)

        if let pageFlag = args.firstIndex(of: "-WatchPage"), args.indices.contains(pageFlag + 1),
           let page = WatchPage(rawValue: args[pageFlag + 1]) {
            return page
        }
        return .radar
    }

    private static let matchEnds = Date().addingTimeInterval(23 * 60 + 41)

    /// A runner mid-match, hearts full, nobody near — the starting point most scenarios adjust.
    private static func runner(_ adjust: (inout WatchGameSnapshot) -> Void = { _ in }) -> WatchGameSnapshot {
        var s = WatchGameSnapshot(
            isActive: true, gameCode: "K7Q2", roleRaw: "RUNNER", arrestCode: "4821", isCaught: false,
            nearestDistanceMeters: 82, nearestBearingDegrees: 40, inventoryRaw: [], isRadarJammed: false,
            updatedAt: Date(),
            hearts: 3, maxHearts: 3, modeRaw: "STANDARD", headingDegrees: 10,
            blips: [WatchBlip(id: "h1", username: "mira", distanceMeters: 82, bearingDegrees: 40)],
            matchEndsAt: matchEnds,
            zoneRadiusMeters: 340, runnersFree: 4, runnersJailed: 1, huntersCount: 2
        )
        adjust(&s)
        return s
    }

    /// A hunter mid-match with three runners around.
    private static func hunter(_ adjust: (inout WatchGameSnapshot) -> Void = { _ in }) -> WatchGameSnapshot {
        var s = WatchGameSnapshot(
            isActive: true, gameCode: "K7Q2", roleRaw: "HUNTER", arrestCode: "1111", isCaught: false,
            nearestDistanceMeters: 12, nearestBearingDegrees: 305, inventoryRaw: [], isRadarJammed: false,
            updatedAt: Date(),
            hearts: 5, maxHearts: 5, modeRaw: "STANDARD", headingDegrees: 280,
            blips: [
                WatchBlip(id: "r1", username: "alex", distanceMeters: 12, bearingDegrees: 305),
                WatchBlip(id: "r2", username: "jonas", distanceMeters: 34, bearingDegrees: 95),
                WatchBlip(id: "r3", username: "lea", distanceMeters: 71, bearingDegrees: 190),
            ],
            matchEndsAt: matchEnds,
            zoneRadiusMeters: 340, runnersFree: 4, runnersJailed: 1, huntersCount: 2
        )
        adjust(&s)
        return s
    }

    static func snapshot(named name: String) -> WatchGameSnapshot? {
        switch name {
        case "idle":
            return .idle

        // --- Runner ---
        case "runner_safe":
            return runner()
        case "runner_close":
            return runner {
                $0.hearts = 2
                $0.blips = [
                    WatchBlip(id: "h1", username: "mira", distanceMeters: 9, bearingDegrees: 200),
                    WatchBlip(id: "h2", username: "tom", distanceMeters: 38, bearingDegrees: 95),
                ]
                $0.nearestDistanceMeters = 9
                $0.headingDegrees = 180
                $0.buffs = [WatchBuff(raw: "ADRENALINE", remainingSeconds: 41)]
            }
        case "runner_zone":
            return runner {
                $0.hearts = 1
                $0.zoneOutside = true
                $0.zoneReason = "ZONE"
                $0.blips = [WatchBlip(id: "h1", username: "mira", distanceMeters: 47, bearingDegrees: 150)]
            }
        case "runner_bail":
            return runner {
                $0.bailActive = true
                $0.bailRemainingSeconds = 6
            }
        case "runner_gear":
            return runner {
                $0.inventoryRaw = ["INVISIBILITY_10MIN", "EMP_JAMMER", "EMP_JAMMER", "SAFE_ZONE_FLARE", "GHOST_DECOY"]
                $0.buffs = [WatchBuff(raw: "ADRENALINE", remainingSeconds: 41)]
            }
        case "runner_empty_gear":
            return runner()
        case "catch_request":
            return runner {
                $0.hearts = 2
                $0.incomingCatch = WatchCatchRequest(requestId: "req-1", hunterUsername: "mira")
            }
        case "caught_walk":
            return runner {
                $0.isCaught = true
                $0.hearts = 2
                $0.jailArrivalRemaining = 132
            }
        case "jailed":
            return runner {
                $0.isJailed = true
                $0.hearts = 2
            }
        case "jailed_escape":
            return runner {
                $0.isJailed = true
                $0.hearts = 2
                $0.jailEscapeCountdown = 8
            }
        case "out":
            return runner {
                $0.isOut = true
                $0.hearts = 0
                $0.eliminationReason = "JAIL_NO_SHOW"
            }

        // --- Hunter ---
        case "hunter_radar", "hunter_targets":
            return hunter()
        case "hunter_close":
            return hunter {
                $0.blips = [
                    WatchBlip(id: "r1", username: "alex", distanceMeters: 6, bearingDegrees: 285),
                    WatchBlip(id: "r2", username: "jonas", distanceMeters: 34, bearingDegrees: 95),
                ]
                $0.nearestDistanceMeters = 6
            }
        case "hunter_gear":
            return hunter { $0.inventoryRaw = ["THERMAL_VISION", "EMP_JAMMER", "GHOST_DECOY"] }
        case "hunter_empty":
            return hunter {
                $0.blips = []
                $0.nearestDistanceMeters = nil
                $0.nearestBearingDegrees = nil
            }
        case "hunter_jammed":
            return hunter {
                $0.blips = []
                $0.nearestDistanceMeters = nil
                $0.isRadarJammed = true
            }
        case "waiting":
            return hunter { $0.pendingCatchTargetName = "alex" }
        case "deny_confirm":
            return hunter { $0.denyConfirm = WatchDenyConfirm(requestId: "req-2", runnerUsername: "alex") }

        // --- Others ---
        case "match_squad":
            return runner {
                $0.modeRaw = "SQUAD"
                $0.runnersFree = 3
                $0.runnersJailed = 2
                $0.huntersCount = 3
            }
        case "spectator":
            return runner {
                $0.roleRaw = "SPECTATOR"
                $0.hearts = 0
                $0.maxHearts = 0
            }
        default:
            return nil
        }
    }
}
#endif
