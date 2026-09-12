import SwiftUI
import CoreLocation

/// The pre-match waiting room: shown the moment you create or join a game, before the host
/// actually starts it. Everyone sits here together — live roster, the host's settings
/// (editable for the host, read-only for everyone else), and an invite shortcut — with no
/// separate trip back to Mission Control needed. The instant the host starts the match,
/// this view swaps straight into `GameView`.
struct GameLobbyView: View {
    @StateObject private var viewModel: GameLobbyViewModel
    // SocketService is a singleton ObservableObject; GameLobbyViewModel's session/settings
    // updates merely react to it internally, so the roster itself (socket.players) is read
    // here directly — same reasoning as GameView's identical setup.
    @ObservedObject private var socket = SocketService.shared
    @StateObject private var locationManager = LocationManager()
    @Environment(\.dismiss) private var dismiss
    @State private var showExitConfirm = false
    @State private var showFriends = false
    @State private var showSettings = false
    // Location sharing is never started automatically (App Store guideline 5.1.2(i)) —
    // this gates `locationManager.requestAuthorizationAndStart()` behind one explicit
    // check-in per match, asked again every time a fresh lobby is entered.
    @State private var showLocationConsent = true
    @State private var isRecordingConsent = false
    @State private var consentError: String?

    init(gamePlayer: GamePlayer, session: GameSession) {
        _viewModel = StateObject(wrappedValue: GameLobbyViewModel(session: session, player: gamePlayer))
    }

    var body: some View {
        Group {
            if viewModel.session.status == .active {
                GameView(gamePlayer: viewModel.player, session: viewModel.session)
            } else {
                waitingRoom
                    .onAppear { viewModel.start() }
                    .onDisappear { viewModel.stop() }
                    .fullScreenCover(isPresented: $showLocationConsent) {
                        LocationConsentView(
                            isSubmitting: isRecordingConsent,
                            errorMessage: consentError,
                            onAccept: { Task { await consentAndStartLocation() } },
                            onDecline: {
                                showLocationConsent = false
                                dismiss()
                            }
                        )
                        .preferredColorScheme(.dark)
                    }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func consentAndStartLocation() async {
        isRecordingConsent = true
        defer { isRecordingConsent = false }
        do {
            try await APIClient.shared.recordLocationSharingConsent(code: viewModel.session.code)
            showLocationConsent = false
            locationManager.requestAuthorizationAndStart()
        } catch {
            consentError = error.localizedDescription
        }
    }

    private var waitingRoom: some View {
        NavigationStack {
            ZStack {
                RadarSweepBackdrop(accent: statusColor)
                    .edgesIgnoringSafeArea(.all)

                // Invite/Start are the two actions that actually matter here — pinned below
                // the scroll area so they're always reachable without scrolling past however
                // long the roster or settings summary get, instead of drifting off the
                // bottom of the screen along with everything else.
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 16) {
                            header
                            rosterSection
                            settingsSummarySection
                        }
                        .padding(.vertical, 20)
                    }

                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(ADATheme.telemetryFont(size: 12))
                            .foregroundColor(ADATheme.hunterRed)
                            .padding(.horizontal)
                            .padding(.top, 8)
                    }

                    actionButtons
                        .padding(.top, 10)
                        .padding(.bottom, 6)
                }
                .adaptiveContentWidth()
                .animation(ADATheme.controlSpring, value: viewModel.errorMessage)
                .animation(ADATheme.controlSpring, value: viewModel.jailEnabled)
            }
            .obsidianBackdrop()
            .navigationTitle("Lobby")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("EXIT") { showExitConfirm = true }
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .confirmationDialog("Leave the lobby?", isPresented: $showExitConfirm, titleVisibility: .visible) {
                Button("Leave", role: .destructive) { dismiss() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You can rejoin from Mission Control while this game is still in the lobby or running.")
            }
            .sheet(isPresented: $showFriends) {
                FriendsView(inviteSessionCode: viewModel.session.code)
            }
            .sheet(isPresented: $showSettings) {
                LobbySetupSheet(viewModel: viewModel, locationManager: locationManager)
            }
        }
    }

    // MARK: - Header / roster

    private var statusColor: Color {
        viewModel.session.status == .lobby ? ADATheme.spatialCyan : ADATheme.runnerGreen
    }

    private var header: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusColor, radius: 4)
                Text("CODE \(viewModel.session.code) · \(viewModel.session.mode.displayName.uppercased())")
                    .font(ADATheme.telemetryFont(size: 13))
                    .foregroundColor(.white)
            }
            Text(viewModel.isHost ? "YOU'RE HOSTING" : "WAITING FOR HOST TO START")
                .font(ADATheme.telemetryFont(size: 10))
                .foregroundColor(.white.opacity(0.4))
                .tracking(2)
        }
        .padding(.top, 12)
    }

    private var rosterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PLAYERS · \(socket.players.count)")
                .font(ADATheme.telemetryFont(size: 11))
                .foregroundColor(.white.opacity(0.4))
                .padding(.leading, 4)

            VStack(spacing: 6) {
                ForEach(socket.players) { p in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(ADATheme.accent(for: p.role))
                            .frame(width: 8, height: 8)
                        Text(p.username.uppercased())
                            .font(ADATheme.uiFont(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        if let squad = p.squad, !squad.isEmpty {
                            Text(squad.uppercased())
                                .font(ADATheme.telemetryFont(size: 9))
                                .foregroundColor(ADATheme.spatialCyan.opacity(0.8))
                        }
                        Spacer()
                        if p.userId == viewModel.session.hostId {
                            StatusBadge(icon: "star.fill", text: "HOST", tint: ADATheme.tacticalAmber)
                        }
                        if viewModel.isHost {
                            // The host assigns everyone's role from here — including their
                            // own — instead of it being picked (often inconsistently, see
                            // the removed pre-lobby picker) before anyone's even joined.
                            Menu {
                                ForEach([PlayerRole.runner, .hunter, .spectator], id: \.self) { role in
                                    Button(role.displayName) { viewModel.setRole(for: p.id, to: role) }
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    Text(p.role.displayName.uppercased())
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 8, weight: .bold))
                                }
                                .foregroundColor(ADATheme.spatialCyan)
                            }
                            .font(ADATheme.telemetryFont(size: 10))
                        } else {
                            Text(p.role.displayName.uppercased())
                                .font(ADATheme.telemetryFont(size: 10))
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassCard(cornerRadius: ADATheme.controlCornerRadius)
                }
            }
        }
        .padding(.horizontal)
        .animation(ADATheme.controlSpring, value: socket.players.map(\.id))
    }

    // MARK: - Settings summary (read-only for everyone; the host edits via a sheet)

    private var settingsSummarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MATCH SETTINGS")
                    .font(ADATheme.telemetryFont(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                if viewModel.isHost {
                    Spacer()
                    Button {
                        showSettings = true
                    } label: {
                        HStack(spacing: 4) { Image(systemName: "gearshape.fill"); Text("SETTINGS") }
                    }
                    .buttonStyle(GlassButtonStyle(tint: ADATheme.spatialCyan))
                }
            }
            .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 8) {
                settingsRow(
                    icon: viewModel.isBoundarySet ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                    text: viewModel.isBoundarySet ? "Play area set" : "Play area not set yet",
                    tint: viewModel.isBoundarySet ? ADATheme.runnerGreen : ADATheme.tacticalAmber
                )
                settingsRow(icon: "clock.fill", text: "\(Int(viewModel.durationMinutes)) minute match")
                settingsRow(icon: "lock.fill", text: viewModel.jailEnabled ? "Jail mode enabled" : "Jail mode off")
                settingsRow(icon: "circle.grid.2x2.fill", text: viewModel.gamblingEnabled ? "Gambling enabled" : "Gambling off")
                settingsRow(
                    icon: "checkerboard.shield",
                    text: "Anti-cheat (BETA) \(viewModel.antiCheatEnabled ? "on" : "off")",
                    tint: viewModel.antiCheatEnabled ? ADATheme.spatialCyan : .white.opacity(0.4)
                )
            }
            .padding(16)
            .glassCard(cornerRadius: ADATheme.cardCornerRadius)
        }
        .padding(.horizontal)
    }

    private func settingsRow(icon: String, text: String, tint: Color = ADATheme.spatialCyan) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 18)
            Text(text)
                .font(ADATheme.uiFont(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
        }
    }

    // MARK: - Actions

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                showFriends = true
            } label: {
                HStack { Image(systemName: "person.2.fill"); Text("INVITE FRIENDS") }
            }
            .buttonStyle(GlassButtonStyle(tint: .white))

            if viewModel.isHost {
                Button {
                    Task { await viewModel.startGame() }
                } label: {
                    if viewModel.isStarting {
                        ProgressView().tint(.black)
                    } else {
                        HStack { Image(systemName: "flag.checkered"); Text("START GAME") }
                    }
                }
                .buttonStyle(GlowButtonStyle(tint: ADATheme.runnerGreen, isLoading: viewModel.isStarting))
                .disabled(!viewModel.isReadyToStart)
                .opacity(viewModel.isReadyToStart ? 1.0 : 0.4)

                if !viewModel.isReadyToStart {
                    Text("Draw the play area in Settings before starting.")
                        .font(ADATheme.telemetryFont(size: 11))
                        .foregroundColor(ADATheme.tacticalAmber.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(.horizontal)
    }
}

/// The host's full setup menu — duration/radar, the play area (only drawable once, before
/// it's saved), jail, and gambling. Opened from the lobby's "Settings" button rather than
/// shown inline, so the waiting room itself stays a simple summary everyone can read.
private struct LobbySetupSheet: View {
    @ObservedObject var viewModel: GameLobbyViewModel
    @ObservedObject var locationManager: LocationManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("DURATION: \(Int(viewModel.durationMinutes)) MIN")
                        Slider(value: $viewModel.durationMinutes, in: 10...180, step: 5)
                            .tint(ADATheme.spatialCyan)
                    }
                    .font(ADATheme.telemetryFont(size: 12))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(16)
                    .glassCard(cornerRadius: ADATheme.cardCornerRadius)
                    .padding(.horizontal)

                    if viewModel.isBoundarySet && !viewModel.isRedrawingBoundary {
                        VStack(spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.seal.fill").foregroundColor(ADATheme.runnerGreen)
                                Text("Play area is set. Redrawing it re-scatters power-ups inside the new shape.")
                                    .font(ADATheme.uiFont(size: 12, weight: .medium))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            Button("REDRAW PLAY AREA") { viewModel.beginRedrawBoundary() }
                                .buttonStyle(GlassButtonStyle(tint: ADATheme.tacticalAmber))
                        }
                        .padding(16)
                        .glassCard(cornerRadius: ADATheme.cardCornerRadius, tint: ADATheme.runnerGreen)
                        .padding(.horizontal)
                    } else {
                        Text(viewModel.isRedrawingBoundary
                             ? "Tap the map to redraw the play-area boundary (min. 3 points)."
                             : "Tap the map to draw the public play-area boundary (min. 3 points).")
                            .font(ADATheme.uiFont(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.45))
                            .padding(.horizontal)

                        BoundaryMapView(
                            points: $viewModel.boundaryPoints,
                            centerCoordinate: locationManager.currentLocation?.coordinate ?? CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
                            userCoordinate: locationManager.currentLocation?.coordinate
                        )
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: ADATheme.cardCornerRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: ADATheme.cardCornerRadius, style: .continuous)
                                .stroke(ADATheme.borderGlass, lineWidth: 1)
                        )
                        .padding(.horizontal)

                        HStack {
                            Button("CLEAR") { viewModel.boundaryPoints.removeAll() }
                                .buttonStyle(GlassButtonStyle(tint: .white.opacity(0.6)))
                            if viewModel.isRedrawingBoundary {
                                Button("CANCEL") {
                                    viewModel.isRedrawingBoundary = false
                                    viewModel.boundaryPoints = viewModel.session.settings.boundsPolygon
                                }
                                .buttonStyle(GlassButtonStyle(tint: .white.opacity(0.6)))
                            }
                            Spacer()
                            Text("\(viewModel.boundaryPoints.count) POINTS")
                                .font(ADATheme.telemetryFont(size: 12))
                                .foregroundColor(.white.opacity(0.4))
                        }
                        .padding(.horizontal)
                    }

                    ToggleRow(
                        title: "JAIL MODE",
                        subtitle: "A caught runner is confined to a marked area instead of spectating immediately.",
                        isOn: $viewModel.jailEnabled.animation(ADATheme.controlSpring),
                        tint: ADATheme.tacticalAmber
                    )
                    .padding(.horizontal)

                    if viewModel.jailEnabled {
                        BoundaryMapView(
                            points: $viewModel.jailPoints,
                            centerCoordinate: locationManager.currentLocation?.coordinate ?? CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
                            userCoordinate: locationManager.currentLocation?.coordinate,
                            strokeColor: .systemPurple
                        )
                        .frame(height: 220)
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
                        subtitle: "A runner can risk a heart on a coin flip instead of accepting a catch.",
                        isOn: $viewModel.gamblingEnabled,
                        tint: ADATheme.tacticalAmber
                    )
                    .padding(.horizontal)

                    ToggleRow(
                        title: "ANTI-CHEAT (BETA)",
                        subtitle: "Rejects GPS fixes that look faked or impossibly fast. Still new — turn it off if it's wrongly flagging real players.",
                        isOn: $viewModel.antiCheatEnabled,
                        tint: ADATheme.spatialCyan
                    )
                    .padding(.horizontal)

                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(ADATheme.telemetryFont(size: 12))
                            .foregroundColor(ADATheme.hunterRed)
                            .padding(.horizontal)
                    }

                    Button {
                        Task {
                            await viewModel.saveSettings()
                            if viewModel.errorMessage == nil { dismiss() }
                        }
                    } label: {
                        if viewModel.isSavingSettings {
                            ProgressView().tint(.black)
                        } else {
                            HStack { Image(systemName: "checkmark.circle.fill"); Text("SAVE SETTINGS") }
                        }
                    }
                    .buttonStyle(GlowButtonStyle(tint: ADATheme.spatialCyan, isLoading: viewModel.isSavingSettings))
                    .disabled(
                        ((!viewModel.isBoundarySet || viewModel.isRedrawingBoundary) && viewModel.boundaryPoints.count < 3)
                            || (viewModel.jailEnabled && viewModel.jailPoints.count < 3)
                    )
                    .padding(.horizontal)

                    Spacer(minLength: 20)
                }
                .padding(.top)
                .adaptiveContentWidth()
                .animation(ADATheme.controlSpring, value: viewModel.jailEnabled)
                .animation(ADATheme.controlSpring, value: viewModel.errorMessage)
            }
            .obsidianBackdrop()
            .navigationTitle("Game Settings")
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
