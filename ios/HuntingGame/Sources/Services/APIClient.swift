import Foundation

enum APIError: Error, LocalizedError {
    case invalidResponse
    case server(String)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The server returned an unexpected response."
        case .server(let message): return message
        case .decoding(let error): return "Failed to decode response: \(error.localizedDescription)"
        }
    }
}

/// Thin REST client for the Hunting Game backend. All game-session, friend,
/// and power-up bookkeeping goes through here; real-time gameplay uses SocketService.
final class APIClient {
    static let shared = APIClient()

    /// Point this at your deployed backend (see docker-compose.yml / .env.example for the paired server config).
    var baseURL = URL(string: "https://31-214-141-29.sslip.io")!

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
        let resp: Response = try await get("/friends/search?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
        return resp.results
    }

    func sendFriendRequest(receiverId: String) async throws {
        struct Body: Encodable { let receiverId: String }
        let _: EmptyResponse = try await post("/friends/requests", body: Body(receiverId: receiverId))
    }

    func acceptFriendRequest(id: String) async throws {
        let _: EmptyResponse = try await post("/friends/requests/\(id)/accept", body: EmptyBody())
    }

    func listFriends() async throws -> [AppUser] {
        struct Response: Decodable { let friends: [AppUser] }
        let resp: Response = try await get("/friends")
        return resp.friends
    }

    // MARK: - Games

    func createGame(durationMinutes: Int, radarIntervalSec: Int, boundsPolygon: [Coordinate], mode: GameMode) async throws -> GameSession {
        struct Body: Encodable {
            let durationMinutes: Int
            let radarIntervalSec: Int
            let boundsPolygon: [Coordinate]
            let mode: String
        }
        struct Response: Decodable { let session: GameSession }
        let resp: Response = try await post(
            "/games",
            body: Body(durationMinutes: durationMinutes, radarIntervalSec: radarIntervalSec, boundsPolygon: boundsPolygon, mode: mode.rawValue)
        )
        return resp.session
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

    // MARK: - Core request helpers

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
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

    private func send<T: Decodable>(_ request: URLRequest, authorized: Bool = true) async throws -> T {
        var request = request
        if authorized, let token = AuthSession.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? decoder.decode(ErrorBody.self, from: data))?.error ?? "Request failed with status \(http.statusCode)."
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
