import AuthenticationServices
import Foundation

/// Drives the account screen: the name and tag, which providers can sign in, and the password.
///
/// Every rule here is also enforced by the server (see backend `services/AccountName.ts` and
/// `services/ProviderAccounts.ts`); what this adds is knowing enough to keep the UI honest — not
/// offering an unlink that would lock the person out, and not letting them type a new name while a
/// cooldown is running only to be refused on save.
@MainActor
final class AccountSettingsViewModel: ObservableObject {
    @Published private(set) var overview: AccountOverview?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var successMessage: String?
    /// Which provider row is mid-request, so only that row shows a spinner.
    @Published var busyProvider: AccountProvider?

    /// Editable copies, seeded from the server and reset whenever it answers.
    @Published var username = ""
    @Published var userTag = ""

    private let api = APIClient.shared
    private let session = AuthSession.shared

    var connections: AccountConnections? { overview?.connections }

    var isDirty: Bool {
        guard let overview else { return false }
        return username != overview.user.username || userTag != overview.user.userTag
    }

    var cooldownNotice: String? {
        guard let overview, let next = overview.nextNameChangeDate, next > Date() else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let when = formatter.localizedString(for: next, relativeTo: Date())
        return "You can change your name again \(when)."
    }

    var canSaveName: Bool {
        guard let overview else { return false }
        return isDirty && !isLoading && !overview.isNameChangeOnCooldown && localNameProblem == nil
    }

    /// The obvious cases, caught before a round trip. The server's answer is still the authority.
    var localNameProblem: String? {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Enter a username." }
        if name.count < 3 { return "Your username needs at least 3 characters." }
        if name.count > 20 { return "Your username can have at most 20 characters." }
        if name.contains("#") { return "Leave the # out — the tag is the separate field below." }
        if name.contains(where: { !$0.isASCII || !($0.isLetter || $0.isNumber || $0 == "_") }) {
            return "Usernames can only contain letters, numbers and underscores."
        }
        let tag = userTag.trimmingCharacters(in: .whitespacesAndNewlines)
        if tag.count != 4 || tag.contains(where: { !$0.isNumber }) { return "A tag is exactly 4 digits, like 4921." }
        return nil
    }

    func load() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            apply(try await api.accountOverview())
        } catch {
            errorMessage = AuthViewModel.message(for: error)
        }
    }

    private func apply(_ fresh: AccountOverview) {
        overview = fresh
        username = fresh.user.username
        userTag = fresh.user.userTag
    }

    func resetEdits() {
        guard let overview else { return }
        username = overview.user.username
        userTag = overview.user.userTag
        errorMessage = nil
    }

    /// Saves whichever halves actually changed — sending the unchanged one would be harmless but
    /// makes the server's "nothing to change" path do pointless work.
    func saveName() async {
        guard let overview else { return }
        errorMessage = nil
        successMessage = nil
        isLoading = true
        defer { isLoading = false }

        let newName = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTag = userTag.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let result = try await api.changeName(
                username: newName == overview.user.username ? nil : newName,
                userTag: newTag == overview.user.userTag ? nil : newTag
            )
            // The token carries the username in its claims, so the new one replaces the stored
            // session rather than leaving the app signed in under the old name.
            session.signIn(token: result.token, user: result.user)
            self.overview = AccountOverview(
                user: result.user,
                connections: overview.connections,
                nameChangeCooldownDays: overview.nameChangeCooldownDays,
                nextNameChangeAt: result.nextNameChangeAt
            )
            username = result.user.username
            userTag = result.user.userTag
            successMessage = "You're now \(result.user.tagLabel)."
        } catch {
            errorMessage = AuthViewModel.message(for: error)
        }
    }

    /// Asks the server for any free tag on the current name. The way out of "every tag on this name
    /// is taken", which is otherwise a dead end for a popular name.
    func useRandomTag() async {
        guard let overview else { return }
        errorMessage = nil
        successMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await api.changeName(
                username: username.trimmingCharacters(in: .whitespacesAndNewlines) == overview.user.username
                    ? nil
                    : username.trimmingCharacters(in: .whitespacesAndNewlines),
                userTag: "random"
            )
            session.signIn(token: result.token, user: result.user)
            self.overview = AccountOverview(
                user: result.user,
                connections: overview.connections,
                nameChangeCooldownDays: overview.nameChangeCooldownDays,
                nextNameChangeAt: result.nextNameChangeAt
            )
            username = result.user.username
            userTag = result.user.userTag
            successMessage = "You're now \(result.user.tagLabel)."
        } catch {
            errorMessage = AuthViewModel.message(for: error)
        }
    }

    // MARK: - Linking

    func handleAppleLinkButton(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            Task { await link(.apple) {
                let credential = try AppleSignInService.shared.credential(from: authorization)
                return try await self.api.linkApple(
                    identityToken: credential.identityToken,
                    nonce: credential.nonce.isEmpty ? nil : credential.nonce
                )
            } }
        case .failure(let error):
            errorMessage = AuthViewModel.message(for: AppleSignInService.shared.failure(from: error))
        }
    }

    func linkGameCenter() {
        Task { await link(.gamecenter) {
            let payload = try await GameCenterIdentityService.fetchIdentity()
            return try await self.api.linkGameCenter(payload)
        } }
    }

    private func link(_ provider: AccountProvider, run: @escaping () async throws -> AccountConnections) async {
        errorMessage = nil
        successMessage = nil
        busyProvider = provider
        defer { busyProvider = nil }
        do {
            let connections = try await run()
            updateConnections(connections)
            successMessage = "\(provider.title) can now sign you in."
        } catch {
            errorMessage = AuthViewModel.message(for: error)
        }
    }

    func unlink(_ provider: AccountProvider) async {
        errorMessage = nil
        successMessage = nil
        busyProvider = provider
        defer { busyProvider = nil }
        do {
            updateConnections(try await api.unlink(provider))
            successMessage = "\(provider.title) no longer signs you in."
        } catch {
            errorMessage = AuthViewModel.message(for: error)
        }
    }

    /// True when removing this one would leave nothing to sign in with. The server refuses it too;
    /// this is so the row can explain itself instead of just failing.
    func isOnlyWayIn(_ provider: AccountProvider) -> Bool {
        guard let connections else { return false }
        return provider.isLinked(in: connections) && connections.signInMethodCount <= 1
    }

    private func updateConnections(_ connections: AccountConnections) {
        guard let overview else { return }
        self.overview = AccountOverview(
            user: overview.user,
            connections: connections,
            nameChangeCooldownDays: overview.nameChangeCooldownDays,
            nextNameChangeAt: overview.nextNameChangeAt
        )
    }

    // MARK: - Password

    func setPassword(new newPassword: String, current: String?) async -> Bool {
        errorMessage = nil
        successMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            try await api.setPassword(newPassword: newPassword, currentPassword: current)
            if let overview {
                var connections = overview.connections
                connections.hasPassword = true
                updateConnections(connections)
            }
            successMessage = "Password saved."
            return true
        } catch {
            errorMessage = AuthViewModel.message(for: error)
            return false
        }
    }
}
