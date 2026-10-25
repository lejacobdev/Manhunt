import SwiftUI

/// Everything for getting people into a lobby: a QR code to scan off this screen, a link to send
/// (it opens the app straight into this lobby, or the App Store page for anyone without it), the
/// code to read out, and the friends list.
struct InviteSheet: View {
    let code: String
    let hostName: String?
    @Environment(\.dismiss) private var dismiss
    @State private var showFriends = false

    private var link: URL { JoinLink.shareURL(code: code) }

    private var shareMessage: String {
        "Join my Hunting Game match! Tap to join, or enter code \(code) in the app: \(link.absoluteString)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Text("SCAN TO JOIN")
                        .tacticalFont(.telemetry, size: 11)
                        .tacticalText(.secondary)
                        .tracking(2)
                        .padding(.top, 12)

                    QRCodeView(payload: link.absoluteString, size: 200)
                        .accessibilityLabel("QR code that opens this lobby")

                    VStack(spacing: 4) {
                        Text(code)
                            .tacticalFont(.display, size: 34)
                            .foregroundColor(.white)
                            .tracking(6)
                            .accessibilityLabel("Game code \(code.map(String.init).joined(separator: " "))")
                        Text("Any camera opens the lobby. People without the app get a link to install it, then type this code.")
                            .tacticalFont(.ui, size: 12, weight: .medium)
                            .tacticalText(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 24)
                    }

                    VStack(spacing: 10) {
                        ShareLink(item: link, subject: Text("Join my Hunting Game match"), message: Text(shareMessage)) {
                            HStack { Image(systemName: "square.and.arrow.up"); Text("SEND INVITE LINK") }
                        }
                        .buttonStyle(GlowButtonStyle(tint: ADATheme.runnerGreen))

                        Button {
                            showFriends = true
                        } label: {
                            HStack { Image(systemName: "person.2.fill"); Text("INVITE FROM FRIENDS") }
                        }
                        .buttonStyle(TacticalGhostButtonStyle(tint: .white))
                    }
                    .padding(.horizontal)

                    Spacer(minLength: 12)
                }
                .frame(maxWidth: .infinity)
                .adaptiveContentWidth()
            }
            .obsidianBackdrop()
            .navigationTitle("Invite Players")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(ADATheme.spatialCyan)
                }
            }
            .sheet(isPresented: $showFriends) {
                FriendsView(inviteSessionCode: code)
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// What a join link opens: whose game it is, how many are waiting, and a squad name if the mode
/// needs one. Confirming joins exactly like typing the code on Mission Control.
struct JoinLinkSheet: View {
    let code: String
    /// Returns an error message, or nil once the player is in.
    let onJoin: (_ preview: GamePreview, _ squad: String?) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var preview: GamePreview?
    @State private var loadError: String?
    @State private var squadName = ""
    @State private var isJoining = false
    @State private var joinError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let preview {
                    content(preview)
                } else if let loadError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .tacticalFont(.symbol, size: 30, weight: .bold)
                            .foregroundColor(ADATheme.tacticalAmber)
                        Text(loadError)
                            .tacticalFont(.ui, size: 14, weight: .medium)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 40)
                } else {
                    ProgressView().tint(.white).padding(.top, 60)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .adaptiveContentWidth()
            .frame(maxWidth: .infinity)
            .obsidianBackdrop()
            .navigationTitle("Join Game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .task { await load() }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func content(_ preview: GamePreview) -> some View {
        VStack(spacing: 6) {
            Text(preview.hostUsername.map { "\($0.uppercased())'S GAME" } ?? "GAME \(preview.code)")
                .tacticalFont(.display, size: 20)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            Text("\(preview.mode.displayName.uppercased()) · CODE \(preview.code)")
                .tacticalFont(.telemetry, size: 11)
                .tacticalText(.secondary)
            Text("\(preview.playerCount) player\(preview.playerCount == 1 ? "" : "s") waiting")
                .tacticalFont(.ui, size: 13, weight: .medium)
                .foregroundColor(ADATheme.runnerGreen)
                .padding(.top, 2)
        }
        .padding(.top, 24)

        if preview.status != .lobby && !preview.isMember {
            Text(preview.status == .ended ? "This match has ended. Ask for a new link." : "This match has already started. Ask the host for the next one.")
                .tacticalFont(.ui, size: 13, weight: .medium)
                .foregroundColor(ADATheme.tacticalAmber)
                .multilineTextAlignment(.center)
        } else {
            if preview.mode == .squad && !preview.isMember {
                ADATextField(placeholder: "Squad name", text: $squadName)
            }
            Text(preview.isMember ? "You're already in this game." : "The host assigns hunters and runners in the lobby.")
                .tacticalFont(.telemetry, size: 10)
                .tacticalText(.secondary)
                .multilineTextAlignment(.center)

            if let joinError {
                Text(joinError)
                    .tacticalFont(.telemetry, size: 12)
                    .foregroundColor(ADATheme.hunterRedText)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await join(preview) }
            } label: {
                if isJoining {
                    ProgressView().tint(.black)
                } else {
                    HStack { Image(systemName: "arrow.right.circle.fill"); Text(preview.isMember ? "OPEN LOBBY" : "JOIN GAME") }
                }
            }
            .buttonStyle(GlowButtonStyle(tint: ADATheme.runnerGreen, isLoading: isJoining))
            .disabled(isJoining || (preview.mode == .squad && !preview.isMember && squadName.trimmingCharacters(in: .whitespaces).isEmpty))
        }
    }

    private func load() async {
        do {
            preview = try await APIClient.shared.gamePreview(code: code)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func join(_ preview: GamePreview) async {
        isJoining = true
        defer { isJoining = false }
        let squad = preview.mode == .squad ? squadName.trimmingCharacters(in: .whitespaces) : nil
        if let error = await onJoin(preview, squad) {
            joinError = error
        } else {
            dismiss()
        }
    }
}
