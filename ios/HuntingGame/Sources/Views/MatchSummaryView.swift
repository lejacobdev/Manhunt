import SwiftUI

/// GET /games/:code/summary — built server-side from what the match recorded.
struct MatchSummary: Decodable {
    struct Player: Decodable, Identifiable {
        let gamePlayerId: String
        let userId: String
        let username: String
        let role: PlayerRole
        let startedAs: PlayerRole
        let squad: String?
        let hearts: Int
        let survived: Bool
        let isOut: Bool
        let outReason: String?
        let distanceMeters: Int
        let catches: Int
        let timesCaught: Int
        let jailbreaks: Int
        let freedOthers: Int
        let powerUpsCollected: Int
        let powerUpsUsed: [String: Int]
        var id: String { gamePlayerId }
        var powerUpsUsedTotal: Int { powerUpsUsed.values.reduce(0, +) }
    }

    struct Highlight: Decodable, Identifiable {
        let title: String
        let username: String
        let gamePlayerId: String
        let value: String
        var id: String { title }
    }

    struct Moment: Decodable, Identifiable {
        let at: Int
        let kind: String
        let text: String
        var id: String { "\(at)-\(text)" }
    }

    let code: String
    let mode: GameMode
    let durationSeconds: Int?
    let endReason: String?
    let winningSquad: String?
    let players: [Player]
    let highlights: [Highlight]
    let timeline: [Moment]
}

/// After a match: how it ended, the highlights, everyone's numbers and what happened when —
/// with the replay one tap away.
struct MatchSummaryView: View {
    let sessionCode: String
    var myUserId: String?

    @Environment(\.dismiss) private var dismiss
    @State private var summary: MatchSummary?
    /// Shown instead of loading — the simulator screenshot scenarios.
    var preloaded: MatchSummary? = nil
    @State private var errorMessage: String?
    @State private var showReplay = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let summary {
                        header(summary)
                        if !summary.highlights.isEmpty { highlights(summary.highlights) }
                        players(summary)
                        if !summary.timeline.isEmpty { timeline(summary.timeline) }
                        Button {
                            showReplay = true
                        } label: {
                            HStack { Image(systemName: "play.circle.fill"); Text("WATCH THE REPLAY") }
                        }
                        .buttonStyle(GlowButtonStyle(tint: ADATheme.spatialCyan))
                        .padding(.horizontal)
                    } else if let errorMessage {
                        Text(errorMessage)
                            .tacticalFont(.ui, size: 13, weight: .medium)
                            .foregroundColor(ADATheme.hunterRedText)
                            .multilineTextAlignment(.center)
                            .padding(.top, 60)
                    } else {
                        ProgressView().tint(.white).padding(.top, 80)
                    }
                }
                .padding(.vertical, 20)
                .adaptiveContentWidth()
            }
            .background(RadarSweepBackdrop(accent: ADATheme.spatialCyan).edgesIgnoringSafeArea(.all))
            .obsidianBackdrop()
            .navigationTitle("Match Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
            .sheet(isPresented: $showReplay) { MatchReplayView(sessionCode: sessionCode) }
        }
        .preferredColorScheme(.dark)
    }

    private func load() async {
        if let preloaded { summary = preloaded; return }
        // The last fixes and the end of the match are written as it ends; a moment's grace
        // means the summary opened straight from the game-over screen is complete.
        for attempt in 0..<3 {
            do {
                let loaded = try await APIClient.shared.matchSummary(code: sessionCode)
                summary = loaded
                if loaded.endReason != nil || attempt == 2 { return }
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // MARK: - Sections

    private func header(_ s: MatchSummary) -> some View {
        let me = s.players.first { $0.userId == myUserId }
        return VStack(spacing: 8) {
            Text(resultHeadline(s, me: me))
                .tacticalFont(.display, size: 26)
                .foregroundColor(resultTint(s, me: me))
                .multilineTextAlignment(.center)
            Text("\(s.mode.displayName.uppercased()) · CODE \(s.code)\(s.durationSeconds.map { " · \(durationLabel($0))" } ?? "")")
                .tacticalFont(.telemetry, size: 11)
                .tacticalText(.secondary)
            if let me {
                HStack(spacing: 10) {
                    stat("\(me.catches)", "CATCHES", ADATheme.hunterRed)
                    stat(distanceLabel(me.distanceMeters), "DISTANCE", ADATheme.spatialCyan)
                    stat("\(me.powerUpsUsedTotal)", "POWER-UPS", ADATheme.tacticalAmber)
                    stat("\(me.hearts)", "HEARTS LEFT", ADATheme.runnerGreen)
                }
                .padding(.top, 8)
            }
        }
        .padding(20)
        .glassCard(cornerRadius: ADATheme.sheetCornerRadius, tint: resultTint(s, me: me))
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
    }

    private func stat(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .tacticalFont(.display, size: 20)
                .foregroundColor(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .tacticalFont(.telemetry, size: 8)
                .tacticalText(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: ADATheme.controlCornerRadius)
    }

    private func highlights(_ list: [MatchSummary.Highlight]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("HIGHLIGHTS")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(list) { h in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(h.title.uppercased())
                            .tacticalFont(.telemetry, size: 9)
                            .foregroundColor(ADATheme.tacticalAmber)
                        Text(h.username)
                            .tacticalFont(.ui, size: 15, weight: .bold)
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(h.value)
                            .tacticalFont(.telemetry, size: 11)
                            .foregroundColor(.white.opacity(0.55))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .glassCard(cornerRadius: ADATheme.cardCornerRadius)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.horizontal)
    }

    private func players(_ s: MatchSummary) -> some View {
        let sorted = s.players.filter { $0.startedAs != .spectator }.sorted {
            if $0.role != $1.role { return $0.role == .hunter }
            return $0.catches + $0.freedOthers > $1.catches + $1.freedOthers
        }
        return VStack(alignment: .leading, spacing: 8) {
            sectionLabel("PLAYERS")
            VStack(spacing: 0) {
                ForEach(sorted) { p in
                    if p.id != sorted.first?.id {
                        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5).padding(.leading, 34)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        Circle()
                            .fill(ADATheme.accent(for: p.role))
                            .frame(width: 10, height: 10)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(p.username)
                                    .tacticalFont(.ui, size: 14, weight: p.userId == myUserId ? .bold : .semibold)
                                    .foregroundColor(.white)
                                if let squad = p.squad, !squad.isEmpty {
                                    Text(squad.uppercased())
                                        .tacticalFont(.telemetry, size: 9)
                                        .foregroundColor(ADATheme.spatialCyan)
                                }
                                Spacer()
                                Text(statusLabel(p))
                                    .tacticalFont(.telemetry, size: 9)
                                    .foregroundColor(p.survived ? ADATheme.runnerGreen : p.isOut ? ADATheme.hunterRed : .white.opacity(0.64))
                            }
                            Text(detailLine(p))
                                .tacticalFont(.telemetry, size: 10)
                                .tacticalText(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let reason = p.outReason {
                                Text("Out: \(reason)")
                                    .tacticalFont(.ui, size: 11, weight: .medium)
                                    .foregroundColor(ADATheme.hunterRed.opacity(0.85))
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .accessibilityElement(children: .combine)
                }
            }
            .glassCard()
        }
        .padding(.horizontal)
    }

    private func timeline(_ moments: [MatchSummary.Moment]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("WHAT HAPPENED")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(moments) { m in
                    HStack(alignment: .top, spacing: 12) {
                        Text(clock(m.at))
                            .tacticalFont(.telemetry, size: 11)
                            .tacticalText(.secondary)
                            .frame(width: 44, alignment: .leading)
                        Image(systemName: icon(for: m.kind))
                            .tacticalFont(.symbol, size: 11, weight: .bold)
                            .foregroundColor(tint(for: m.kind))
                            .frame(width: 16)
                        Text(m.text)
                            .tacticalFont(.ui, size: 13, weight: .medium)
                            .foregroundColor(.white.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .glassCard()
        }
        .padding(.horizontal)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .tacticalFont(.telemetry, size: 11)
            .tacticalText(.secondary)
            .padding(.leading, 4)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Wording

    private func resultHeadline(_ s: MatchSummary, me: MatchSummary.Player?) -> String {
        if let squad = s.winningSquad {
            return squad == me?.squad ? "Your squad won" : "Squad \(squad) won"
        }
        let winner: PlayerRole? = {
            switch s.endReason {
            case "TIME_EXPIRED", "ALL_HUNTERS_ELIMINATED": return .runner
            case "ALL_RUNNERS_RESOLVED": return .hunter
            default: return nil
            }
        }()
        guard let winner else {
            if s.endReason == "DRAW" || s.endReason == "TIME_EXPIRED_DRAW" { return "A draw" }
            return "Match ended"
        }
        guard let me, me.role != .spectator else { return winner == .hunter ? "Hunters won" : "Runners won" }
        return me.role == winner ? "You won" : (winner == .hunter ? "Hunters won" : "Runners won")
    }

    private func resultTint(_ s: MatchSummary, me: MatchSummary.Player?) -> Color {
        let headline = resultHeadline(s, me: me)
        if headline.hasPrefix("You") || headline == "Your squad won" { return ADATheme.runnerGreen }
        if headline == "Match ended" || headline == "A draw" { return ADATheme.spatialCyan }
        return ADATheme.hunterRed
    }

    private func statusLabel(_ p: MatchSummary.Player) -> String {
        if p.survived { return "SURVIVED" }
        if p.isOut { return "OUT" }
        if p.startedAs == .runner && p.role == .hunter { return "TURNED" }
        return p.role.displayName.uppercased()
    }

    private func detailLine(_ p: MatchSummary.Player) -> String {
        var parts = [distanceLabel(p.distanceMeters)]
        if p.catches > 0 { parts.append("\(p.catches) catch\(p.catches == 1 ? "" : "es")") }
        if p.timesCaught > 0 { parts.append("caught \(p.timesCaught)×") }
        if p.freedOthers > 0 { parts.append("freed \(p.freedOthers)") }
        if p.powerUpsUsedTotal > 0 {
            parts.append(p.powerUpsUsed.sorted { $0.value > $1.value }.map { $0.value > 1 ? "\($0.key) ×\($0.value)" : $0.key }.joined(separator: ", "))
        }
        parts.append("\(p.hearts) ♥ left")
        return parts.joined(separator: " · ")
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "catch": return "hand.raised.fill"
        case "infect": return "allergens"
        case "jailbreak": return "lock.open.fill"
        case "revive": return "arrow.uturn.backward.circle.fill"
        case "out": return "xmark.seal.fill"
        case "powerup": return "bolt.fill"
        default: return "circle.fill"
        }
    }

    private func tint(for kind: String) -> Color {
        switch kind {
        case "catch", "out": return ADATheme.hunterRed
        case "infect": return ADATheme.stealthPurple
        case "jailbreak", "revive": return ADATheme.runnerGreen
        case "powerup": return ADATheme.tacticalAmber
        default: return .white
        }
    }

    private func clock(_ seconds: Int) -> String { String(format: "%d:%02d", seconds / 60, seconds % 60) }

    private func durationLabel(_ seconds: Int) -> String {
        seconds >= 3600 ? "\(seconds / 3600)H \((seconds % 3600) / 60)M" : "\(seconds / 60) MIN"
    }

    private func distanceLabel(_ meters: Int) -> String {
        meters >= 1000 ? String(format: "%.2f km", Double(meters) / 1000) : "\(meters) m"
    }
}
