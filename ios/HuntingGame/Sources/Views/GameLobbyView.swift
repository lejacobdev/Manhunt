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

    init(gamePlayer: GamePlayer, session: GameSession) {
        _viewModel = StateObject(wrappedValue: GameLobbyViewModel(session: session, player: gamePlayer))
    }

    var body: some View {
        Group {
            if viewModel.session.status == .active {
                GameView(gamePlayer: viewModel.player, session: viewModel.session)
            } else {
                waitingRoom
                    .onAppear {
                        viewModel.start()
                        locationManager.requestAuthorizationAndStart()
                    }
                    .onDisappear { viewModel.stop() }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var waitingRoom: some View {
        NavigationStack {
            ZStack {
                RadarSweepBackdrop(accent: statusColor)
                    .edgesIgnoringSafeArea(.all)

                ScrollView {
                    VStack(spacing: 16) {
                        header
                        rosterSection

                        if viewModel.isHost {
                            hostSettingsSection
                        } else {
                            readOnlySettingsSection
                        }

                        if let error = viewModel.errorMessage {
                            Text(error)
                                .font(ADATheme.telemetryFont(size: 12))
                                .foregroundColor(ADATheme.hunterRed)
                                .padding(.horizontal)
                        }

                        actionButtons
                    }
                    .adaptiveContentWidth()
                    .padding(.vertical, 20)
                    .animation(ADATheme.controlSpring, value: viewModel.errorMessage)
                    .animation(ADATheme.controlSpring, value: viewModel.jailEnabled)
                }
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
                        Text(p.role.displayName.uppercased())
                            .font(ADATheme.telemetryFont(size: 10))
                            .foregroundColor(.white.opacity(0.4))
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

    // MARK: - Settings

    private var readOnlySettingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MATCH SETTINGS")
                .font(ADATheme.telemetryFont(size: 11))
                .foregroundColor(.white.opacity(0.4))
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 8) {
                settingsRow(icon: "clock.fill", text: "\(Int(viewModel.durationMinutes)) minute match")
                settingsRow(icon: "dot.radiowaves.left.and.right", text: "Radar every \(Int(viewModel.radarIntervalSec))s")
                settingsRow(icon: "lock.fill", text: viewModel.jailEnabled ? "Jail mode enabled" : "Jail mode off")
                settingsRow(icon: "circle.grid.2x2.fill", text: viewModel.gamblingEnabled ? "Gambling enabled" : "Gambling off")
            }
            .padding(16)
            .glassCard(cornerRadius: ADATheme.cardCornerRadius)
        }
        .padding(.horizontal)
    }

    private func settingsRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(ADATheme.spatialCyan)
                .frame(width: 18)
            Text(text)
                .font(ADATheme.uiFont(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
        }
    }

    @ViewBuilder
    private var hostSettingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MATCH SETTINGS")
                .font(ADATheme.telemetryFont(size: 11))
                .foregroundColor(.white.opacity(0.4))
                .padding(.leading, 4)

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

            ToggleRow(
                title: "JAIL MODE",
                subtitle: "A caught runner is confined to a marked area instead of spectating immediately.",
                isOn: $viewModel.jailEnabled,
                tint: ADATheme.tacticalAmber
            )

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
                .transition(.opacity.combined(with: .move(edge: .top)))

                HStack {
                    Button("CLEAR") { viewModel.jailPoints.removeAll() }
                        .buttonStyle(GlassButtonStyle(tint: .white.opacity(0.6)))
                    Spacer()
                    Text("\(viewModel.jailPoints.count) POINTS")
                        .font(ADATheme.telemetryFont(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            ToggleRow(
                title: "GAMBLING",
                subtitle: "A runner can risk a heart on a coin flip instead of accepting a catch.",
                isOn: $viewModel.gamblingEnabled,
                tint: ADATheme.tacticalAmber
            )

            Button {
                Task { await viewModel.saveSettings() }
            } label: {
                if viewModel.isSavingSettings {
                    ProgressView().tint(.black)
                } else {
                    HStack { Image(systemName: "checkmark.circle.fill"); Text("SAVE SETTINGS") }
                }
            }
            .buttonStyle(GlowButtonStyle(tint: ADATheme.spatialCyan, isLoading: viewModel.isSavingSettings))
            .disabled(viewModel.jailEnabled && viewModel.jailPoints.count < 3)
        }
        .padding(.horizontal)
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
            }
        }
        .padding(.horizontal)
    }
}
