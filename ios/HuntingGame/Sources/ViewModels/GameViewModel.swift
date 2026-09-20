import Foundation
import CoreLocation
import Combine
import UIKit
import WidgetKit

@MainActor
final class GameViewModel: ObservableObject {
    let locationManager = LocationManager()
    let socket = SocketService.shared

    @Published var role: PlayerRole
    @Published var mode: GameMode
    @Published var arrestCode: String
    @Published var isCaught: Bool = false
    @Published var isInvisible: Bool = false
    @Published var invisibilityRemainingSec: Int = 0
    /// Power-ups this player has active right now, with the second they run out — drives
    /// the HUD badges for buffs whose effect is otherwise invisible to their own caster
    /// (thermal vision, adrenaline, a dropped flare).
    @Published var activeBuffRemainingSec: [PowerUpType: Int] = [:]
    @Published var catchTargetId: String?
    @Published var catchCodeEntry: String = ""
    @Published var showCatchFailure: String?
    /// Republished from `locationManager` so views that only observe this
    /// StateObject (not the nested LocationManager) still react live — a
    /// view can't get change notifications from an object it doesn't hold
    /// as its own @StateObject/@ObservedObject.
    @Published var currentLocation: CLLocation?
    @Published var currentHeadingDegrees: Double = 0
    /// Republished from `locationManager` for the same reason as `currentLocation` above.
    /// GameView watches this to react when the *system* permission prompt comes back denied
    /// — the in-app consent screen no longer has a decline button of its own (App Store
    /// guideline 5.1.1(iv)), so this is how a real "no" at the OS level still lets the
    /// player leave a match they can't play without location.
    @Published var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var powerUpSpawns: [PowerUpSpawn] = []

    // MARK: - Hearts / jail / gamble state

    @Published var hearts: Int
    @Published var isJailed: Bool = false
    @Published var isOut: Bool = false
    @Published var eliminationReason: String?
    /// The runner's own incoming "did you get caught?" popup.
    @Published var incomingCatchRequest: CatchRequest?
    /// Hunter-side "was it an accident?" prompt, after a runner taps No.
    @Published var pendingDenyConfirm: DenyConfirmRequest?
    /// The hunter's own "waiting for a response" state, keyed by the runner they asked.
    @Published var pendingCatchRequestRunnerId: String?
    @Published var isCoinFlipping: Bool = false
    @Published var gambleChoicePending: GambleChoice?
    @Published var lastGambleOutcome: GambleResult?
    /// True between rounds of a duel that hasn't produced a loser yet — the runner has to
    /// call the next toss, and neither side can walk away until someone's hearts run out.
    @Published var awaitingGambleCall: Bool = false
    @Published var boundaryOutside: Bool = false
    @Published var boundaryWarning: Bool = false
    /// Which shape the player is outside — "ZONE" or "BOUNDARY" — so the warning names it.
    @Published var boundaryReason: String = "BOUNDARY"
    @Published var jailOutside: Bool = false
    @Published var jailCountdownRemaining: Int?
    private var jailCountdownTimer: Timer?
    /// Seconds left for a freshly-sentenced runner to physically reach the jail. Non-nil
    /// only between being caught and arriving; running it out is a disqualification.
    @Published var jailArrivalRemaining: Int?
    private var jailArrivalTimer: Timer?
    /// This runner's progress toward springing the jail while standing inside it.
    @Published var bailActive: Bool = false
    @Published var bailProgress: Double = 0
    @Published var bailRemainingSeconds: Int = 0
    /// The most recent jailbreak, cleared a few seconds after it lands.
    @Published var lastBailout: BailoutEvent?
    /// Bumped every time this player actually loses a heart, whatever took it — zone or
    /// boundary damage, a catch, a jailbreak. Drives the full-screen damage flash. A
    /// counter rather than a flag so two hits in quick succession each register instead of
    /// collapsing into one.
    @Published var heartLossPulse: Int = 0
    @Published var lastHeartLossCause: String?

    private var cancellables = Set<AnyCancellable>()
    private var invisibilityTimer: Timer?
    private var watchSyncTimer: Timer?
    private let watchConnectivity = PhoneConnectivityManager.shared
    private var watchChangeSubscription: AnyCancellable?
    private var lastSentAt: Date = .distantPast
    private let minSendInterval: TimeInterval = 2.0
    private var lastWidgetReloadAt: Date = .distantPast
    private var lastWidgetWriteAt: Date = .distantPast
    /// WidgetKit metes out a small daily budget of *actual* re-renders per widget kind —
    /// on the order of a few dozen, shared across the whole day, regardless of how many
    /// times reloadTimelines is called. Calling it on every 1.5s watchSyncTimer tick (as
    /// this used to) burns through that budget within the first minute of any single
    /// match, silently dropping every reload request for the rest of the day — which is
    /// exactly what "the widget shows No active game the whole match" looks like from the
    /// outside. The App Group write itself is cheap and happens on every tick regardless;
    /// only this explicit reload trigger needs throttling.
    private let minWidgetReloadInterval: TimeInterval = 60

    let gamePlayerId: String
    let sessionId: String
    let mySquad: String?
    let sessionSettings: GameSettings
    let roomCode: String
    /// Whether this player hosted the game — grants host-only admin actions
    /// (end game, override a catch) regardless of their chosen HUNTER/RUNNER/SPECTATOR role.
    let isHost: Bool

    init(gamePlayer: GamePlayer, session: GameSession) {
        self.role = gamePlayer.role
        self.mode = session.mode
        self.arrestCode = gamePlayer.arrestCode
        self.isCaught = gamePlayer.isCaught
        self.hearts = gamePlayer.hearts
        self.gamePlayerId = gamePlayer.id
        self.sessionId = gamePlayer.sessionId
        self.mySquad = gamePlayer.squad
        self.sessionSettings = session.settings
        self.roomCode = session.code
        self.isHost = session.hostId == gamePlayer.userId

        bindLocation()
        bindSocket()
    }

    func start() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        HapticsEngine.shared.prepareEngine()
        // Deliberately NOT starting location here: nothing is shared until the player
        // checks in for this match (see startLocationSharing, called from GameView's
        // consent screen). Everything else about the match can spin up meanwhile.
        socket.connect(roomCode: roomCode, gamePlayerId: gamePlayerId)
        LiveActivityManager.shared.start(gameCode: roomCode, role: role)

        watchConnectivity.onAction = { [weak self] action in
            self?.handleWatchAction(action)
        }
        watchSyncTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pushWatchSnapshot() }
        }
        // The timer alone left a catch request waiting up to 1.5s before the wrist buzzed. Also
        // push whenever this model or the socket changes; PhoneConnectivityManager throttles
        // ordinary updates and lets urgent ones (catch request, lost heart, jail) straight through.
        watchChangeSubscription = objectWillChange
            .merge(with: socket.objectWillChange)
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.pushWatchSnapshot() }
        pushWatchSnapshot()

        if role == .hunter || role == .runner {
            Task { [weak self] in await self?.loadPowerUpSpawns() }
        }
    }

    /// Begins sharing position with the rest of the match. Only ever called from the
    /// per-match check-in screen, never automatically — that separation is the whole point.
    func startLocationSharing() {
        locationManager.requestAuthorizationAndStart()
    }

    private func loadPowerUpSpawns() async {
        do {
            powerUpSpawns = try await APIClient.shared.fetchPowerUpSpawns(sessionId: sessionId)
        } catch {
            // Non-fatal: the map just won't show spawn pins this session:
            // the player can still receive power-ups via other means (drops, etc).
        }
    }

    func stop() {
        locationManager.stop()
        socket.disconnect()
        invisibilityTimer?.invalidate()
        watchSyncTimer?.invalidate()
        watchChangeSubscription = nil
        jailCountdownTimer?.invalidate()
        jailArrivalTimer?.invalidate()
        watchConnectivity.onAction = nil
        watchConnectivity.sendIdle()
        PhoneWidgetAppGroup.writeSnapshot(.idle)
        WidgetCenter.shared.reloadTimelines(ofKind: "HuntingGameHomeWidget")
        LiveActivityManager.shared.end()
    }

    // MARK: - Watch companion

    private func pushWatchSnapshot() {
        let snapshot = makeWatchSnapshot()
        watchConnectivity.send(snapshot)

        // Same snapshot, relayed to the iPhone home-screen widget via their shared App
        // Group instead of WatchConnectivity — that's phone-to-watch only, but the widget
        // extension runs on this same device, so no relay is needed at all. The write is just
        // local storage, kept to once a second: this now runs on every (debounced) state change
        // as well as the 1.5s timer, and the widget gains nothing from being rewritten several
        // times a second. The explicit reload request below is throttled much harder still.
        let now = Date()
        if now.timeIntervalSince(lastWidgetWriteAt) >= 1.0 {
            lastWidgetWriteAt = now
            PhoneWidgetAppGroup.writeSnapshot(snapshot)
        }

        guard now.timeIntervalSince(lastWidgetReloadAt) >= minWidgetReloadInterval else { return }
        lastWidgetReloadAt = now
        WidgetCenter.shared.reloadTimelines(ofKind: "HuntingGameHomeWidget")
    }

    /// Which way the player is facing, for the Watch's radar. Course over ground while moving —
    /// the compass is unreliable with the phone in a pocket, GPS course isn't — and the compass
    /// only once they've stopped. Nil when neither is known.
    private var watchHeadingDegrees: Double? {
        if let location = currentLocation, location.speed > 1.2, location.course >= 0 {
            return location.course
        }
        if let heading = locationManager.currentHeading {
            return heading.trueHeading >= 0 ? heading.trueHeading : heading.magneticHeading
        }
        return nil
    }

    /// The nearest players on the other side, for the Watch radar — hunters for a runner,
    /// runners for a hunter — nearest first, capped so the payload stays small.
    private func watchBlips() -> [WatchBlip] {
        switch role {
        case .runner:
            return (socket.compass?.hunters ?? []).prefix(6).map {
                WatchBlip(id: $0.hunterId, username: $0.username, distanceMeters: $0.distanceMeters, bearingDegrees: $0.bearingDegrees)
            }
        case .hunter:
            return visibleRunnerBearings.prefix(6).map {
                WatchBlip(id: $0.runnerId, username: $0.username, distanceMeters: $0.distanceMeters, bearingDegrees: $0.bearingDegrees)
            }
        case .spectator:
            return []
        }
    }

    private func makeWatchSnapshot() -> WatchGameSnapshot {
        let blips = watchBlips()
        let players = socket.players
        let matchEndsAt = socket.matchStartedAt.map {
            $0.addingTimeInterval(TimeInterval(sessionSettings.durationMinutes * 60))
        }
        let pendingTargetName = pendingCatchRequestRunnerId.flatMap { id in
            players.first(where: { $0.id == id })?.username
        }

        return WatchGameSnapshot(
            // Stays true for the whole match — including once caught or out. It used to be
            // `!isCaught`, which made the Watch fall back to its "not in a game" screen the
            // moment the wearer was caught, hiding its own caught state.
            isActive: true,
            gameCode: roomCode,
            roleRaw: role.rawValue,
            arrestCode: arrestCode,
            isCaught: isCaught,
            nearestDistanceMeters: role == .hunter ? blips.first?.distanceMeters : nearestHunterDistance,
            nearestBearingDegrees: role == .hunter ? blips.first?.bearingDegrees : nearestHunterBearing,
            inventoryRaw: inventory.map(\.rawValue),
            isRadarJammed: isRadarJammed,
            // Kept for Watch 1.0.0, which reads only this.
            visibleRunners: visibleRunners.map { WatchRunnerBlip(id: $0.id, username: $0.username) },
            updatedAt: Date(),
            hearts: hearts,
            maxHearts: role == .hunter ? 5 : 3,
            modeRaw: mode.rawValue,
            headingDegrees: watchHeadingDegrees,
            blips: blips,
            matchEndsAt: matchEndsAt,
            isJailed: isJailed,
            isOut: isOut,
            eliminationReason: eliminationReason ?? "",
            jailArrivalRemaining: jailArrivalRemaining,
            jailEscapeCountdown: jailOutside ? (jailCountdownRemaining ?? 10) : nil,
            bailActive: bailActive,
            bailRemainingSeconds: bailRemainingSeconds,
            // Same guard the iPhone banner uses against a stale warning once caught/jailed/out.
            zoneOutside: boundaryOutside && !isCaught && !isJailed && !isOut,
            zoneReason: boundaryOutside ? boundaryReason : "",
            zoneRadiusMeters: zone.map { Int($0.radiusMeters) },
            buffs: activeBuffRemainingSec
                .map { WatchBuff(raw: $0.key.rawValue, remainingSeconds: $0.value) }
                .sorted { $0.raw < $1.raw },
            incomingCatch: incomingCatchRequest.map {
                WatchCatchRequest(requestId: $0.requestId, hunterUsername: $0.hunterUsername)
            },
            pendingCatchTargetName: pendingTargetName,
            denyConfirm: pendingDenyConfirm.map {
                WatchDenyConfirm(requestId: $0.requestId, runnerUsername: $0.runnerUsername)
            },
            notice: showCatchFailure ?? "",
            runnersFree: players.filter { $0.role == .runner && !$0.isCaught && !$0.isJailed && !$0.isOut }.count,
            runnersJailed: players.filter { $0.role == .runner && $0.isJailed && !$0.isOut }.count,
            huntersCount: players.filter { $0.role == .hunter && !$0.isOut }.count
        )
    }

    private func handleWatchAction(_ action: WatchActionMessage) {
        switch action.type {
        case .usePowerUp:
            guard let raw = action.powerUpTypeRaw, let type = PowerUpType(rawValue: raw) else { return }
            usePowerUp(type)
        case .attemptCatch:
            // Watch 1.0.0's arrest-code catch. Kept so an un-updated Watch still works.
            guard let target = action.targetRunnerId, let code = action.arrestCode else { return }
            socket.attemptCatch(runnerId: target, arrestCode: code)
        case .requestCatch:
            guard role == .hunter, let target = action.targetRunnerId else { return }
            beginCatch(on: target)
        case .cancelCatchRequest:
            cancelPendingCatchRequest()
        case .acceptCatch:
            acceptCatch()
        case .denyCatch:
            denyCatch()
        case .acknowledgeDeny:
            confirmDenyWasAccidental()
        }
    }

    private func bindLocation() {
        locationManager.$authorizationStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.locationAuthorizationStatus = status
            }
            .store(in: &cancellables)

        locationManager.$currentHeading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] heading in
                self?.currentHeadingDegrees = heading?.trueHeading ?? 0
            }
            .store(in: &cancellables)

        locationManager.onLocationUpdate = { [weak self] location in
            guard let self else { return }
            // Update the self-pin on every fix, independent of the socket send throttle below.
            self.currentLocation = location

            let now = Date()
            guard now.timeIntervalSince(self.lastSentAt) >= self.minSendInterval else { return }
            self.lastSentAt = now
            self.socket.sendLocationUpdate(
                lat: location.coordinate.latitude,
                lng: location.coordinate.longitude,
                speed: max(0, location.speed),
                accuracy: location.horizontalAccuracy,
                battery: max(0, Int(UIDevice.current.batteryLevel * 100)),
                isMovingOnFoot: self.locationManager.isMovingOnFoot
            )
        }
    }

    private func bindSocket() {
        socket.playerCaughtSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                if event.runnerId == self.gamePlayerId {
                    self.isCaught = true
                    HapticsEngine.shared.catchFailed()
                    LiveActivityManager.shared.markCaught()
                    self.pushWatchSnapshot()
                } else if let hunterId = event.hunterId, hunterId == self.gamePlayerId {
                    HapticsEngine.shared.catchSucceeded()
                    // The request this hunter had out has been answered — nothing is pending
                    // any more. Nothing on the iPhone showed this state, so it never mattered
                    // there; the Watch does show a "waiting for…" screen and would otherwise
                    // sit on it after a successful catch.
                    self.pendingCatchRequestRunnerId = nil
                }
            }
            .store(in: &cancellables)

        socket.playerRevivedSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self, event.playerId == self.gamePlayerId else { return }
                self.isCaught = false
                HapticsEngine.shared.powerUpActivated()
                self.pushWatchSnapshot()
            }
            .store(in: &cancellables)

        socket.$compass
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { update in
                LiveActivityManager.shared.update(distanceMeters: update.distanceMeters, bearingDegrees: update.bearingDegrees)
            }
            .store(in: &cancellables)

        socket.playerInfectedSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                if event.runnerId == self.gamePlayerId {
                    self.role = .hunter
                    self.isCaught = false
                    self.pushWatchSnapshot()
                }
            }
            .store(in: &cancellables)

        socket.powerUpCollectedSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] spawnId in
                self?.powerUpSpawns.removeAll { $0.id == spawnId }
            }
            .store(in: &cancellables)

        socket.$lastCatchFailure
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reason in
                self?.showCatchFailure = reason
                // A failed attempt (out of range, runner already caught…) ends the request too.
                self?.pendingCatchRequestRunnerId = nil
                HapticsEngine.shared.catchFailed()
            }
            .store(in: &cancellables)

        socket.$incomingCatchRequest
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request in
                self?.incomingCatchRequest = request
                if request != nil { HapticsEngine.shared.lightTap() }
            }
            .store(in: &cancellables)

        socket.$pendingDenyConfirm
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request in
                self?.pendingDenyConfirm = request
            }
            .store(in: &cancellables)

        socket.catchRequestCancelledSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Reaches both a runner (their incoming popup should close) and a hunter
                // (their own "waiting for response" state should clear) — harmless no-op
                // for whichever side this particular event doesn't apply to.
                self?.incomingCatchRequest = nil
                self?.pendingCatchRequestRunnerId = nil
            }
            .store(in: &cancellables)

        socket.catchRequestExpiredSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.pendingCatchRequestRunnerId = nil
            }
            .store(in: &cancellables)

        socket.gambleResultSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] result in
                guard let self else { return }
                self.lastGambleOutcome = result
                self.isCoinFlipping = false
                self.gambleChoicePending = nil
                if result.hunterId == self.gamePlayerId { self.hearts = result.hunterHeartsRemaining }
                if result.runnerId == self.gamePlayerId { self.hearts = result.runnerHeartsRemaining }
                // A duel only stops when someone is out of hearts, so between rounds the
                // runner is put straight back on the hook for the next call.
                self.awaitingGambleCall = result.continues && result.runnerId == self.gamePlayerId
                HapticsEngine.shared.lightTap()
            }
            .store(in: &cancellables)

        socket.gambleCancelledSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.awaitingGambleCall = false
                self.isCoinFlipping = false
                self.lastGambleOutcome = nil
                self.gambleChoicePending = nil
            }
            .store(in: &cancellables)

        socket.heartsUpdateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self, event.playerId == self.gamePlayerId else { return }
                // Every cause gets the same treatment, not just boundary damage: losing a
                // heart to a catch or to someone else's jailbreak is exactly as worth
                // noticing, and the old cause check meant most of them passed silently.
                let lostOne = event.hearts < self.hearts
                self.hearts = event.hearts
                guard lostOne else { return }
                self.lastHeartLossCause = event.cause
                self.heartLossPulse += 1
                HapticsEngine.shared.catchFailed()
            }
            .store(in: &cancellables)

        socket.playerJailedSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self, event.runnerId == self.gamePlayerId else { return }
                self.isCaught = true
                self.isJailed = true
                // Being sentenced isn't the same as being locked up — they still have to
                // walk there, against this clock.
                if let deadlineMs = event.arrivalDeadlineMs {
                    self.startJailArrivalCountdown(milliseconds: deadlineMs)
                }
                HapticsEngine.shared.catchFailed()
                self.pushWatchSnapshot()
            }
            .store(in: &cancellables)

        socket.jailArrivedSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] runnerId in
                guard let self, runnerId == self.gamePlayerId else { return }
                self.jailArrivalTimer?.invalidate()
                self.jailArrivalRemaining = nil
            }
            .store(in: &cancellables)

        socket.bailProgressSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                self.bailActive = event.active
                guard event.active, event.requiredMs > 0 else {
                    self.bailProgress = 0
                    self.bailRemainingSeconds = 0
                    return
                }
                self.bailProgress = min(1, Double(event.elapsedMs) / Double(event.requiredMs))
                self.bailRemainingSeconds = max(0, (event.requiredMs - event.elapsedMs + 999) / 1000)
            }
            .store(in: &cancellables)

        socket.bailoutSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                self.bailActive = false
                self.bailProgress = 0
                // Whoever pulled it off, if this player was inside they're out now.
                if event.freedPlayerIds.contains(self.gamePlayerId) {
                    self.isCaught = false
                    self.isJailed = false
                    self.jailOutside = false
                    self.jailCountdownTimer?.invalidate()
                    self.jailCountdownRemaining = nil
                    self.jailArrivalTimer?.invalidate()
                    self.jailArrivalRemaining = nil
                    self.pushWatchSnapshot()
                }
                self.lastBailout = BailoutEvent(
                    bailerId: event.bailerId,
                    bailerUsername: event.bailerUsername,
                    freedCount: event.freedPlayerIds.count
                )
                HapticsEngine.shared.powerUpActivated()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, self.lastBailout?.bailerId == event.bailerId else { return }
                    self.lastBailout = nil
                }
            }
            .store(in: &cancellables)

        socket.playerEliminatedSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self, event.playerId == self.gamePlayerId else { return }
                self.isOut = true
                self.eliminationReason = event.reason
                self.jailCountdownTimer?.invalidate()
                self.jailCountdownRemaining = nil
                HapticsEngine.shared.catchFailed()
                LiveActivityManager.shared.end()
                self.pushWatchSnapshot()
            }
            .store(in: &cancellables)

        socket.boundaryStatusSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.boundaryOutside = event.outside
                self?.boundaryWarning = event.warning
                self?.boundaryReason = event.reason
            }
            .store(in: &cancellables)

        socket.jailStatusSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                self.jailOutside = event.outside
                self.jailCountdownTimer?.invalidate()
                if event.outside, let deadlineMs = event.deadlineMs {
                    var remaining = deadlineMs / 1000
                    self.jailCountdownRemaining = remaining
                    self.jailCountdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                        Task { @MainActor in
                            remaining -= 1
                            if remaining <= 0 {
                                timer.invalidate()
                                self?.jailCountdownRemaining = nil
                            } else {
                                self?.jailCountdownRemaining = remaining
                            }
                        }
                    }
                } else {
                    self.jailCountdownRemaining = nil
                }
            }
            .store(in: &cancellables)
    }

    /// Ticks the "get to the jail" countdown locally from the single deadline the server
    /// sends at sentencing, rather than having it re-broadcast every second.
    private func startJailArrivalCountdown(milliseconds: Int) {
        jailArrivalTimer?.invalidate()
        var remaining = max(0, milliseconds / 1000)
        jailArrivalRemaining = remaining
        jailArrivalTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            Task { @MainActor in
                remaining -= 1
                if remaining <= 0 {
                    timer.invalidate()
                    self?.jailArrivalRemaining = nil
                } else {
                    self?.jailArrivalRemaining = remaining
                }
            }
        }
    }

    // MARK: - Power-ups

    func usePowerUp(_ type: PowerUpType) {
        socket.usePowerUp(type)
        HapticsEngine.shared.powerUpActivated()

        // Every buff gets a live countdown badge, not just invisibility — thermal vision,
        // adrenaline and a dropped flare all used to activate with no on-screen sign that
        // anything had happened beyond the inventory slot emptying.
        activeBuffRemainingSec[type] = type.durationSeconds
        if type == .invisibility {
            isInvisible = true
            invisibilityRemainingSec = type.durationSeconds
        }
        startBuffTickerIfNeeded()
    }

    /// One shared 1s ticker driving every active buff countdown, started lazily and stopped
    /// as soon as the last buff expires.
    private func startBuffTickerIfNeeded() {
        guard invisibilityTimer == nil else { return }
        invisibilityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                for (type, remaining) in self.activeBuffRemainingSec {
                    let next = remaining - 1
                    if next <= 0 {
                        self.activeBuffRemainingSec.removeValue(forKey: type)
                        if type == .invisibility { self.isInvisible = false }
                    } else {
                        self.activeBuffRemainingSec[type] = next
                    }
                }
                self.invisibilityRemainingSec = self.activeBuffRemainingSec[.invisibility] ?? 0
                if self.activeBuffRemainingSec.isEmpty {
                    timer.invalidate()
                    self.invisibilityTimer = nil
                }
            }
        }
    }

    func collectPowerUp(spawnId: String) {
        HapticsEngine.shared.powerUpCollected()
        socket.collectPowerUp(spawnId: spawnId)
    }

    // MARK: - Catch flow

    /// Every mode — STANDARD, SQUAD and INFECTION alike — now uses the real-time request the
    /// runner answers on their own device. The old arrest-code entry it replaced is still
    /// wired up server-side (`attempt_catch`) because the Watch app has no way to show the
    /// request popup and still catches by code.
    func beginCatch(on runnerId: String) {
        HapticsEngine.shared.lightTap()
        pendingCatchRequestRunnerId = runnerId
        socket.requestCatch(runnerId: runnerId)
    }

    func confirmCatch() {
        guard let target = catchTargetId else { return }
        socket.attemptCatch(runnerId: target, arrestCode: catchCodeEntry)
        catchTargetId = nil
    }

    func cancelCatch() {
        catchTargetId = nil
        catchCodeEntry = ""
    }

    func cancelPendingCatchRequest() {
        guard let runnerId = pendingCatchRequestRunnerId else { return }
        socket.cancelCatchRequest(runnerId: runnerId)
        pendingCatchRequestRunnerId = nil
    }

    func acceptCatch() {
        guard let request = incomingCatchRequest else { return }
        HapticsEngine.shared.catchFailed()
        socket.respondToCatch(hunterId: request.hunterId, decision: "accept")
        incomingCatchRequest = nil
    }

    // GAMBLING — disabled for now, kept here in full so it can be switched back on without
    // rebuilding it. The published state above, the socket bindings, and the server-side
    // duel are all still in place; only these entry points and their UI are commented out.
    //
    // /// Opens a gamble duel: from here the coin keeps being tossed round after round until
    // /// either the runner or the hunter is out of hearts.
    // func gambleCatch(choice: GambleChoice) {
    //     guard let request = incomingCatchRequest else { return }
    //     HapticsEngine.shared.lightTap()
    //     gambleChoicePending = choice
    //     isCoinFlipping = true
    //     awaitingGambleCall = false
    //     socket.respondToCatch(hunterId: request.hunterId, decision: "gamble", gambleChoice: choice.rawValue)
    //     incomingCatchRequest = nil
    // }
    //
    // /// The runner's call for the next round of a duel already in progress.
    // func callGamble(choice: GambleChoice) {
    //     guard awaitingGambleCall else { return }
    //     HapticsEngine.shared.lightTap()
    //     gambleChoicePending = choice
    //     isCoinFlipping = true
    //     awaitingGambleCall = false
    //     lastGambleOutcome = nil
    //     socket.callGamble(choice: choice.rawValue)
    // }

    func denyCatch() {
        guard let request = incomingCatchRequest else { return }
        HapticsEngine.shared.lightTap()
        socket.respondToCatch(hunterId: request.hunterId, decision: "deny")
        incomingCatchRequest = nil
    }

    func confirmDenyWasAccidental() {
        guard let denyConfirm = pendingDenyConfirm else { return }
        socket.acknowledgeDenyWasAccidental(requestId: denyConfirm.requestId)
        pendingDenyConfirm = nil
        pendingCatchRequestRunnerId = nil
    }

    // GAMBLING — disabled, see gambleCatch/callGamble above.
    //
    // /// Only closes the coin view once the duel has actually produced a loser — mid-duel the
    // /// runner has to keep calling, so there's deliberately no way out of it here.
    // func dismissGambleResult() {
    //     guard !awaitingGambleCall else { return }
    //     lastGambleOutcome = nil
    //     isCoinFlipping = false
    // }

    // MARK: - Squad mode

    /// A caught squadmate this player is close enough (and same-squad) to attempt reviving.
    func revivableSquadmate() -> PlayerState? {
        guard mode == .squad, let mySquad, let me = currentLocation else { return nil }
        return allPlayers.first { candidate in
            guard candidate.id != gamePlayerId, candidate.isCaught, candidate.squad == mySquad else { return false }
            let distance = me.distance(from: CLLocation(latitude: candidate.lat, longitude: candidate.lng))
            return distance <= 15
        }
    }

    func revive(_ playerId: String) {
        HapticsEngine.shared.lightTap()
        socket.reviveTeammate(targetId: playerId)
    }

    // MARK: - Host actions

    func hostOverride(playerId: String, isCaught: Bool) {
        HapticsEngine.shared.lightTap()
        socket.hostOverride(targetId: playerId, isCaught: isCaught)
    }

    func hostEndGame() {
        HapticsEngine.shared.catchFailed()
        socket.hostEndGame()
    }

    // MARK: - Derived state

    var nearestHunterDistance: Int? { socket.compass?.distanceMeters }
    var nearestHunterBearing: Double? { socket.compass?.bearingDegrees }
    var visibleHunterBearings: [HunterBearing] { socket.compass?.hunters ?? [] }
    var zone: ZoneUpdate? { socket.zone }
    /// Flares that haven't burned out yet — an expired one stops protecting anyone
    /// server-side, so it shouldn't keep drawing a bubble on the map either.
    var activeSafeZones: [ActiveSafeZone] {
        let now = Date()
        return socket.safeZones.values.filter { $0.expiresAt > now }
    }
    var visibleRunners: [PlayerState] { socket.radar?.runners ?? [] }
    var visibleRunnerBearings: [RunnerBearing] { socket.radar?.runnerBearings ?? [] }
    var isRadarJammed: Bool { socket.radar?.jammed ?? false }
    var allPlayers: [PlayerState] { socket.players }
    var inventory: [PowerUpType] { socket.inventory }
}
