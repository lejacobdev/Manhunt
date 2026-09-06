import Foundation

/// Backs both the signed-in player's own profile tab and a friend's profile screen — the
/// payload is identical either way, only the source differs.
@MainActor
final class ProfileViewModel: ObservableObject {
    enum Source: Equatable {
        case me
        case user(id: String)
    }

    @Published private(set) var profile: UserProfile?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let source: Source
    private let api = APIClient.shared

    init(source: Source) {
        self.source = source
    }

    func load() async {
        // Refreshing an already-loaded profile shouldn't blank the screen back to a
        // spinner — the stats are still valid until the new ones land.
        if profile == nil { isLoading = true }
        defer { isLoading = false }
        do {
            switch source {
            case .me:
                profile = try await api.myProfile()
            case .user(let id):
                profile = try await api.profile(userId: id)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
