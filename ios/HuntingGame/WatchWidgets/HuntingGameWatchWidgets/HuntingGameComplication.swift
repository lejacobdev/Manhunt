import WidgetKit
import SwiftUI

/// The watch face complication: a glanceable "nearest hunter" readout read
/// straight from the App Group container the Watch app writes to on every
/// WatchConnectivity update. This extension has no network/WatchConnectivity
/// access of its own by design — it's a pure reader of shared, already-synced
/// state, which is exactly what a complication should be (cheap to refresh,
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
        }
        .configurationDisplayName("Hunter Radar")
        .description("Live distance to the nearest hunter.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct HuntingGameComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HuntingGameEntry

    private var snapshot: WatchGameSnapshot { entry.snapshot }

    private var dangerColor: Color {
        guard snapshot.isActive, let distance = snapshot.nearestDistanceMeters else { return .gray }
        return TacticalPalette.dangerColor(distanceMeters: distance)
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular
        case .accessoryRectangular:
            rectangular
        case .accessoryInline:
            inline
        default:
            rectangular
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 12, weight: .bold))
                if snapshot.isActive, let distance = snapshot.nearestDistanceMeters {
                    Text("\(distance)m")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                } else {
                    Text("--")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
            }
            .foregroundStyle(dangerColor)
        }
    }

    private var rectangular: some View {
        HStack(spacing: 6) {
            Image(systemName: "location.north.fill")
                .foregroundStyle(dangerColor)
            VStack(alignment: .leading, spacing: 0) {
                Text(snapshot.isActive ? "NEAREST HUNTER" : "NO ACTIVE GAME")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                if snapshot.isActive, let distance = snapshot.nearestDistanceMeters {
                    Text("\(distance) meters")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                } else {
                    Text("—")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
            }
        }
    }

    @ViewBuilder
    private var inline: some View {
        if snapshot.isActive, let distance = snapshot.nearestDistanceMeters {
            Label("\(distance)m to hunter", systemImage: "location.north.fill")
        } else {
            Label("No active game", systemImage: "location.north.fill")
        }
    }
}
