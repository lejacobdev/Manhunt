import SwiftUI
import MapKit

struct GameView: View {
    @StateObject private var viewModel: GameViewModel
    // SocketService is a singleton ObservableObject; GameViewModel's radar/compass/inventory
    // properties merely proxy its @Published state, so this view also observes it directly —
    // otherwise those socket-driven updates wouldn't trigger a re-render.
    @ObservedObject private var socket = SocketService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var now = Date()
    @State private var focusedPlayerId: String?
    @State private var showReplay = false
    /// Starts collapsed — lives in the bottom dock now, not floating over the map.
    @State private var isRadarPanelExpanded = false
    @State private var isEquipmentPanelExpanded = false
    /// Bumped by the "recenter on me" button; see `GameMapView.recenterRequest`.
    @State private var recenterRequestToken = 0

    init(gamePlayer: GamePlayer, session: GameSession) {
        _viewModel = StateObject(wrappedValue: GameViewModel(gamePlayer: gamePlayer, session: session))
    }

    var body: some View {
        ZStack {
            GameMapView(
                players: mapAnnotations,
                zone: socket.zone,
                extractionPoint: socket.extractionPoint,
                decoys: socket.radar?.decoys ?? [],
                powerUpSpawns: viewModel.powerUpSpawns,
                onSelectSpawn: viewModel.collectPowerUp,
                initialCenter: viewModel.currentLocation?.coordinate,
                focusPlayerId: focusedPlayerId,
                recenterRequest: recenterRequestToken,
                recenterTargetId: viewModel.gamePlayerId
            )
            .edgesIgnoringSafeArea(.all)
            // allowsHitTesting(false) is load-bearing: a plain Color overlay is opaque to
            // hit-testing by default, so without this every pan/pinch/tap aimed at the map
            // was being swallowed by this dimming layer instead of reaching the MKMapView
            // underneath — the map was never actually interactive.
            .overlay(Color.black.opacity(0.18).edgesIgnoringSafeArea(.all).allowsHitTesting(false))

            recenterButton

            VStack {
                topBar
                Spacer()
                // Nothing here floats mid-screen: everything below hugs the bottom
                // edge, so the map stays visible through the middle of the screen.
                if viewModel.role == .runner {
                    radarDock
                }
                bottomDock
            }
            .adaptiveContentWidth(ADATheme.dockContentWidth)

            if socket.gameOverReason != nil {
                dimScrim
                gameOverOverlay
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            } else if viewModel.isExtracted {
                dimScrim
                extractedOverlay
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            } else if viewModel.isCaught {
                dimScrim
                caughtOverlay
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }

            if viewModel.catchTargetId != nil {
                dimScrim
                    .onTapGesture { viewModel.cancelCatch() }
                catchCodeSheet
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(ADATheme.ambientSpring, value: viewModel.isCaught)
        .animation(ADATheme.ambientSpring, value: viewModel.isExtracted)
        .animation(ADATheme.ambientSpring, value: socket.gameOverReason)
        .animation(ADATheme.ambientSpring, value: viewModel.catchTargetId)
        .animation(ADATheme.controlSpring, value: viewModel.role)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { tick in
            now = tick
        }
        .alert("Catch failed", isPresented: Binding(
            get: { viewModel.showCatchFailure != nil },
            set: { if !$0 { viewModel.showCatchFailure = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.showCatchFailure = nil }
        } message: {
            Text(viewModel.showCatchFailure ?? "")
        }
        .alert("Notice", isPresented: Binding(
            get: { socket.lastErrorMessage != nil },
            set: { if !$0 { socket.lastErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { socket.lastErrorMessage = nil }
        } message: {
            Text(socket.lastErrorMessage ?? "")
        }
    }

    // MARK: - Chrome

    private var dimScrim: some View {
        Color.black.opacity(0.65)
            .edgesIgnoringSafeArea(.all)
            .transition(.opacity)
    }

    /// Google Maps-style "snap back to me" button, floating over the trailing edge of
    /// the map — the map free-pans now (see the hit-testing fix above), so there needs
    /// to be a way back to your own position after wandering off to look around.
    private var recenterButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    HapticsEngine.shared.lightTap()
                    recenterRequestToken += 1
                } label: {
                    Image(systemName: "location.fill")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(GlassButtonStyle(tint: ADATheme.spatialCyan))
                .clipShape(Circle())
            }
            .padding(.trailing, 16)
            // Sits just above the radar (runner) / dock (everyone else) rather than
            // overlapping either.
            .padding(.bottom, viewModel.role == .runner ? ADATheme.dockPanelWidth + 90 : 190)
        }
    }

    /// The runner's proximity compass — shrunk down and docked above the right-hand
    /// column (where the host panel lives) instead of a huge circle dominating the
    /// screen, with its own left/right edges matching that column's.
    private var radarDock: some View {
        HStack {
            Spacer()
            SpatialRadarView(
                distanceMeters: viewModel.nearestHunterDistance,
                bearingDegrees: viewModel.nearestHunterBearing,
                currentHeading: viewModel.currentHeadingDegrees,
                role: viewModel.role,
                diameter: ADATheme.dockPanelWidth
            )
            .transition(.scale.combined(with: .opacity))
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(ADATheme.accent(for: viewModel.role))
                        .frame(width: 8, height: 8)
                        .shadow(color: ADATheme.accent(for: viewModel.role), radius: 4)
                    Text(viewModel.role.displayName.uppercased())
                        .font(ADATheme.telemetryFont(size: 14))
                        .foregroundColor(.white)
                }
                if viewModel.role == .runner {
                    Text("CODE: \(viewModel.arrestCode)")
                        .font(ADATheme.telemetryFont(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
                if let remaining = matchRemainingText {
                    Text("TIME LEFT: \(remaining)")
                        .font(ADATheme.telemetryFont(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
                if let zone = socket.zone, viewModel.mode == .standard {
                    Text("ZONE: \(Int(zone.radiusMeters))M")
                        .font(ADATheme.telemetryFont(size: 12))
                        .foregroundColor(ADATheme.tacticalAmber)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    if viewModel.isInvisible {
                        StatusBadge(icon: "eye.slash.fill", text: "STEALTH \(viewModel.invisibilityRemainingSec)s", tint: ADATheme.stealthPurple)
                    }
                    if viewModel.isRadarJammed {
                        StatusBadge(icon: "bolt.slash.fill", text: "JAMMED", tint: ADATheme.tacticalAmber)
                    }
                }
                Button {
                    dismiss()
                } label: {
                    Text("EXIT")
                }
                .buttonStyle(GlassButtonStyle(tint: .white.opacity(0.7)))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .glassCard(cornerRadius: 20)
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    // MARK: - Bottom dock
    //
    // Every HUD element that isn't the top bar or (for a runner) the spatial
    // compass lives here: a row hugging the bottom edge, two fixed-width columns
    // with nothing but a flexible Spacer between them — nothing floats mid-screen
    // over the map. Panels are grouped by what they're *for* rather than dealt out
    // to balance a count: the left column is your own gear/situational info
    // (equipment, the hunter's nearby-runners list, a squad revive prompt), the
    // right column is match administration/observation (spectator roster, host
    // controls). Splitting it this way — instead of the previous "alternate
    // left/right by however many panels are active" — is also what fixed a real
    // layout bug: with two fixed 150pt columns and nothing else needing width in
    // between, there's no longer any leftover gap for a third item to be crushed
    // into (that crush is what wrapped "TACTICAL EQUIPMENT" into an unreadable
    // one-syllable-per-line column spanning the full screen height).

    private var leftDockPanels: [AnyView] {
        var panels: [AnyView] = []
        if viewModel.role == .hunter || viewModel.role == .runner {
            panels.append(AnyView(
                PowerUpDeckView(inventory: viewModel.inventory, onActivate: viewModel.usePowerUp, isExpanded: $isEquipmentPanelExpanded)
            ))
        }
        if viewModel.role == .hunter {
            panels.append(AnyView(radarPanel))
        }
        if let squadmate = viewModel.revivableSquadmate() {
            panels.append(AnyView(revivePanel(for: squadmate)))
        }
        return panels
    }

    private var rightDockPanels: [AnyView] {
        var panels: [AnyView] = []
        if viewModel.role == .spectator {
            panels.append(AnyView(
                SpectatorDashboardView(players: viewModel.allPlayers, focusedPlayerId: focusedPlayerId, onFocus: { focusedPlayerId = $0 })
            ))
        }
        if viewModel.isHost {
            panels.append(AnyView(
                HostControlPanelView(players: viewModel.allPlayers, onOverride: viewModel.hostOverride, onEndGame: viewModel.hostEndGame)
            ))
        }
        return panels
    }

    private var bottomDock: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(leftDockPanels.enumerated()), id: \.offset) { _, panel in
                    panel.frame(width: ADATheme.dockPanelWidth)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 8) {
                ForEach(Array(rightDockPanels.enumerated()), id: \.offset) { _, panel in
                    panel.frame(width: ADATheme.dockPanelWidth)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .animation(ADATheme.controlSpring, value: leftDockPanels.count + rightDockPanels.count)
    }

    private var radarPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureHeader(icon: "eye.fill", title: "RUNNERS: \(viewModel.visibleRunners.count)", tint: ADATheme.hunterRed, isExpanded: $isRadarPanelExpanded)

            if isRadarPanelExpanded {
                Group {
                    if viewModel.visibleRunners.isEmpty {
                        Text(viewModel.isRadarJammed ? "Jammed by EMP." : "None in range.")
                            .font(ADATheme.uiFont(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))
                    } else {
                        ScrollView {
                            VStack(spacing: 6) {
                                ForEach(viewModel.visibleRunners) { runner in
                                    Button {
                                        viewModel.beginCatch(on: runner.id)
                                    } label: {
                                        VStack(spacing: 2) {
                                            Image(systemName: "figure.run")
                                            Text(runner.username.uppercased())
                                                .font(ADATheme.telemetryFont(size: 10))
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.7)
                                        }
                                    }
                                    .buttonStyle(GlowButtonStyle(tint: ADATheme.hunterRed))
                                    .transition(.scale.combined(with: .opacity))
                                }
                            }
                        }
                        .frame(maxHeight: 220)
                    }
                }
                .clipped()
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(12)
        .glassCard(cornerRadius: ADATheme.cardCornerRadius, tint: ADATheme.hunterRed)
        .animation(ADATheme.controlSpring, value: viewModel.visibleRunners.map(\.id))
    }

    private func revivePanel(for squadmate: PlayerState) -> some View {
        VStack(spacing: 8) {
            VStack(spacing: 2) {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 14, weight: .bold))
                Text("\(squadmate.username.uppercased()) CAUGHT")
                    .font(ADATheme.telemetryFont(size: 10))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundColor(ADATheme.runnerGreen)

            Button {
                viewModel.revive(squadmate.id)
            } label: {
                HStack {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                    Text("REVIVE")
                }
                .font(ADATheme.telemetryFont(size: 11))
            }
            .buttonStyle(GlowButtonStyle(tint: ADATheme.runnerGreen))
        }
        .padding(12)
        .glassCard(cornerRadius: ADATheme.cardCornerRadius, tint: ADATheme.runnerGreen)
    }

    private var gameOverOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "flag.checkered.circle.fill")
                .font(.system(size: 36, weight: .bold))
                .foregroundColor(ADATheme.spatialCyan)
                .shadow(color: ADATheme.spatialCyan, radius: 12)

            Text("MATCH ENDED")
                .font(ADATheme.displayFont(size: 20))
                .foregroundColor(.white)

            Text(gameOverReasonLabel)
                .font(ADATheme.uiFont(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            HStack(spacing: 14) {
                Button("EXIT") { dismiss() }
                    .buttonStyle(GlassButtonStyle(tint: .white.opacity(0.6)))

                Button {
                    showReplay = true
                } label: {
                    HStack {
                        Image(systemName: "play.circle.fill")
                        Text("WATCH REPLAY")
                    }
                }
                .buttonStyle(GlowButtonStyle(tint: ADATheme.spatialCyan))
            }
        }
        .padding(32)
        .glassCard(cornerRadius: ADATheme.sheetCornerRadius, tint: ADATheme.spatialCyan)
        .padding(.horizontal, 40)
        .sheet(isPresented: $showReplay) {
            MatchReplayView(sessionCode: viewModel.roomCode)
        }
    }

    private var gameOverReasonLabel: String {
        switch socket.gameOverReason {
        case "TIME_EXPIRED": return "Time expired — the runners survived."
        case "ALL_RUNNERS_RESOLVED": return "All runners caught or extracted."
        case "HOST_ENDED": return "The host ended the match early."
        default: return "The match has ended."
        }
    }

    private var extractedOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 36, weight: .bold))
                .foregroundColor(ADATheme.runnerGreen)
                .shadow(color: ADATheme.runnerGreen, radius: 12)

            Text("YOU EXTRACTED SAFELY")
                .font(ADATheme.displayFont(size: 20))
                .foregroundColor(.white)

            Text("Spectate the rest of the match from here.")
                .font(ADATheme.uiFont(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(32)
        .glassCard(cornerRadius: ADATheme.sheetCornerRadius, tint: ADATheme.runnerGreen)
        .padding(.horizontal, 40)
    }

    private var caughtOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 36, weight: .bold))
                .foregroundColor(ADATheme.hunterRed)
                .shadow(color: ADATheme.hunterRed, radius: 12)

            Text("YOU HAVE BEEN CAUGHT")
                .font(ADATheme.displayFont(size: 20))
                .foregroundColor(.white)

            Text("Spectate the rest of the match from here.")
                .font(ADATheme.uiFont(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(32)
        .glassCard(cornerRadius: ADATheme.sheetCornerRadius, tint: ADATheme.hunterRed)
        .padding(.horizontal, 40)
    }

    private var catchCodeSheet: some View {
        VStack(spacing: 16) {
            Text("ENTER ARREST CODE")
                .font(ADATheme.telemetryFont(size: 15))
                .foregroundColor(.white)

            TextField("4-digit code", text: $viewModel.catchCodeEntry)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(ADATheme.displayFont(size: 28))
                .foregroundColor(.white)
                .padding()
                .background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: ADATheme.controlCornerRadius, style: .continuous))
                .padding(.horizontal, 30)

            HStack(spacing: 14) {
                Button("CANCEL") { viewModel.cancelCatch() }
                    .buttonStyle(GlassButtonStyle(tint: .white.opacity(0.6)))

                Button {
                    viewModel.confirmCatch()
                } label: {
                    HStack {
                        Image(systemName: "checkmark.shield.fill")
                        Text("CONFIRM CATCH")
                    }
                }
                .buttonStyle(GlowButtonStyle(tint: ADATheme.hunterRed))
                .disabled(viewModel.catchCodeEntry.count < 4)
                .opacity(viewModel.catchCodeEntry.count < 4 ? 0.5 : 1.0)
            }
            .padding(.horizontal, 20)
        }
        .padding(.vertical, 26)
        .glassCard(cornerRadius: ADATheme.sheetCornerRadius, tint: ADATheme.hunterRed)
        .padding(.horizontal, 24)
    }

    private var mapAnnotations: [GameMapView.Blip] {
        // The roster (viewModel.allPlayers) only gets a fresh snapshot on
        // join/leave for HUNTER/RUNNER players — it's never refreshed
        // afterward, so it still carries whatever position you were at
        // (lat/lng 0,0) the moment you joined. Render your own pin from
        // live GPS instead, and drop the stale roster copy of yourself so
        // there's no ghost pin sitting at (0,0).
        var blips = viewModel.allPlayers
            .filter { $0.id != viewModel.gamePlayerId }
            .map { GameMapView.Blip(id: $0.id, coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng), kind: $0.role) }

        if let selfCoordinate = viewModel.currentLocation?.coordinate {
            blips.append(GameMapView.Blip(id: viewModel.gamePlayerId, coordinate: selfCoordinate, kind: viewModel.role))
        }

        return blips
    }

    private var matchRemainingText: String? {
        guard let startedAt = socket.matchStartedAt else { return nil }
        let totalSeconds = viewModel.sessionSettings.durationMinutes * 60
        let elapsed = Int(now.timeIntervalSince(startedAt))
        let remaining = max(0, totalSeconds - elapsed)
        return String(format: "%02d:%02d", remaining / 60, remaining % 60)
    }
}
