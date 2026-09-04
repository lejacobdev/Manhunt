import SwiftUI
import CoreLocation

/// Post-game (or in-progress) playback of a match's GPS tracks, scrubbable via a
/// slider. Backed by GET /games/:code/replay, which returns every buffered fix
/// server.ts logged to LocationLog during the match.
struct MatchReplayView: View {
    let sessionCode: String
    @Environment(\.dismiss) private var dismiss

    @State private var tracks: [ParsedTrack] = []
    @State private var timeRange: (start: Date, end: Date)?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var scrubProgress: Double = 0
    @State private var isPlaying = false
    @State private var playbackTimer: Timer?

    private struct ParsedTrack {
        let gamePlayerId: String
        let username: String
        let role: PlayerRole
        let points: [(time: Date, lat: Double, lng: Double)]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if isLoading {
                    ProgressView().tint(.white)
                } else if let errorMessage {
                    Text(errorMessage)
                        .font(ADATheme.uiFont(size: 13, weight: .medium))
                        .foregroundColor(ADATheme.hunterRed)
                        .padding()
                } else if timeRange != nil {
                    GameMapView(
                        players: currentBlips,
                        zone: nil,
                        extractionPoint: nil,
                        decoys: [],
                        initialCenter: currentBlips.first?.coordinate
                    )
                    .edgesIgnoringSafeArea(.all)

                    VStack {
                        Spacer()
                        controls
                    }
                    .adaptiveContentWidth()
                } else {
                    Text("No location data was recorded for this match.")
                        .font(ADATheme.uiFont(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .padding()
                }
            }
            .obsidianBackdrop()
            .navigationTitle("Match Replay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(ADATheme.spatialCyan)
                }
            }
            .task { await load() }
            .onDisappear { playbackTimer?.invalidate() }
        }
        .preferredColorScheme(.dark)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Slider(value: $scrubProgress, in: 0...1) { editing in
                if editing { stopPlayback() }
            }
            .tint(ADATheme.spatialCyan)

            HStack(spacing: 14) {
                Button {
                    isPlaying ? stopPlayback() : startPlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                }
                .buttonStyle(GlassButtonStyle(tint: ADATheme.spatialCyan))

                Text(timeLabel)
                    .font(ADATheme.telemetryFont(size: 13))
                    .foregroundColor(.white.opacity(0.7))

                Spacer()
            }
        }
        .padding(16)
        .glassCard(cornerRadius: ADATheme.cardCornerRadius)
        .padding()
    }

    private func load() async {
        do {
            let replay = try await APIClient.shared.fetchReplay(code: sessionCode)
            // The backend stamps every field with JS's Date.toISOString(), which always
            // includes milliseconds ("...ss.sssZ") — ISO8601DateFormatter's default options
            // don't parse that fractional-seconds suffix and silently return nil for every
            // single point, which emptied `tracks` and made every replay show as "no data".
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let parsed = replay.players.map { player -> ParsedTrack in
                let points = player.track
                    .compactMap { pt -> (Date, Double, Double)? in
                        guard let t = formatter.date(from: pt.timestamp) else { return nil }
                        return (t, pt.lat, pt.lng)
                    }
                    .sorted { $0.0 < $1.0 }
                    .map { (time: $0.0, lat: $0.1, lng: $0.2) }
                return ParsedTrack(gamePlayerId: player.gamePlayerId, username: player.username, role: player.role, points: points)
            }
            tracks = parsed
            let allTimes = parsed.flatMap { $0.points.map(\.time) }
            if let start = allTimes.min(), let end = allTimes.max(), start < end {
                timeRange = (start, end)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private var currentBlips: [GameMapView.Blip] {
        guard let (start, end) = timeRange else { return [] }
        let targetTime = start.addingTimeInterval(scrubProgress * end.timeIntervalSince(start))
        return tracks.compactMap { track -> GameMapView.Blip? in
            guard let latest = track.points.last(where: { $0.time <= targetTime }) else { return nil }
            return GameMapView.Blip(id: track.gamePlayerId, coordinate: CLLocationCoordinate2D(latitude: latest.lat, longitude: latest.lng), kind: track.role)
        }
    }

    private var timeLabel: String {
        guard let (start, end) = timeRange else { return "--:-- / --:--" }
        let elapsed = Int(scrubProgress * end.timeIntervalSince(start))
        let total = Int(end.timeIntervalSince(start))
        return String(format: "%02d:%02d / %02d:%02d", elapsed / 60, elapsed % 60, total / 60, total % 60)
    }

    private func startPlayback() {
        isPlaying = true
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                scrubProgress = min(1, scrubProgress + 0.006)
                if scrubProgress >= 1 { stopPlayback() }
            }
        }
    }

    private func stopPlayback() {
        isPlaying = false
        playbackTimer?.invalidate()
        playbackTimer = nil
    }
}
