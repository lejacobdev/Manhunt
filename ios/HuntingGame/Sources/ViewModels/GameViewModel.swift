import Foundation
import CoreLocation
import Combine
import UIKit

@MainActor
final class GameViewModel: ObservableObject {
    let locationManager = LocationManager()
    let socket = SocketService.shared

    @Published var role: PlayerRole
    @Published var mode: GameMode
    @Published var arrestCode: String
    @Published var isCaught: Bool = false
    @Published var isExtracted: Bool = false
    @Published var isInvisible: Bool = false
    @Published var invisibilityRemainingSec: Int = 0
    @Published var activeSafeZone: (lat: Double, lng: Double, radius: Double)?
    @Published var catchTargetId: String?
    @Published var catchCodeEntry: String = ""
    @Published var showCatchFailure: String?
    /// Republished from `locationManager` so views that only observe this
    /// StateObject (not the nested LocationManager) still react live — a
    /// view can't get change notifications from an object it doesn't hold
    /// as its own @StateObject/@ObservedObject.
    @Published var currentLocation: CLLocation?
    @Published var currentHeadingDegrees: Double = 0
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
    @Published var boundaryOutside: Bool = false
    @Published var boundaryWarning: Bool = false
    @Published var jailOutside: Bool = false
    @Published var jailCountdownRemaining: Int?
    private var jailCountdownTimer: Timer?

    private var cancellables = Set<AnyCancellable>()
    private var invisibilityTimer: Timer?
    private var watchSyncTimer: Timer?
    private let watchConnectivity = PhoneConnectivityManager.shared
    private var lastSentAt: Date = .distantPast
    private let minSendInterval: TimeInterval = 2.0

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
        locationManager.requestAuthorizationAndStart()
        socket.connect(roomCode: roomCode, gamePlayerId: gamePlayerId)
        LiveActivityManager.shared.start(gameCode: roomCode, role: role)

        watchConnectivity.onAction = { [weak self] action in
            self?.handleWatchAction(action)
        }
        watchSyncTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pushWatchSnapshot() }
        }
        pushWatchSnapshot()

        if role == .hunter || role == .runner {
            Task { [weak self] in await self?.loadPowerUpSpawns() }
        }
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
        jailCountdownTimer?.invalidate()
        watchConnectivity.onAction = nil
        watchConnectivity.sendIdle()
        LiveActivityManager.shared.end()
    }

    // MARK: - Watch companion

    private func pushWatchSnapshot() {
        let snapshot = WatchGameSnapshot(
            isActive: !isCaught && !isExtracted,
            gameCode: roomCode,
            roleRaw: role.rawValue,
            arrestCode: arrestCode,
            isCaught: isCaught,
            nearestDistanceMeters: nearestHunterDistance,
            nearestBearingDegrees: nearestHunterBearing,
            inventoryRaw: inventory.map(\.rawValue),
            isRadarJammed: isRadarJammed,
            visibleRunners: visibleRunners.map { WatchRunnerBlip(id: $0.id, username: $0.username) },
            updatedAt: Date()
        )
        watchConnectivity.send(snapshot)
    }

    private func handleWatchAction(_ action: WatchActionMessage) {
        switch action.type {
        case .usePowerUp:
            guard let raw = action.powerUpTypeRaw, let type = PowerUpType(rawValue: raw) else { return }
            usePowerUp(type)
        case .attemptCatch:
            guard let target = action.targetRunnerId, let code = action.arrestCode else { return }
            socket.attemptCatch(runnerId: target, arrestCode: code)
        }
    }

    private func bindLocation() {
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
                }
            }
            .store(in: &cancellables)

        socket.playerExtractedSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playerId in
                guard let self, playerId == self.gamePlayerId else { return }
                self.isExtracted = true
                HapticsEngine.shared.catchSucceeded()
                LiveActivityManager.shared.end()
                self.pushWatchSnapshot()
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
                if result.hunterId == self.gamePlayerId {
                    if result.heartsLostBy == "HUNTER" {
                        // Real dip, then heal back — matches what the server actually
                        // persisted (nothing), purely a visual "took a hit" flourish.
                        self.hearts = result.hunterHeartsAfterLoss
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.hearts = result.hunterHeartsRemaining }
                    } else {
                        self.hearts = result.hunterHeartsRemaining
                    }
                }
                if result.runnerId == self.gamePlayerId {
                    self.hearts = result.runnerHeartsRemaining
                }
                HapticsEngine.shared.lightTap()
            }
            .store(in: &cancellables)

        socket.heartsUpdateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self, event.playerId == self.gamePlayerId else { return }
                self.hearts = event.hearts
                if event.cause == "BOUNDARY" { HapticsEngine.shared.catchFailed() }
            }
            .store(in: &cancellables)

        socket.playerJailedSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self, event.runnerId == self.gamePlayerId else { return }
                self.isCaught = true
                self.isJailed = true
                HapticsEngine.shared.catchFailed()
                self.pushWatchSnapshot()
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

    // MARK: - Power-ups

    func usePowerUp(_ type: PowerUpType) {
        socket.usePowerUp(type)
        if type == .invisibility {
            isInvisible = true
            invisibilityRemainingSec = type.durationSeconds
            invisibilityTimer?.invalidate()
            invisibilityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                Task { @MainActor in
                    guard let self else { timer.invalidate(); return }
                    self.invisibilityRemainingSec -= 1
                    if self.invisibilityRemainingSec <= 0 {
                        self.isInvisible = false
                        timer.invalidate()
                    }
                }
            }
        }
    }

    func collectPowerUp(spawnId: String) {
        HapticsEngine.shared.powerUpCollected()
        socket.collectPowerUp(spawnId: spawnId)
    }

    // MARK: - Catch flow

    /// INFECTION mode keeps the old code-entry sheet; every other mode uses the new
    /// real-time request the runner answers on their own device.
    func beginCatch(on runnerId: String) {
        HapticsEngine.shared.lightTap()
        if mode == .infection {
            catchTargetId = runnerId
            catchCodeEntry = ""
        } else {
            pendingCatchRequestRunnerId = runnerId
            socket.requestCatch(runnerId: runnerId)
        }
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

    func gambleCatch(choice: GambleChoice) {
        guard let request = incomingCatchRequest else { return }
        HapticsEngine.shared.lightTap()
        gambleChoicePending = choice
        isCoinFlipping = true
        socket.respondToCatch(hunterId: request.hunterId, decision: "gamble", gambleChoice: choice.rawValue)
        incomingCatchRequest = nil
    }

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

    func dismissGambleResult() {
        lastGambleOutcome = nil
        isCoinFlipping = false
    }

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
    var visibleRunners: [PlayerState] { socket.radar?.runners ?? [] }
    var isRadarJammed: Bool { socket.radar?.jammed ?? false }
    var allPlayers: [PlayerState] { socket.players }
    var inventory: [PowerUpType] { socket.inventory }
}
