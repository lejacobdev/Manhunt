import Foundation

@MainActor
final class LobbyViewModel: ObservableObject {
    @Published var joinCodeInput = ""
    @Published var selectedMode: GameMode = .standard
    @Published var squadName = ""

    /// Separate from `selectedMode` above — hosting and joining are shown side by side on
    /// the same screen now, so sharing state between them would mean changing one picker
    /// visibly changes the other's form too.
    @Published var hostMode: GameMode = .standard
    @Published var hostSquadName = ""

    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var activeSession: GameSession?
    @Published var activePlayer: GamePlayer?

    private let api = APIClient.shared

    /// Hosting used to require the whole play-area/jail/gambling setup up front, behind a
    /// multi-step wizard, before you ever saw the lobby. Now it only needs what can't
    /// change once you've joined the session (the mode) — everything else, including who
    /// plays which role, is configured from inside the lobby itself (see
    /// GameLobbyView/GameLobbyViewModel), which is also where the empty play area gets
    /// drawn before Start unlocks. Role used to be picked here too, but it's the host's
    /// call once everyone's actually in the lobby, not a guess made before joining — so
    /// everyone starts as RUNNER and the host reassigns from the roster.
    func hostGame() async {
        if hostMode == .squad && hostSquadName.isEmpty {
            errorMessage = "Enter a squad name before hosting a SQUAD mode game."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let (player, session) = try await api.createGame(
                durationMinutes: 60,
                boundsPolygon: [],
                mode: hostMode,
                role: .runner,
                squad: hostMode == .squad ? hostSquadName : nil
            )
            activePlayer = player
            activeSession = session
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
                role: .runner,
                squad: selectedMode == .squad ? squadName : nil
            )
            activePlayer = player
            activeSession = session
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}
