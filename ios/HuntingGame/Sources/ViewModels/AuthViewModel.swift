import Foundation

@MainActor
final class AuthViewModel: ObservableObject {
    @Published var username = ""
    @Published var userTag = ""
    @Published var password = ""
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let api = APIClient.shared
    private let session = AuthSession.shared

    func register() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let (token, user) = try await api.register(username: username, password: password)
            session.signIn(token: token, user: user)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func login() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let (token, user) = try await api.login(username: username, userTag: userTag, password: password)
            session.signIn(token: token, user: user)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() {
        session.signOut()
    }
}
