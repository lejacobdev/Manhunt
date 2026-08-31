import SwiftUI

/// Your past matches (GET /games/history/mine) — tap an ended one to scrub through
/// its replay.
struct MatchHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [HistoryEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var replaySessionCode: String?

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
                } else if entries.isEmpty {
                    Text("No matches yet — your finished games will show up here.")
                        .font(ADATheme.uiFont(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .padding()
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(entries) { entry in
                                row(for: entry)
                            }
                        }
                        .padding()
                    }
                }
            }
            .obsidianBackdrop()
            .navigationTitle("Match History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(ADATheme.spatialCyan)
                }
            }
            .task { await load() }
            .sheet(item: Binding(
                get: { replaySessionCode.map { IdentifiableCode(code: $0) } },
                set: { replaySessionCode = $0?.code }
            )) { wrapped in
                MatchReplayView(sessionCode: wrapped.code)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(for entry: HistoryEntry) -> some View {
        let isEnded = entry.session.status == .ended
        return Button {
            guard isEnded else { return }
            replaySessionCode = entry.session.code
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
                    .foregroundColor(isEnded ? ADATheme.spatialCyan : .white.opacity(0.3))

                if isEnded {
                    Image(systemName: "play.circle.fill")
                        .foregroundColor(ADATheme.spatialCyan)
                }
            }
            .padding(12)
            .glassCard(cornerRadius: ADATheme.controlCornerRadius)
        }
        .buttonStyle(.plain)
        .opacity(isEnded ? 1.0 : 0.6)
    }

    private func resultLabel(for entry: HistoryEntry) -> String {
        if entry.isExtracted { return "EXTRACTED SAFELY" }
        if entry.isCaught { return "CAUGHT" }
        return entry.role.displayName.uppercased()
    }

    private func load() async {
        do {
            entries = try await APIClient.shared.gameHistory()
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
