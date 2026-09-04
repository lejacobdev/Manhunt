import Foundation

enum APIError: Error, LocalizedError {
    case invalidResponse
    case server(String)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The server returned an unexpected response."
        case .server(let message): return message
        case .decoding(let error): return Self.describeDecodingFailure(error)
        }
    }

    /// `DecodingError.localizedDescription` is always the same useless sentence
    /// ("The data couldn't be read because it isn't in the correct format"), which
    /// says nothing about *which* field disagreed with the server. Unpack it into
    /// something that names the actual key and its path, so a model/API mismatch is
    /// diagnosable from the screen it broke rather than only under a debugger.
    private static func describeDecodingFailure(_ error: Error) -> String {
        guard let error = error as? DecodingError else {
            return "Failed to decode response: \(error.localizedDescription)"
        }

        func path(_ context: DecodingError.Context) -> String {
            let joined = context.codingPath
                .map { key in key.intValue.map { "[\($0)]" } ?? ".\(key.stringValue)" }
                .joined()
            if joined.isEmpty { return "the response" }
            return joined.hasPrefix(".") ? String(joined.dropFirst()) : joined
        }

        switch error {
        case .keyNotFound(let key, let context):
            return "Server response is missing '\(key.stringValue)' (at \(path(context)))."
        case .typeMismatch(let type, let context):
            return "Server sent the wrong type for \(path(context)) — expected \(type)."
        case .valueNotFound(let type, let context):
            return "Server sent null for \(path(context)), which needs a \(type)."
        case .dataCorrupted(let context):
            return "Server sent an unexpected value for \(path(context)): \(context.debugDescription)"
        @unknown default:
            return "Failed to decode response: \(error.localizedDescription)"
        }
    }
}

/// Thin REST client for the Hunting Game backend. All game-session, friend,
/// and power-up bookkeeping goes through here; real-time gameplay uses SocketService.
final class APIClient {
    static let shared = APIClient()

    /// The shared production backend, serving every player.
    var baseURL = URL(string: "https://api.lejacob.dev")!

    private let session = URLSession(configuration: .default)
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
    private let encoder = JSONEncoder()

    private init() {}

    // MARK: - Auth

    func register(username: String, password: String) async throws -> (token: String, user: AppUser) {
        struct Body: Encodable { let username: String; let password: String }
        struct Response: Decodable { let token: String; let user: AppUser }
        let resp: Response = try await post("/auth/register", body: Body(username: username, password: password), authorized: false)
        return (resp.token, resp.user)
    }

    func login(username: String, userTag: String, password: String) async throws -> (token: String, user: AppUser) {
        struct Body: Encodable { let username: String; let userTag: String; let password: String }
        struct Response: Decodable { let token: String; let user: AppUser }
        let resp: Response = try await post(
            "/auth/login",
            body: Body(username: username, userTag: userTag, password: password),
            authorized: false
        )
        return (resp.token, resp.user)
    }

    // MARK: - Friends

    func searchUsers(query: String) async throws -> [AppUser] {
        struct Response: Decodable { let results: [AppUser] }
        let resp: Response = try await get("/friends/search", queryItems: [URLQueryItem(name: "q", value: query)])
        return resp.results
    }

    func sendFriendRequest(receiverId: String) async throws {
        struct Body: Encodable { let receiverId: String }
        let _: EmptyResponse = try await post("/friends/requests", body: Body(receiverId: receiverId))
    }

    func acceptFriendRequest(id: String) async throws {
        let _: EmptyResponse = try await post("/friends/requests/\(id)/accept", body: EmptyBody())
    }

    func declineFriendRequest(id: String) async throws {
        try await delete("/friends/requests/\(id)/decline")
    }

    func listFriends() async throws -> [AppUser] {
        struct Response: Decodable { let friends: [AppUser] }
        let resp: Response = try await get("/friends")
        return resp.friends
    }

    func incomingFriendRequests() async throws -> [FriendRequest] {
        struct Response: Decodable { let requests: [FriendRequest] }
        let resp: Response = try await get("/friends/requests/incoming")
        return resp.requests
    }

    func outgoingFriendRequests() async throws -> [FriendRequest] {
        struct Response: Decodable { let requests: [FriendRequest] }
        let resp: Response = try await get("/friends/requests/outgoing")
        return resp.requests
    }

    // MARK: - Invites

    func sendGameInvite(toUserId: String, sessionCode: String) async throws {
        struct Body: Encodable { let toUserId: String; let sessionCode: String }
        let _: EmptyResponse = try await post("/invites", body: Body(toUserId: toUserId, sessionCode: sessionCode))
    }

    func incomingInvites() async throws -> [GameInvite] {
        struct Response: Decodable { let invites: [GameInvite] }
        let resp: Response = try await get("/invites/incoming")
        return resp.invites
    }

    /// Marks the invite resolved and returns the session to join; the caller still
    /// picks a role and calls `joinGame(code:role:squad:)` to actually enter the lobby.
    func acceptInvite(id: String) async throws -> GameSession {
        struct Response: Decodable { let session: GameSession }
        let resp: Response = try await post("/invites/\(id)/accept", body: EmptyBody())
        return resp.session
    }

    func declineInvite(id: String) async throws {
        try await delete("/invites/\(id)/decline")
    }

    // MARK: - Games

    /// The host plays too — no separate supervisor/observer role forced on them. They pick
    /// role/squad just like anyone joining, and get host-only admin actions (end game,
    /// override a catch) via GameSession.hostId instead.
    func createGame(durationMinutes: Int, radarIntervalSec: Int, boundsPolygon: [Coordinate], mode: GameMode, role: PlayerRole, squad: String?, jailEnabled: Bool = false, jailPolygon: [Coordinate] = [], gamblingEnabled: Bool = false) async throws -> (player: GamePlayer, session: GameSession) {
        struct Body: Encodable {
            let durationMinutes: Int
            let radarIntervalSec: Int
            let boundsPolygon: [Coordinate]
            let mode: String
            let role: String
            let squad: String?
            let jailEnabled: Bool
            let jailPolygon: [Coordinate]
            let gamblingEnabled: Bool
        }
        struct Response: Decodable { let session: GameSession; let player: GamePlayer }
        let resp: Response = try await post(
            "/games",
            body: Body(
                durationMinutes: durationMinutes,
                radarIntervalSec: radarIntervalSec,
                boundsPolygon: boundsPolygon,
                mode: mode.rawValue,
                role: role.rawValue,
                squad: squad,
                jailEnabled: jailEnabled,
                jailPolygon: jailPolygon,
                gamblingEnabled: gamblingEnabled
            )
        )
        return (resp.player, resp.session)
    }

    func joinGame(code: String, role: PlayerRole, squad: String?) async throws -> (player: GamePlayer, session: GameSession) {
        struct Body: Encodable { let role: String; let squad: String? }
        struct Response: Decodable { let player: GamePlayer; let session: GameSession }
        let resp: Response = try await post("/games/\(code)/join", body: Body(role: role.rawValue, squad: squad))
        return (resp.player, resp.session)
    }

    func startGame(code: String) async throws -> GameSession {
        struct Response: Decodable { let session: GameSession }
        let resp: Response = try await post("/games/\(code)/start", body: EmptyBody())
        return resp.session
    }

    func fetchGame(code: String) async throws -> GameSession {
        struct Response: Decodable { let session: GameSession }
        let resp: Response = try await get("/games/\(code)")
        return resp.session
    }

    func fetchReplay(code: String) async throws -> MatchReplay {
        try await get("/games/\(code)/replay")
    }

    // MARK: - Power-ups

    func fetchPowerUpSpawns(sessionId: String) async throws -> [PowerUpSpawn] {
        struct Response: Decodable { let spawns: [PowerUpSpawn] }
        let resp: Response = try await get("/powerups/session/\(sessionId)")
        return resp.spawns
    }

    /// Returns the readable rows plus a count of any that couldn't be decoded, rather
    /// than throwing when a single row is unreadable — see `Lenient`. The caller
    /// surfaces the skipped count so dropped matches are visible, not silent.
    func gameHistory() async throws -> (entries: [HistoryEntry], unreadableCount: Int) {
        struct Response: Decodable { let history: [Lenient<HistoryEntry>] }
        let resp: Response = try await get("/games/history/mine")
        let entries = resp.history.compactMap(\.value)
        return (entries, resp.history.count - entries.count)
    }

    // MARK: - Core request helpers

    private func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem] = []) async throws -> T {
        // appendingPathComponent doesn't understand query-string syntax — it would
        // literalize a "?q=..." suffix into the path itself, producing a malformed
        // request (this was the actual cause of friend search always 404ing).
        // URLComponents + queryItems handles percent-encoding correctly too.
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        return try await send(request)
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, body: B, authorized: Bool = true) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        return try await send(request, authorized: authorized)
    }

    /// For 204-No-Content endpoints (decline routes) where there's no response body to
    /// decode — an empty byte stream isn't valid JSON, so this skips `send`'s decode step.
    private func delete(_ path: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        if let token = AuthSession.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? decoder.decode(ErrorBody.self, from: data))?.error ?? "Request failed with status \(http.statusCode)."
            if http.statusCode == 401 {
                await MainActor.run { AuthSession.shared.signOut() }
            }
            throw APIError.server(message)
        }
    }

    private func send<T: Decodable>(_ request: URLRequest, authorized: Bool = true) async throws -> T {
        var request = request
        if authorized, let token = AuthSession.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? decoder.decode(ErrorBody.self, from: data))?.error ?? "Request failed with status \(http.statusCode)."
            // A 401 on a request that carried our saved token means the server has
            // genuinely rejected it (expired/invalid) — the user should land back on
            // the login screen rather than see the same request fail silently over
            // and over while the app still thinks they're signed in. A 401 from an
            // unauthorized call (login/register with wrong credentials) never hits
            // this, since the user was never signed in to begin with.
            if authorized, http.statusCode == 401 {
                await MainActor.run { AuthSession.shared.signOut() }
            }
            throw APIError.server(message)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }
}

private struct EmptyBody: Encodable {}
private struct EmptyResponse: Decodable {}
private struct ErrorBody: Decodable { let error: String }

/// Decodes `T`, but yields nil instead of throwing when a single element doesn't fit
/// the model. Swift decodes arrays all-or-nothing, so without this one stale or
/// malformed row from an older schema takes down the entire list it appeared in.
private struct Lenient<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
