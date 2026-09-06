import SwiftUI

/// Adds a friend from a QR code — either scanned live in-app, or handed straight to us by
/// the `huntinggame://add-friend` deep link when the code was scanned by the system camera
/// outside the app. Both paths converge on the same confirm step: resolve the tag to a real
/// account, show who it is, then send the request on an explicit tap. Nothing is sent just
/// because a link was opened.
struct AddFriendSheet: View {
    enum Mode: Equatable {
        case scan
        case handle(FriendLink.Handle)
    }

    let mode: Mode
    /// Called after a request is actually sent, so the friends list can refresh itself.
    var onSent: (() -> Void)? = nil

    @EnvironmentObject var authSession: AuthSession
    @Environment(\.dismiss) private var dismiss
    @State private var resolved: AppUser?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var sentMessage: String?
    /// The other direction of adding a friend: you point your camera at *their* code by
    /// default here, but they might expect to scan yours instead — this surfaces it
    /// without backing out to Profile.
    @State private var showMyCode = false

    var body: some View {
        NavigationStack {
            ZStack {
                if resolved == nil && errorMessage == nil && sentMessage == nil, case .scan = mode {
                    scanner
                } else {
                    resultCard
                }
            }
            .obsidianBackdrop()
            .navigationTitle("Add Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(sentMessage == nil ? "Cancel" : "Done") { dismiss() }
                        .foregroundColor(ADATheme.spatialCyan)
                }
            }
            .task {
                if case .handle(let handle) = mode { await resolve(handle) }
            }
            .sheet(isPresented: $showMyCode) {
                if let me = authSession.currentUser {
                    FriendCodeSheet(username: me.username, userTag: me.userTag)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Scanning

    private var scanner: some View {
        ZStack {
            QRScannerView(
                onScan: { value in
                    guard let handle = FriendLink.parse(value) else {
                        errorMessage = "That isn't a Hunting Game friend code."
                        return
                    }
                    Task { await resolve(handle) }
                },
                onFailure: { errorMessage = $0 }
            )
            .edgesIgnoringSafeArea(.all)

            // Reticle over the live preview — the camera fills the screen, so without a
            // frame there's nothing telling the player where to aim.
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(ADATheme.spatialCyan.opacity(0.9), lineWidth: 3)
                .frame(width: 240, height: 240)
                .shadow(color: ADATheme.spatialCyan.opacity(0.5), radius: 12)

            VStack(spacing: 14) {
                Spacer()
                Text("POINT AT A FRIEND CODE")
                    .font(ADATheme.telemetryFont(size: 11))
                    .foregroundColor(.white.opacity(0.8))
                    .tracking(2)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .glassCard(cornerRadius: ADATheme.controlCornerRadius, tint: ADATheme.spatialCyan)

                // The other half of adding a friend by QR — they might expect to scan
                // yours instead of you scanning theirs, so it's offered right here rather
                // than making them back out to Profile to find it.
                if authSession.currentUser != nil {
                    Button {
                        showMyCode = true
                    } label: {
                        HStack { Image(systemName: "qrcode"); Text("MY FRIEND CODE") }
                    }
                    .buttonStyle(GlassButtonStyle(tint: ADATheme.tacticalAmber))
                }
            }
            .padding(.bottom, 44)
        }
    }

    // MARK: - Resolve / confirm

    private var resultCard: some View {
        VStack(spacing: 18) {
            Spacer()

            if isWorking {
                ProgressView().tint(ADATheme.spatialCyan)
            } else if let message = sentMessage {
                statusCard(icon: "checkmark.seal.fill", tint: ADATheme.runnerGreen, title: "REQUEST SENT", detail: message)
            } else if let error = errorMessage {
                statusCard(icon: "exclamationmark.triangle.fill", tint: ADATheme.hunterRed, title: "COULDN'T ADD", detail: error)
            } else if let user = resolved {
                VStack(spacing: 14) {
                    Circle()
                        .fill(ADATheme.spatialCyan.opacity(0.18))
                        .frame(width: 72, height: 72)
                        .overlay(
                            Text(user.username.prefix(1).uppercased())
                                .font(ADATheme.displayFont(size: 30))
                                .foregroundColor(ADATheme.spatialCyan)
                        )
                    Text(user.tagLabel)
                        .font(ADATheme.displayFont(size: 20))
                        .foregroundColor(.white)
                    Text("Send them a friend request?")
                        .font(ADATheme.uiFont(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))

                    Button {
                        Task { await send(to: user) }
                    } label: {
                        HStack { Image(systemName: "person.badge.plus"); Text("SEND REQUEST") }
                    }
                    .buttonStyle(GlowButtonStyle(tint: ADATheme.runnerGreen))
                }
                .padding(26)
                .glassCard(cornerRadius: ADATheme.sheetCornerRadius, tint: ADATheme.spatialCyan)
            }

            Spacer()
        }
        .padding(.horizontal, 28)
        .adaptiveContentWidth()
        .animation(ADATheme.controlSpring, value: resolved)
        .animation(ADATheme.controlSpring, value: sentMessage)
        .animation(ADATheme.controlSpring, value: errorMessage)
    }

    private func statusCard(icon: String, tint: Color, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(tint)
                .shadow(color: tint.opacity(0.6), radius: 10)
            Text(title)
                .font(ADATheme.displayFont(size: 18))
                .foregroundColor(.white)
            Text(detail)
                .font(ADATheme.uiFont(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .padding(26)
        .glassCard(cornerRadius: ADATheme.sheetCornerRadius, tint: tint)
    }

    private func resolve(_ handle: FriendLink.Handle) async {
        isWorking = true
        defer { isWorking = false }
        if handle.label.caseInsensitiveCompare(AuthSession.shared.currentUser?.tagLabel ?? "") == .orderedSame {
            errorMessage = "That's your own friend code."
            return
        }
        do {
            resolved = try await APIClient.shared.lookupUser(username: handle.username, userTag: handle.userTag)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func send(to user: AppUser) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await APIClient.shared.sendFriendRequest(receiverId: user.id)
            sentMessage = "\(user.tagLabel) will see your request in their Friends tab."
            onSent?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
