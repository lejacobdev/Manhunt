import SwiftUI

struct AuthView: View {
    @StateObject private var viewModel = AuthViewModel()
    @State private var isRegisterMode = true
    @State private var hasAppeared = false

    var body: some View {
        NavigationStack {
            ZStack {
                RadialGradient(
                    colors: [ADATheme.runnerGreen.opacity(0.12), .clear],
                    center: .top,
                    startRadius: 20,
                    endRadius: 420
                )
                .edgesIgnoringSafeArea(.all)

                VStack(spacing: 20) {
                    VStack(spacing: 6) {
                        Text("HUNTING GAME")
                            .font(ADATheme.displayFont(size: 32))
                            .foregroundColor(.white)
                            .shadow(color: ADATheme.runnerGreen.opacity(0.5), radius: 16)

                        Text("REAL-WORLD GPS MANHUNT")
                            .font(ADATheme.telemetryFont(size: 12))
                            .foregroundColor(.white.opacity(0.4))
                            .tracking(2)
                    }
                    .padding(.top, 60)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : -12)

                    Picker("Mode", selection: $isRegisterMode.animation(ADATheme.controlSpring)) {
                        Text("Register").tag(true)
                        Text("Login").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 12)

                    VStack(spacing: 12) {
                        ADATextField(placeholder: "Username", text: $viewModel.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        if !isRegisterMode {
                            ADATextField(placeholder: "Tag (e.g. 4921)", text: $viewModel.userTag)
                                .keyboardType(.numberPad)
                                .transition(.scale.combined(with: .opacity))
                        }

                        ADASecureField(placeholder: "Password", text: $viewModel.password)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .glassCard(cornerRadius: ADATheme.cardCornerRadius)
                    .padding(.horizontal)

                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(ADATheme.telemetryFont(size: 12))
                            .foregroundColor(ADATheme.hunterRed)
                            .padding(.horizontal)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    Button(action: submit) {
                        if viewModel.isLoading {
                            ProgressView()
                                .tint(.black)
                        } else {
                            Text(isRegisterMode ? "CREATE ACCOUNT" : "LOG IN")
                        }
                    }
                    .buttonStyle(GlowButtonStyle(tint: ADATheme.runnerGreen, isLoading: viewModel.isLoading))
                    .padding(.horizontal)
                    .disabled(viewModel.isLoading)

                    Spacer()
                }
                .animation(ADATheme.controlSpring, value: viewModel.errorMessage)
            }
            .obsidianBackdrop()
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) { hasAppeared = true }
        }
    }

    private func submit() {
        Task {
            if isRegisterMode {
                await viewModel.register()
            } else {
                await viewModel.login()
            }
        }
    }
}

/// Shared glass-surfaced text field styling for the auth/lobby forms.
struct ADATextField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(.white.opacity(0.35)))
            .font(ADATheme.uiFont(size: 15))
            .foregroundColor(.white)
            .padding()
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: ADATheme.controlCornerRadius, style: .continuous))
    }
}

struct ADASecureField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        SecureField("", text: $text, prompt: Text(placeholder).foregroundColor(.white.opacity(0.35)))
            .font(ADATheme.uiFont(size: 15))
            .foregroundColor(.white)
            .padding()
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: ADATheme.controlCornerRadius, style: .continuous))
    }
}

#Preview {
    AuthView()
}
