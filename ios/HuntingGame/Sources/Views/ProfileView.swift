import SwiftUI

/// The signed-in player's own profile tab: career stats, achievement roster, and the QR
/// code other players scan to add them.
struct ProfileView: View {
    @StateObject private var viewModel = ProfileViewModel(source: .me)
    @EnvironmentObject var authSession: AuthSession
    @State private var showQRSheet = false

    /// The tint for this tab's own backdrop, handed down by LobbyView so it matches the
    /// other tabs' mid-swipe crossfade exactly — see the comment on its `SwipeablePager`
    /// for why each page paints its own instance instead of sharing one.
    var backdropAccent: Color = ADATheme.spatialCyan
    /// How far to shift that backdrop so it stays pinned to the screen while this page
    /// slides — supplied by the pager, and nil only when the page is fully off screen.
    /// Zero (the default) is the standalone, unpaged case.
    var backdropOffset: CGFloat? = 0

    var body: some View {
        NavigationStack {
            ZStack {
                if let backdropOffset {
                    RadarSweepBackdrop(accent: backdropAccent)
                        .edgesIgnoringSafeArea(.all)
                        .offset(x: backdropOffset)
                }

                ScrollView {
                    VStack(spacing: 18) {
                        Text("Profile")
                            .font(ADATheme.displayFont(size: 20))
                            .foregroundColor(.white)
                            .padding(.top, 8)

                        ProfileBody(viewModel: viewModel, fallbackUser: authSession.currentUser)

                        if viewModel.profile != nil {
                            Button {
                                showQRSheet = true
                            } label: {
                                HStack { Image(systemName: "qrcode"); Text("MY FRIEND CODE") }
                            }
                            .buttonStyle(GlowButtonStyle(tint: ADATheme.spatialCyan))
                            .padding(.horizontal)
                        }

                        Button("SIGN OUT") {
                            Task {
                                // Unregister while the auth token is still valid to make the
                                // call with — a signed-out device shouldn't keep receiving
                                // this account's pushes.
                                await PushNotificationManager.shared.unregisterCurrentToken()
                                authSession.signOut()
                            }
                        }
                        .font(ADATheme.telemetryFont(size: 11))
                        .foregroundColor(.white.opacity(0.3))
                        .tracking(1.5)
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 20)
                    .adaptiveContentWidth()
                }
                .refreshable { await viewModel.load() }
            }
            // The sweep itself is translucent, so it needs a dark ground of its own rather
            // than relying on whatever the enclosing NavigationStack happens to fill with.
            .obsidianBackdrop()
            .task { await viewModel.load() }
            .sheet(isPresented: $showQRSheet) {
                if let user = viewModel.profile?.user {
                    FriendCodeSheet(username: user.username, userTag: user.userTag)
                }
            }
        }
    }
}

/// A friend's profile, pushed from the friends list. Same body as your own, minus the
/// account controls that only make sense for yourself.
struct PublicProfileView: View {
    let userId: String
    let displayName: String

    @StateObject private var viewModel: ProfileViewModel

    init(userId: String, displayName: String) {
        self.userId = userId
        self.displayName = displayName
        _viewModel = StateObject(wrappedValue: ProfileViewModel(source: .user(id: userId)))
    }

    var body: some View {
        ZStack {
            RadarSweepBackdrop(accent: ADATheme.runnerGreen)
                .edgesIgnoringSafeArea(.all)

            ScrollView {
                ProfileBody(viewModel: viewModel, fallbackUser: nil)
                    .padding(.vertical, 20)
                    .adaptiveContentWidth()
            }
        }
        .obsidianBackdrop()
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await viewModel.load() }
    }
}

// MARK: - Shared body

private struct ProfileBody: View {
    @ObservedObject var viewModel: ProfileViewModel
    /// Shown while the real profile is still loading, so the header doesn't pop in blank
    /// on your own tab where the username is already known locally.
    let fallbackUser: AppUser?

    var body: some View {
        VStack(spacing: 18) {
            header

            if let error = viewModel.errorMessage, viewModel.profile == nil {
                Text(error)
                    .font(ADATheme.telemetryFont(size: 12))
                    .foregroundColor(ADATheme.hunterRed)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if viewModel.isLoading && viewModel.profile == nil {
                ProgressView().tint(ADATheme.spatialCyan).padding(.top, 20)
            }

            if let profile = viewModel.profile {
                statTiles(profile.stats)
                breakdown(profile.stats)
                achievements(profile.achievements)
            }
        }
        .animation(ADATheme.controlSpring, value: viewModel.profile)
    }

    private var header: some View {
        let profileUser = viewModel.profile?.user
        let name = profileUser?.username ?? fallbackUser?.username ?? "—"
        let label = profileUser?.tagLabel ?? fallbackUser?.tagLabel ?? ""
        let isOnline = profileUser?.isOnline ?? false

        return VStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(ADATheme.spatialCyan.opacity(0.18))
                    .frame(width: 84, height: 84)
                    .overlay(
                        Text(name.prefix(1).uppercased())
                            .font(ADATheme.displayFont(size: 34))
                            .foregroundColor(ADATheme.spatialCyan)
                    )
                    .overlay(Circle().stroke(ADATheme.spatialCyan.opacity(0.4), lineWidth: 1))

                if isOnline {
                    Circle()
                        .fill(ADATheme.runnerGreen)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(ADATheme.obsidianBackground, lineWidth: 3))
                        .shadow(color: ADATheme.runnerGreen, radius: 5)
                }
            }

            Text(label)
                .font(ADATheme.displayFont(size: 20))
                .foregroundColor(.white)

            if let since = profileUser?.memberSinceLabel {
                Text("PLAYING SINCE \(since.uppercased())")
                    .font(ADATheme.telemetryFont(size: 10))
                    .foregroundColor(.white.opacity(0.35))
                    .tracking(1.5)
            }
        }
    }

    // MARK: Stats

    private func statTiles(_ stats: ProfileStats) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            statTile("MATCHES", "\(stats.matchesPlayed)", ADATheme.spatialCyan)
            statTile("WINS", "\(stats.wins)", ADATheme.runnerGreen)
            statTile("WIN RATE", "\(stats.winRatePercent)%", ADATheme.tacticalAmber)
            statTile("CATCHES", "\(stats.catchesMade)", ADATheme.hunterRed)
            statTile("PLAYTIME", stats.playtimeLabel, ADATheme.spatialCyan)
        }
        .padding(.horizontal)
    }

    private func statTile(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(ADATheme.displayFont(size: 22))
                .foregroundColor(tint)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(label)
                .font(ADATheme.telemetryFont(size: 9))
                .foregroundColor(.white.opacity(0.4))
                .tracking(1)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .glassCard(cornerRadius: ADATheme.controlCornerRadius)
    }

    private func breakdown(_ stats: ProfileStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CAREER")
                .font(ADATheme.telemetryFont(size: 11))
                .foregroundColor(.white.opacity(0.4))
                .padding(.leading, 4)

            VStack(spacing: 0) {
                breakdownRow("figure.run", "Matches as hunter", "\(stats.matchesAsHunter)")
                breakdownRow("figure.walk", "Matches as runner", "\(stats.matchesAsRunner)")
                breakdownRow("hand.raised.fill", "Times caught", "\(stats.timesCaught)")
                breakdownRow("heart.slash.fill", "Times eliminated", "\(stats.timesEliminated)")
                breakdownRow("star.fill", "Matches hosted", "\(stats.matchesHosted)")
                breakdownRow("shippingbox.fill", "Power-ups collected", "\(stats.powerUpsCollected)")
                breakdownRow("circle.grid.2x2.fill", "Coin flips won", "\(stats.gamblesWon)", last: true)
            }
            .padding(.vertical, 4)
            .glassCard(cornerRadius: ADATheme.cardCornerRadius)
        }
        .padding(.horizontal)
    }

    private func breakdownRow(_ icon: String, _ label: String, _ value: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(ADATheme.spatialCyan)
                    .frame(width: 20)
                Text(label)
                    .font(ADATheme.uiFont(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                Spacer()
                Text(value)
                    .font(ADATheme.telemetryFont(size: 13))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            if !last {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)
                    .padding(.leading, 44)
            }
        }
    }

    // MARK: Achievements

    private func achievements(_ list: [Achievement]) -> some View {
        let unlocked = list.filter(\.unlocked).count
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ACHIEVEMENTS")
                    .font(ADATheme.telemetryFont(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                Spacer()
                Text("\(unlocked)/\(list.count)")
                    .font(ADATheme.telemetryFont(size: 11))
                    .foregroundColor(ADATheme.tacticalAmber)
            }
            .padding(.horizontal, 4)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                ForEach(list) { achievement in
                    achievementCard(achievement)
                }
            }
        }
        .padding(.horizontal)
    }

    private func achievementCard(_ achievement: Achievement) -> some View {
        let tint = achievement.unlocked ? ADATheme.tacticalAmber : Color.white.opacity(0.25)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: achievement.icon)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(tint)
                    .shadow(color: achievement.unlocked ? tint.opacity(0.6) : .clear, radius: 6)
                Spacer()
                if achievement.unlocked {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 12))
                        .foregroundColor(ADATheme.tacticalAmber)
                }
            }

            Text(achievement.title.uppercased())
                .font(ADATheme.telemetryFont(size: 11))
                .foregroundColor(achievement.unlocked ? .white : .white.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(achievement.description)
                .font(ADATheme.uiFont(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Locked cards show how far along you are; unlocked ones don't need a bar
            // that's always full, so they get the earned total instead.
            if achievement.unlocked {
                Text("EARNED")
                    .font(ADATheme.telemetryFont(size: 9))
                    .foregroundColor(ADATheme.tacticalAmber.opacity(0.8))
            } else {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(ADATheme.spatialCyan.opacity(0.7))
                            .frame(width: proxy.size.width * achievement.fractionComplete)
                    }
                }
                .frame(height: 4)

                Text("\(achievement.progress)/\(achievement.goal)")
                    .font(ADATheme.telemetryFont(size: 9))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .glassCard(cornerRadius: ADATheme.controlCornerRadius, tint: achievement.unlocked ? ADATheme.tacticalAmber : .white)
        .opacity(achievement.unlocked ? 1 : 0.72)
    }
}

// MARK: - Friend code

/// The player's own QR code, plus the raw tag for anyone typing it in by hand.
struct FriendCodeSheet: View {
    let username: String
    let userTag: String
    @Environment(\.dismiss) private var dismiss

    private var shareURL: String { FriendLink.shareURL(username: username, userTag: userTag) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("SCAN TO ADD ME")
                    .font(ADATheme.telemetryFont(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                    .tracking(2)
                    .padding(.top, 20)

                QRCodeView(payload: shareURL)

                Text("\(username)#\(userTag)")
                    .font(ADATheme.displayFont(size: 22))
                    .foregroundColor(.white)

                Text("Any camera app can scan this — it opens Hunting Game and sends the friend request.")
                    .font(ADATheme.uiFont(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                ShareLink(item: shareURL) {
                    HStack { Image(systemName: "square.and.arrow.up"); Text("SHARE LINK") }
                }
                .buttonStyle(GlassButtonStyle(tint: ADATheme.spatialCyan))

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .adaptiveContentWidth()
            .obsidianBackdrop()
            .navigationTitle("Friend Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(ADATheme.spatialCyan)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
