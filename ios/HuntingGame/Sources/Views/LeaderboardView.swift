import SwiftUI

struct LeaderboardView: View {
    @StateObject private var viewModel = LeaderboardViewModel()
    @EnvironmentObject var authSession: AuthSession
    @ObservedObject private var gameCenter = GameCenterManager.shared
    @State private var gameCenterDestination: GameCenterDestination?

    /// No backdrop or NavigationStack of its own — LobbyView owns both, so its stationary
    /// backdrop shows through this page and the friend-profile rows below push onto its
    /// stack.
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Leaderboard")
                    .tacticalFont(.display, size: 20)
                    .foregroundColor(.white)

                // This screen ranks you against your own players; Game Center's board is the
                // whole world's. Only offered once Game Center is actually connected.
                if gameCenter.isConnected {
                    HStack {
                        Spacer()
                        Button {
                            gameCenterDestination = .leaderboard(sort: viewModel.sort.rawValue)
                        } label: {
                            Image(systemName: "globe.americas.fill")
                                .tacticalFont(.symbol, size: 18, weight: .semibold)
                                .foregroundColor(ADATheme.spatialCyan)
                                .padding(8)
                        }
                        .accessibilityLabel("Open this leaderboard in Game Center")
                    }
                    .padding(.horizontal, 12)
                }
            }
            .padding(.top, 12)

            sortPicker

            if viewModel.isLoading && viewModel.leaderboard == nil {
                Spacer()
                ProgressView().tint(ADATheme.tacticalAmber)
                Spacer()
            } else if let error = viewModel.errorMessage, viewModel.leaderboard == nil {
                Spacer()
                Text(error)
                    .tacticalFont(.ui, size: 13, weight: .medium)
                    .foregroundColor(ADATheme.hunterRedText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
            } else if let entries = viewModel.leaderboard?.entries, entries.isEmpty {
                Spacer()
                Text("No finished matches yet — play a game to get on the board.")
                    .tacticalFont(.ui, size: 13, weight: .medium)
                    .tacticalText(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
            } else {
                list
            }
        }
        .adaptiveContentWidth()
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
        .sheet(item: $gameCenterDestination) { destination in
            GameCenterView(destination: destination) { gameCenterDestination = nil }
                .ignoresSafeArea()
        }
    }

    private var sortPicker: some View {
        Picker("Sort", selection: $viewModel.sort) {
            ForEach(LeaderboardSort.allCases) { sort in
                Text(sort.label).tag(sort)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// Top three on a podium, everyone else as one glass list with hairline dividers (one
    /// surface, not a card per row), and your own standing pinned to the bottom edge so you
    /// never have to scroll to find yourself.
    private var list: some View {
        let entries = viewModel.leaderboard?.entries ?? []
        let podiumEntries = entries.count >= 3 ? Array(entries.prefix(3)) : []
        let rest = podiumEntries.isEmpty ? entries : Array(entries.dropFirst(3))
        let me = viewModel.leaderboard?.me

        return ScrollView {
            VStack(spacing: 14) {
                if !podiumEntries.isEmpty {
                    podium(podiumEntries)
                }

                if !rest.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(rest.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 {
                                Rectangle()
                                    .fill(Color.white.opacity(0.07))
                                    .frame(height: 0.5)
                                    .padding(.leading, 56)
                            }
                            row(entry, isMe: entry.user.id == authSession.currentUser?.id)
                        }
                    }
                    .padding(.vertical, 4)
                    .glassCard()
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
        .safeAreaInset(edge: .bottom) {
            if let me {
                myStanding(me)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
        .animation(ADATheme.controlSpring, value: viewModel.sort)
    }

    private func podium(_ top: [LeaderboardEntry]) -> some View {
        // Silver, gold, bronze — the winner in the middle and tallest.
        HStack(alignment: .bottom, spacing: 10) {
            podiumTile(top[1], height: 128)
            podiumTile(top[0], height: 152)
            podiumTile(top[2], height: 116)
        }
        .padding(.top, 4)
    }

    private func podiumTile(_ entry: LeaderboardEntry, height: CGFloat) -> some View {
        let medal = medalColor(entry.rank)
        let isMe = entry.user.id == authSession.currentUser?.id
        return NavigationLink {
            PublicProfileView(userId: entry.user.id, displayName: entry.user.tagLabel)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "medal.fill")
                    .tacticalFont(.symbol, size: entry.rank == 1 ? 26 : 21, weight: .regular)
                    .foregroundColor(medal)
                    .shadow(color: medal.opacity(0.55), radius: 8)
                Text(entry.user.tagLabel)
                    .tacticalFont(.ui, size: 12, weight: isMe ? .bold : .semibold)
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Text(entry.displayValue(for: viewModel.sort))
                    .tacticalFont(.display, size: entry.rank == 1 ? 22 : 18)
                    .foregroundColor(medal)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(viewModel.sort.label)
                    .tacticalFont(.telemetry, size: 8)
                    .tacticalText(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .glassCard(tint: entry.rank == 1 ? ADATheme.tacticalAmber : (isMe ? ADATheme.tacticalAmber : .clear))
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.96))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rank \(entry.rank), \(entry.user.tagLabel), \(entry.displayValue(for: viewModel.sort)) \(viewModel.sort.label)")
    }

    private func myStanding(_ me: LeaderboardEntry) -> some View {
        HStack(spacing: 12) {
            Text("#\(me.rank)")
                .tacticalFont(.display, size: 18)
                .foregroundColor(ADATheme.tacticalAmber)
                .frame(minWidth: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text("YOUR RANK")
                    .tacticalFont(.telemetry, size: 9)
                    .tacticalText(.secondary)
                Text("\(me.matchesPlayed) matches · \(me.winRatePercent)% wins")
                    .tacticalFont(.ui, size: 12, weight: .semibold)
                    .foregroundColor(.white)
            }
            Spacer()
            Text(me.displayValue(for: viewModel.sort))
                .tacticalFont(.display, size: 16)
                .foregroundColor(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .tacticalGlass(in: Capsule(), tint: ADATheme.tacticalAmber)
        .accessibilityElement(children: .combine)
    }

    private func medalColor(_ rank: Int) -> Color {
        switch rank {
        case 1: return ADATheme.tacticalAmber
        case 2: return Color(hex: "#C9D1DC")
        default: return Color(hex: "#C98A5A")
        }
    }

    private func row(_ entry: LeaderboardEntry, isMe: Bool) -> some View {
        NavigationLink {
            PublicProfileView(userId: entry.user.id, displayName: entry.user.tagLabel)
        } label: {
            HStack(spacing: 12) {
                rankBadge(entry.rank)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.user.tagLabel)
                        .tacticalFont(.ui, size: 13, weight: isMe ? .bold : .semibold)
                        .foregroundColor(isMe ? ADATheme.tacticalAmber : .white)
                    Text("\(entry.matchesPlayed) matches · \(entry.winRatePercent)% wins")
                        .tacticalFont(.telemetry, size: 9)
                        .tacticalText(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 0) {
                    Text(entry.displayValue(for: viewModel.sort))
                        .tacticalFont(.display, size: viewModel.sort == .playtime ? 14 : 18)
                        .foregroundColor(ADATheme.tacticalAmber)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(viewModel.sort.label)
                        .tacticalFont(.telemetry, size: 8)
                        .tacticalText(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(isMe ? ADATheme.tacticalAmber.opacity(0.10) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func rankBadge(_ rank: Int) -> some View {
        let tint: Color = rank == 1 ? ADATheme.tacticalAmber : rank <= 3 ? .white.opacity(0.85) : .white.opacity(0.4)
        return ZStack {
            if rank <= 3 {
                Image(systemName: "medal.fill")
                    .tacticalFont(.symbol, size: 20, weight: .regular)
                    .foregroundColor(tint)
                    .shadow(color: rank == 1 ? tint.opacity(0.6) : .clear, radius: 6)
            } else {
                Text("\(rank)")
                    .tacticalFont(.telemetry, size: 13)
                    .foregroundColor(tint)
            }
        }
        .frame(width: 30)
    }
}
