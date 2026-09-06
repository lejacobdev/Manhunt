import Foundation

@MainActor
final class LobbyViewModel: ObservableObject {
    @Published var joinCodeInput = ""
    @Published var selectedRole: PlayerRole = .runner
    /// Separate from `hostRole` (used when hosting) so picking a role while joining by
    /// code doesn't cross-contaminate the hosting picker's selection.
    @Published var selectedMode: GameMode = .standard
    @Published var squadName = ""

    /// Separate from `selectedMode`/`selectedRole` above — hosting and joining are shown
    /// side by side on the same screen now, so sharing state between them would mean
    /// changing one picker visibly changes the other's form too.
    @Published var hostMode: GameMode = .standard
    @Published var hostRole: PlayerRole = .runner
    @Published var hostSquadName = ""

    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var activeSession: GameSession?
    @Published var activePlayer: GamePlayer?

    private let api = APIClient.shared

    /// Hosting used to require the whole play-area/jail/gambling setup up front, behind a
    /// multi-step wizard, before you ever saw the lobby. Now it only needs what can't
    /// change once you've joined the session (mode, your own role) — everything else is
    /// configured from inside the lobby itself (see GameLobbyView/GameLobbyViewModel),
    /// which is also where the empty play area gets drawn before Start unlocks.
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
                role: hostRole,
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
}
