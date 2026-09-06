import WidgetKit
import SwiftUI

/// The iPhone home-screen widget: a glanceable "nearest hunter" readout, read from the App
/// Group the main app writes to on every location/radar update (`PhoneWidgetAppGroup` in
/// Shared/WatchSyncPayload.swift). This is what actually shows up in iOS's "Add Widget"
/// gallery — `HuntingGameLiveActivity` above is a Live Activity, which by design only ever
/// appears on the Lock Screen/Dynamic Island while a match is running and is never listed
/// in that gallery, so without a real `Widget` like this one there was nothing there to find.
struct HuntingGameHomeWidget: Widget {
    let kind = "HuntingGameHomeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HomeWidgetProvider()) { entry in
            HomeWidgetView(snapshot: entry.snapshot)
                .homeWidgetBackground()
        }
        .configurationDisplayName("Hunter Radar")
        .description("Live distance to the nearest hunter during a match.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct HomeWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchGameSnapshot
}

private struct HomeWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> HomeWidgetEntry {
        HomeWidgetEntry(date: Date(), snapshot: .idle)
    }

    func getSnapshot(in context: Context, completion: @escaping (HomeWidgetEntry) -> Void) {
        completion(HomeWidgetEntry(date: Date(), snapshot: PhoneWidgetAppGroup.readSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HomeWidgetEntry>) -> Void) {
        let snapshot = PhoneWidgetAppGroup.readSnapshot()
        let entry = HomeWidgetEntry(date: Date(), snapshot: snapshot)
        // Reloaded on-demand by the app (WidgetCenter.reloadTimelines) whenever a fresh
        // snapshot arrives; this fallback refresh just guards against a stale entry if
        // that reload was ever missed — same policy the Watch complication uses.
        let nextRefresh = Date().addingTimeInterval(snapshot.isActive ? 60 : 900)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

private struct HomeWidgetView: View {
    let snapshot: WatchGameSnapshot

    private var dangerColor: Color {
        guard snapshot.isActive, let distance = snapshot.nearestDistanceMeters else { return .gray }
        return TacticalPalette.dangerColor(distanceMeters: distance)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(dangerColor)
                Text(snapshot.isActive ? "GAME \(snapshot.gameCode)" : "NO ACTIVE GAME")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if snapshot.isActive, let distance = snapshot.nearestDistanceMeters {
                Text("\(distance)m")
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                Text("TO NEAREST HUNTER")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(dangerColor)
            } else {
                Text("—")
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundColor(.white.opacity(0.4))
                Text(snapshot.isActive ? "AWAITING SIGNAL" : "OPEN A MATCH TO TRACK IT HERE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private extension View {
    /// `containerBackground(_:for:)` is required from iOS 17 onward (an un-migrated widget
    /// renders with a system-imposed default background there) but doesn't exist on the
    /// app's 16.2 floor, so this picks whichever the running OS actually supports.
    @ViewBuilder
    func homeWidgetBackground() -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(TacticalPalette.obsidianBackground, for: .widget)
        } else {
            background(TacticalPalette.obsidianBackground)
        }
    }
}
