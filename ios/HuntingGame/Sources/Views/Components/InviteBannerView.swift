import SwiftUI

/// A stack of incoming lobby-invite cards shown at the top of the lobby screen —
/// live-delivered via PresenceService's socket connection (with a REST fallback for
/// invites that arrived while the app was closed).
struct InviteBannerView: View {
    let invites: [GameInvite]
    let onJoin: (GameInvite) -> Void
    let onDecline: (GameInvite) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(invites) { invite in
                HStack(spacing: 10) {
                    Image(systemName: "envelope.badge.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(ADATheme.tacticalAmber)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(invite.fromUsername.uppercased()) INVITED YOU")
                            .font(ADATheme.telemetryFont(size: 12))
                            .foregroundColor(.white)
                        Text("\(invite.mode.displayName) · CODE \(invite.sessionCode)")
                            .font(ADATheme.uiFont(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                    }

                    Spacer()

                    Button {
                        onDecline(invite)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(ADATheme.hunterRed)
                    }
                    .font(.system(size: 22))

                    Button("JOIN") { onJoin(invite) }
                        .buttonStyle(GlassButtonStyle(tint: ADATheme.tacticalAmber))
                }
                .padding(12)
                .glassCard(cornerRadius: ADATheme.controlCornerRadius, tint: ADATheme.tacticalAmber)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal)
        .animation(ADATheme.controlSpring, value: invites.map(\.id))
    }
}

/// Presented after accepting an invite: pick a role (and squad name for SQUAD mode)
/// before actually joining the friend's lobby.
struct InviteJoinSheet: View {
    let invite: GameInvite
    let onConfirm: (PlayerRole, String?) async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selectedRole: PlayerRole = .runner
    @State private var squadName = ""
    @State private var isJoining = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 4) {
                    Text("JOIN \(invite.fromUsername.uppercased())'S GAME")
                        .font(ADATheme.displayFont(size: 18))
                        .foregroundColor(.white)
                    Text("\(invite.mode.displayName.uppercased()) · CODE \(invite.sessionCode)")
                        .font(ADATheme.telemetryFont(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                }
                .padding(.top, 24)

                Picker("Role", selection: $selectedRole) {
                    ForEach([PlayerRole.runner, .hunter, .spectator], id: \.self) { role in
                        Text(role.displayName).tag(role)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                if invite.mode == .squad {
                    ADATextField(placeholder: "Squad name", text: $squadName)
                        .padding(.horizontal)
                }

                Button {
                    isJoining = true
                    Task {
                        await onConfirm(selectedRole, invite.mode == .squad ? squadName : nil)
                        isJoining = false
                        dismiss()
                    }
                } label: {
                    if isJoining {
                        ProgressView().tint(.black)
                    } else {
                        HStack {
                            Image(systemName: "arrow.right.circle.fill")
                            Text("JOIN GAME")
                        }
                    }
                }
                .buttonStyle(GlowButtonStyle(tint: ADATheme.runnerGreen, isLoading: isJoining))
                .padding(.horizontal)
                .disabled(invite.mode == .squad && squadName.isEmpty)

                Spacer()
            }
            .adaptiveContentWidth()
            .obsidianBackdrop()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.white.opacity(0.6))
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
