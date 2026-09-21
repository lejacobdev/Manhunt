import AuthenticationServices
import Foundation

@MainActor
final class AuthViewModel: ObservableObject {
    @Published var username = ""
    @Published var userTag = ""
    @Published var password = ""
    @Published var isLoading = false
    @Published var errorMessage: String?

    /// Set when a provider sign-in found no account: the ticket proving the identity was verified,
    /// held while the person chooses what to be called. Non-nil is what shows the username sheet.
    @Published var pendingSignUpTicket: String?
    /// Which button is busy, so only that one shows a spinner.
    @Published var busyProvider: AccountProvider?

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

    // MARK: - Sign in with Apple / Game Center

    /// Handles what SwiftUI's `SignInWithAppleButton` reports. Apple's own button runs the request,
    /// so this picks up from its result rather than starting one.
    func handleAppleButton(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            Task { await signIn(provider: .apple) {
                let credential = try AppleSignInService.shared.credential(from: authorization)
                return try await self.api.signInWithApple(
                    identityToken: credential.identityToken,
                    nonce: credential.nonce.isEmpty ? nil : credential.nonce
                )
            } }
        case .failure(let error):
            show(AppleSignInService.shared.failure(from: error))
        }
    }

    func signInWithGameCenter() {
        Task { await signIn(provider: .gamecenter) {
            let payload = try await GameCenterIdentityService.fetchIdentity()
            return try await self.api.signInWithGameCenter(payload)
        } }
    }

    /// The shared tail of both: run the provider's own flow, then either land in the app or ask for
    /// a username.
    private func signIn(provider: AccountProvider, run: @escaping () async throws -> ProviderSignInOutcome) async {
        errorMessage = nil
        busyProvider = provider
        defer { busyProvider = nil }
        do {
            switch try await run() {
            case .signedIn(let token, let user):
                session.signIn(token: token, user: user)
            case .needsUsername(let ticket):
                // Reuse whatever is already typed in the form as a starting point, so someone who
                // began registering and then tapped a provider button doesn't lose it.
                pendingSignUpTicket = ticket
            }
        } catch {
            show(error)
        }
    }

    /// Second half of a provider sign-up, with the username the person chose.
    func completeSignUp(username chosen: String) async {
        guard let ticket = pendingSignUpTicket else { return }
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let (token, user) = try await api.completeProviderSignUp(ticket: ticket, username: chosen)
            pendingSignUpTicket = nil
            session.signIn(token: token, user: user)
        } catch {
            show(error)
        }
    }

    func cancelSignUp() {
        pendingSignUpTicket = nil
        errorMessage = nil
    }

    /// Shows an error, unless it is a deliberate cancellation — closing Apple's or Game Center's
    /// sheet is not a failure, and `localizedDescription` would turn it into a scary sentence.
    private func show(_ error: Error) {
        errorMessage = Self.message(for: error)
    }

    static func message(for error: Error) -> String? {
        if let failure = error as? AppleSignInService.Failure { return failure.errorDescription }
        if let failure = error as? GameCenterIdentityService.Failure { return failure.errorDescription }
        return error.localizedDescription
    }
}
