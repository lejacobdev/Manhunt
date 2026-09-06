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

    var body: some View {
        // Friends used to be a button opening a sheet; it's a proper tab now, same level
        // as Play, rather than something layered on top of it.
        TabView {
            playTab
                .tabItem { Label("Play", systemImage: "gamecontroller.fill") }

            FriendsView()
                .tabItem { Label("Friends", systemImage: "person.2.fill") }

            LeaderboardView()
                .tabItem { Label("Leaderboard", systemImage: "trophy.fill") }

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle.fill") }
        }
        .tint(ADATheme.runnerGreen)
        .preferredColorScheme(.dark)
        // A scanned friend code can arrive at any moment — including while a match is on
        // screen — so the prompt is mounted at the tab root rather than inside Friends,
        // which may not be the selected tab when the link opens.
        .sheet(item: $deepLinkRouter.pendingFriend) { handle in
            AddFriendSheet(mode: .handle(handle))
        }
    }

    private var playTab: some View {
        NavigationStack {
            ZStack {
                // Same radar backdrop as AuthView (see RadarSweepBackdrop) — Mission
                // Control shouldn't feel like a plain settings screen once sign-in
                // already reads as part of the tactical HUD. Centered on the screen, not
                // pinned to the top edge, so it reads as a circle instead of a clipped wedge.
                RadarSweepBackdrop(accent: ADATheme.runnerGreen)
                    .edgesIgnoringSafeArea(.all)

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
            }
            .obsidianBackdrop()
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
