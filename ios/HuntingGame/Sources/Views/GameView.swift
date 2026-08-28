import SwiftUI
import MapKit

struct GameView: View {
    @StateObject private var viewModel: GameViewModel
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

            VStack {
                topBar
                Spacer()
                if viewModel.role == .runner {
                    compassPanel
                }
                if viewModel.role == .hunter {
                    radarPanel
                }
                Spacer()
                inventoryBar
            }

            if viewModel.isCaught {
                caughtOverlay
            }

            if viewModel.catchTargetId != nil {
                catchCodeSheet
            }
        }
        .onAppear {
            viewModel.start()
            if let loc = viewModel.locationManager.currentLocation {
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

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("ROLE: \(viewModel.role.displayName.uppercased())")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.green)
                if viewModel.role == .runner {
                    Text("ARREST CODE: \(viewModel.arrestCode)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                }
            }
            Spacer()
            if viewModel.isInvisible {
                Text("GHOST MODE \(viewModel.invisibilityRemainingSec)s")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(6)
                    .background(Color.purple.opacity(0.8))
                    .cornerRadius(6)
            }
            if viewModel.isRadarJammed {
                Text("RADAR JAMMED")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(6)
                    .background(Color.red.opacity(0.8))
                    .cornerRadius(6)
            }
            Button("EXIT") { dismiss() }
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.gray)
        }
        .padding()
        .background(Color.black.opacity(0.85))
    }

    private var compassPanel: some View {
        VStack {
            ZStack {
                Circle()
                    .stroke(Color.green.opacity(0.4), lineWidth: 3)
                    .frame(width: 180, height: 180)
                Image(systemName: "location.north.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)
                    .foregroundColor(.red)
                    .rotationEffect(.degrees((viewModel.nearestHunterBearing ?? 0) - (viewModel.locationManager.currentHeading?.trueHeading ?? 0)))
                    .animation(.spring(), value: viewModel.nearestHunterBearing)
                Text("\(viewModel.nearestHunterDistance ?? 0)m")
                    .font(.system(size: 20, weight: .black, design: .monospaced))
                    .foregroundColor(.white)
                    .offset(y: 50)
            }
            Text("NEAREST HUNTER RADAR")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.gray)
                .padding(.top, 4)
        }
        .padding()
        .background(Color.black.opacity(0.75))
        .cornerRadius(100)
    }

    private var radarPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("VISIBLE RUNNERS: \(viewModel.visibleRunners.count)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.red)
            ForEach(viewModel.visibleRunners) { runner in
                Button {
                    viewModel.beginCatch(on: runner.id)
                } label: {
                    Text("CATCH \(runner.username)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(Color.red.opacity(0.75))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }
        }
        .padding()
        .background(Color.black.opacity(0.75))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    private var inventoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(viewModel.inventory) { item in
                    Button {
                        viewModel.usePowerUp(item)
                    } label: {
                        HStack {
                            Image(systemName: item.iconName)
                            Text(item.displayName)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.blue.opacity(0.8))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                }
            }
            .padding()
        }
        .background(Color.black.opacity(0.85))
    }

    private var caughtOverlay: some View {
        VStack(spacing: 12) {
            Text("YOU HAVE BEEN CAUGHT")
                .font(.system(size: 22, weight: .black, design: .monospaced))
                .foregroundColor(.red)
            Text("Spectate the rest of the match from here.")
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.gray)
        }
        .padding(30)
        .background(Color.black.opacity(0.92))
        .cornerRadius(16)
    }

    private var catchCodeSheet: some View {
        VStack(spacing: 14) {
            Text("ENTER ARREST CODE")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
            TextField("4-digit code", text: $viewModel.catchCodeEntry)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .padding()
                .background(Color.white.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal, 40)
            HStack(spacing: 20) {
                Button("CANCEL") { viewModel.cancelCatch() }
                    .foregroundColor(.gray)
                Button("CONFIRM CATCH") { viewModel.confirmCatch() }
                    .fontWeight(.bold)
                    .foregroundColor(.red)
            }
            .font(.system(size: 13, design: .monospaced))
        }
        .padding(24)
        .background(Color.black.opacity(0.95))
        .cornerRadius(16)
        .padding(.horizontal, 30)
    }

    private var mapAnnotations: [MapBlip] {
        viewModel.allPlayers.map { MapBlip(id: $0.id, coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng), kind: $0.role) }
    }
}

private struct MapBlip: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let kind: PlayerRole
}

private struct PlayerBlipView: View {
    let kind: PlayerRole

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
    }

    private var color: Color {
        switch kind {
        case .hunter: return .red
        case .runner: return .green
        case .supervisor: return .blue
        case .spectator: return .gray
        }
    }
}
