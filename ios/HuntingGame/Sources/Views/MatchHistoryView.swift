import SwiftUI

/// Your past matches (GET /games/history/mine) — tap an ended one to scrub through its
/// replay, swipe one away to remove it from your own list, or jump back into whatever
/// match is still open (moved here from Mission Control, which only ever showed one thing
/// at a time anyway).
struct MatchHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [HistoryEntry] = []
    @State private var unreadableCount = 0
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var replaySessionCode: String?
    @State private var rejoinLaunch: RejoinLaunch?
    @State private var isRejoining = false
    @State private var showClearConfirm = false
    /// Separate from `errorMessage` (which replaces the whole list on a *load* failure) —
    /// a failed rejoin/delete/clear shouldn't blank out an already-loaded, otherwise-fine list.
    @State private var actionError: String?
    @State private var currentSession: GameSession?
    @State private var currentPlayer: GamePlayer?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView().tint(.white)
                } else if let errorMessage {
                    Text(errorMessage)
                        .font(ADATheme.uiFont(size: 13, weight: .medium))
                        .foregroundColor(ADATheme.hunterRed)
                        .padding()
                } else {
                    List {
                        if let session = currentSession, let player = currentPlayer {
                            currentSessionCard(session: session, player: player)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        }

                        if entries.isEmpty && currentSession == nil {
                            Text("No matches yet — your finished games will show up here.")
                                .font(ADATheme.uiFont(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.4))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        } else {
                            ForEach(entries) { entry in
                                row(for: entry)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        // Only a finished match can be individually removed —
                                        // matches POST /history/:id/hide's own restriction, and
                                        // a still-open one wouldn't make sense to "delete" while
                                        // it's still tracked live via GET /active/mine anyway.
                                        if entry.session.status == .ended {
                                            Button(role: .destructive) {
                                                Task { await hide(entry) }
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                    }
                            }

                            if unreadableCount > 0 {
                                Text(unreadableCount == 1
                                     ? "1 older match couldn't be read and was skipped."
                                     : "\(unreadableCount) older matches couldn't be read and were skipped.")
                                    .font(ADATheme.telemetryFont(size: 10))
                                    .foregroundColor(ADATheme.tacticalAmber.opacity(0.7))
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .adaptiveContentWidth()
                }
            }
            .obsidianBackdrop()
            .navigationTitle("Match History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if entries.contains(where: { $0.session.status == .ended }) {
                        Button("Clear") { showClearConfirm = true }
                            .foregroundColor(ADATheme.hunterRed)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(ADATheme.spatialCyan)
                }
            }
            .task {
                async let historyTask: Void = load()
                async let currentTask: Void = loadCurrentSession()
                _ = await (historyTask, currentTask)
            }
            .confirmationDialog("Clear match history?", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("Clear History", role: .destructive) { Task { await clearHistory() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This only clears your own list — it doesn't affect other players' history or replays.")
            }
            .sheet(item: Binding(
                get: { replaySessionCode.map { IdentifiableCode(code: $0) } },
                set: { replaySessionCode = $0?.code }
            )) { wrapped in
                MatchReplayView(sessionCode: wrapped.code)
            }
            .fullScreenCover(item: $rejoinLaunch) { launch in
                GameLobbyView(gamePlayer: launch.player, session: launch.session)
            }
            .alert("Couldn't do that", isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionError ?? "")
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Current game (moved here from Mission Control)

    private func currentSessionCard(session: GameSession, player: GamePlayer) -> some View {
        let tint = statusColor(for: session.status)
        return VStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text("CODE \(session.code) · \(session.mode.displayName.uppercased())")
                    .font(ADATheme.telemetryFont(size: 13))
                    .foregroundColor(.white)
            }
            Text(session.status.rawValue)
                .font(ADATheme.telemetryFont(size: 11))
                .foregroundColor(tint)

            // Starting, settings, and inviting friends all happen inside the lobby itself
            // (GameLobbyView) rather than from this card — one door in either way. Already
            // have the player/session in hand from GET /active/mine, so this launches
            // straight in without the extra round trip rejoin(_:) below needs.
            Button("ENTER") { rejoinLaunch = RejoinLaunch(player: player, session: session) }
                .buttonStyle(GlowButtonStyle(tint: tint))
        }
        .padding(18)
        .glassCard(cornerRadius: ADATheme.cardCornerRadius, tint: tint)
    }

    private func statusColor(for status: GameStatus) -> Color {
        switch status {
        case .lobby: return ADATheme.spatialCyan
        case .active: return ADATheme.runnerGreen
        case .paused: return ADATheme.tacticalAmber
        case .ended: return ADATheme.neutralGray
        }
    }

    private func loadCurrentSession() async {
        guard let result = try? await APIClient.shared.activeSession() else {
            currentSession = nil
            currentPlayer = nil
            return
        }
        currentSession = result.session
        currentPlayer = result.player
    }

    // MARK: - History rows

    private func row(for entry: HistoryEntry) -> some View {
        let isEnded = entry.session.status == .ended
        return Button {
            if isEnded {
                replaySessionCode = entry.session.code
            } else {
                Task { await rejoin(entry) }
            }
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(ADATheme.accent(for: entry.role))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(entry.session.mode.displayName.uppercased()) · \(entry.session.code)")
                        .font(ADATheme.uiFont(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Text(resultLabel(for: entry))
                        .font(ADATheme.telemetryFont(size: 10))
                        .foregroundColor(.white.opacity(0.45))
                }

                Spacer()

                Text(entry.session.status.rawValue)
                    .font(ADATheme.telemetryFont(size: 10))
                    .foregroundColor(isEnded ? ADATheme.spatialCyan : ADATheme.runnerGreen)

                Image(systemName: isEnded ? "play.circle.fill" : "arrow.uturn.backward.circle.fill")
                    .foregroundColor(isEnded ? ADATheme.spatialCyan : ADATheme.runnerGreen)
            }
            .padding(12)
            .glassCard(cornerRadius: ADATheme.controlCornerRadius)
        }
        .buttonStyle(.plain)
        .disabled(isRejoining)
    }

    /// Rejoins a still-open (lobby or active) match from a history row — the current-game
    /// card above already has the player/session in hand, so it skips this round trip.
    private func rejoin(_ entry: HistoryEntry) async {
        isRejoining = true
        defer { isRejoining = false }
        do {
            let result = try await APIClient.shared.rejoinGame(code: entry.session.code)
            rejoinLaunch = RejoinLaunch(player: result.player, session: result.session)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func hide(_ entry: HistoryEntry) async {
        do {
            try await APIClient.shared.hideHistoryEntry(playerId: entry.id)
            entries.removeAll { $0.id == entry.id }
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func clearHistory() async {
        do {
            try await APIClient.shared.clearHistory()
            entries.removeAll { $0.session.status == .ended }
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func resultLabel(for entry: HistoryEntry) -> String {
        if entry.isExtracted { return "EXTRACTED SAFELY" }
        if entry.isCaught { return "CAUGHT" }
        return entry.role.displayName.uppercased()
    }

    private func load() async {
        do {
            let result = try await APIClient.shared.gameHistory()
            entries = result.entries
            unreadableCount = result.unreadableCount
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct IdentifiableCode: Identifiable {
    let code: String
    var id: String { code }
}

private struct RejoinLaunch: Identifiable {
    let player: GamePlayer
    let session: GameSession
    var id: String { player.id + session.id }
}
