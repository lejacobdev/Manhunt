import Foundation

@MainActor
final class LeaderboardViewModel: ObservableObject {
    @Published var sort: LeaderboardSort = .wins {
        didSet {
            guard sort != oldValue else { return }
            Task { await load() }
        }
    }
    @Published private(set) var leaderboard: Leaderboard?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let api = APIClient.shared

    func load() async {
        if leaderboard == nil { isLoading = true }
        defer { isLoading = false }
        do {
            leaderboard = try await api.leaderboard(sort: sort)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
