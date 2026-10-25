import SwiftUI

/// A story-sized (9:16) picture of how a match went, for sharing to Instagram, Snapchat or
/// Messages. Drawn with SwiftUI and rendered to an image, so it always matches the app.
struct ShareCardView: View {
    let headline: String
    let subline: String
    let tint: Color
    let stats: [(value: String, label: String)]

    static let appStoreURL = "https://apps.apple.com/app/id6809603844"

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "#071013"), Color(hex: "#0F1E24"), Color(hex: "#071013")], startPoint: .top, endPoint: .bottom)
            // The radar rings, as on the app icon.
            ForEach(1..<6) { ring in
                Circle()
                    .stroke(tint.opacity(0.10), lineWidth: 2)
                    .frame(width: CGFloat(ring) * 190, height: CGFloat(ring) * 190)
                    .offset(y: -240)
            }

            VStack(spacing: 0) {
                Text("HUNTING GAME")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .tracking(10)
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.top, 150)

                Spacer()

                Image(systemName: "flag.checkered.circle.fill")
                    .font(.system(size: 120, weight: .bold))
                    .foregroundColor(tint)
                    .shadow(color: tint.opacity(0.7), radius: 30)

                Text(headline)
                    .font(.system(size: 92, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
                    .lineLimit(2)
                    .padding(.horizontal, 70)
                    .padding(.top, 40)

                Text(subline)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.top, 18)

                HStack(spacing: 24) {
                    ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                        VStack(spacing: 10) {
                            Text(stat.value)
                                .font(.system(size: 60, weight: .heavy, design: .rounded))
                                .foregroundColor(.white)
                                .minimumScaleFactor(0.5)
                                .lineLimit(1)
                            Text(stat.label)
                                .font(.system(size: 22, weight: .bold, design: .monospaced))
                                .tracking(2)
                                .foregroundColor(tint)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 34)
                        .background(RoundedRectangle(cornerRadius: 36, style: .continuous).fill(Color.white.opacity(0.07)))
                        .overlay(RoundedRectangle(cornerRadius: 36, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 2))
                    }
                }
                .padding(.horizontal, 60)
                .padding(.top, 70)

                Spacer()

                HStack(spacing: 30) {
                    QRCodeView(payload: Self.appStoreURL, size: 150)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Real-life manhunt")
                            .font(.system(size: 40, weight: .heavy, design: .rounded))
                            .foregroundColor(.white)
                        Text("Free on the App Store")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundColor(.white.opacity(0.65))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 80)
                .padding(.bottom, 170)
            }
        }
        .frame(width: 1080, height: 1920)
    }
}

extension ShareCardView {
    /// The card for this player's view of a finished match, or nil when they weren't in it.
    @MainActor
    static func image(for summary: MatchSummary, myUserId: String?) -> UIImage? {
        guard let me = summary.players.first(where: { $0.userId == myUserId }) else { return nil }
        let won = didWin(summary, me: me)
        let headline: String = {
            if let squad = summary.winningSquad { return squad == me.squad ? "My squad won" : "Squad \(squad) won" }
            if won { return me.role == .hunter ? "I won as a hunter" : (me.survived ? "I survived" : "Runners won") }
            if me.isOut { return "Knocked out" }
            switch summary.endReason {
            case "ALL_RUNNERS_RESOLVED": return "Hunters won"
            case "TIME_EXPIRED", "ALL_HUNTERS_ELIMINATED": return "Runners won"
            default: return "Match played"
            }
        }()
        var parts = [summary.mode.displayName.uppercased()]
        if let seconds = summary.durationSeconds { parts.append("\(max(1, seconds / 60)) MIN") }
        parts.append("\(summary.players.count) PLAYERS")
        let distance = me.distanceMeters >= 1000 ? String(format: "%.1f km", Double(me.distanceMeters) / 1000) : "\(me.distanceMeters) m"
        let stats: [(String, String)] = me.startedAs == .hunter || me.catches > 0
            ? [("\(me.catches)", "CATCHES"), (distance, "RAN"), ("\(me.powerUpsUsedTotal)", "POWER-UPS")]
            : [(distance, "RAN"), ("\(me.timesCaught)", "CAUGHT"), ("\(me.jailbreaks)", "JAILBREAKS")]
        let card = ShareCardView(
            headline: headline.uppercased(),
            subline: parts.joined(separator: " · "),
            tint: won ? ADATheme.runnerGreen : (me.role == .hunter ? ADATheme.hunterRed : ADATheme.spatialCyan),
            stats: stats.map { (value: $0.0, label: $0.1) }
        )
        let renderer = ImageRenderer(content: card)
        renderer.scale = 1
        return renderer.uiImage
    }

    /// Whether this player's side won — the same rule the results screen uses.
    static func didWin(_ summary: MatchSummary, me: MatchSummary.Player) -> Bool {
        if let squad = summary.winningSquad { return squad == me.squad }
        switch summary.endReason {
        case "TIME_EXPIRED", "ALL_HUNTERS_ELIMINATED": return me.role == .runner
        case "ALL_RUNNERS_RESOLVED": return me.role == .hunter
        default: return false
        }
    }
}
