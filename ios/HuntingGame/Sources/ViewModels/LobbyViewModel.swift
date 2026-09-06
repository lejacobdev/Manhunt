import Foundation
import CoreLocation

@MainActor
final class LobbyViewModel: ObservableObject {
    @Published var joinCodeInput = ""
    @Published var selectedRole: PlayerRole = .runner
    /// Separate from `selectedRole` (used by the join-by-code flow) so picking a
    /// role while hosting doesn't cross-contaminate the join picker's selection.
    @Published var hostRole: PlayerRole = .runner
    @Published var selectedMode: GameMode = .standard
    @Published var squadName = ""
    @Published var hostSquadName = ""
    @Published var durationMinutes: Double = 60
    @Published var radarIntervalSec: Double = 120
    @Published var boundaryPoints: [Coordinate] = []
    @Published var jailEnabled = false
    @Published var jailPoints: [Coordinate] = []
    @Published var gamblingEnabled = false
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
        if selectedMode == .squad && hostSquadName.isEmpty {
            errorMessage = "Enter a squad name before hosting a SQUAD mode game."
            return
        }
        if jailEnabled && jailPoints.count < 3 {
            errorMessage = "Draw a jail area with at least 3 points, or turn jail mode off."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let (player, session) = try await api.createGame(
                durationMinutes: Int(durationMinutes),
                radarIntervalSec: Int(radarIntervalSec),
                boundsPolygon: boundaryPoints,
                mode: selectedMode,
                role: hostRole,
                squad: selectedMode == .squad ? hostSquadName : nil,
                jailEnabled: jailEnabled,
                jailPolygon: jailEnabled ? jailPoints : [],
                gamblingEnabled: gamblingEnabled
            )
            activePlayer = player
            activeSession = session
            joinCodeInput = session.code
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

    /// Recovers a still-running or still-in-lobby game this account belongs to, so Mission
    /// Control can offer a way back in after the app was relaunched — not just while this
    /// one in-memory view model instance happens to still remember it from create/join.
    func refreshActiveSession() async {
        guard let result = try? await api.activeSession() else { return }
        activeSession = result.session
        activePlayer = result.player
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
