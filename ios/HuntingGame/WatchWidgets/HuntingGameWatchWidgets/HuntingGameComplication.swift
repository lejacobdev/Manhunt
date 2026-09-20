import WidgetKit
import SwiftUI

/// The watch face complication: your role, your hearts and the nearest player, read straight from
/// the App Group container the Watch app writes to on every WatchConnectivity update. This
/// extension has no network/WatchConnectivity access of its own by design — it's a pure reader of
/// shared, already-synced state, which is exactly what a complication should be (cheap to refresh,
/// never blocks on a live connection).
struct HuntingGameTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> HuntingGameEntry {
        HuntingGameEntry(date: Date(), snapshot: .idle)
    }

    func getSnapshot(in context: Context, completion: @escaping (HuntingGameEntry) -> Void) {
        completion(HuntingGameEntry(date: Date(), snapshot: WatchAppGroup.readSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HuntingGameEntry>) -> Void) {
        let snapshot = WatchAppGroup.readSnapshot()
        let entry = HuntingGameEntry(date: Date(), snapshot: snapshot)
        // Reloaded on-demand by the Watch app (WidgetCenter.reloadAllTimelines)
        // whenever new state arrives; this fallback refresh just guards against
        // a stale entry if that reload was ever missed.
        let nextRefresh = Date().addingTimeInterval(snapshot.isActive ? 60 : 900)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

struct HuntingGameEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchGameSnapshot
}

struct HuntingGameComplication: Widget {
    let kind: String = "HuntingGameComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HuntingGameTimelineProvider()) { entry in
            HuntingGameComplicationView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Hunting Game")
        .description("Your hearts and the nearest player, at a glance.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct HuntingGameComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HuntingGameEntry

    private var snapshot: WatchGameSnapshot { entry.snapshot }

    /// A match the phone is still reporting on. Without the age check, a match that ended while
    /// the phone was out of reach would sit on the watch face indefinitely.
    private var isLive: Bool {
        snapshot.isActive && entry.date.timeIntervalSince(snapshot.updatedAt) < 180
    }

    private var distance: Int? {
        guard isLive, !snapshot.isCaught, !snapshot.isOut else { return nil }
        return snapshot.nearestBlip?.distanceMeters
    }

    private var tint: Color {
        guard isLive else { return TacticalPalette.neutralGray }
        if snapshot.isOut || snapshot.isCaught { return TacticalPalette.hunterRed }
        guard let distance else { return roleColor }
        return TacticalPalette.dangerColor(distanceMeters: distance)
    }

    private var roleColor: Color {
        switch snapshot.roleRaw {
        case "HUNTER": return TacticalPalette.hunterRed
        case "RUNNER": return TacticalPalette.runnerGreen
        default: return TacticalPalette.spatialCyan
        }
    }

    private var roleSymbol: String {
        switch snapshot.roleRaw {
        case "HUNTER": return "scope"
        case "RUNNER": return "figure.run"
        default: return "eye.fill"
        }
    }

    /// The gauge fills as the nearest player closes in: full at 0 m, empty at 100 m or beyond.
    private var closeness: Double {
        guard let distance else { return 0 }
        return 1 - min(Double(distance), 100) / 100
    }

    private var otherSide: String { snapshot.isHunter ? "runner" : "hunter" }

    /// What the wearer's status is, in a few words.
    private var statusText: String {
        guard isLive else { return "No active match" }
        if snapshot.isOut { return "You're out" }
        if snapshot.isJailed { return "In jail" }
        if snapshot.isCaught { return "Caught" }
        if let distance { return "\(distance) m to \(otherSide)" }
        return "Scanning…"
    }

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        case .accessoryCorner: corner
        default: rectangular
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let distance {
                Gauge(value: closeness) {
                    Text("")
                } currentValueLabel: {
                    VStack(spacing: -1) {
                        Text("\(distance)")
                            .font(.system(size: 15, weight: .black, design: .rounded))
                        Text("M")
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                    }
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(tint)
            } else {
                Image(systemName: isLive ? roleSymbol : "figure.run")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(tint)
            }
        }
        .widgetAccentable()
    }

    private var rectangular: some View {
        HStack(spacing: 7) {
            Image(systemName: isLive ? roleSymbol : "figure.run")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(tint)
                .widgetAccentable()

            VStack(alignment: .leading, spacing: 1) {
                Text(isLive ? snapshot.roleRaw : "HUNTING GAME")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(statusText)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if isLive, snapshot.maxHearts > 0 {
                    hearts
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var hearts: some View {
        HStack(spacing: 2) {
            ForEach(0..<max(snapshot.hearts, snapshot.maxHearts), id: \.self) { index in
                Image(systemName: index < snapshot.hearts ? "heart.fill" : "heart")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(index < snapshot.hearts ? TacticalPalette.hunterRed : Color.secondary)
            }
        }
    }

    @ViewBuilder
    private var inline: some View {
        if isLive, snapshot.maxHearts > 0, let distance {
            Label("\(snapshot.hearts)♥ · \(distance)m \(otherSide)", systemImage: roleSymbol)
        } else if isLive, snapshot.maxHearts > 0 {
            Label("\(snapshot.hearts)♥ · \(statusText)", systemImage: roleSymbol)
        } else {
            Label(statusText, systemImage: isLive ? roleSymbol : "figure.run")
        }
    }

    private var corner: some View {
        Group {
            if let distance {
                Text("\(distance)m")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
            } else {
                Image(systemName: isLive ? roleSymbol : "figure.run")
                    .font(.system(size: 18, weight: .bold))
            }
        }
        .foregroundStyle(tint)
        .widgetCurvesContent()
        .widgetLabel {
            Text(isLive && snapshot.maxHearts > 0 ? "\(snapshot.hearts) ♥ · \(snapshot.roleRaw)" : statusText)
        }
    }
}
