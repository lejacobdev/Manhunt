import Foundation
import Combine
import SocketIO

/// Owns the single Socket.IO connection for the active match: joins the room,
/// streams location fixes upstream, and republishes every server event as a
/// Combine publisher for the view models to consume.
final class SocketService: ObservableObject {
    static let shared = SocketService()

    /// The shared production backend — must match APIClient.baseURL.
    var serverURL = URL(string: "https://api.lejacob.dev")!

    @Published var players: [PlayerState] = []
    @Published var compass: CompassUpdate?
    @Published var radar: RadarBroadcast?
    @Published var extractionPoint: Coordinate?
    @Published var matchStartedAt: Date?
    @Published var lastCatchFailure: String?
    @Published var lastErrorMessage: String?
    @Published var lastAntiCheatWarning: String?
    @Published var inventory: [PowerUpType] = []
    @Published var isConnected: Bool = false
    @Published var gameOverReason: String?
    /// The runner's own incoming "did you get caught?" popup.
    @Published var incomingCatchRequest: CatchRequest?
    /// Hunter-side "was it an accident?" prompt, after a runner taps No.
    @Published var pendingDenyConfirm: DenyConfirmRequest?
    @Published var lastGambleResult: GambleResult?

    /// Fires with the caught player's id whenever a catch/infection event lands.
    /// hunterId is nil when no hunter was involved (kept for backward shape compatibility).
    let playerCaughtSubject = PassthroughSubject<(runnerId: String, hunterId: String?, reason: String?), Never>()
    let playerInfectedSubject = PassthroughSubject<(runnerId: String, hunterId: String), Never>()
    let playerExtractedSubject = PassthroughSubject<String, Never>()
    let playerRevivedSubject = PassthroughSubject<(playerId: String, revivedById: String), Never>()
    /// Fires with the spawn's id whenever anyone (not just this player) collects it, so
    /// every client can drop the matching pin from its map.
    let powerUpCollectedSubject = PassthroughSubject<String, Never>()
    /// Fires on the hunter's own client once their request is stored server-side.
    let catchRequestSentSubject = PassthroughSubject<(runnerId: String, requestId: String), Never>()
    /// Fires on the hunter's own client when their request timed out unanswered.
    let catchRequestExpiredSubject = PassthroughSubject<(runnerId: String, requestId: String), Never>()
    /// Fires on the runner's own client (carries the hunter's id) whenever their incoming
    /// request/popup should be dismissed — the hunter cancelled it, confirmed a deny was
    /// accidental, or it simply expired.
    let catchRequestCancelledSubject = PassthroughSubject<String, Never>()
    let gambleResultSubject = PassthroughSubject<GambleResult, Never>()
    let heartsUpdateSubject = PassthroughSubject<(playerId: String, hearts: Int, cause: String), Never>()
    let playerJailedSubject = PassthroughSubject<(runnerId: String, hunterId: String), Never>()
    let playerEliminatedSubject = PassthroughSubject<(playerId: String, role: String, reason: String), Never>()
    let boundaryStatusSubject = PassthroughSubject<(outside: Bool, warning: Bool), Never>()
    let jailStatusSubject = PassthroughSubject<(outside: Bool, deadlineMs: Int?), Never>()

    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private var roomCode: String?
    private var gamePlayerId: String?

    // Must accept fractional seconds — the backend stamps this with JS's
    // Date.toISOString(), which always includes milliseconds.
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {}

    func connect(roomCode: String, gamePlayerId: String) {
        self.roomCode = roomCode
        self.gamePlayerId = gamePlayerId

        guard let token = AuthSession.shared.token else { return }
        let manager = SocketManager(
            socketURL: serverURL,
            config: [
                .log(false),
                .compress,
                .connectParams(["token": token]),
                .extraHeaders(["Authorization": "Bearer \(token)"]),
            ]
        )
        self.manager = manager
        let socket = manager.defaultSocket
        self.socket = socket

        registerHandlers(on: socket)
        socket.connect()
    }

    func disconnect() {
        socket?.emit("leave_room")
        socket?.disconnect()
        manager = nil
        socket = nil
        isConnected = false
        // Full reset, not just the map/roster fields — this is a singleton reused across
        // matches, so anything left stale here (most importantly gameOverReason) would leak
        // into the next match's GameView and show a "Match Ended" overlay on a fresh game.
        players = []
        compass = nil
        radar = nil
        extractionPoint = nil
        matchStartedAt = nil
        lastCatchFailure = nil
        lastErrorMessage = nil
        lastAntiCheatWarning = nil
        inventory = []
        gameOverReason = nil
        incomingCatchRequest = nil
        pendingDenyConfirm = nil
        lastGambleResult = nil
    }

    func sendLocationUpdate(lat: Double, lng: Double, speed: Double, accuracy: Double, battery: Int, isMovingOnFoot: Bool) {
        socket?.emit("send_location_update", [
            "lat": lat,
            "lng": lng,
            "speed": speed,
            "accuracy": accuracy,
            "battery": battery,
            "isMovingOnFoot": isMovingOnFoot,
        ])
    }

    /// INFECTION mode only — every other mode uses the request/accept/gamble flow below.
    func attemptCatch(runnerId: String, arrestCode: String) {
        socket?.emit("attempt_catch", ["runnerId": runnerId, "arrestCode": arrestCode])
    }

    /// STANDARD/SQUAD catch flow: no arrest code, just a real-time request the runner
    /// answers on their own device.
    func requestCatch(runnerId: String) {
        socket?.emit("request_catch", ["runnerId": runnerId])
    }

    func cancelCatchRequest(runnerId: String) {
        socket?.emit("cancel_catch_request", ["runnerId": runnerId])
    }

    /// The runner's answer to a pending request. `decision` is "accept" | "gamble" | "deny".
    func respondToCatch(hunterId: String, decision: String, gambleChoice: String? = nil) {
        var payload: [String: Any] = ["hunterId": hunterId, "decision": decision]
        if let gambleChoice { payload["gambleChoice"] = gambleChoice }
        socket?.emit("respond_catch", payload)
    }

    /// Hunter confirms a runner's "no, that wasn't a catch" really was accidental.
    func acknowledgeDenyWasAccidental(requestId: String) {
        socket?.emit("catch_deny_ack", ["requestId": requestId])
    }

    func collectPowerUp(spawnId: String) {
        socket?.emit("collect_powerup", ["spawnId": spawnId])
    }

    func usePowerUp(_ type: PowerUpType) {
        socket?.emit("use_powerup", ["powerUpType": type.rawValue])
    }

    /// Squad mode: revive a caught teammate within arm's reach.
    func reviveTeammate(targetId: String) {
        socket?.emit("revive_teammate", ["targetId": targetId])
    }

    /// Host-only: force-resolve a disputed catch.
    func hostOverride(targetId: String, isCaught: Bool) {
        socket?.emit("host_override", ["targetId": targetId, "isCaught": isCaught])
    }

    /// Host-only: force-end the match immediately.
    func hostEndGame() {
        socket?.emit("host_end_game")
    }

    private func registerHandlers(on socket: SocketIOClient) {
        socket.on(clientEvent: .connect) { [weak self] _, _ in
            guard let self, let roomCode = self.roomCode, let gamePlayerId = self.gamePlayerId else { return }
            self.isConnected = true
            socket.emit("join_room", ["roomCode": roomCode, "gamePlayerId": gamePlayerId])
        }

        socket.on(clientEvent: .disconnect) { [weak self] _, _ in
            self?.isConnected = false
        }

        socket.on("player_joined") { [weak self] data, _ in
            guard let self, let raw = data.first else { return }
            self.players = Self.decodeArray(raw)
        }

        socket.on("player_left") { [weak self] data, _ in
            guard let self, let dict = data.first as? [String: Any], let id = dict["gamePlayerId"] as? String else { return }
            self.players.removeAll { $0.id == id }
        }

        socket.on("compass_update") { [weak self] data, _ in
            guard let self, let raw = data.first else { return }
            self.compass = Self.decode(raw)
        }

        socket.on("radar_broadcast") { [weak self] data, _ in
            guard let self, let raw = data.first else { return }
            self.radar = Self.decode(raw)
        }

        socket.on("extraction_point") { [weak self] data, _ in
            guard let self, let raw = data.first else { return }
            self.extractionPoint = Self.decode(raw)
        }

        socket.on("game_started") { [weak self] data, _ in
            guard let self, let dict = data.first as? [String: Any], let raw = dict["startedAt"] as? String else { return }
            self.matchStartedAt = Self.iso8601.date(from: raw)
        }

        // Sent to SPECTATOR observers (and to the host regardless of role) — the full
        // live roster, on every location tick, since they don't get the hunter-only radar feed.
        socket.on("roster_update") { [weak self] data, _ in
            guard let self, let raw = data.first else { return }
            self.players = Self.decodeArray(raw)
        }

        socket.on("player_caught") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any], let runnerId = dict["runnerId"] as? String else { return }
            let hunterId = dict["hunterId"] as? String
            let reason = dict["reason"] as? String
            self?.playerCaughtSubject.send((runnerId, hunterId, reason))
        }

        socket.on("player_infected") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let runnerId = dict["runnerId"] as? String,
                  let hunterId = dict["hunterId"] as? String else { return }
            self?.playerInfectedSubject.send((runnerId, hunterId))
        }

        socket.on("player_extracted") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any], let playerId = dict["playerId"] as? String else { return }
            self?.playerExtractedSubject.send(playerId)
            if let index = self?.players.firstIndex(where: { $0.id == playerId }) {
                self?.players[index].isExtracted = true
            }
        }

        socket.on("player_revived") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let playerId = dict["playerId"] as? String,
                  let revivedById = dict["revivedById"] as? String else { return }
            self?.playerRevivedSubject.send((playerId, revivedById))
            if let index = self?.players.firstIndex(where: { $0.id == playerId }) {
                self?.players[index].isCaught = false
            }
        }

        socket.on("host_override_applied") { [weak self] data, _ in
            guard let self, let dict = data.first as? [String: Any],
                  let playerId = dict["playerId"] as? String,
                  let isCaught = dict["isCaught"] as? Bool else { return }
            if let index = self.players.firstIndex(where: { $0.id == playerId }) {
                self.players[index].isCaught = isCaught
            }
        }

        socket.on("catch_failed") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            self?.lastCatchFailure = dict["reason"] as? String
        }

        // MARK: Request/accept/gamble catch flow (STANDARD/SQUAD)

        socket.on("catch_requested") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let requestId = dict["requestId"] as? String,
                  let hunterId = dict["hunterId"] as? String,
                  let hunterUsername = dict["hunterUsername"] as? String else { return }
            self?.incomingCatchRequest = CatchRequest(requestId: requestId, hunterId: hunterId, hunterUsername: hunterUsername)
        }

        socket.on("catch_request_sent") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let runnerId = dict["runnerId"] as? String,
                  let requestId = dict["requestId"] as? String else { return }
            self?.catchRequestSentSubject.send((runnerId, requestId))
        }

        socket.on("catch_request_expired") { [weak self] data, _ in
            guard let self, let dict = data.first as? [String: Any],
                  let runnerId = dict["runnerId"] as? String,
                  let requestId = dict["requestId"] as? String else { return }
            self.catchRequestExpiredSubject.send((runnerId, requestId))
            // The hunter's own stale "was it an accident?" prompt (if any) is about this
            // same request — clear it alongside the "your request timed out" job above.
            if self.pendingDenyConfirm?.requestId == requestId { self.pendingDenyConfirm = nil }
        }

        socket.on("catch_request_cancelled") { [weak self] data, _ in
            guard let self, let dict = data.first as? [String: Any], let hunterId = dict["hunterId"] as? String else { return }
            self.catchRequestCancelledSubject.send(hunterId)
            self.incomingCatchRequest = nil
        }

        socket.on("catch_deny_confirm") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let requestId = dict["requestId"] as? String,
                  let runnerUsername = dict["runnerUsername"] as? String else { return }
            self?.pendingDenyConfirm = DenyConfirmRequest(requestId: requestId, runnerUsername: runnerUsername)
        }

        socket.on("gamble_result") { [weak self] data, _ in
            guard let self, let raw = data.first, let result: GambleResult = Self.decode(raw) else { return }
            self.lastGambleResult = result
            self.gambleResultSubject.send(result)
            if let index = self.players.firstIndex(where: { $0.id == result.hunterId }) {
                self.players[index].hearts = result.hunterHeartsRemaining
            }
            if let index = self.players.firstIndex(where: { $0.id == result.runnerId }) {
                self.players[index].hearts = result.runnerHeartsRemaining
            }
        }

        socket.on("hearts_update") { [weak self] data, _ in
            guard let self, let dict = data.first as? [String: Any],
                  let playerId = dict["playerId"] as? String,
                  let hearts = dict["hearts"] as? Int,
                  let cause = dict["cause"] as? String else { return }
            self.heartsUpdateSubject.send((playerId, hearts, cause))
            if let index = self.players.firstIndex(where: { $0.id == playerId }) {
                self.players[index].hearts = hearts
            }
        }

        socket.on("player_jailed") { [weak self] data, _ in
            guard let self, let dict = data.first as? [String: Any],
                  let runnerId = dict["runnerId"] as? String,
                  let hunterId = dict["hunterId"] as? String else { return }
            self.playerJailedSubject.send((runnerId, hunterId))
            if let index = self.players.firstIndex(where: { $0.id == runnerId }) {
                self.players[index].isCaught = true
                self.players[index].isJailed = true
            }
        }

        socket.on("player_eliminated") { [weak self] data, _ in
            guard let self, let dict = data.first as? [String: Any],
                  let playerId = dict["playerId"] as? String,
                  let role = dict["role"] as? String,
                  let reason = dict["reason"] as? String else { return }
            self.playerEliminatedSubject.send((playerId, role, reason))
            if let index = self.players.firstIndex(where: { $0.id == playerId }) {
                self.players[index].isOut = true
            }
        }

        socket.on("boundary_status") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any], let outside = dict["outside"] as? Bool else { return }
            self?.boundaryStatusSubject.send((outside, dict["warning"] as? Bool ?? false))
        }

        socket.on("jail_status") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any], let outside = dict["outside"] as? Bool else { return }
            self?.jailStatusSubject.send((outside, dict["deadlineMs"] as? Int))
        }

        socket.on("error_event") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            self?.lastErrorMessage = dict["reason"] as? String
        }

        socket.on("anti_cheat_warning") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            self?.lastAntiCheatWarning = dict["reason"] as? String
        }

        socket.on("powerup_collected") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any], let spawnId = dict["spawnId"] as? String else { return }
            self?.powerUpCollectedSubject.send(spawnId)
        }

        socket.on("inventory_update") { [weak self] data, _ in
            guard let self, let dict = data.first as? [String: Any], let rawItems = dict["inventory"] as? [String] else { return }
            self.inventory = rawItems.compactMap { PowerUpType(rawValue: $0) }
        }

        socket.on("game_over") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            self?.gameOverReason = dict["reason"] as? String
        }
    }

    private static func decode<T: Decodable>(_ raw: Any) -> T? {
        guard JSONSerialization.isValidJSONObject(raw) || raw is [Any] else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func decodeArray<T: Decodable>(_ raw: Any) -> [T] {
        guard let array = raw as? [Any] else { return [] }
        guard let data = try? JSONSerialization.data(withJSONObject: array) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }
}
