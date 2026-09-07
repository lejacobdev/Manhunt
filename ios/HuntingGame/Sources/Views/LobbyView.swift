import SwiftUI
import CoreLocation

struct LobbyView: View {
    @StateObject private var viewModel = LobbyViewModel()
    @StateObject private var locationManager = LocationManager()
    @EnvironmentObject var authSession: AuthSession
    @EnvironmentObject var presence: PresenceService
    @ObservedObject private var deepLinkRouter = DeepLinkRouter.shared
    @ObservedObject private var updateChecker = UpdateChecker.shared
    @State private var showHistory = false
    @State private var joiningInvite: GameInvite?
    @State private var launchedGame: (player: GamePlayer, session: GameSession)?
    @State private var selectedTab: AppTab = .play
    /// Continuous [0, 3] position across the 4 tabs, fractional mid-swipe — drives the
    /// shared backdrop's interpolated tint. Kept in sync with `selectedTab` on a tap-driven
    /// switch too (see the `onChange` below), so tapping a tab crossfades the color exactly
    /// the same way swiping to it would, instead of only the swipe gesture animating it.
    @State private var pageProgress: Double = 0

    private var interpolatedBackdropAccent: Color {
        let tabs = AppTab.allCases
        let clamped = min(max(pageProgress, 0), Double(tabs.count - 1))
        let lowerIndex = Int(clamped.rounded(.down))
        let upperIndex = min(lowerIndex + 1, tabs.count - 1)
        return Color.interpolate(from: tabs[lowerIndex].accent, to: tabs[upperIndex].accent, fraction: clamped - Double(lowerIndex))
    }

    var body: some View {
        // Replaces the system TabView chrome with a floating pill + circle (see
        // FloatingTabBar), and its swipe-between-pages gesture with a hand-rolled one (see
        // SwipeablePager) — SwiftUI's TabView has no supported way to swap out its own
        // bottom bar's visual, and its page style doesn't expose continuous drag progress,
        // which the shared backdrop below needs to crossfade its tint smoothly while
        // dragging rather than snapping once a swipe settles.
        ZStack(alignment: .bottom) {
            // One shared backdrop instead of each tab owning its own — its rotation was
            // already synchronized process-wide (see RadarSweepBackdrop), and hoisting it
            // here means switching or swiping between tabs only ever crossfades this single
            // instance's *color*, with the sweep itself never restarting or jumping.
            RadarSweepBackdrop(accent: interpolatedBackdropAccent)
                .edgesIgnoringSafeArea(.all)

            SwipeablePager(
                tabs: AppTab.allCases,
                selection: $selectedTab,
                onProgressChange: { pageProgress = $0 }
            ) { tab in
                switch tab {
                case .play: playTab
                case .friends: FriendsView()
                case .leaderboard: LeaderboardView()
                case .profile: ProfileView()
                }
            }
            // Reserves room at the bottom of every tab's own scroll content so the last
            // row/button isn't sitting underneath the floating bar drawn on top of it.
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 78)
            }

            FloatingTabBar(selection: $selectedTab)
        }
        .tint(ADATheme.runnerGreen)
        .preferredColorScheme(.dark)
        .onChange(of: selectedTab) { newValue in
            guard let index = AppTab.allCases.firstIndex(of: newValue) else { return }
            withAnimation(ADATheme.controlSpring) { pageProgress = Double(index) }
        }
        // A scanned friend code can arrive at any moment — including while a match is on
        // screen — so the prompt is mounted at the tab root rather than inside Friends,
        // which may not be the selected tab when the link opens.
        .sheet(item: $deepLinkRouter.pendingFriend) { handle in
            AddFriendSheet(mode: .handle(handle))
        }
    }

    private var playTab: some View {
        NavigationStack {
            // No backdrop of its own — this is only ever used as a tab, and LobbyView's
            // shared RadarSweepBackdrop (crossfading tint as the pager swipes) shows
            // through from behind it.
            //
            // Vertically centered rather than stacked from the top edge: this screen
            // holds only a handful of controls, so top-anchoring left the whole lower
            // half empty. minHeight keeps it centered when it fits and lets it scroll
            // normally once invites/session cards push it past a screenful.
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 18) {
                        header

                        if let update = updateChecker.available {
                            UpdateBannerView(update: update, onDismiss: { updateChecker.dismiss() })
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        if !presence.incomingInvites.isEmpty {
                            InviteBannerView(
                                invites: presence.incomingInvites,
                                onJoin: { joiningInvite = $0 },
                                onDecline: { invite in
                                    Task { _ = try? await presence.respondToInvite(invite, accept: false) }
                                }
                            )
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        joinSection
                        hostSection

                        Button {
                            showHistory = true
                        } label: {
                            HStack {
                                Image(systemName: "clock.arrow.circlepath")
                                Text("HISTORY")
                            }
                        }
                        .buttonStyle(GlassButtonStyle(tint: .white))
                        .padding(.horizontal)

                        if let error = viewModel.errorMessage {
                            Text(error)
                                .font(ADATheme.telemetryFont(size: 12))
                                .foregroundColor(ADATheme.hunterRed)
                                .padding(.horizontal)
                                .transition(.opacity)
                        }
                    }
                    .adaptiveContentWidth()
                    .padding(.vertical, 28)
                    .frame(minHeight: proxy.size.height, alignment: .center)
                    .frame(maxWidth: .infinity)
                    .animation(ADATheme.controlSpring, value: viewModel.errorMessage)
                    .animation(ADATheme.controlSpring, value: presence.incomingInvites.map(\.id))
                    .animation(ADATheme.controlSpring, value: updateChecker.available)
                }
            }
            .sheet(isPresented: $showHistory) {
                MatchHistoryView()
            }
            .sheet(item: $joiningInvite) { invite in
                InviteJoinSheet(invite: invite) { role, squad in
                    guard let session = try? await presence.respondToInvite(invite, accept: true) else { return }
                    guard let (player, joinedSession) = try? await APIClient.shared.joinGame(code: session.code, role: role, squad: squad) else { return }
                    launchedGame = (player, joinedSession)
                }
            }
            .fullScreenCover(item: Binding(
                get: { launchedGame.map { GameLaunch(player: $0.player, session: $0.session) } },
                set: { _ in launchedGame = nil }
            )) { launch in
                // Always the waiting room first — it swaps itself to GameView the moment
                // the match is (or becomes) active, so rejoining an already-running match
                // and entering a fresh lobby both funnel through the same entry point.
                GameLobbyView(gamePlayer: launch.player, session: launch.session)
            }
            .onAppear { locationManager.requestAuthorizationAndStart() }
        }
    }

    /// Wordmark, section label and who you're signed in as, as one block — these were three
    /// separate items spaced like unrelated cards, which read as clutter above the controls.
    private var header: some View {
        VStack(spacing: 6) {
            HuntingGameWordmark(size: 28)

            Text("MISSION CONTROL")
                .font(ADATheme.telemetryFont(size: 10))
                .foregroundColor(ADATheme.runnerGreen)
                .tracking(3)

            if let user = authSession.currentUser {
                // Same dot+telemetry-label pattern as GameView's top bar role indicator.
                HStack(spacing: 6) {
                    Circle()
                        .fill(ADATheme.runnerGreen)
                        .frame(width: 6, height: 6)
                        .shadow(color: ADATheme.runnerGreen, radius: 4)
                    Text(user.tagLabel.uppercased())
                        .font(ADATheme.telemetryFont(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                }
                .padding(.top, 2)
            }
        }
        .padding(.bottom, 4)
    }

    private var joinSection: some View {
        VStack(spacing: 10) {
            ADATextField(placeholder: "GAME CODE", text: $viewModel.joinCodeInput)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .multilineTextAlignment(.center)
                .font(ADATheme.displayFont(size: 20))

            if viewModel.selectedMode == .squad {
                ADATextField(placeholder: "Squad name", text: $viewModel.squadName)
                    .transition(.scale.combined(with: .opacity))
            }

            Button {
                Task {
                    await viewModel.joinGame()
                    if let player = viewModel.activePlayer, let session = viewModel.activeSession {
                        launchedGame = (player, session)
                    }
                }
            } label: {
                HStack {
                    Image(systemName: "arrow.right.circle.fill")
                    Text("JOIN GAME")
                }
            }
            .buttonStyle(GlowButtonStyle(tint: ADATheme.runnerGreen))
        }
        .padding(16)
        .glassCard(cornerRadius: ADATheme.cardCornerRadius)
        .padding(.horizontal)
        .animation(ADATheme.controlSpring, value: viewModel.selectedMode)
    }

    /// Hosting used to open a whole multi-step wizard before you could see the lobby at
    /// all. Now it only asks the two things that can't be changed once you're a member of
    /// the session (mode, your own role) and opens the lobby immediately — duration, the
    /// play area, jail and gambling all get set up from inside it instead.
    private var hostSection: some View {
        VStack(spacing: 10) {
            Picker("Mode", selection: $viewModel.hostMode.animation(ADATheme.controlSpring)) {
                ForEach(GameMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text("Everyone joins as a runner — the host assigns hunters from the lobby once everyone's in.")
                .font(ADATheme.telemetryFont(size: 10))
                .foregroundColor(.white.opacity(0.35))
                .multilineTextAlignment(.center)

            if viewModel.hostMode == .squad {
                ADATextField(placeholder: "Squad name", text: $viewModel.hostSquadName)
                    .transition(.scale.combined(with: .opacity))
            }

            Button {
                Task {
                    await viewModel.hostGame()
                    if let player = viewModel.activePlayer, let session = viewModel.activeSession {
                        launchedGame = (player, session)
                    }
                }
            } label: {
                if viewModel.isLoading {
                    ProgressView().tint(.black)
                } else {
                    HStack {
                        Image(systemName: "mappin.and.ellipse")
                        Text("HOST NEW GAME")
                    }
                }
            }
            .buttonStyle(GlowButtonStyle(tint: ADATheme.spatialCyan, isLoading: viewModel.isLoading))
        }
        .padding(16)
        .glassCard(cornerRadius: ADATheme.cardCornerRadius)
        .padding(.horizontal)
        .animation(ADATheme.controlSpring, value: viewModel.hostMode)
    }

}

private struct GameLaunch: Identifiable {
    let player: GamePlayer
    let session: GameSession
    var id: String { player.id + session.id }
}
