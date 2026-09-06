import SwiftUI

struct AuthView: View {
    @StateObject private var viewModel = AuthViewModel()
    @State private var isRegisterMode = true
    @State private var hasAppeared = false

    var body: some View {
        NavigationStack {
            ZStack {
                // Same tactical radar drawing the live HUD uses (SpatialRadarView),
                // scaled up and stripped of its needle/readout — ties sign-in into
                // the same HUD system instead of a plain app-glow background. Centered
                // on the screen, not pinned to the top edge, so the full circle (and its
                // rotating sweep) reads as a circle instead of a clipped wedge.
                RadarSweepBackdrop(accent: ADATheme.runnerGreen)
                    .edgesIgnoringSafeArea(.all)

                content
            }
            .obsidianBackdrop()
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) { hasAppeared = true }
        }
    }

    /// Vertically centered when it fits the screen, scrolling normally once the error
    /// message or a taller keyboard-avoidance pushes it past a screenful — previously a
    /// plain top-anchored VStack with a trailing Spacer, which left the whole form
    /// crammed against the top edge with empty space below it.
    private var content: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 6) {
                        HuntingGameWordmark(size: 32)
                            .shadow(color: ADATheme.runnerGreen.opacity(0.5), radius: 16)

                        Text("REAL-WORLD GPS MANHUNT")
                            .font(ADATheme.telemetryFont(size: 12))
                            .foregroundColor(.white.opacity(0.4))
                            .tracking(2)

                        // Same dot+telemetry-label status row as GameView's top bar
                        // (role indicator) — reads as a live status line, not copy.
                        HStack(spacing: 6) {
                            Circle()
                                .fill(ADATheme.runnerGreen)
                                .frame(width: 6, height: 6)
                                .shadow(color: ADATheme.runnerGreen, radius: 4)
                            Text(isRegisterMode ? "NEW OPERATIVE" : "AWAITING CREDENTIALS")
                                .font(ADATheme.telemetryFont(size: 10))
                                .foregroundColor(.white.opacity(0.35))
                                .tracking(1.5)
                        }
                        .padding(.top, 4)
                    }
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
                }
                .adaptiveContentWidth()
                .padding(.vertical, 28)
                .frame(minHeight: proxy.size.height, alignment: .center)
                .frame(maxWidth: .infinity)
                .animation(ADATheme.controlSpring, value: viewModel.errorMessage)
            }
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

/// Shared text field styling for the auth/lobby forms. A solid light surface with dark
/// text, like a standard system text field, rather than a translucent dark fill — sitting
/// inside an already-dark glass card, a same-tone-as-everything-else field had almost no
/// visible boundary and didn't read as something you could tap and type into.
struct ADATextField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(FieldSurface.placeholderColor))
            .font(ADATheme.uiFont(size: 15))
            .foregroundColor(FieldSurface.textColor)
            .padding()
            .background(FieldSurface())
    }
}

struct ADASecureField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        SecureField("", text: $text, prompt: Text(placeholder).foregroundColor(FieldSurface.placeholderColor))
            .font(ADATheme.uiFont(size: 15))
            .foregroundColor(FieldSurface.textColor)
            .padding()
            .background(FieldSurface())
    }
}

/// A sunken input surface: the app's own obsidian background dropped into the lighter
/// glass card around it, with a tactical-cyan rim — reads clearly as "type here" (unlike
/// the old barely-there translucent-white fill) without breaking out of the dark theme
/// the way a plain white field would.
private struct FieldSurface: View {
    static let textColor = Color.white
    static let placeholderColor = Color.white.opacity(0.4)

    var body: some View {
        RoundedRectangle(cornerRadius: ADATheme.controlCornerRadius, style: .continuous)
            .fill(ADATheme.obsidianBackground)
            .overlay(
                RoundedRectangle(cornerRadius: ADATheme.controlCornerRadius, style: .continuous)
                    .stroke(ADATheme.spatialCyan.opacity(0.35), lineWidth: 1)
            )
    }
}

// SwiftUI's #Preview macro relies on a plugin only Xcode's live-preview
// system provides — unavailable when building headlessly via plain
// `swift build` (as the xtool/SwiftPM build path does). SWIFT_PACKAGE is
// defined automatically by SwiftPM (never by Xcode), so this keeps the
// canvas preview working in Xcode while skipping it there.
#if !SWIFT_PACKAGE
#Preview {
    AuthView()
}
#endif
