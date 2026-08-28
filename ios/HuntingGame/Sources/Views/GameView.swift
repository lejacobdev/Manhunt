import SwiftUI
import MapKit

struct GameView: View {
    @StateObject private var viewModel: GameViewModel
    // SocketService is a singleton ObservableObject; GameViewModel's radar/compass/inventory
    // properties merely proxy its @Published state, so this view also observes it directly —
    // otherwise those socket-driven updates wouldn't trigger a re-render.
    @ObservedObject private var socket = SocketService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var mapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    )

    init(gamePlayer: GamePlayer, session: GameSession) {
        _viewModel = StateObject(wrappedValue: GameViewModel(gamePlayer: gamePlayer, session: session))
    }

    var body: some View {
        ZStack {
            Map(coordinateRegion: $mapRegion, showsUserLocation: true, annotationItems: mapAnnotations) { item in
                MapAnnotation(coordinate: item.coordinate) {
                    PlayerBlipView(kind: item.kind)
                }
            }
            .edgesIgnoringSafeArea(.all)
            .overlay(Color.black.opacity(0.18).edgesIgnoringSafeArea(.all))

            VStack {
                topBar
                Spacer()
                if viewModel.role == .runner {
                    SpatialRadarView(
                        distanceMeters: viewModel.nearestHunterDistance,
                        bearingDegrees: viewModel.nearestHunterBearing,
                        currentHeading: viewModel.currentHeadingDegrees,
                        role: viewModel.role
                    )
                    .transition(.scale.combined(with: .opacity))
                }
                if viewModel.role == .hunter {
                    radarPanel
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                PowerUpDeckView(inventory: viewModel.inventory, onActivate: viewModel.usePowerUp)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }

            if viewModel.isCaught {
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
        .animation(ADATheme.ambientSpring, value: viewModel.catchTargetId)
        .animation(ADATheme.controlSpring, value: viewModel.role)
        .onAppear {
            viewModel.start()
            if let loc = viewModel.currentLocation {
                mapRegion.center = loc.coordinate
            }
        }
        .onDisappear { viewModel.stop() }
        .alert("Catch failed", isPresented: Binding(
            get: { viewModel.showCatchFailure != nil },
            set: { if !$0 { viewModel.showCatchFailure = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.showCatchFailure = nil }
        } message: {
            Text(viewModel.showCatchFailure ?? "")
        }
    }

    // MARK: - Chrome

    private var dimScrim: some View {
        Color.black.opacity(0.65)
            .edgesIgnoringSafeArea(.all)
            .transition(.opacity)
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

    private var radarPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "eye.fill")
                    .font(.system(size: 12, weight: .bold))
                Text("VISIBLE RUNNERS: \(viewModel.visibleRunners.count)")
                    .font(ADATheme.telemetryFont(size: 12))
            }
            .foregroundColor(ADATheme.hunterRed)

            if viewModel.visibleRunners.isEmpty {
                Text(viewModel.isRadarJammed ? "Radar jammed by an EMP power-up." : "No runners currently in range.")
                    .font(ADATheme.uiFont(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
            } else {
                ForEach(viewModel.visibleRunners) { runner in
                    Button {
                        viewModel.beginCatch(on: runner.id)
                    } label: {
                        HStack {
                            Image(systemName: "figure.run")
                            Text("CATCH \(runner.username.uppercased())")
                        }
                    }
                    .buttonStyle(GlowButtonStyle(tint: ADATheme.hunterRed))
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .padding(18)
        .glassCard(cornerRadius: ADATheme.cardCornerRadius, tint: ADATheme.hunterRed)
        .padding(.horizontal, 16)
        .animation(ADATheme.controlSpring, value: viewModel.visibleRunners.map(\.id))
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

    private var mapAnnotations: [MapBlip] {
        // The roster (viewModel.allPlayers) only gets a fresh snapshot on
        // join/leave — for non-supervisors it's never refreshed afterward,
        // so it still carries whatever position you were at (lat/lng 0,0)
        // the moment you joined. Render your own pin from live GPS instead,
        // and drop the stale roster copy of yourself so there's no ghost
        // pin sitting at (0,0).
        var blips = viewModel.allPlayers
            .filter { $0.id != viewModel.gamePlayerId }
            .map { MapBlip(id: $0.id, coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng), kind: $0.role) }

        if let selfCoordinate = viewModel.currentLocation?.coordinate {
            blips.append(MapBlip(id: viewModel.gamePlayerId, coordinate: selfCoordinate, kind: viewModel.role))
        }

        return blips
    }
}

private struct MapBlip: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let kind: PlayerRole
}

private struct PlayerBlipView: View {
    let kind: PlayerRole
    @State private var isVisible = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            .shadow(color: color.opacity(0.8), radius: 6)
            .scaleEffect(isVisible ? 1.0 : 0.3)
            .opacity(isVisible ? 1.0 : 0.0)
            .onAppear {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                    isVisible = true
                }
            }
    }

    private var color: Color { ADATheme.accent(for: kind) }
}
