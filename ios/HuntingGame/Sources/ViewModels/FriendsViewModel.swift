import Foundation

@MainActor
final class FriendsViewModel: ObservableObject {
    @Published var friends: [AppUser] = []
    @Published var incomingRequests: [FriendRequest] = []
    @Published var outgoingRequests: [FriendRequest] = []
    @Published var searchQuery = ""
    @Published var searchResults: [AppUser] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastActionMessage: String?

    private let api = APIClient.shared

    func loadAll() async {
        isLoading = true
        defer { isLoading = false }
        async let friendsTask = api.listFriends()
        async let incomingTask = api.incomingFriendRequests()
        async let outgoingTask = api.outgoingFriendRequests()
        do {
            friends = try await friendsTask
            incomingRequests = try await incomingTask
            outgoingRequests = try await outgoingTask
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadFriends() async {
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

    func accept(_ request: FriendRequest) async {
        do {
            try await api.acceptFriendRequest(id: request.id)
            lastActionMessage = "You're now friends with \(request.otherUser.tagLabel)."
            incomingRequests.removeAll { $0.id == request.id }
            await loadFriends()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func decline(_ request: FriendRequest) async {
        do {
            try await api.declineFriendRequest(id: request.id)
            incomingRequests.removeAll { $0.id == request.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func invite(_ friend: AppUser, toSessionCode code: String) async {
        do {
            try await api.sendGameInvite(toUserId: friend.id, sessionCode: code)
            lastActionMessage = "Invited \(friend.tagLabel) to the match."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
