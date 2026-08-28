import SwiftUI
import CoreLocation

struct LobbyView: View {
    @StateObject private var viewModel = LobbyViewModel()
    @StateObject private var locationManager = LocationManager()
    @EnvironmentObject var authSession: AuthSession
    @State private var showCreateSheet = false
    @State private var showFriends = false
    @State private var launchedGame: (player: GamePlayer, session: GameSession)?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                header

                if let user = authSession.currentUser {
                    Text("Signed in as \(user.tagLabel)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.gray)
                }

                joinSection

                Button {
                    showCreateSheet = true
                } label: {
                    Text("HOST NEW GAME")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue.opacity(0.85))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .padding(.horizontal)

                Button {
                    showFriends = true
                } label: {
                    Text("FRIENDS")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.white.opacity(0.1))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .padding(.horizontal)

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.red)
                }

                if let session = viewModel.activeSession, let player = viewModel.activePlayer {
                    sessionStatusCard(session: session, player: player)
                }

                Spacer()

                Button("Sign Out") { authSession.signOut() }
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.gray)
                    .padding(.bottom, 20)
            }
            .background(Color.black.edgesIgnoringSafeArea(.all))
            .sheet(isPresented: $showCreateSheet) {
                CreateGameSheet(viewModel: viewModel, locationManager: locationManager)
            }
            .sheet(isPresented: $showFriends) {
                FriendsView()
            }
            .fullScreenCover(item: Binding(
                get: { launchedGame.map { GameLaunch(player: $0.player, session: $0.session) } },
                set: { _ in launchedGame = nil }
            )) { launch in
                GameView(gamePlayer: launch.player, session: launch.session)
            }
            .onAppear { locationManager.requestAuthorizationAndStart() }
        }
    }

    private var header: some View {
        Text("HUNTING GAME")
            .font(.system(size: 26, weight: .black, design: .monospaced))
            .foregroundColor(.green)
            .padding(.top, 40)
    }

    private var joinSection: some View {
        VStack(spacing: 10) {
            TextField("Game code", text: $viewModel.joinCodeInput)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .multilineTextAlignment(.center)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .padding()
                .background(Color.white.opacity(0.08))
                .cornerRadius(8)

            Picker("Role", selection: $viewModel.selectedRole) {
                ForEach([PlayerRole.runner, .hunter, .spectator], id: \.self) { role in
                    Text(role.displayName).tag(role)
                }
            }
            .pickerStyle(.segmented)

            if viewModel.selectedMode == .squad {
                TextField("Squad name", text: $viewModel.squadName)
                    .padding()
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(8)
            }

            Button {
                Task {
                    await viewModel.joinGame()
                    if let player = viewModel.activePlayer, let session = viewModel.activeSession {
                        launchedGame = (player, session)
                    }
                }
            } label: {
                Text("JOIN GAME")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.green.opacity(0.85))
                    .foregroundColor(.black)
                    .cornerRadius(10)
            }
        }
        .padding(.horizontal)
    }

    private func sessionStatusCard(session: GameSession, player: GamePlayer) -> some View {
        VStack(spacing: 8) {
            Text("Code: \(session.code)  ·  Mode: \(session.mode.displayName)")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
            Text("Status: \(session.status.rawValue)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.gray)

            HStack(spacing: 12) {
                if player.role == .supervisor && session.status == .lobby {
                    Button("START GAME") {
                        Task {
                            await viewModel.startGame()
                            if let updated = viewModel.activeSession {
                                launchedGame = (player, updated)
                            }
                        }
                    }
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .padding(8)
                    .background(Color.orange.opacity(0.85))
                    .foregroundColor(.black)
                    .cornerRadius(8)
                }

                Button("ENTER") { launchedGame = (player, session) }
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .padding(8)
                    .background(Color.blue.opacity(0.85))
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
        }
        .padding()
        .background(Color.white.opacity(0.06))
        .cornerRadius(12)
        .padding(.horizontal)
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("Mode", selection: $viewModel.selectedMode) {
                    ForEach(GameMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                VStack(alignment: .leading) {
                    Text("Duration: \(Int(viewModel.durationMinutes)) min")
                    Slider(value: $viewModel.durationMinutes, in: 10...180, step: 5)
                    Text("Radar interval: \(Int(viewModel.radarIntervalSec))s")
                    Slider(value: $viewModel.radarIntervalSec, in: 15...300, step: 15)
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal)

                Text("Tap the map to draw the public play-area boundary (min. 3 points). Power-ups only spawn on verified public land inside it.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray)
                    .padding(.horizontal)

                BoundaryMapView(
                    points: $viewModel.boundaryPoints,
                    centerCoordinate: locationManager.currentLocation?.coordinate ?? CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
                )
                .frame(height: 300)
                .cornerRadius(12)
                .padding(.horizontal)

                HStack {
                    Button("Clear") { viewModel.resetBoundary() }
                        .font(.system(size: 12, design: .monospaced))
                    Spacer()
                    Text("\(viewModel.boundaryPoints.count) points")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.gray)
                }
                .padding(.horizontal)

                if let error = viewModel.errorMessage {
                    Text(error).font(.system(size: 12, design: .monospaced)).foregroundColor(.red)
                }

                Button {
                    Task {
                        await viewModel.createGame()
                        if viewModel.activeSession != nil { dismiss() }
                    }
                } label: {
                    if viewModel.isLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("CREATE GAME").font(.system(size: 14, weight: .bold, design: .monospaced)).frame(maxWidth: .infinity)
                    }
                }
                .padding()
                .background(Color.green.opacity(0.85))
                .foregroundColor(.black)
                .cornerRadius(10)
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top)
            .navigationTitle("Host a Game")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
