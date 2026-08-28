import Foundation

@MainActor
final class FriendsViewModel: ObservableObject {
    @Published var friends: [AppUser] = []
    @Published var searchQuery = ""
    @Published var searchResults: [AppUser] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastActionMessage: String?

    private let api = APIClient.shared

    func loadFriends() async {
        isLoading = true
        defer { isLoading = false }
        do {
            friends = try await api.listFriends()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func search() async {
        guard searchQuery.count >= 2 else {
            searchResults = []
            return
        }
        do {
            searchResults = try await api.searchUsers(query: searchQuery)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendRequest(to user: AppUser) async {
        do {
            try await api.sendFriendRequest(receiverId: user.id)
            lastActionMessage = "Friend request sent to \(user.tagLabel)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
