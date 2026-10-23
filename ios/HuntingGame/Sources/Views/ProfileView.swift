import SwiftUI

/// The signed-in player's own profile tab: career stats, achievement roster, and the QR
/// code other players scan to add them.
struct ProfileView: View {
    @StateObject private var viewModel = ProfileViewModel(source: .me)
    @EnvironmentObject var authSession: AuthSession
    @State private var showQRSheet = false
    @State private var showDeleteConfirm = false
    @State private var isDeletingAccount = false
    @State private var deleteError: String?

    /// No backdrop or NavigationStack of its own — LobbyView owns both, so its stationary
    /// backdrop simply shows through this page.
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("Profile")
                    .tacticalFont(.display, size: 20)
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

                NavigationLink {
                    CosmeticsView()
                    .clearsFloatingTabBar()
                } label: {
                    HStack { Image(systemName: "paintpalette.fill"); Text("CUSTOMIZE") }
                }
                .buttonStyle(TacticalGhostButtonStyle(tint: ADATheme.stealthPurple))
                .padding(.horizontal)

                NavigationLink {
                    AccountSettingsView()
                    .clearsFloatingTabBar()
                } label: {
                    HStack { Image(systemName: "person.text.rectangle"); Text("NAME & SIGN-IN") }
                }
                .buttonStyle(TacticalGhostButtonStyle(tint: ADATheme.spatialCyan))
                .padding(.horizontal)

                GameCenterCard()

                NavigationLink {
                    RulesView()
                    .clearsFloatingTabBar()
                } label: {
                    HStack { Image(systemName: "list.bullet.rectangle"); Text("GAME RULES") }
                }
                .buttonStyle(TacticalGhostButtonStyle(tint: ADATheme.tacticalAmber))
                .padding(.horizontal)

                NavigationLink {
                    BlockedUsersView()
                    .clearsFloatingTabBar()
                } label: {
                    HStack { Image(systemName: "hand.raised.fill"); Text("BLOCKED USERS") }
                }
                .buttonStyle(TacticalGhostButtonStyle(tint: .white.opacity(0.6)))
                .padding(.horizontal)

                Button("SIGN OUT") {
                    Task {
                        // Unregister while the auth token is still valid to make the
                        // call with — a signed-out device shouldn't keep receiving
                        // this account's pushes.
                        await PushNotificationManager.shared.unregisterCurrentToken()
                        authSession.signOut()
                    }
                }
                .tacticalFont(.telemetry, size: 11)
                .tacticalText(.tertiary)
                .tracking(1.5)
                .padding(.top, 4)

                Button {
                    showDeleteConfirm = true
                } label: {
                    if isDeletingAccount {
                        ProgressView().tint(ADATheme.hunterRed)
                    } else {
                        Text("DELETE ACCOUNT")
                    }
                }
                .tacticalFont(.telemetry, size: 11)
                .foregroundColor(ADATheme.hunterRed.opacity(0.7))
                .tracking(1.5)
                .disabled(isDeletingAccount)
            }
            .padding(.vertical, 20)
            .adaptiveContentWidth()
        }
        .refreshable { await viewModel.load() }
        .task { await viewModel.load() }
        .sheet(isPresented: $showQRSheet) {
            if let user = viewModel.profile?.user {
                FriendCodeSheet(username: user.username, userTag: user.userTag)
            }
        }
        .confirmationDialog("Delete your account?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) { Task { await deleteAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your profile, friendships, and match history. It cannot be undone.")
        }
        .alert("Couldn't delete account", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    private func deleteAccount() async {
        isDeletingAccount = true
        defer { isDeletingAccount = false }
        do {
            try await APIClient.shared.deleteAccount()
            await PushNotificationManager.shared.unregisterCurrentToken()
            authSession.signOut()
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

/// A friend's profile, pushed from the friends list. Same body as your own, minus the
/// account controls that only make sense for yourself.
struct PublicProfileView: View {
    let userId: String
    let displayName: String

    @StateObject private var viewModel: ProfileViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showReportSheet = false
    @State private var showBlockConfirm = false
    @State private var isSubmitting = false
    @State private var actionError: String?

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
        .toolbar { reportBlockToolbarContent }
        .task { await viewModel.load() }
        .sheet(isPresented: $showReportSheet) {
            ReportSheet(displayName: displayName) { category, detail in
                await submitReport(category: category, detail: detail)
            }
        }
        .confirmationDialog("Block \(displayName)?", isPresented: $showBlockConfirm, titleVisibility: .visible) {
            Button("Block User", role: .destructive) { Task { await block() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They'll be removed from your friends list and won't be able to see you or contact you again.")
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .disabled(isSubmitting)
    }

    // App Store guideline 1.2 (user-generated content) requires both a way to flag
    // objectionable content and a way to block the account it came from — this menu is that
    // mechanism, reachable from any player's profile. Pulled out of `body` into its own
    // `@ToolbarContentBuilder` property rather than inlined, since the Swift type-checker
    // struggled to resolve the long modifier chain in `body` with this nested `Menu` inline.
    @ToolbarContentBuilder
    private var reportBlockToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    showReportSheet = true
                } label: {
                    Label("Report User", systemImage: "flag.fill")
                }
                Button(role: .destructive) {
                    showBlockConfirm = true
                } label: {
                    Label("Block User", systemImage: "hand.raised.fill")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundColor(.white)
            }
        }
    }

    /// Returns an error message for the sheet to show, or nil once it's filed.
    private func submitReport(category: ReportCategory, detail: String?) async -> String? {
        do {
            try await APIClient.shared.reportUser(id: userId, category: category.rawValue, detail: detail)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func block() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await APIClient.shared.blockUser(id: userId)
            dismiss()
        } catch {
            actionError = error.localizedDescription
        }
    }
}

// MARK: - Shared body

private struct ProfileBody: View {
    @ObservedObject var viewModel: ProfileViewModel
    /// Shown while the real profile is still loading, so the header doesn't pop in blank
    /// on your own tab where the username is already known locally.
    let fallbackUser: AppUser?
    @ObservedObject private var cosmetics = CosmeticsStore.shared

    /// Your own profile shows what you just equipped; anyone else's shows what the server says.
    private var isMine: Bool { fallbackUser != nil }
    private var banner: String? { isMine ? cosmetics.equipped["banner"] ?? viewModel.profile?.user.banner : viewModel.profile?.user.banner }
    private var badge: String? { isMine ? cosmetics.equipped["badge"] ?? viewModel.profile?.user.badge : viewModel.profile?.user.badge }

    var body: some View {
        VStack(spacing: 18) {
            // The hero: identity and the headline numbers on one glass surface. The stat tiles
            // inside it render as insets, never as glass on glass.
            VStack(spacing: 16) {
                header
                if let profile = viewModel.profile {
                    statTiles(profile.stats)
                }
            }
            .padding(.vertical, 20)
            .padding(.top, 6)
            // The equipped banner: a gradient strip across the top of the card, and its tint.
            .overlay(alignment: .top) {
                LinearGradient(colors: CosmeticStyle.bannerColors(banner), startPoint: .leading, endPoint: .trailing)
                    .frame(height: 6)
                    .accessibilityHidden(true)
            }
            .glassCard(cornerRadius: ADATheme.sheetCornerRadius, tint: CosmeticStyle.bannerTint(banner))
            .padding(.horizontal)

            if let error = viewModel.errorMessage, viewModel.profile == nil {
                Text(error)
                    .tacticalFont(.telemetry, size: 12)
                    .foregroundColor(ADATheme.hunterRedText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if viewModel.isLoading && viewModel.profile == nil {
                ProgressView().tint(ADATheme.spatialCyan).padding(.top, 20)
            }

            if let profile = viewModel.profile {
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
                            .tacticalFont(.display, size: 34)
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
                .tacticalFont(.display, size: 20)
                .foregroundColor(.white)

            CosmeticBadgeView(id: badge)

            if let since = profileUser?.memberSinceLabel {
                Text("PLAYING SINCE \(since.uppercased())")
                    .tacticalFont(.telemetry, size: 10)
                    .tacticalText(.tertiary)
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
        .padding(.horizontal, 14)
    }

    private func statTile(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .tacticalFont(.display, size: 22)
                .foregroundColor(tint)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(label)
                .tacticalFont(.telemetry, size: 9)
                .tacticalText(.secondary)
                .tracking(1)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .glassCard(cornerRadius: ADATheme.controlCornerRadius)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label.capitalized): \(value)")
    }

    private func breakdown(_ stats: ProfileStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CAREER")
                .tacticalFont(.telemetry, size: 11)
                .tacticalText(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                breakdownRow("figure.run", "Matches as hunter", "\(stats.matchesAsHunter)")
                breakdownRow("figure.walk", "Matches as runner", "\(stats.matchesAsRunner)")
                breakdownRow("hand.raised.fill", "Times caught", "\(stats.timesCaught)")
                breakdownRow("heart.slash.fill", "Times eliminated", "\(stats.timesEliminated)")
                breakdownRow("star.fill", "Matches hosted", "\(stats.matchesHosted)")
                breakdownRow("shippingbox.fill", "Power-ups collected", "\(stats.powerUpsCollected)", last: true)
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
                    .tacticalFont(.symbol, size: 12, weight: .semibold)
                    .foregroundColor(ADATheme.spatialCyan)
                    .frame(width: 20)
                Text(label)
                    .tacticalFont(.ui, size: 13, weight: .medium)
                    .foregroundColor(.white.opacity(0.75))
                Spacer()
                Text(value)
                    .tacticalFont(.telemetry, size: 13)
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
                    .tacticalFont(.telemetry, size: 11)
                    .tacticalText(.secondary)
                Spacer()
                Text("\(unlocked)/\(list.count)")
                    .tacticalFont(.telemetry, size: 11)
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
                    .tacticalFont(.symbol, size: 15, weight: .bold)
                    .foregroundColor(tint)
                    .shadow(color: achievement.unlocked ? tint.opacity(0.6) : .clear, radius: 6)
                Spacer()
                progressRing(achievement)
            }

            Text(achievement.title.uppercased())
                .tacticalFont(.telemetry, size: 11)
                .foregroundColor(achievement.unlocked ? .white : .white.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(achievement.description)
                .tacticalFont(.ui, size: 10, weight: .medium)
                .tacticalText(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Locked cards show how far along you are; unlocked ones don't need a bar
            // that's always full, so they get the earned total instead.
            Text(achievement.unlocked ? "EARNED" : "\(achievement.progress)/\(achievement.goal)")
                .tacticalFont(.telemetry, size: 9)
                .foregroundColor(achievement.unlocked ? ADATheme.tacticalAmber.opacity(0.8) : .white.opacity(0.35))
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .glassCard(cornerRadius: ADATheme.cardCornerRadius, tint: achievement.unlocked ? ADATheme.tacticalAmber : .clear)
        .opacity(achievement.unlocked ? 1 : 0.78)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(achievement.title)
        .accessibilityValue(achievement.unlocked ? "Earned. \(achievement.description)" : "\(achievement.progress) of \(achievement.goal). \(achievement.description)")
    }

    /// Locked achievements show how far along you are; earned ones a full ring with a check.
    private func progressRing(_ achievement: Achievement) -> some View {
        let tint = achievement.unlocked ? ADATheme.tacticalAmber : ADATheme.spatialCyan
        return ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 3)
            Circle()
                .trim(from: 0, to: achievement.unlocked ? 1 : achievement.fractionComplete)
                .stroke(tint.opacity(0.85), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if achievement.unlocked {
                Image(systemName: "checkmark")
                    .tacticalFont(.symbol, size: 9, weight: .heavy)
                    .foregroundColor(tint)
            }
        }
        .frame(width: 24, height: 24)
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
                    .tacticalFont(.telemetry, size: 11)
                    .tacticalText(.secondary)
                    .tracking(2)
                    .padding(.top, 20)

                QRCodeView(payload: shareURL)

                Text("\(username)#\(userTag)")
                    .tacticalFont(.display, size: 22)
                    .foregroundColor(.white)

                Text("Any camera app can scan this — it opens Hunting Game and sends the friend request.")
                    .tacticalFont(.ui, size: 12, weight: .medium)
                    .tacticalText(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                ShareLink(item: shareURL) {
                    HStack { Image(systemName: "square.and.arrow.up"); Text("SHARE LINK") }
                }
                .buttonStyle(TacticalGhostButtonStyle(tint: ADATheme.spatialCyan))

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
