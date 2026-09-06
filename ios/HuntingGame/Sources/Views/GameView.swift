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
    @State private var toastDismissWorkItem: DispatchWorkItem?
    @State private var showExitConfirm = false

    init(gamePlayer: GamePlayer, session: GameSession) {
        _viewModel = StateObject(wrappedValue: GameViewModel(gamePlayer: gamePlayer, session: session))
    }

    var body: some View {
        ZStack {
            GameMapView(
                players: mapAnnotations,
                boundsPolygon: viewModel.sessionSettings.boundsPolygon,
                jailPolygon: viewModel.sessionSettings.jailPolygon,
                zone: viewModel.zone,
                safeZones: viewModel.activeSafeZones,
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
            .adaptiveContentWidth(ADATheme.dockContentWidth)

            // Drawn after (so on top of) the dock/radar above — on the right, behind
            // the radar, it used to render underneath both and never actually show.
            recenterButton
            toastBanner
            containmentWarningBanner

            if socket.gameOverReason != nil {
                dimScrim
                gameOverOverlay
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            } else if viewModel.isOut {
                dimScrim
                eliminatedOverlay
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            } else if viewModel.isExtracted {
                dimScrim
                extractedOverlay
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            } else if viewModel.isCaught && !viewModel.isJailed {
                dimScrim
                caughtOverlay
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }

            if viewModel.catchTargetId != nil && viewModel.mode == .infection {
                dimScrim
                    .onTapGesture { viewModel.cancelCatch() }
                catchCodeSheet
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if viewModel.incomingCatchRequest != nil {
                dimScrim
                catchRequestPopup
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let denyConfirm = viewModel.pendingDenyConfirm {
                dimScrim
                denyConfirmSheet(denyConfirm)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }

            if viewModel.isCoinFlipping || viewModel.lastGambleOutcome != nil || viewModel.awaitingGambleCall {
                dimScrim
                CoinFlipView(
                    myChoice: viewModel.gambleChoicePending,
                    outcome: viewModel.lastGambleOutcome,
                    isSelf: viewModel.gamePlayerId,
                    awaitingCall: viewModel.awaitingGambleCall,
                    onCall: viewModel.callGamble,
                    onContinue: viewModel.dismissGambleResult
                )
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .animation(ADATheme.ambientSpring, value: viewModel.isCaught)
        .animation(ADATheme.ambientSpring, value: viewModel.isExtracted)
        .animation(ADATheme.ambientSpring, value: viewModel.isOut)
        .animation(ADATheme.ambientSpring, value: socket.gameOverReason)
        .animation(ADATheme.ambientSpring, value: viewModel.catchTargetId)
        .animation(ADATheme.controlSpring, value: viewModel.incomingCatchRequest)
        .animation(ADATheme.controlSpring, value: viewModel.pendingDenyConfirm)
        .animation(ADATheme.controlSpring, value: viewModel.isCoinFlipping)
        .animation(ADATheme.controlSpring, value: viewModel.role)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
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

    // MARK: - Chrome

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
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(GlassButtonStyle(tint: ADATheme.spatialCyan))
                .clipShape(Circle())
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
                        .font(.system(size: 13, weight: .bold))
                    Text(message)
                        .font(ADATheme.uiFont(size: 12, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(ADATheme.tacticalAmber)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .glassCard(cornerRadius: ADATheme.controlCornerRadius, tint: ADATheme.tacticalAmber)
                .padding(.horizontal, 24)
                .padding(.top, 130)
                .transition(.move(edge: .top).combined(with: .opacity))
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
                        .font(ADATheme.telemetryFont(size: 14))
                        .foregroundColor(.white)
                }
                // The arrest code only means anything in INFECTION, the one mode still using
                // the code-entry catch. Everywhere else it was pure noise sitting where the
                // match clock should be.
                if viewModel.role == .runner && viewModel.mode == .infection {
                    Text("CODE: \(viewModel.arrestCode)")
                        .font(ADATheme.telemetryFont(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
                if let remaining = matchRemainingText {
                    Text("TIME LEFT: \(remaining)")
                        .font(ADATheme.telemetryFont(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
                if let zoneText = zoneRadiusText {
                    Text(zoneText)
                        .font(ADATheme.telemetryFont(size: 12))
                        .foregroundColor(ADATheme.spatialCyan.opacity(0.8))
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    if viewModel.isJailed {
                        StatusBadge(icon: "lock.fill", text: "JAILED", tint: ADATheme.tacticalAmber)
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
                        StatusBadge(icon: "bolt.slash.fill", text: "JAMMED", tint: ADATheme.tacticalAmber)
                    }
                }
                Button {
                    showExitConfirm = true
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
                    diameter: ADATheme.dockPanelWidth
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
                .foregroundColor(gameOverTint)
                .shadow(color: gameOverTint, radius: 12)

            Text(gameOverHeadline)
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
                .buttonStyle(GlowButtonStyle(tint: gameOverTint))
            }
        }
        .padding(32)
        .glassCard(cornerRadius: ADATheme.sheetCornerRadius, tint: gameOverTint)
        .padding(.horizontal, 40)
        .sheet(isPresented: $showReplay) {
            MatchReplayView(sessionCode: viewModel.roomCode)
        }
    }

    /// nil for an inconclusive end (the host cut it short, or an unrecognized reason) —
    /// everything else has a real winning side, so the overlay can be colored/labeled
    /// to match instead of always reading as a neutral "match ended".
    private var gameOverWinner: PlayerRole? {
        switch socket.gameOverReason {
        case "TIME_EXPIRED", "ALL_HUNTERS_ELIMINATED": return .runner
        case "ALL_RUNNERS_RESOLVED": return .hunter
        default: return nil
        }
    }

    private var gameOverTint: Color {
        gameOverWinner.map { ADATheme.accent(for: $0) } ?? ADATheme.spatialCyan
    }

    private var gameOverHeadline: String {
        switch gameOverWinner {
        case .hunter: return "HUNTERS WIN"
        case .runner: return "RUNNERS WIN"
        default: return "MATCH ENDED"
        }
    }

    private var gameOverReasonLabel: String {
        switch socket.gameOverReason {
        case "TIME_EXPIRED": return "Time expired — the runners survived."
        case "ALL_RUNNERS_RESOLVED": return "All runners caught or extracted."
        case "ALL_HUNTERS_ELIMINATED": return "All hunters were eliminated — the runners win!"
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

    private var eliminatedOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "xmark.seal.fill")
                .font(.system(size: 36, weight: .bold))
                .foregroundColor(ADATheme.hunterRed)
                .shadow(color: ADATheme.hunterRed, radius: 12)

            Text("YOU'RE OUT")
                .font(ADATheme.displayFont(size: 20))
                .foregroundColor(.white)

            Text(eliminationReasonLabel)
                .font(ADATheme.uiFont(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            Text("Spectate the rest of the match from here.")
                .font(ADATheme.uiFont(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(32)
        .glassCard(cornerRadius: ADATheme.sheetCornerRadius, tint: ADATheme.hunterRed)
        .padding(.horizontal, 40)
    }

    private var eliminationReasonLabel: String {
        switch viewModel.eliminationReason {
        case "GAMBLE": return "You gambled and lost your last heart."
        case "BOUNDARY": return "You ran out of hearts outside the play area."
        case "JAIL_BREACH": return "You didn't make it back to the jail zone in time."
        default: return "You've been eliminated."
        }
    }

    /// The runner's incoming "did you get caught?" popup — the new request-based catch
    /// flow's core interaction, replacing the hunter's old code-entry sheet.
    private var catchRequestPopup: some View {
        VStack(spacing: 16) {
            Text("DID YOU GET CAUGHT BY \(viewModel.incomingCatchRequest?.hunterUsername.uppercased() ?? "")?")
                .font(ADATheme.telemetryFont(size: 15))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)

            if viewModel.sessionSettings.gamblingEnabled == true {
                Text("Gambling risks a heart, but never sends you to jail.")
                    .font(ADATheme.uiFont(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
            }

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

                if viewModel.sessionSettings.gamblingEnabled == true {
                    HStack(spacing: 10) {
                        Button {
                            viewModel.gambleCatch(choice: .heads)
                        } label: {
                            HStack { Image(systemName: "circle.fill"); Text("GAMBLE: HEADS") }
                        }
                        .buttonStyle(GlowButtonStyle(tint: ADATheme.tacticalAmber))

                        Button {
                            viewModel.gambleCatch(choice: .tails)
                        } label: {
                            HStack { Image(systemName: "circle"); Text("GAMBLE: TAILS") }
                        }
                        .buttonStyle(GlowButtonStyle(tint: ADATheme.tacticalAmber))
                    }
                }

                Button("NO, THAT WASN'T A CATCH") {
                    viewModel.denyCatch()
                }
                .buttonStyle(GlassButtonStyle(tint: .white.opacity(0.6)))
            }
        }
        .padding(.vertical, 26)
        .glassCard(cornerRadius: ADATheme.sheetCornerRadius, tint: ADATheme.hunterRed)
        .padding(.horizontal, 24)
    }

    /// Hunter-side follow-up after a runner taps "No" — a genuine disagreement here
    /// falls back to the host's existing override control, not a new arbitration flow.
    private func denyConfirmSheet(_ request: DenyConfirmRequest) -> some View {
        VStack(spacing: 16) {
            Text("\(request.runnerUsername.uppercased()) SAYS THAT WASN'T A CATCH")
                .font(ADATheme.telemetryFont(size: 14))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            Text("Was it an accident?")
                .font(ADATheme.uiFont(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
            Button("YES, IT WAS AN ACCIDENT") {
                viewModel.confirmDenyWasAccidental()
            }
            .buttonStyle(GlowButtonStyle(tint: ADATheme.tacticalAmber))
        }
        .padding(24)
        .glassCard(cornerRadius: ADATheme.sheetCornerRadius, tint: ADATheme.tacticalAmber)
        .padding(.horizontal, 30)
    }

    /// A persistent (not auto-dismissing) warning for straying outside the play area or,
    /// with higher priority, outside the jail zone — clears the instant the server reports
    /// back inside, no local timer of its own beyond the jail countdown display.
    private var containmentWarningBanner: some View {
        VStack {
            if viewModel.jailOutside {
                Text("LEAVE THE JAIL ZONE — RETURN IN \(viewModel.jailCountdownRemaining ?? 10)s")
                    .font(ADATheme.telemetryFont(size: 12))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassCard(cornerRadius: ADATheme.controlCornerRadius, tint: ADATheme.hunterRed)
                    .padding(.horizontal, 24)
                    .padding(.top, 130)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            } else if viewModel.boundaryOutside {
                Text("OUTSIDE THE ZONE — RETURN OR LOSE HEARTS")
                    .font(ADATheme.telemetryFont(size: 12))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassCard(cornerRadius: ADATheme.controlCornerRadius, tint: ADATheme.tacticalAmber)
                    .padding(.horizontal, 24)
                    .padding(.top, 130)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
            Spacer()
        }
        .animation(ADATheme.controlSpring, value: viewModel.jailOutside)
        .animation(ADATheme.controlSpring, value: viewModel.boundaryOutside)
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
