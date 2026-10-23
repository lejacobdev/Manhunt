import SwiftUI
import MapKit

struct GameView: View {
    @StateObject private var viewModel: GameViewModel
    // SocketService is a singleton ObservableObject; GameViewModel's radar/compass/inventory
    // properties merely proxy its @Published state, so this view also observes it directly —
    // otherwise those socket-driven updates wouldn't trigger a re-render.
    @ObservedObject private var socket = SocketService.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var now = Date()
    @State private var focusedPlayerId: String?
    @State private var showReplay = false
    /// Starts collapsed — lives in the bottom dock now, not floating over the map.
    @State private var isRadarPanelExpanded = false
    @State private var isEquipmentPanelExpanded = false
    /// Bumped by the "recenter on me" button; see `GameMapView.recenterRequest`.
    @State private var recenterRequestToken = 0
    @State private var toastDismissWorkItem: DispatchWorkItem?
    @State private var showExitConfirm = false
    /// Opacity of the red edge flash played on every heart lost — see `damageFlash`.
    @State private var damageFlashOpacity: Double = 0
    // The per-match check-in (App Store guideline 5.1.2(i)). It lives here rather than in
    // the lobby because this is the point position actually starts being shared with other
    // players — asking on lobby entry meant consenting long before anything was shared, and
    // left location running through the whole waiting room for no reason.
    @State private var showLocationConsent = true
    @State private var isRecordingConsent = false
    @State private var consentError: String?

    /// A static screen for the simulator screenshot scenarios: no socket, no location, no
    /// check-in screen.
    private let isPreview: Bool

    init(gamePlayer: GamePlayer, session: GameSession, isPreview: Bool = false) {
        _viewModel = StateObject(wrappedValue: GameViewModel(gamePlayer: gamePlayer, session: session))
        self.isPreview = isPreview
        _showLocationConsent = State(initialValue: !isPreview)
    }

    var body: some View {
        ZStack {
            GameMapView(
                players: mapAnnotations,
                boundsPolygon: viewModel.sessionSettings.boundsPolygon,
                jailPolygon: viewModel.sessionSettings.jailPolygon,
                zone: viewModel.zone,
                safeZones: viewModel.activeSafeZones,
                decoys: socket.radar?.decoys ?? [],
                heat: viewModel.role == .hunter ? (socket.radar?.heat ?? []) : [],
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

            TacticalGlassContainer(spacing: 6) {
            VStack {
                topBar
                Spacer()
                // Nothing here floats mid-screen: everything below hugs the bottom edge,
                // so the map stays visible through the middle of the screen. The radar/
                // compass docks inside bottomDock's own right column (see rightDockPanels)
                // rather than floating separately above it, so expanding a panel in one
                // column never shifts the other column's vertical position.
                bottomDock
            }
            }
            .adaptiveContentWidth(ADATheme.dockContentWidth)
            // Text in the HUD scales up to about 235 %. Past that a panel would push the map off
            // the screen entirely; the dock columns widen with the text (see dockWidth).
            .dynamicTypeSize(...DynamicTypeSize.accessibility3)

            // Drawn after (so on top of) the dock/radar above — on the right, behind
            // the radar, it used to render underneath both and never actually show.
            damageFlash
            recenterButton
            toastBanner
            containmentWarningBanner

            if socket.gameOverReason != nil {
                dimScrim
                gameOverOverlay
                    .tacticalTransition(.scale(scale: 0.85).combined(with: .opacity))
            } else if viewModel.isOut {
                dimScrim
                eliminatedOverlay
                    .tacticalTransition(.scale(scale: 0.85).combined(with: .opacity))
            } else if viewModel.isCaught && !viewModel.isJailed {
                dimScrim
                caughtOverlay
                    .tacticalTransition(.scale(scale: 0.85).combined(with: .opacity))
            }

            if viewModel.catchTargetId != nil && viewModel.mode == .infection {
                dimScrim
                    .onTapGesture { viewModel.cancelCatch() }
                catchCodeSheet
                    .tacticalTransition(.move(edge: .bottom).combined(with: .opacity))
            }

            if viewModel.incomingCatchRequest != nil {
                dimScrim
                catchRequestPopup
                    .tacticalTransition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let denyConfirm = viewModel.pendingDenyConfirm {
                dimScrim
                denyConfirmSheet(denyConfirm)
                    .tacticalTransition(.scale(scale: 0.85).combined(with: .opacity))
            }

            if let dispute = socket.pendingDispute {
                dimScrim
                disputeRulingSheet(dispute)
                    .tacticalTransition(.scale(scale: 0.85).combined(with: .opacity))
            }

            // GAMBLING — disabled for now, kept here in full so it can be switched back on
            // without rebuilding it. The backend duel logic, SocketService events and
            // GameViewModel state it depends on are all still in place and untouched; only
            // the entry points (this overlay, the GAMBLE buttons in catchRequestPopup, and
            // the host's GAMBLING toggle in GameLobbyView) are commented out.
            //
            // if viewModel.isCoinFlipping || viewModel.lastGambleOutcome != nil || viewModel.awaitingGambleCall {
            //     dimScrim
            //     CoinFlipView(
            //         myChoice: viewModel.gambleChoicePending,
            //         outcome: viewModel.lastGambleOutcome,
            //         isSelf: viewModel.gamePlayerId,
            //         awaitingCall: viewModel.awaitingGambleCall,
            //         onCall: viewModel.callGamble,
            //         onContinue: viewModel.dismissGambleResult
            //     )
            //     .tacticalTransition(.scale(scale: 0.85).combined(with: .opacity))
            // }
        }
        .animation(ADATheme.ambientSpring, value: viewModel.isCaught)
        .animation(ADATheme.ambientSpring, value: viewModel.isOut)
        .animation(ADATheme.ambientSpring, value: socket.gameOverReason)
        // A match just finished, so wins, catches and playtime just changed. Give the server a
        // moment to write the final results, then tell Game Center; that is what turns an
        // achievement earned in this match into a banner while the player is still looking.
        .onChange(of: socket.gameOverReason) { reason in
            guard reason != nil else { return }
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await GameCenterManager.shared.syncFromServer(force: true)
            }
        }
        .animation(ADATheme.ambientSpring, value: viewModel.catchTargetId)
        .animation(ADATheme.controlSpring, value: viewModel.incomingCatchRequest)
        .animation(ADATheme.controlSpring, value: viewModel.pendingDenyConfirm)
        .animation(ADATheme.controlSpring, value: viewModel.isCoinFlipping)
        .animation(ADATheme.controlSpring, value: viewModel.role)
        .onAppear { if !isPreview { viewModel.start() } }
        .onDisappear { viewModel.stop() }
        .fullScreenCover(isPresented: $showLocationConsent) {
            LocationConsentView(
                purpose: .match,
                isSubmitting: isRecordingConsent,
                errorMessage: consentError,
                onAccept: { Task { await consentAndShareLocation() } }
            )
            .preferredColorScheme(.dark)
        }
        // The consent screen above always leads to the real system permission prompt now
        // (App Store guideline 5.1.1(iv) — no in-app decline that bypasses it). If the
        // player says no there, this is how that still gets them out of a match they can't
        // play without location, rather than leaving them stuck with a dead radar.
        .onChange(of: viewModel.locationAuthorizationStatus) { status in
            guard !showLocationConsent, status == .denied || status == .restricted else { return }
            dismiss()
        }
        .onChange(of: viewModel.isCaught) { caught in
            if caught { announce("You have been caught.") }
        }
        .onChange(of: viewModel.isOut) { out in
            if out { announce("You're out. \(eliminationReasonLabel)") }
        }
        .onChange(of: socket.gameOverReason) { reason in
            if reason != nil { announce("\(gameOverHeadline.capitalized). \(gameOverReasonLabel)") }
        }
        .onChange(of: viewModel.boundaryOutside) { outside in
            if outside { announce("Outside the play area. You are losing hearts.") }
        }
        .onChange(of: viewModel.heartLossPulse) { _ in
            // Snap on, ease off — a symmetric fade reads as a soft glow rather than a hit.
            withAnimation(.easeIn(duration: 0.07)) { damageFlashOpacity = 0.5 }
            withAnimation(.easeOut(duration: 0.65).delay(0.07)) { damageFlashOpacity = 0 }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { tick in
            now = tick
        }
        // Transient notices (a failed catch, "too far to collect", anti-cheat warnings)
        // auto-dismiss instead of blocking on a tap — a modal alert mid-chase is exactly
        // the wrong interaction for something the player should just glance at and keep
        // moving. Both sources funnel into the one toast banner below.
        .onChange(of: activeToastMessage) { newValue in
            guard newValue != nil else { return }
            scheduleToastDismiss()
        }
        .confirmationDialog("Exit the match?", isPresented: $showExitConfirm, titleVisibility: .visible) {
            Button("Exit", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can rejoin from Mission Control while this match is still running.")
        }
    }

    /// Speaks match events to VoiceOver users, who can't see the overlay that just appeared.
    private func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func consentAndShareLocation() async {
        isRecordingConsent = true
        defer { isRecordingConsent = false }
        do {
            try await APIClient.shared.recordLocationSharingConsent(code: viewModel.roomCode)
            showLocationConsent = false
            viewModel.startLocationSharing()
        } catch {
            consentError = error.localizedDescription
        }
    }

    // MARK: - Chrome

    /// Red vignette pulsed from the screen edges whenever this player loses a heart. The
    /// hearts row itself is small and docked at the bottom, so on its own it's easy to miss
    /// while you're actually looking at the map — which made zone damage in particular feel
    /// like nothing was happening.
    private var damageFlash: some View {
        RadialGradient(
            colors: [.clear, ADATheme.hunterRed.opacity(damageFlashOpacity)],
            center: .center,
            startRadius: 120,
            endRadius: 560
        )
        .edgesIgnoringSafeArea(.all)
        .allowsHitTesting(false)
    }

    private var dimScrim: some View {
        Color.black.opacity(0.65)
            .edgesIgnoringSafeArea(.all)
            .transition(.opacity)
    }

    /// Google Maps-style "snap back to me" button, floating above the left dock
    /// column (equipment/radar-list/revive) — the map free-pans now (see the
    /// hit-testing fix above), so there needs to be a way back to your own position
    /// after wandering off to look around. Deliberately on the *left*: the runner's
    /// compass gauge docks above the right column, and a right-aligned button there
    /// used to sit right behind it, invisible and untappable.
    private var recenterButton: some View {
        VStack {
            Spacer()
            HStack {
                Button {
                    HapticsEngine.shared.lightTap()
                    recenterRequestToken += 1
                } label: {
                    Image(systemName: "location.fill")
                        .tacticalFont(.symbol, size: 18, weight: .bold)
                        .foregroundColor(ADATheme.spatialCyan)
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                }
                .buttonStyle(ScaleButtonStyle())
                .tacticalGlass(in: Circle(), interactive: true)
                .accessibilityLabel("Recenter on my position")
                Spacer()
            }
            .padding(.leading, 16)
            // Clears a collapsed left-column dock panel sitting below it.
            .padding(.bottom, 92)
        }
    }

    /// A failed catch, a server-rejected action ("too far to collect"), or a location
    /// update the anti-cheat pipeline silently dropped (bad GPS accuracy, non-foot
    /// motion, an implausible jump) — shown as a brief non-blocking banner rather than
    /// a modal alert. Without this, a rejected fix left the radar/compass looking frozen
    /// with no visible reason why. See `scheduleToastDismiss`.
    private var activeToastMessage: String? {
        viewModel.showCatchFailure ?? socket.lastErrorMessage ?? socket.lastAntiCheatWarning
    }

    private var toastBanner: some View {
        VStack {
            if let message = activeToastMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .tacticalFont(.symbol, size: 13, weight: .bold)
                    Text(message)
                        .tacticalFont(.ui, size: 12, weight: .semibold)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(ADATheme.tacticalAmber)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .tacticalGlass(in: Capsule(), tint: ADATheme.tacticalAmber)
                .padding(.horizontal, 24)
                .padding(.top, 130)
                .tacticalTransition(.move(edge: .top).combined(with: .scale(scale: 0.6, anchor: .top)).combined(with: .opacity))
                .accessibilityAddTraits(.updatesFrequently)
                .allowsHitTesting(false)
            }
            Spacer()
        }
        .animation(ADATheme.controlSpring, value: activeToastMessage)
    }

    /// Auto-clears whichever transient notice is currently showing after a beat —
    /// cancels any previous pending clear first, so a second notice landing mid-display
    /// gets its own full timer instead of vanishing early on the first one's schedule.
    /// Clears both underlying sources rather than just the one currently displayed:
    /// `activeToastMessage` only shows one at a time, so the other is either already
    /// nil or itself stale and due to go regardless.
    private func scheduleToastDismiss() {
        toastDismissWorkItem?.cancel()
        let work = DispatchWorkItem {
            viewModel.showCatchFailure = nil
            socket.lastErrorMessage = nil
            socket.lastAntiCheatWarning = nil
        }
        toastDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// Bearings for whichever role this device is playing, mapped into the radar gauge's
    /// role-neutral shape — a hunter's radar and a runner's compass share the same visual,
    /// just pointed at the opposite side.
    private var radarTargets: [RadarBearing] {
        if viewModel.role == .hunter {
            return viewModel.visibleRunnerBearings.map {
                RadarBearing(id: $0.runnerId, username: $0.username, distanceMeters: $0.distanceMeters, bearingDegrees: $0.bearingDegrees)
            }
        }
        return viewModel.visibleHunterBearings.map {
            RadarBearing(id: $0.hunterId, username: $0.username, distanceMeters: $0.distanceMeters, bearingDegrees: $0.bearingDegrees)
        }
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
                        .tacticalFont(.telemetry, size: 14)
                        .foregroundColor(.white)
                }
                // The arrest code only means anything in INFECTION, the one mode still using
                // the code-entry catch. Everywhere else it was pure noise sitting where the
                // match clock should be.
                if viewModel.role == .runner && viewModel.mode == .infection {
                    Text("CODE: \(viewModel.arrestCode)")
                        .tacticalFont(.telemetry, size: 12)
                        .tacticalText(.secondary)
                }
                if let remaining = matchRemainingText {
                    Text("TIME LEFT: \(remaining)")
                        .tacticalFont(.telemetry, size: 12)
                        .tacticalNumericTransition(countsDown: true)
                        .animation(.default, value: remaining)
                        .tacticalText(.secondary)
                }
                if let pingText = radarPingText {
                    Text(pingText)
                        .tacticalFont(.telemetry, size: 12)
                        .foregroundColor(socket.radar?.live == true && viewModel.radarPingInterval > 0 ? ADATheme.hunterRed : .white.opacity(0.5))
                        .tacticalNumericTransition(countsDown: true)
                        .animation(.default, value: pingText)
                }
                if let zoneText = zoneRadiusText {
                    Text(zoneText)
                        .tacticalFont(.telemetry, size: 12)
                        .foregroundColor(ADATheme.spatialCyan.opacity(0.8))
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { statusBadges }
                    VStack(alignment: .trailing, spacing: 6) { statusBadges }
                }
                Button {
                    showExitConfirm = true
                } label: {
                    Text("EXIT")
                }
                .accessibilityLabel("Exit match")
                .buttonStyle(TacticalGhostButtonStyle(tint: .white.opacity(0.7)))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .glassCard(cornerRadius: 20, tint: ADATheme.accent(for: viewModel.role))
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    /// Buffs, jail and jam badges — a row when there's room, a column when the text is large.
    @ViewBuilder
    private var statusBadges: some View {
        if viewModel.isJailed {
            StatusBadge(icon: "lock.fill", text: "JAILED", tint: ADATheme.tacticalAmber)
        }
        if let until = viewModel.protectedUntil, until > now {
            StatusBadge(icon: "shield.lefthalf.filled", text: "SHIELDED \(Int(until.timeIntervalSince(now).rounded(.up)))s", tint: ADATheme.runnerGreen)
        }
        if viewModel.isInvisible {
            StatusBadge(icon: "eye.slash.fill", text: "STEALTH \(viewModel.invisibilityRemainingSec)s", tint: ADATheme.stealthPurple)
        }
        // Every other buff this player is running, so activating one visibly
        // does something rather than just emptying an inventory slot.
        ForEach(otherActiveBuffs, id: \.type) { buff in
            StatusBadge(
                icon: buff.type.iconName,
                text: "\(buff.type.displayName.uppercased()) \(buff.remaining)s",
                tint: ADATheme.accent(for: buff.type)
            )
        }
        if viewModel.isRadarJammed {
            StatusBadge(
                icon: "bolt.slash.fill",
                text: viewModel.jammedRemainingSec > 0 ? "JAMMED \(viewModel.jammedRemainingSec)s" : "JAMMED",
                tint: ADATheme.tacticalAmber
            )
        }
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
                HeartsRowView(hearts: viewModel.hearts, maxHearts: viewModel.role == .hunter ? 5 : 3)
            ))
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
        // Lives in the right column itself (above the host panel, for a host) rather than
        // floating separately above the whole dock — floating it above meant expanding the
        // *left* column (e.g. the hunter's runner list) pushed this independently-positioned
        // gauge upward too, since both sat below the same flexible Spacer. Docked here, it
        // only ever moves in response to this column's own content.
        if viewModel.role == .runner || viewModel.role == .hunter {
            panels.append(AnyView(
                SpatialRadarView(
                    distanceMeters: viewModel.role == .hunter ? nil : viewModel.nearestHunterDistance,
                    bearingDegrees: viewModel.role == .hunter ? nil : viewModel.nearestHunterBearing,
                    targets: radarTargets,
                    currentHeading: viewModel.currentHeadingDegrees,
                    role: viewModel.role,
                    diameter: dockWidth
                )
            ))
        }
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

    /// Each dock column widens with the reader's text size — up to half the screen, so the two
    /// columns still sit on either side with the map visible above them.
    private var dockWidth: CGFloat {
        let textScale = TacticalTypeScale.scaled(1, for: min(dynamicTypeSize, .accessibility3))
        let half = (UIScreen.main.bounds.width - 36) / 2
        return min(max(ADATheme.dockPanelWidth, ADATheme.dockPanelWidth * textScale * 0.8), max(ADATheme.dockPanelWidth, half))
    }

    private var bottomDock: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(leftDockPanels.enumerated()), id: \.offset) { _, panel in
                    panel.frame(width: dockWidth)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 8) {
                ForEach(Array(rightDockPanels.enumerated()), id: \.offset) { _, panel in
                    panel.frame(width: dockWidth)
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
                            .tacticalFont(.ui, size: 11, weight: .medium)
                            .tacticalText(.secondary)
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
                                                .tacticalFont(.telemetry, size: 10)
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.7)
                                        }
                                    }
                                    .buttonStyle(GlowButtonStyle(tint: ADATheme.hunterRed, glow: false))
                                    .accessibilityLabel("Catch \(runner.username)")
                                    .tacticalTransition(.scale.combined(with: .opacity))
                                }
                            }
                        }
                        .frame(maxHeight: 220)
                    }
                }
                .clipped()
                .tacticalTransition(.opacity.combined(with: .move(edge: .bottom)))
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
                    .tacticalFont(.symbol, size: 14, weight: .bold)
                Text("\(squadmate.username.uppercased()) CAUGHT")
                    .tacticalFont(.telemetry, size: 10)
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
                .tacticalFont(.telemetry, size: 11)
            }
            .buttonStyle(GlowButtonStyle(tint: ADATheme.runnerGreen))
        }
        .padding(12)
        .glassCard(cornerRadius: ADATheme.cardCornerRadius, tint: ADATheme.runnerGreen)
    }

    private var gameOverOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "flag.checkered.circle.fill")
                .tacticalFont(.symbol, size: 36, weight: .bold)
                .foregroundColor(gameOverTint)
                .shadow(color: gameOverTint, radius: 12)

            Text(gameOverHeadline)
                .tacticalFont(.display, size: 20)
                .foregroundColor(.white)

            Text(gameOverReasonLabel)
                .tacticalFont(.ui, size: 13, weight: .medium)
                .tacticalText(.secondary)

            HStack(spacing: 14) {
                Button("EXIT") { dismiss() }
                    .buttonStyle(TacticalGhostButtonStyle(tint: .white.opacity(0.6)))

                Button {
                    showReplay = true
                } label: {
                    HStack {
                        Image(systemName: "list.bullet.rectangle.portrait.fill")
                        Text("MATCH SUMMARY")
                    }
                }
                .buttonStyle(GlowButtonStyle(tint: gameOverTint))
            }
        }
        .padding(32)
        .glassCard(cornerRadius: ADATheme.sheetCornerRadius, tint: gameOverTint, strength: .strong)
        .padding(.horizontal, 40)
        .sheet(isPresented: $showReplay) {
            // The summary first — who caught whom, distances, power-ups — with the replay inside it.
            MatchSummaryView(sessionCode: viewModel.roomCode, myUserId: AuthSession.shared.currentUser?.id)
        }
    }

    /// nil for an inconclusive end (the host cut it short, or an unrecognized reason) —
    /// everything else has a real winning side, so the overlay can be colored/labeled
    /// to match instead of always reading as a neutral "match ended".
    private var gameOverWinner: PlayerRole? {
        guard viewModel.mode != .squad else { return nil }
        switch socket.gameOverReason {
        case "TIME_EXPIRED", "ALL_HUNTERS_ELIMINATED": return .runner
        case "ALL_RUNNERS_RESOLVED": return .hunter
        default: return nil
        }
    }

    private var gameOverTint: Color {
        if let squad = socket.winningSquad {
            return squad == viewModel.mySquad ? ADATheme.runnerGreen : ADATheme.hunterRed
        }
        return gameOverWinner.map { ADATheme.accent(for: $0) } ?? ADATheme.spatialCyan
    }

    private var gameOverHeadline: String {
        if let squad = socket.winningSquad {
            return squad == viewModel.mySquad ? "YOUR SQUAD WINS" : "SQUAD \(squad.uppercased()) WINS"
        }
        if socket.gameOverReason == "DRAW" || socket.gameOverReason == "TIME_EXPIRED_DRAW" { return "DRAW" }
        switch gameOverWinner {
        case .hunter: return "HUNTERS WIN"
        case .runner: return "RUNNERS WIN"
        default: return "MATCH ENDED"
        }
    }

    private var gameOverReasonLabel: String {
        switch socket.gameOverReason {
        case "TIME_EXPIRED" where socket.winningSquad != nil: return "Time's up — they had the most runners still free."
        case "TIME_EXPIRED": return "Time expired — the runners survived."
        case "TIME_EXPIRED_DRAW": return "Time's up with the squads level."
        case "SQUAD_WON": return "Every other squad's runners were caught."
        case "DRAW": return "No squad has a runner left free."
        case "ALL_RUNNERS_RESOLVED" where viewModel.mode == .infection: return "Everyone has been turned."
        case "ALL_RUNNERS_RESOLVED": return "All runners caught or eliminated."
        case "ALL_HUNTERS_ELIMINATED": return "All hunters were eliminated — the runners win!"
        case "HOST_ENDED": return "The host ended the match early."
        case "ENDED_BY_ADMIN": return "A moderator ended this match."
        case "ABANDONED": return "Everyone had left — the match was closed automatically."
        default: return "The match has ended."
        }
    }

    private var caughtOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "hand.raised.fill")
                .tacticalFont(.symbol, size: 36, weight: .bold)
                .foregroundColor(ADATheme.hunterRedText)
                .shadow(color: ADATheme.hunterRed, radius: 12)

            Text("YOU HAVE BEEN CAUGHT")
                .tacticalFont(.display, size: 20)
                .foregroundColor(.white)

            Text("Spectate the rest of the match from here.")
                .tacticalFont(.ui, size: 13, weight: .medium)
                .tacticalText(.secondary)
        }
        .padding(32)
        .glassCard(cornerRadius: ADATheme.sheetCornerRadius, tint: ADATheme.hunterRed, strength: .strong)
        .padding(.horizontal, 40)
    }

    private var eliminatedOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "xmark.seal.fill")
                .tacticalFont(.symbol, size: 36, weight: .bold)
                .foregroundColor(ADATheme.hunterRedText)
                .shadow(color: ADATheme.hunterRed, radius: 12)

            Text("YOU'RE OUT")
                .tacticalFont(.display, size: 20)
                .foregroundColor(.white)

            Text(eliminationReasonLabel)
                .tacticalFont(.ui, size: 13, weight: .medium)
                .tacticalText(.secondary)

            Text("Spectate the rest of the match from here.")
                .tacticalFont(.ui, size: 13, weight: .medium)
                .tacticalText(.secondary)
        }
        .padding(32)
        .glassCard(cornerRadius: ADATheme.sheetCornerRadius, tint: ADATheme.hunterRed, strength: .strong)
        .padding(.horizontal, 40)
    }

    private var eliminationReasonLabel: String {
        switch viewModel.eliminationReason {
        case "GAMBLE": return "You gambled and lost your last heart."
        case "BOUNDARY": return "You ran out of hearts outside the play area."
        case "JAIL_BREACH": return "You didn't make it back to the jail zone in time."
        case "JAIL_NO_SHOW": return "You never made it to the jail after being caught."
        case "BAILOUT": return "That jailbreak cost you your last heart."
        case "CAUGHT": return "You were caught with your last heart on the line."
        default: return "You've been eliminated."
        }
    }

    /// The runner's incoming "did you get caught?" popup — the new request-based catch
    /// flow's core interaction, replacing the hunter's old code-entry sheet.
    private var catchRequestPopup: some View {
        VStack(spacing: 16) {
            Text("DID YOU GET CAUGHT BY \(viewModel.incomingCatchRequest?.hunterUsername.uppercased() ?? "")?")
                .tacticalFont(.telemetry, size: 15)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            Text("Answer within 20 seconds — no answer counts as caught.")
                .tacticalFont(.ui, size: 11, weight: .medium)
                .tacticalText(.secondary)
                .multilineTextAlignment(.center)

            // GAMBLING — see the commented-out CoinFlipView overlay above.
            // if viewModel.sessionSettings.gamblingEnabled == true {
            //     Text("Gambling risks a heart, but never sends you to jail.")
            //         .tacticalFont(.ui, size: 11, weight: .medium)
            //         .tacticalText(.secondary)
            // }

            VStack(spacing: 10) {
                Button {
                    viewModel.acceptCatch()
                } label: {
                    HStack {
                        Image(systemName: "hand.raised.fill")
                        Text("YES, I WAS CAUGHT")
                    }
                }
                .buttonStyle(GlowButtonStyle(tint: ADATheme.hunterRed))

                // GAMBLING — see the commented-out CoinFlipView overlay above.
                // if viewModel.sessionSettings.gamblingEnabled == true {
                //     HStack(spacing: 10) {
                //         Button {
                //             viewModel.gambleCatch(choice: .heads)
                //         } label: {
                //             HStack { Image(systemName: "circle.fill"); Text("GAMBLE: HEADS") }
                //         }
                //         .buttonStyle(GlowButtonStyle(tint: ADATheme.tacticalAmber))
                //
                //         Button {
                //             viewModel.gambleCatch(choice: .tails)
                //         } label: {
                //             HStack { Image(systemName: "circle"); Text("GAMBLE: TAILS") }
                //         }
                //         .buttonStyle(GlowButtonStyle(tint: ADATheme.tacticalAmber))
                //     }
                // }

                Button("NO, THAT WASN'T A CATCH") {
                    viewModel.denyCatch()
                }
                .buttonStyle(TacticalGhostButtonStyle(tint: .white.opacity(0.6)))
            }
        }
        .padding(.vertical, 26)
        .glassCard(cornerRadius: ADATheme.sheetCornerRadius, tint: ADATheme.hunterRed, strength: .strong)
        .padding(.horizontal, 24)
    }

    /// Hunter-side follow-up after a runner taps "No" — a genuine disagreement here
    /// falls back to the host's existing override control, not a new arbitration flow.
    private func denyConfirmSheet(_ request: DenyConfirmRequest) -> some View {
        VStack(spacing: 16) {
            Text("\(request.runnerUsername.uppercased()) SAYS THAT WASN'T A CATCH")
                .tacticalFont(.telemetry, size: 14)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            Text("If you really caught them, the host decides. If you don't answer, their word stands.")
                .tacticalFont(.ui, size: 12, weight: .medium)
                .tacticalText(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 10) {
                Button {
                    viewModel.disputeDenial()
                } label: {
                    HStack { Image(systemName: "hand.raised.fill"); Text("I DID CATCH THEM") }
                }
                .buttonStyle(GlowButtonStyle(tint: ADATheme.hunterRed))
                Button("MY MISTAKE, NO CATCH") {
                    viewModel.confirmDenyWasAccidental()
                }
                .buttonStyle(TacticalGhostButtonStyle(tint: .white.opacity(0.7)))
            }
        }
        .padding(24)
        .glassCard(cornerRadius: ADATheme.sheetCornerRadius, tint: ADATheme.tacticalAmber, strength: .strong)
        .padding(.horizontal, 30)
    }

    /// The host's ruling on a catch the runner denied and the hunter insisted on.
    private func disputeRulingSheet(_ dispute: CatchDispute) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "scale.3d")
                .tacticalFont(.symbol, size: 30, weight: .bold)
                .foregroundColor(ADATheme.tacticalAmber)
            Text("DISPUTED CATCH")
                .tacticalFont(.display, size: 20)
                .foregroundColor(.white)
            Text("\(dispute.hunterUsername) says they caught \(dispute.runnerUsername). \(dispute.runnerUsername) says they didn't. They're \(dispute.distanceMeters) m apart right now. If you don't decide in 45 seconds, the catch stands.")
                .tacticalFont(.ui, size: 13, weight: .medium)
                .foregroundColor(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                Button {
                    viewModel.ruleOnDispute(catchStands: true)
                } label: {
                    HStack { Image(systemName: "checkmark.seal.fill"); Text("IT'S A CATCH") }
                }
                .buttonStyle(GlowButtonStyle(tint: ADATheme.hunterRed))
                Button("NOT A CATCH") { viewModel.ruleOnDispute(catchStands: false) }
                    .buttonStyle(TacticalGhostButtonStyle(tint: ADATheme.runnerGreen))
            }
        }
        .padding(24)
        .glassCard(cornerRadius: ADATheme.sheetCornerRadius, tint: ADATheme.tacticalAmber, strength: .strong)
        .padding(.horizontal, 28)
    }

    /// A persistent (not auto-dismissing) warning for straying outside the play area or,
    /// with higher priority, outside the jail zone — clears the instant the server reports
    /// back inside, no local timer of its own beyond the jail countdown display.
    private var containmentWarningBanner: some View {
        VStack {
            if let arrival = viewModel.jailArrivalRemaining {
                // Sentenced but not there yet — the clock is to *reach* the jail, and
                // running it out is a disqualification for never showing up.
                bannerText(
                    "GET TO THE JAIL — \(arrival / 60):\(String(format: "%02d", arrival % 60))",
                    tint: ADATheme.hunterRed
                )
            } else if viewModel.jailOutside {
                Text("LEAVE THE JAIL ZONE — RETURN IN \(viewModel.jailCountdownRemaining ?? 10)s")
                    .tacticalFont(.telemetry, size: 12)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .tacticalGlass(in: Capsule(), tint: ADATheme.hunterRed, strength: .strong)
                    .padding(.horizontal, 24)
                    .padding(.top, 130)
                    .tacticalTransition(.move(edge: .top).combined(with: .scale(scale: 0.6, anchor: .top)).combined(with: .opacity))
                    .allowsHitTesting(false)
            } else if viewModel.bailActive {
                bannerText(
                    "FREEING PRISONERS — HOLD \(viewModel.bailRemainingSeconds)s",
                    tint: ADATheme.runnerGreen
                )
            } else if viewModel.boundaryOutside && !viewModel.isCaught && !viewModel.isJailed && !viewModel.isOut {
                // The caught/jailed/out guard is belt-and-braces against a stale warning:
                // the server retracts it now, but a client already mid-match when this
                // shipped would otherwise keep showing one with no damage behind it.
                bannerText(
                    viewModel.boundaryReason == "ZONE"
                        ? "OUTSIDE THE SHRINKING ZONE — LOSING HEARTS"
                        : "OUTSIDE THE PLAY AREA — LOSING HEARTS",
                    tint: ADATheme.tacticalAmber
                )
            }

            if let headStart = headStartRemaining {
                bannerText(
                    viewModel.role == .hunter
                        ? "HEAD START — YOUR RADAR COMES ONLINE IN \(headStart / 60):\(String(format: "%02d", headStart % 60))"
                        : "HEAD START — HUNTERS ARE BLIND FOR \(headStart / 60):\(String(format: "%02d", headStart % 60))",
                    tint: viewModel.role == .hunter ? ADATheme.tacticalAmber : ADATheme.runnerGreen
                )
            }

            if let bailout = viewModel.lastBailout {
                bannerText(
                    "JAILBREAK — \(bailout.bailerUsername.uppercased()) FREED \(bailout.freedCount)",
                    tint: ADATheme.runnerGreen
                )
            }
            Spacer()
        }
        .animation(ADATheme.controlSpring, value: viewModel.jailOutside)
        .animation(ADATheme.controlSpring, value: viewModel.boundaryOutside)
        .animation(ADATheme.controlSpring, value: viewModel.jailArrivalRemaining)
        .animation(ADATheme.controlSpring, value: viewModel.bailActive)
        .animation(ADATheme.controlSpring, value: viewModel.lastBailout)
    }

    /// Shared chrome for the stacked containment/jail banners — same glass pill, same
    /// placement under the top bar, only the copy and tint differ.
    private func bannerText(_ text: String, tint: Color) -> some View {
        Text(text)
            .tacticalFont(.telemetry, size: 12)
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .tacticalGlass(in: Capsule(), tint: tint, strength: .strong)
            .padding(.horizontal, 24)
            .padding(.top, 130)
            .tacticalTransition(.move(edge: .top).combined(with: .scale(scale: 0.6, anchor: .top)).combined(with: .opacity))
            .allowsHitTesting(false)
    }

    private var catchCodeSheet: some View {
        VStack(spacing: 16) {
            Text("ENTER ARREST CODE")
                .tacticalFont(.telemetry, size: 15)
                .foregroundColor(.white)

            TextField("4-digit code", text: $viewModel.catchCodeEntry)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .tacticalFont(.display, size: 28)
                .foregroundColor(.white)
                .padding()
                .background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: ADATheme.controlCornerRadius, style: .continuous))
                .padding(.horizontal, 30)

            HStack(spacing: 14) {
                Button("CANCEL") { viewModel.cancelCatch() }
                    .buttonStyle(TacticalGhostButtonStyle(tint: .white.opacity(0.6)))

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
        .glassCard(cornerRadius: ADATheme.sheetCornerRadius, tint: ADATheme.hunterRed, strength: .strong)
        .padding(.horizontal, 24)
    }

    private var mapAnnotations: [GameMapView.Blip] {
        // The roster (viewModel.allPlayers) only gets a fresh snapshot on
        // join/leave for HUNTER/RUNNER players — it's never refreshed
        // afterward, so it still carries whatever position you were at
        // (lat/lng 0,0) the moment you joined. Render your own pin from
        // live GPS instead, and drop the stale roster copy of yourself so
        // there's no ghost pin sitting at (0,0).
        //
        // The server also broadcasts (0,0) deliberately for anyone else who's
        // currently INVISIBILITY_10MIN-buffed (masking their real position from
        // the host/spectator roster feed) — same sentinel, same fix: don't plot it.
        //
        // Only ever plots players who share this device's own role: the whole point of the
        // hunter's radar and the runner's compass is that finding the other side takes
        // active tracking, not a glance at the map. A host/spectator (no role of their own
        // to match against) still sees everyone, same as the dedicated admin/observer
        // panels already do.
        var blips = viewModel.allPlayers
            .filter { $0.id != viewModel.gamePlayerId && !($0.lat == 0 && $0.lng == 0) }
            .filter { viewModel.role == .spectator || $0.role == viewModel.role }
            .map { GameMapView.Blip(id: $0.id, coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng), kind: $0.role, username: $0.username) }

        if let selfCoordinate = viewModel.currentLocation?.coordinate {
            blips.append(GameMapView.Blip(id: viewModel.gamePlayerId, coordinate: selfCoordinate, kind: viewModel.role))
        }

        return blips
    }

    /// Buff badges other than stealth, which has its own dedicated badge above.
    private var otherActiveBuffs: [(type: PowerUpType, remaining: Int)] {
        viewModel.activeBuffRemainingSec
            .filter { $0.key != .invisibility }
            .map { (type: $0.key, remaining: $0.value) }
            .sorted { $0.type.rawValue < $1.type.rawValue }
    }

    /// Seconds left of the runners' head start, while it's running.
    private var headStartRemaining: Int? {
        guard viewModel.headStartSeconds > 0, let startedAt = socket.matchStartedAt,
              viewModel.role == .hunter || viewModel.role == .runner else { return nil }
        let left = Double(viewModel.headStartSeconds) - now.timeIntervalSince(startedAt)
        return left > 0 ? Int(left.rounded(.up)) : nil
    }

    /// "NEXT PING 0:23" in a match with a ping interval; "THERMAL: LIVE" while Thermal Vision
    /// tracks between pings; nothing in a continuous match.
    private var radarPingText: String? {
        let interval = viewModel.radarPingInterval
        guard interval > 0, let startedAt = socket.matchStartedAt,
              viewModel.role == .hunter || viewModel.role == .runner else { return nil }
        if viewModel.role == .hunter, socket.radar?.live == true, viewModel.activeBuffRemainingSec[.thermalVision] != nil {
            return "THERMAL: LIVE"
        }
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        let remaining = Int(Double(interval) - elapsed.truncatingRemainder(dividingBy: Double(interval)))
        return String(format: "NEXT PING: %d:%02d", remaining / 60, remaining % 60)
    }

    private var zoneRadiusText: String? {
        guard let zone = viewModel.zone else { return nil }
        return "ZONE: \(Int(zone.radiusMeters))m"
    }

    private var matchRemainingText: String? {
        guard let startedAt = socket.matchStartedAt else { return nil }
        let totalSeconds = viewModel.sessionSettings.durationMinutes * 60
        let elapsed = Int(now.timeIntervalSince(startedAt))
        let remaining = max(0, totalSeconds - elapsed)
        return String(format: "%02d:%02d", remaining / 60, remaining % 60)
    }
}
