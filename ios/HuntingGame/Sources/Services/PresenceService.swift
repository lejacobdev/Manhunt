import Foundation
import Combine
import SocketIO

/// A persistent Socket.IO connection independent of any match — alive for as long as
/// the user is signed in (started/stopped from RootView), rather than only while inside
/// a game like `SocketService`. Carries friend online/offline presence and lobby invites,
/// both of which need to work while the player is just browsing the lobby/friends screens.
final class PresenceService: ObservableObject {
    static let shared = PresenceService()

    var serverURL = URL(string: "https://api.lejacob.eu")!

    @Published var onlineFriendIds: Set<String> = []
    @Published var incomingInvites: [GameInvite] = []

    private var manager: SocketManager?
    private var socket: SocketIOClient?

    private init() {}

    func start() {
        guard socket == nil, let token = AuthSession.shared.token else { return }
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

        Task { await refreshIncomingInvites() }
    }

    func stop() {
        socket?.disconnect()
        manager = nil
        socket = nil
        onlineFriendIds = []
        incomingInvites = []
    }

    /// REST fallback that seeds `incomingInvites` on launch/reconnect, covering invites
    /// that arrived while this device was offline — live delivery is via `game_invite` below.
    @MainActor
    func refreshIncomingInvites() async {
        guard let invites = try? await APIClient.shared.incomingInvites() else { return }
        incomingInvites = invites
    }

    @MainActor
    func respondToInvite(_ invite: GameInvite, accept: Bool) async throws -> GameSession? {
        let session: GameSession?
        if accept {
            session = try await APIClient.shared.acceptInvite(id: invite.id)
        } else {
            try await APIClient.shared.declineInvite(id: invite.id)
            session = nil
        }
        incomingInvites.removeAll { $0.id == invite.id }
        return session
    }

    private func registerHandlers(on socket: SocketIOClient) {
        socket.on(clientEvent: .connect) { [weak self] _, _ in
            socket.emit("get_online_friends")
            Task { await self?.refreshIncomingInvites() }
        }

        socket.on("online_friends_snapshot") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any], let ids = dict["onlineFriendIds"] as? [String] else { return }
            self?.onlineFriendIds = Set(ids)
        }

        socket.on("friend_online") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any], let id = dict["userId"] as? String else { return }
            self?.onlineFriendIds.insert(id)
        }

        socket.on("friend_offline") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any], let id = dict["userId"] as? String else { return }
            self?.onlineFriendIds.remove(id)
        }

        socket.on("game_invite") { [weak self] data, _ in
            guard let self, let dict = data.first as? [String: Any],
                  let id = dict["id"] as? String,
                  let sessionCode = dict["sessionCode"] as? String,
                  let modeRaw = dict["mode"] as? String, let mode = GameMode(rawValue: modeRaw),
                  let fromUserId = dict["fromUserId"] as? String,
                  let fromUsername = dict["fromUsername"] as? String,
                  let createdAt = dict["createdAt"] as? String
            else { return }

            let invite = GameInvite(
                id: id,
                sessionCode: sessionCode,
                mode: mode,
                fromUserId: fromUserId,
                fromUsername: fromUsername,
                createdAt: createdAt
            )
            if !self.incomingInvites.contains(where: { $0.id == invite.id }) {
                self.incomingInvites.append(invite)
            }
            HapticsEngine.shared.lightTap()
        }
    }
}
