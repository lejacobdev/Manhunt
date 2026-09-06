import Foundation
import Combine

/// Drives the pre-match waiting room: everyone who joined sits here (live roster, current
/// settings) until the host starts the match, at which point `GameLobbyView` swaps to the
/// real `GameView`. The host can also edit settings and invite friends from here, without
/// ever leaving back out to Mission Control.
@MainActor
final class GameLobbyViewModel: ObservableObject {
    @Published private(set) var session: GameSession
    /// Kept in sync with the live roster (see `bindSocket`) rather than frozen at whatever
    /// role this player joined with — the host can reassign anyone's role, including their
    /// own, from the lobby roster, and `GameView` is launched from whatever this holds the
    /// instant the match actually starts.
    @Published private(set) var player: GamePlayer

    @Published var errorMessage: String?
    @Published var isSavingSettings = false
    @Published var isStarting = false

    // Host-editable settings, seeded from the session and kept in sync with whatever the
    // host last saved — a non-host's copies are overwritten live by settings_updated too,
    // so their read-only summary always reflects the current values.
    @Published var durationMinutes: Double
    /// The play area being drawn, before it's saved. Once `session.settings.boundsPolygon`
    /// has 3+ points the area is locked in server-side, so this stops being editable —
    /// see `isBoundarySet`.
    @Published var boundaryPoints: [Coordinate]
    @Published var jailEnabled: Bool
    @Published var jailPoints: [Coordinate]
    @Published var gamblingEnabled: Bool
    /// BETA — see GameSettings.antiCheatEnabled. Off by default; a host opts in.
    @Published var antiCheatEnabled: Bool
    /// True while the host is actively redrawing an already-set play area — see
    /// `beginRedrawBoundary()`. The boundary is otherwise treated as fixed once set, the
    /// same way `isBoundarySet` already gates the first-time drawing UI.
    @Published var isRedrawingBoundary = false

    let socket = SocketService.shared
    private var cancellables = Set<AnyCancellable>()

    var isHost: Bool { session.hostId == player.userId }
    var isBoundarySet: Bool { session.settings.boundsPolygon.count >= 3 }
    /// The one thing setup actually requires — everything else (jail, gambling, the exact
    /// duration) has a working default and can be changed later, but there's no match
    /// without a play area to generate power-ups and an extraction point inside.
    var isReadyToStart: Bool { isBoundarySet }

    init(session: GameSession, player: GamePlayer) {
        self.session = session
        self.player = player
        self.durationMinutes = Double(session.settings.durationMinutes)
        self.boundaryPoints = session.settings.boundsPolygon
        self.jailEnabled = session.settings.jailEnabled ?? false
        self.jailPoints = session.settings.jailPolygon ?? []
        self.gamblingEnabled = session.settings.gamblingEnabled ?? false
        self.antiCheatEnabled = session.settings.antiCheatEnabled ?? false
        bindSocket()
    }

    /// Host-only: reassign any player's role (including their own) from the lobby roster.
    func setRole(for playerId: String, to role: PlayerRole) {
        guard isHost else { return }
        socket.setPlayerRole(targetId: playerId, role: role)
    }

    /// Host-only: re-enter draw mode for an already-set play area. Saving afterward
    /// regenerates the extraction point and re-scatters power-ups inside the new shape.
    func beginRedrawBoundary() {
        guard isHost else { return }
        boundaryPoints = []
        isRedrawingBoundary = true
    }

    func start() {
        socket.connect(roomCode: session.code, gamePlayerId: player.id)
    }

    /// Only actually disconnects while still in the lobby — once the match goes active,
    /// `GameLobbyView` swaps in `GameView`, which owns the connection from that point on.
    func stop() {
        guard session.status == .lobby else { return }
        socket.disconnect()
    }

    private func bindSocket() {
        socket.$latestSettings
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] settings in
                guard let self else { return }
                self.applySettings(settings)
                // A non-host's local copies are display-only, so they always track the
                // host's last save; the host's own copies are their own in-progress edits
                // and shouldn't be clobbered by the echo of their own save.
                guard !self.isHost else { return }
                self.durationMinutes = Double(settings.durationMinutes)
                self.boundaryPoints = settings.boundsPolygon
                self.jailEnabled = settings.jailEnabled ?? false
                self.jailPoints = settings.jailPolygon ?? []
                self.gamblingEnabled = settings.gamblingEnabled ?? false
                self.antiCheatEnabled = settings.antiCheatEnabled ?? false
            }
            .store(in: &cancellables)

        socket.$matchStartedAt
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.session = GameSession(
                    id: self.session.id, code: self.session.code, status: .active, mode: self.session.mode,
                    hostId: self.session.hostId, startedAt: self.session.startedAt, endedAt: self.session.endedAt,
                    settings: self.session.settings
                )
            }
            .store(in: &cancellables)

        // The host can reassign roles (see `setRole`) any time before the match starts —
        // this keeps `player` current so GameView launches with whatever role this device
        // actually ended up with, not whichever one it joined the lobby as.
        socket.$players
            .receive(on: DispatchQueue.main)
            .sink { [weak self] players in
                guard let self, let mine = players.first(where: { $0.id == self.player.id }) else { return }
                guard mine.role != self.player.role || mine.hearts != self.player.hearts else { return }
                self.player = GamePlayer(
                    id: self.player.id, sessionId: self.player.sessionId, userId: self.player.userId,
                    role: mine.role, squad: self.player.squad, isCaught: self.player.isCaught,
                    arrestCode: self.player.arrestCode, hearts: mine.hearts
                )
            }
            .store(in: &cancellables)
    }

    private func applySettings(_ settings: GameSettings) {
        session = GameSession(
            id: session.id, code: session.code, status: session.status, mode: session.mode,
            hostId: session.hostId, startedAt: session.startedAt, endedAt: session.endedAt,
            settings: settings
        )
    }

    func saveSettings() async {
        guard isHost else { return }
        let needsBoundary = !isBoundarySet || isRedrawingBoundary
        if needsBoundary && boundaryPoints.count < 3 {
            errorMessage = "Draw the play area (at least 3 points) before saving."
            return
        }
        if jailEnabled && jailPoints.count < 3 {
            errorMessage = "Draw a jail area (at least 3 points), or turn jail mode off."
            return
        }
        isSavingSettings = true
        defer { isSavingSettings = false }
        do {
            let updated = try await APIClient.shared.updateSessionSettings(
                code: session.code,
                durationMinutes: Int(durationMinutes),
                // Sent whenever the boundary hasn't been set yet, or the host is actively
                // redrawing it — resending the already-saved points otherwise would trigger
                // a needless regeneration of the extraction point and power-ups server-side.
                boundsPolygon: needsBoundary ? boundaryPoints : nil,
                jailEnabled: jailEnabled,
                jailPolygon: jailEnabled ? jailPoints : nil,
                gamblingEnabled: gamblingEnabled,
                antiCheatEnabled: antiCheatEnabled
            )
            applySettings(updated.settings)
            isRedrawingBoundary = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startGame() async {
        guard isHost, isReadyToStart else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            session = try await APIClient.shared.startGame(code: session.code)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
