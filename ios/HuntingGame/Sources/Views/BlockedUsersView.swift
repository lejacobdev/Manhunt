import SwiftUI

/// Lets a player review and reverse blocks made from `PublicProfileView` — App Store
/// guideline 1.2 requires a block mechanism, and a block with no way back would be a poor
/// one, so this is reachable from the player's own Profile tab.
struct BlockedUsersView: View {
    @State private var blocked: [AppUser] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var unblockingId: String?

    var body: some View {
        ZStack {
            RadarSweepBackdrop(accent: ADATheme.hunterRed)
                .edgesIgnoringSafeArea(.all)

            ScrollView {
                VStack(spacing: 12) {
                    if isLoading && blocked.isEmpty {
                        ProgressView().tint(ADATheme.spatialCyan).padding(.top, 40)
                    } else if blocked.isEmpty {
                        Text("You haven't blocked anyone.")
                            .font(ADATheme.uiFont(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.35))
                            .padding(.top, 40)
                    } else {
                        ForEach(blocked) { user in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(.white.opacity(0.15))
                                    .frame(width: 28, height: 28)
                                    .overlay(
                                        Text(user.username.prefix(1).uppercased())
                                            .font(ADATheme.telemetryFont(size: 11))
                                            .foregroundColor(.white.opacity(0.6))
                                    )
                                Text(user.tagLabel)
                                    .font(ADATheme.uiFont(size: 13))
                                    .foregroundColor(.white)
                                Spacer()
                                Button {
                                    Task { await unblock(user) }
                                } label: {
                                    if unblockingId == user.id {
                                        ProgressView().tint(ADATheme.spatialCyan)
                                    } else {
                                        Text("UNBLOCK")
                                    }
                                }
                                .buttonStyle(GlassButtonStyle(tint: ADATheme.spatialCyan))
                                .disabled(unblockingId != nil)
                            }
                            .padding(12)
                            .glassCard(cornerRadius: ADATheme.controlCornerRadius)
                            .transition(.scale.combined(with: .opacity))
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(ADATheme.telemetryFont(size: 12))
                            .foregroundColor(ADATheme.hunterRed)
                    }
                }
                .padding()
                .adaptiveContentWidth()
                .animation(ADATheme.controlSpring, value: blocked.map(\.id))
            }
        }
        .obsidianBackdrop()
        .navigationTitle("Blocked Users")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            blocked = try await APIClient.shared.blockedUsers()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func unblock(_ user: AppUser) async {
        unblockingId = user.id
        defer { unblockingId = nil }
        do {
            try await APIClient.shared.unblockUser(id: user.id)
            blocked.removeAll { $0.id == user.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
