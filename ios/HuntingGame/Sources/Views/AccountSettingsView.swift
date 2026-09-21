import AuthenticationServices
import SwiftUI

/// Profile → Account: the name and tag, which Apple/Game Center identities can sign in, and the
/// password.
///
/// Laid out as a plain top-to-bottom column of cards rather than floating panels, matching the rest
/// of the app's screens.
struct AccountSettingsView: View {
    @StateObject private var viewModel = AccountSettingsViewModel()
    @State private var showPasswordSheet = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("Account")
                    .font(ADATheme.displayFont(size: 20))
                    .foregroundColor(.white)
                    .padding(.top, 8)

                if viewModel.overview == nil && viewModel.isLoading {
                    ProgressView()
                        .tint(ADATheme.spatialCyan)
                        .padding(.top, 40)
                } else {
                    nameCard
                    connectionsCard
                    passwordCard
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(ADATheme.telemetryFont(size: 12))
                        .foregroundColor(ADATheme.hunterRed)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                if let success = viewModel.successMessage {
                    Text(success)
                        .font(ADATheme.telemetryFont(size: 12))
                        .foregroundColor(ADATheme.runnerGreen)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .adaptiveContentWidth()
            .padding(.bottom, 32)
            .animation(ADATheme.controlSpring, value: viewModel.errorMessage)
            .animation(ADATheme.controlSpring, value: viewModel.successMessage)
        }
        .task { await viewModel.load() }
        .sheet(isPresented: $showPasswordSheet) {
            PasswordSheet(viewModel: viewModel, hasPassword: viewModel.connections?.hasPassword ?? true)
        }
    }

    // MARK: - Name and tag

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("NAME & TAG", icon: "person.text.rectangle")

            Text("Other players find you by your name and tag together, so both can change.")
                .font(ADATheme.uiFont(size: 12))
                .foregroundColor(.white.opacity(0.5))

            ADATextField(placeholder: "Username", text: $viewModel.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            HStack(spacing: 10) {
                ADATextField(placeholder: "Tag", text: $viewModel.userTag)
                    .keyboardType(.numberPad)
                    .frame(maxWidth: 120)

                Button {
                    Task { await viewModel.useRandomTag() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "die.face.5")
                        Text("Random")
                    }
                    .font(ADATheme.uiFont(size: 13))
                }
                .buttonStyle(GlassButtonStyle(tint: .white.opacity(0.6)))
                .disabled(viewModel.isLoading || viewModel.overview?.isNameChangeOnCooldown == true)
            }

            if let problem = viewModel.localNameProblem, viewModel.isDirty {
                Text(problem)
                    .font(ADATheme.telemetryFont(size: 11))
                    .foregroundColor(ADATheme.tacticalAmber)
            }

            if let notice = viewModel.cooldownNotice {
                Label(notice, systemImage: "clock")
                    .font(ADATheme.telemetryFont(size: 11))
                    .foregroundColor(ADATheme.tacticalAmber)
            } else if let days = viewModel.overview?.nameChangeCooldownDays {
                Text("You can change this once every \(days) days.")
                    .font(ADATheme.telemetryFont(size: 10))
                    .foregroundColor(.white.opacity(0.3))
            }

            HStack(spacing: 10) {
                Button {
                    Task { await viewModel.saveName() }
                } label: {
                    if viewModel.isLoading {
                        ProgressView().tint(.black)
                    } else {
                        Text("SAVE")
                    }
                }
                .buttonStyle(GlowButtonStyle(tint: ADATheme.runnerGreen, isLoading: viewModel.isLoading))
                .disabled(!viewModel.canSaveName)

                if viewModel.isDirty {
                    Button("Undo") { viewModel.resetEdits() }
                        .font(ADATheme.uiFont(size: 13))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
        }
        .padding(16)
        .glassCard(cornerRadius: ADATheme.cardCornerRadius)
        .padding(.horizontal)
    }

    // MARK: - Sign-in methods

    private var connectionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("SIGN-IN METHODS", icon: "key.horizontal")

            Text("Add Apple or Game Center to sign in without typing your name and password.")
                .font(ADATheme.uiFont(size: 12))
                .foregroundColor(.white.opacity(0.5))

            ForEach(AccountProvider.allCases) { provider in
                providerRow(provider)
                if provider != AccountProvider.allCases.last {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                }
            }
        }
        .padding(16)
        .glassCard(cornerRadius: ADATheme.cardCornerRadius)
        .padding(.horizontal)
    }

    @ViewBuilder
    private func providerRow(_ provider: AccountProvider) -> some View {
        let isLinked = viewModel.connections.map { provider.isLinked(in: $0) } ?? false
        let isBusy = viewModel.busyProvider == provider

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: provider.icon)
                    .font(.system(size: 16))
                    .foregroundColor(isLinked ? ADATheme.runnerGreen : .white.opacity(0.5))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.title)
                        .font(ADATheme.uiFont(size: 15))
                        .foregroundColor(.white)
                    Text(isLinked ? "Connected" : "Not connected")
                        .font(ADATheme.telemetryFont(size: 10))
                        .foregroundColor(isLinked ? ADATheme.runnerGreen.opacity(0.8) : .white.opacity(0.35))
                }

                Spacer()

                if isBusy {
                    ProgressView().tint(.white)
                } else if isLinked {
                    Button("Unlink") { Task { await viewModel.unlink(provider) } }
                        .font(ADATheme.uiFont(size: 13))
                        .foregroundColor(viewModel.isOnlyWayIn(provider) ? .white.opacity(0.25) : ADATheme.hunterRed)
                        .disabled(viewModel.isOnlyWayIn(provider))
                } else if provider == .apple {
                    // Apple's own button, as their guidelines require, sized to sit in a row.
                    SignInWithAppleButton(.continue) { request in
                        AppleSignInService.shared.configure(request)
                    } onCompletion: { result in
                        viewModel.handleAppleLinkButton(result)
                    }
                    .signInWithAppleButtonStyle(.white)
                    .frame(width: 120, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Button("Link") { viewModel.linkGameCenter() }
                        .font(ADATheme.uiFont(size: 13))
                        .foregroundColor(ADATheme.spatialCyan)
                }
            }

            if isLinked && viewModel.isOnlyWayIn(provider) {
                Text("This is the only way into your account. Set a password first to unlink it.")
                    .font(ADATheme.telemetryFont(size: 10))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Password

    private var passwordCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("PASSWORD", icon: "lock")

            let hasPassword = viewModel.connections?.hasPassword ?? true
            Text(hasPassword
                 ? "You can sign in with your name, tag and password."
                 : "This account has no password yet — it signs in with Apple or Game Center. Add one as a backup.")
                .font(ADATheme.uiFont(size: 12))
                .foregroundColor(.white.opacity(0.5))

            Button {
                showPasswordSheet = true
            } label: {
                HStack {
                    Image(systemName: hasPassword ? "lock.rotation" : "lock.badge.plus")
                    Text(hasPassword ? "CHANGE PASSWORD" : "SET A PASSWORD")
                }
            }
            .buttonStyle(GlassButtonStyle(tint: ADATheme.spatialCyan))
        }
        .padding(16)
        .glassCard(cornerRadius: ADATheme.cardCornerRadius)
        .padding(.horizontal)
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(ADATheme.spatialCyan)
            Text(title)
                .font(ADATheme.telemetryFont(size: 11))
                .foregroundColor(.white.opacity(0.45))
                .tracking(1.5)
        }
    }
}

/// Setting a first password, or changing an existing one. The current password is asked for only
/// when there is one — see the route in backend `routes/users.ts` for why that is safe.
private struct PasswordSheet: View {
    @ObservedObject var viewModel: AccountSettingsViewModel
    let hasPassword: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var newPassword = ""
    @State private var confirmation = ""

    private var problem: String? {
        if hasPassword && current.isEmpty { return "Enter your current password." }
        if newPassword.count < 8 { return "Your new password needs at least 8 characters." }
        if !confirmation.isEmpty && confirmation != newPassword { return "The two new passwords don't match." }
        if confirmation.isEmpty { return "Type your new password twice." }
        return nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(spacing: 14) {
                        if hasPassword {
                            ADASecureField(placeholder: "Current password", text: $current)
                        }
                        ADASecureField(placeholder: "New password", text: $newPassword)
                        ADASecureField(placeholder: "New password again", text: $confirmation)

                        if let problem, !newPassword.isEmpty || !current.isEmpty {
                            Text(problem)
                                .font(ADATheme.telemetryFont(size: 11))
                                .foregroundColor(ADATheme.tacticalAmber)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if let error = viewModel.errorMessage {
                            Text(error)
                                .font(ADATheme.telemetryFont(size: 12))
                                .foregroundColor(ADATheme.hunterRed)
                                .multilineTextAlignment(.center)
                        }

                        Button {
                            Task {
                                let saved = await viewModel.setPassword(
                                    new: newPassword,
                                    current: hasPassword ? current : nil
                                )
                                if saved { dismiss() }
                            }
                        } label: {
                            if viewModel.isLoading {
                                ProgressView().tint(.black)
                            } else {
                                Text(hasPassword ? "CHANGE PASSWORD" : "SET PASSWORD")
                            }
                        }
                        .buttonStyle(GlowButtonStyle(tint: ADATheme.runnerGreen, isLoading: viewModel.isLoading))
                        .disabled(problem != nil || viewModel.isLoading)
                    }
                    .adaptiveContentWidth()
                    .padding(.vertical, 20)
                    .animation(ADATheme.controlSpring, value: problem)
                }
            }
            .obsidianBackdrop()
            .navigationTitle(hasPassword ? "Change password" : "Set a password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
