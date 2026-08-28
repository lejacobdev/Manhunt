import Foundation
import CoreLocation

@MainActor
final class LobbyViewModel: ObservableObject {
    @Published var joinCodeInput = ""
    @Published var selectedRole: PlayerRole = .runner
    @Published var selectedMode: GameMode = .standard
    @Published var squadName = ""
    @Published var durationMinutes: Double = 60
    @Published var radarIntervalSec: Double = 120
    @Published var boundaryPoints: [Coordinate] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var activeSession: GameSession?
    @Published var activePlayer: GamePlayer?

    private let api = APIClient.shared

    func addBoundaryPoint(_ coordinate: CLLocationCoordinate2D) {
        boundaryPoints.append(Coordinate(lat: coordinate.latitude, lng: coordinate.longitude))
    }

    func resetBoundary() {
        boundaryPoints.removeAll()
    }

    func createGame() async {
        guard boundaryPoints.count >= 3 else {
            errorMessage = "Draw a play-area boundary with at least 3 points before creating a game."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let session = try await api.createGame(
                durationMinutes: Int(durationMinutes),
                radarIntervalSec: Int(radarIntervalSec),
                boundsPolygon: boundaryPoints,
                mode: selectedMode
            )
            activeSession = session
            joinCodeInput = session.code
            let (player, joinedSession) = try await api.joinGame(code: session.code, role: .supervisor, squad: nil)
            activePlayer = player
            activeSession = joinedSession
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func joinGame() async {
        guard !joinCodeInput.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (player, session) = try await api.joinGame(
                code: joinCodeInput.uppercased(),
                role: selectedRole,
                squad: selectedMode == .squad ? squadName : nil
            )
            activePlayer = player
            activeSession = session
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startGame() async {
        guard let session = activeSession else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            activeSession = try await api.startGame(code: session.code)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
