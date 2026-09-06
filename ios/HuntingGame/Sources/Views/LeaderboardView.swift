import SwiftUI

struct LeaderboardView: View {
    @StateObject private var viewModel = LeaderboardViewModel()
    @EnvironmentObject var authSession: AuthSession

    var body: some View {
        NavigationStack {
            ZStack {
                RadarSweepBackdrop(accent: ADATheme.tacticalAmber)
                    .edgesIgnoringSafeArea(.all)

                VStack(spacing: 0) {
                    sortPicker

                    if viewModel.isLoading && viewModel.leaderboard == nil {
                        Spacer()
                        ProgressView().tint(ADATheme.tacticalAmber)
                        Spacer()
                    } else if let error = viewModel.errorMessage, viewModel.leaderboard == nil {
                        Spacer()
                        Text(error)
                            .font(ADATheme.uiFont(size: 13, weight: .medium))
                            .foregroundColor(ADATheme.hunterRed)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Spacer()
                    } else if let entries = viewModel.leaderboard?.entries, entries.isEmpty {
                        Spacer()
                        Text("No finished matches yet — play a game to get on the board.")
                            .font(ADATheme.uiFont(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Spacer()
                    } else {
                        list
                    }
                }
                .adaptiveContentWidth()
            }
            .obsidianBackdrop()
            .navigationTitle("Leaderboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .task { await viewModel.load() }
            .refreshable { await viewModel.load() }
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

    private var list: some View {
        ScrollView {
            VStack(spacing: 6) {
                if let entries = viewModel.leaderboard?.entries {
                    ForEach(entries) { entry in
                        row(entry, isMe: entry.user.id == authSession.currentUser?.id)
                    }
                }

                // Only shown when the player's own standing didn't already appear in the
                // top 100 above — otherwise this would just duplicate their own row.
                if let me = viewModel.leaderboard?.me,
                   viewModel.leaderboard?.entries.contains(where: { $0.user.id == me.user.id }) != true {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)
                        .padding(.vertical, 6)
                    row(me, isMe: true)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
        .animation(ADATheme.controlSpring, value: viewModel.sort)
    }

    private func row(_ entry: LeaderboardEntry, isMe: Bool) -> some View {
        NavigationLink {
            PublicProfileView(userId: entry.user.id, displayName: entry.user.tagLabel)
        } label: {
            HStack(spacing: 12) {
                rankBadge(entry.rank)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.user.tagLabel)
                        .font(ADATheme.uiFont(size: 13, weight: isMe ? .bold : .semibold))
                        .foregroundColor(.white)
                    Text("\(entry.matchesPlayed) matches · \(entry.winRatePercent)% wins")
                        .font(ADATheme.telemetryFont(size: 9))
                        .foregroundColor(.white.opacity(0.4))
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(entry.value(for: viewModel.sort))")
                        .font(ADATheme.displayFont(size: 18))
                        .foregroundColor(ADATheme.tacticalAmber)
                    Text(viewModel.sort.label)
                        .font(ADATheme.telemetryFont(size: 8))
                        .foregroundColor(.white.opacity(0.3))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassCard(cornerRadius: ADATheme.controlCornerRadius, tint: isMe ? ADATheme.tacticalAmber : .white)
        }
        .buttonStyle(.plain)
    }

    private func rankBadge(_ rank: Int) -> some View {
        let tint: Color = rank == 1 ? ADATheme.tacticalAmber : rank <= 3 ? .white.opacity(0.85) : .white.opacity(0.4)
        return ZStack {
            if rank <= 3 {
                Image(systemName: "medal.fill")
                    .font(.system(size: 20))
                    .foregroundColor(tint)
                    .shadow(color: rank == 1 ? tint.opacity(0.6) : .clear, radius: 6)
            } else {
                Text("\(rank)")
                    .font(ADATheme.telemetryFont(size: 13))
                    .foregroundColor(tint)
            }
        }
        .frame(width: 30)
    }
}
