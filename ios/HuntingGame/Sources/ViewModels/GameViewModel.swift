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
    @Published var isInvisible: Bool = false
    @Published var invisibilityRemainingSec: Int = 0
    @Published var activeSafeZone: (lat: Double, lng: Double, radius: Double)?
    @Published var catchTargetId: String?
    @Published var catchCodeEntry: String = ""
    @Published var showCatchFailure: String?

    private var cancellables = Set<AnyCancellable>()
    private var invisibilityTimer: Timer?
    private var lastSentAt: Date = .distantPast
    private let minSendInterval: TimeInterval = 2.0

    private let gamePlayerId: String
    private let roomCode: String

    init(gamePlayer: GamePlayer, session: GameSession) {
        self.role = gamePlayer.role
        self.mode = session.mode
        self.arrestCode = gamePlayer.arrestCode
        self.isCaught = gamePlayer.isCaught
        self.gamePlayerId = gamePlayer.id
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
    }

    func stop() {
        locationManager.stop()
        socket.disconnect()
        invisibilityTimer?.invalidate()
        LiveActivityManager.shared.end()
    }

    private func bindLocation() {
        locationManager.onLocationUpdate = { [weak self] location in
            guard let self else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastSentAt) >= self.minSendInterval else { return }
            self.lastSentAt = now
            self.socket.sendLocationUpdate(
                lat: location.coordinate.latitude,
                lng: location.coordinate.longitude,
                speed: max(0, location.speed),
                accuracy: location.horizontalAccuracy,
                battery: max(0, Int(UIDevice.current.batteryLevel * 100))
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
                } else if event.hunterId == self.gamePlayerId {
                    HapticsEngine.shared.catchSucceeded()
                }
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

    // MARK: - Derived state

    var nearestHunterDistance: Int? { socket.compass?.distanceMeters }
    var nearestHunterBearing: Double? { socket.compass?.bearingDegrees }
    var visibleRunners: [PlayerState] { socket.radar?.runners ?? [] }
    var isRadarJammed: Bool { socket.radar?.jammed ?? false }
    var allPlayers: [PlayerState] { socket.players }
    var inventory: [PowerUpType] { socket.inventory }
}
