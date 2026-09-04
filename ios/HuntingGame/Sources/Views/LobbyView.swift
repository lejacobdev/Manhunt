import SwiftUI
import CoreLocation

struct LobbyView: View {
    @StateObject private var viewModel = LobbyViewModel()
    @StateObject private var locationManager = LocationManager()
    @EnvironmentObject var authSession: AuthSession
    @EnvironmentObject var presence: PresenceService
    @State private var showCreateSheet = false
    @State private var showFriends = false
    @State private var showHistory = false
    @State private var joiningInvite: GameInvite?
    @State private var launchedGame: (player: GamePlayer, session: GameSession)?

    var body: some View {
        NavigationStack {
            ZStack {
                // Same ambient arrival glow as AuthView — "home" shouldn't feel
                // flatter than "login" just because it's a ScrollView instead of a
                // centered form.
                RadialGradient(
                    colors: [ADATheme.runnerGreen.opacity(0.10), .clear],
                    center: .top,
                    startRadius: 20,
                    endRadius: 500
                )
                .edgesIgnoringSafeArea(.all)

                ScrollView {
                    VStack(spacing: 16) {
                        header

                        if let user = authSession.currentUser {
                            Text("SIGNED IN AS \(user.tagLabel.uppercased())")
                                .font(ADATheme.telemetryFont(size: 11))
                                .foregroundColor(.white.opacity(0.4))
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

                        Button {
                            showCreateSheet = true
                        } label: {
                            HStack {
                                Image(systemName: "mappin.and.ellipse")
                                Text("HOST NEW GAME")
                            }
                        }
                        .buttonStyle(GlowButtonStyle(tint: ADATheme.spatialCyan))
                        .padding(.horizontal)

                        HStack(spacing: 10) {
                            Button {
                                showFriends = true
                            } label: {
                                HStack {
                                    Image(systemName: "person.2.fill")
                                    Text("FRIENDS")
                                }
                            }
                            .buttonStyle(GlassButtonStyle(tint: .white))
                            .frame(maxWidth: .infinity)

                            Button {
                                showHistory = true
                            } label: {
                                HStack {
                                    Image(systemName: "clock.arrow.circlepath")
                                    Text("HISTORY")
                                }
                            }
                            .buttonStyle(GlassButtonStyle(tint: .white))
                            .frame(maxWidth: .infinity)
                        }
                        .padding(.horizontal)

                        if let error = viewModel.errorMessage {
                            Text(error)
                                .font(ADATheme.telemetryFont(size: 12))
                                .foregroundColor(ADATheme.hunterRed)
                                .padding(.horizontal)
                                .transition(.opacity)
                        }

                        if let session = viewModel.activeSession, let player = viewModel.activePlayer {
                            sessionStatusCard(session: session, player: player)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        Button("Sign Out") { authSession.signOut() }
                            .font(ADATheme.telemetryFont(size: 12))
                            .foregroundColor(.white.opacity(0.35))
                            .padding(.top, 12)
                            .padding(.bottom, 30)
                    }
                    .adaptiveContentWidth()
                    .animation(ADATheme.controlSpring, value: viewModel.errorMessage)
                    .animation(ADATheme.ambientSpring, value: viewModel.activeSession?.status)
                    .animation(ADATheme.controlSpring, value: presence.incomingInvites.map(\.id))
                }
            }
            .obsidianBackdrop()
            .sheet(isPresented: $showCreateSheet) {
                CreateGameSheet(viewModel: viewModel, locationManager: locationManager)
            }
            .sheet(isPresented: $showFriends) {
                FriendsView(inviteSessionCode: viewModel.activeSession?.status == .lobby ? viewModel.activeSession?.code : nil)
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
                GameView(gamePlayer: launch.player, session: launch.session)
            }
            .onAppear { locationManager.requestAuthorizationAndStart() }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("HUNTING GAME")
                .font(ADATheme.displayFont(size: 26))
                .foregroundColor(.white)
            Text("MISSION CONTROL")
                .font(ADATheme.telemetryFont(size: 10))
                .foregroundColor(ADATheme.runnerGreen)
                .tracking(3)
        }
        .padding(.top, 40)
    }

    private var joinSection: some View {
        VStack(spacing: 10) {
            ADATextField(placeholder: "GAME CODE", text: $viewModel.joinCodeInput)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .multilineTextAlignment(.center)
                .font(ADATheme.displayFont(size: 20))

            Picker("Role", selection: $viewModel.selectedRole) {
                ForEach([PlayerRole.runner, .hunter, .spectator], id: \.self) { role in
                    Text(role.displayName).tag(role)
                }
            }
            .pickerStyle(.segmented)

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

    private func sessionStatusCard(session: GameSession, player: GamePlayer) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor(for: session.status))
                    .frame(width: 8, height: 8)
                Text("CODE \(session.code) · \(session.mode.displayName.uppercased())")
                    .font(ADATheme.telemetryFont(size: 13))
                    .foregroundColor(.white)
            }
            Text(session.status.rawValue)
                .font(ADATheme.telemetryFont(size: 11))
                .foregroundColor(statusColor(for: session.status))

            HStack(spacing: 12) {
                if session.hostId == player.userId && session.status == .lobby {
                    Button("START") {
                        Task {
                            await viewModel.startGame()
                            if let updated = viewModel.activeSession {
                                launchedGame = (player, updated)
                            }
                        }
                    }
                    .buttonStyle(GlowButtonStyle(tint: ADATheme.tacticalAmber))
                }

                Button("ENTER") { launchedGame = (player, session) }
                    .buttonStyle(GlassButtonStyle(tint: ADATheme.spatialCyan))
            }
        }
        .padding(18)
        .glassCard(cornerRadius: ADATheme.cardCornerRadius, tint: statusColor(for: session.status))
        .padding(.horizontal)
    }

    private func statusColor(for status: GameStatus) -> Color {
        switch status {
        case .lobby: return ADATheme.spatialCyan
        case .active: return ADATheme.runnerGreen
        case .paused: return ADATheme.tacticalAmber
        case .ended: return ADATheme.neutralGray
        }
    }
}

private struct GameLaunch: Identifiable {
    let player: GamePlayer
    let session: GameSession
    var id: String { player.id + session.id }
}

struct CreateGameSheet: View {
    @ObservedObject var viewModel: LobbyViewModel
    @ObservedObject var locationManager: LocationManager
    @Environment(\.dismiss) private var dismiss
    /// Step 2 (jail area + gambling toggle) only appears after "Next" on step 1 —
    /// this sheet was a single-page form before; jail setup needed its own map and
    /// didn't fit alongside the boundary map without the whole form feeling cramped.
    @State private var step: Int = 1

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if step == 1 {
                        stepOneContent
                    } else {
                        stepTwoContent
                    }

                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(ADATheme.telemetryFont(size: 12))
                            .foregroundColor(ADATheme.hunterRed)
                            .padding(.horizontal)
                    }

                    Spacer(minLength: 20)
                }
                .padding(.top)
                .adaptiveContentWidth()
                .animation(ADATheme.controlSpring, value: viewModel.errorMessage)
                .animation(ADATheme.controlSpring, value: step)
            }
            .obsidianBackdrop()
            .navigationTitle(step == 1 ? "Host a Game" : "Host a Game — Step 2")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var stepOneContent: some View {
        Picker("Mode", selection: $viewModel.selectedMode.animation(ADATheme.controlSpring)) {
            ForEach(GameMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)

        VStack(alignment: .leading, spacing: 6) {
            Text("PLAY AS")
                .font(ADATheme.telemetryFont(size: 11))
                .foregroundColor(.white.opacity(0.5))
            Picker("Role", selection: $viewModel.hostRole) {
                ForEach([PlayerRole.runner, .hunter, .spectator], id: \.self) { role in
                    Text(role.displayName).tag(role)
                }
            }
            .pickerStyle(.segmented)

            if viewModel.selectedMode == .squad {
                ADATextField(placeholder: "Squad name", text: $viewModel.hostSquadName)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal)
        .animation(ADATheme.controlSpring, value: viewModel.selectedMode)

        VStack(alignment: .leading, spacing: 6) {
            Text("DURATION: \(Int(viewModel.durationMinutes)) MIN")
            Slider(value: $viewModel.durationMinutes, in: 10...180, step: 5)
                .tint(ADATheme.spatialCyan)
            Text("RADAR INTERVAL: \(Int(viewModel.radarIntervalSec))S")
            Slider(value: $viewModel.radarIntervalSec, in: 15...300, step: 15)
                .tint(ADATheme.spatialCyan)
        }
        .font(ADATheme.telemetryFont(size: 12))
        .foregroundColor(.white.opacity(0.7))
        .padding(16)
        .glassCard(cornerRadius: ADATheme.cardCornerRadius)
        .padding(.horizontal)

        Text("Tap the map to draw the public play-area boundary (min. 3 points). Power-ups only spawn on verified public land inside it.")
            .font(ADATheme.uiFont(size: 12, weight: .medium))
            .foregroundColor(.white.opacity(0.45))
            .padding(.horizontal)

        BoundaryMapView(
            points: $viewModel.boundaryPoints,
            centerCoordinate: locationManager.currentLocation?.coordinate ?? CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            userCoordinate: locationManager.currentLocation?.coordinate
        )
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: ADATheme.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ADATheme.cardCornerRadius, style: .continuous)
                .stroke(ADATheme.borderGlass, lineWidth: 1)
        )
        .padding(.horizontal)

        HStack {
            Button("CLEAR") { viewModel.resetBoundary() }
                .buttonStyle(GlassButtonStyle(tint: .white.opacity(0.6)))
            Spacer()
            Text("\(viewModel.boundaryPoints.count) POINTS")
                .font(ADATheme.telemetryFont(size: 12))
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(.horizontal)

        Button {
            guard viewModel.boundaryPoints.count >= 3 else {
                viewModel.errorMessage = "Draw a play-area boundary with at least 3 points before continuing."
                return
            }
            if viewModel.selectedMode == .squad && viewModel.hostSquadName.isEmpty {
                viewModel.errorMessage = "Enter a squad name before hosting a SQUAD mode game."
                return
            }
            viewModel.errorMessage = nil
            step = 2
        } label: {
            HStack {
                Text("NEXT")
                Image(systemName: "arrow.right")
            }
        }
        .buttonStyle(GlowButtonStyle(tint: ADATheme.spatialCyan))
        .padding(.horizontal)
    }

    @ViewBuilder
    private var stepTwoContent: some View {
        ToggleRow(
            title: "JAIL MODE",
            subtitle: "A caught runner is confined to a marked area instead of spectating immediately. Leaving it eliminates them.",
            isOn: $viewModel.jailEnabled.animation(ADATheme.controlSpring),
            tint: ADATheme.tacticalAmber
        )
        .padding(.horizontal)

        if viewModel.jailEnabled {
            Text("Tap the map to draw the jail area (min. 3 points).")
                .font(ADATheme.uiFont(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.45))
                .padding(.horizontal)

            BoundaryMapView(
                points: $viewModel.jailPoints,
                centerCoordinate: locationManager.currentLocation?.coordinate ?? CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
                userCoordinate: locationManager.currentLocation?.coordinate,
                strokeColor: .systemPurple
            )
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: ADATheme.cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ADATheme.cardCornerRadius, style: .continuous)
                    .stroke(ADATheme.borderGlass, lineWidth: 1)
            )
            .padding(.horizontal)
            .transition(.opacity.combined(with: .move(edge: .top)))

            HStack {
                Button("CLEAR") { viewModel.jailPoints.removeAll() }
                    .buttonStyle(GlassButtonStyle(tint: .white.opacity(0.6)))
                Spacer()
                Text("\(viewModel.jailPoints.count) POINTS")
                    .font(ADATheme.telemetryFont(size: 12))
                    .foregroundColor(.white.opacity(0.4))
            }
            .padding(.horizontal)
        }

        ToggleRow(
            title: "GAMBLING",
            subtitle: "A runner can risk a heart on a coin flip instead of accepting a catch. Never sends them to jail either way.",
            isOn: $viewModel.gamblingEnabled.animation(ADATheme.controlSpring),
            tint: ADATheme.tacticalAmber
        )
        .padding(.horizontal)

        HStack(spacing: 14) {
            Button {
                step = 1
            } label: {
                HStack {
                    Image(systemName: "arrow.left")
                    Text("BACK")
                }
            }
            .buttonStyle(GlassButtonStyle(tint: .white.opacity(0.6)))

            Button {
                Task {
                    await viewModel.createGame()
                    if viewModel.activeSession != nil { dismiss() }
                }
            } label: {
                if viewModel.isLoading {
                    ProgressView().tint(.black)
                } else {
                    HStack {
                        Image(systemName: "flag.checkered")
                        Text("CREATE GAME")
                    }
                }
            }
            .buttonStyle(GlowButtonStyle(tint: ADATheme.runnerGreen, isLoading: viewModel.isLoading))
        }
        .padding(.horizontal)
    }
}
