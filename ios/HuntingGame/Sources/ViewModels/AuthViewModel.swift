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
        let (resolvedUsername, resolvedTag) = Self.resolveIdentifier(username: username, userTag: userTag)
        do {
            let (token, user) = try await api.login(username: resolvedUsername, userTag: resolvedTag, password: password)
            session.signIn(token: token, user: user)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// App Store Connect's demo-account section has a single "User Name" field — no separate
    /// tag box — so a reviewer given "applereview#0000" naturally pastes the whole string
    /// into our Username field with Tag left blank (App Review rejection, submission
    /// fdcbff62, Sep 18 2026: "unable to sign in with the following demo account
    /// credentials"). Splitting that shape out here is what makes the single pasted string
    /// actually work, instead of depending on whoever's signing in to notice the separate
    /// Tag field and split it themselves. Only kicks in when Tag is already empty and the
    /// text after '#' looks like an actual tag (4 digits) — never touches a normal two-field
    /// login.
    static func resolveIdentifier(username: String, userTag: String) -> (username: String, userTag: String) {
        guard userTag.trimmingCharacters(in: .whitespaces).isEmpty,
              let hashIndex = username.firstIndex(of: "#") else {
            return (username, userTag)
        }
        let name = String(username[username.startIndex..<hashIndex])
        let tag = String(username[username.index(after: hashIndex)...])
        guard !name.isEmpty, tag.count == 4, tag.allSatisfy(\.isNumber) else {
            return (username, userTag)
        }
        return (name, tag)
    }

    func signOut() {
        session.signOut()
    }
}
