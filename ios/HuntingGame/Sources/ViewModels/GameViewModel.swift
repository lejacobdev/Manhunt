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

    private var cancellables = Set<AnyCancellable>()
    private var invisibilityTimer: Timer?
    private var watchSyncTimer: Timer?
    private let watchConnectivity = PhoneConnectivityManager.shared
    private var lastSentAt: Date = .distantPast
    private let minSendInterval: TimeInterval = 2.0

    let gamePlayerId: String
    let mySquad: String?
    let sessionSettings: GameSettings
    private let roomCode: String

    init(gamePlayer: GamePlayer, session: GameSession) {
        self.role = gamePlayer.role
        self.mode = session.mode
        self.arrestCode = gamePlayer.arrestCode
        self.isCaught = gamePlayer.isCaught
        self.gamePlayerId = gamePlayer.id
        self.mySquad = gamePlayer.squad
        self.sessionSettings = session.settings
        self.roomCode = session.code

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
    }

    func stop() {
        locationManager.stop()
        socket.disconnect()
        invisibilityTimer?.invalidate()
        watchSyncTimer?.invalidate()
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

        socket.$lastCatchFailure
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reason in
                self?.showCatchFailure = reason
                HapticsEngine.shared.catchFailed()
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

    func beginCatch(on runnerId: String) {
        HapticsEngine.shared.lightTap()
        catchTargetId = runnerId
        catchCodeEntry = ""
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

    // MARK: - Supervisor actions

    func supervisorOverride(playerId: String, isCaught: Bool) {
        HapticsEngine.shared.lightTap()
        socket.supervisorOverride(targetId: playerId, isCaught: isCaught)
    }

    func supervisorEndGame() {
        HapticsEngine.shared.catchFailed()
        socket.supervisorEndGame()
    }

    // MARK: - Derived state

    var nearestHunterDistance: Int? { socket.compass?.distanceMeters }
    var nearestHunterBearing: Double? { socket.compass?.bearingDegrees }
    var visibleRunners: [PlayerState] { socket.radar?.runners ?? [] }
    var isRadarJammed: Bool { socket.radar?.jammed ?? false }
    var allPlayers: [PlayerState] { socket.players }
    var inventory: [PowerUpType] { socket.inventory }
}
