import SwiftUI

/// Second step of signing in with Apple or Game Center when no account exists yet.
///
/// Neither provider gives us a name worth using — Apple's is withheld unless asked for (and this app
/// deliberately asks for nothing), and a Game Center nickname is the player's Apple-wide handle, not
/// a name for this game. So rather than minting something like "player_8f31c2", the person is asked
/// once. The same rules as registration apply, and the server enforces them: this screen only avoids
/// a pointless round trip for the obvious cases.
struct ChooseUsernameView: View {
    @ObservedObject var viewModel: AuthViewModel

    @State private var chosen = ""
    @FocusState private var fieldFocused: Bool

    /// Mirrors the server's own rule (backend `utils/validation.ts`), which stays the authority.
    private var localProblem: String? {
        let trimmed = chosen.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.count < 3 { return "At least 3 characters." }
        if trimmed.count > 20 { return "At most 20 characters." }
        if trimmed.contains("#") { return "No # — your tag is added for you." }
        if trimmed.contains(where: { !$0.isASCII || !($0.isLetter || $0.isNumber || $0 == "_") }) {
            return "Letters, numbers and underscores only."
        }
        return nil
    }

    private var canSubmit: Bool {
        let trimmed = chosen.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && localProblem == nil && !viewModel.isLoading
    }

    var body: some View {
        NavigationStack {
            ZStack {
                RadarSweepBackdrop(accent: ADATheme.runnerGreen)
                    .edgesIgnoringSafeArea(.all)

                ScrollView {
                    VStack(spacing: 18) {
                        VStack(spacing: 8) {
                            Image(systemName: "person.badge.plus")
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundColor(ADATheme.runnerGreen)
                                .shadow(color: ADATheme.runnerGreen.opacity(0.5), radius: 14)

                            Text("PICK YOUR NAME")
                                .font(ADATheme.telemetryFont(size: 12))
                                .foregroundColor(.white.opacity(0.4))
                                .tracking(2)
                        }
                        .padding(.top, 8)

                        Text("This is how other players see you. We'll add a 4-digit tag so several people can share a name.")
                            .font(ADATheme.uiFont(size: 13))
                            .foregroundColor(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)

                        VStack(spacing: 10) {
                            ADATextField(placeholder: "Username", text: $chosen)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($fieldFocused)
                                .submitLabel(.done)
                                .onSubmit { if canSubmit { submit() } }

                            if let problem = localProblem {
                                Text(problem)
                                    .font(ADATheme.telemetryFont(size: 11))
                                    .foregroundColor(ADATheme.tacticalAmber)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .glassCard(cornerRadius: ADATheme.cardCornerRadius)
                        .padding(.horizontal)

                        if let error = viewModel.errorMessage {
                            Text(error)
                                .font(ADATheme.telemetryFont(size: 12))
                                .foregroundColor(ADATheme.hunterRed)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }

                        Button(action: submit) {
                            if viewModel.isLoading {
                                ProgressView().tint(.black)
                            } else {
                                Text("CONTINUE")
                            }
                        }
                        .buttonStyle(GlowButtonStyle(tint: ADATheme.runnerGreen, isLoading: viewModel.isLoading))
                        .padding(.horizontal)
                        .disabled(!canSubmit)

                        Button("Cancel") { viewModel.cancelSignUp() }
                            .font(ADATheme.uiFont(size: 13))
                            .foregroundColor(.white.opacity(0.45))
                            .disabled(viewModel.isLoading)
                    }
                    .adaptiveContentWidth()
                    .padding(.vertical, 24)
                    .animation(ADATheme.controlSpring, value: viewModel.errorMessage)
                    .animation(ADATheme.controlSpring, value: localProblem)
                }
            }
            .obsidianBackdrop()
            // No swipe-to-dismiss: leaving halfway would drop the verified identity on the floor
            // and the person would have to run the provider sheet again. Cancel is explicit.
            .interactiveDismissDisabled(viewModel.isLoading)
        }
        .onAppear { fieldFocused = true }
    }

    private func submit() {
        let trimmed = chosen.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await viewModel.completeSignUp(username: trimmed) }
    }
}
