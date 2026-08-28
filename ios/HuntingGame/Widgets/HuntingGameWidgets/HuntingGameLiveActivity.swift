import ActivityKit
import WidgetKit
import SwiftUI

/// Lock Screen banner + Dynamic Island presentations for the runner's live
/// "nearest hunter" threat readout. All three Dynamic Island regions
/// (minimal, compact, expanded) and the Lock Screen view share the same
/// SAFE/WARNING/CRITICAL color ramp as the in-app radar.
struct HuntingGameLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HuntingGameAttributes.self) { context in
            LockScreenLiveActivityView(context: context)
                .activityBackgroundTint(TacticalPalette.obsidianBackground)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ZStack {
                        Circle()
                            .stroke(dangerColor(context).opacity(0.35), lineWidth: 3)
                            .frame(width: 36, height: 36)
                        Image(systemName: "location.north.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(dangerColor(context))
                            .rotationEffect(.degrees(context.state.nearestHunterBearing))
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(context.state.distanceMeters)m")
                            .font(.system(size: 20, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                        Text(context.state.dangerLevel)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(dangerColor(context))
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text("GAME \(context.attributes.gameCode)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.gray)
                        Spacer()
                        Text(context.state.isRadarActive ? "RADAR ACTIVE" : "STANDBY")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                }
            } compactLeading: {
                Image(systemName: "location.north.fill")
                    .foregroundColor(dangerColor(context))
                    .rotationEffect(.degrees(context.state.nearestHunterBearing))
            } compactTrailing: {
                Text("\(context.state.distanceMeters)m")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(dangerColor(context))
            } minimal: {
                Circle()
                    .fill(dangerColor(context))
                    .frame(width: 10, height: 10)
            }
            .widgetURL(URL(string: "huntinggame://game/\(context.attributes.gameCode)"))
            .keylineTint(dangerColor(context))
        }
    }

    private func dangerColor(_ context: ActivityViewContext<HuntingGameAttributes>) -> Color {
        TacticalPalette.dangerColor(forLevel: context.state.dangerLevel)
    }
}

private struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<HuntingGameAttributes>

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(dangerColor.opacity(0.3), lineWidth: 4)
                    .frame(width: 44, height: 44)

                Image(systemName: "location.north.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(dangerColor)
                    .rotationEffect(.degrees(context.state.nearestHunterBearing))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(context.state.isRadarActive ? "HUNTER NEARBY" : "MATCH IN PROGRESS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)
                Text("\(context.state.distanceMeters) METERS")
                    .font(.system(size: 20, weight: .black, design: .monospaced))
                    .foregroundColor(.white)
            }

            Spacer()

            Text(context.state.dangerLevel)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(dangerColor.opacity(0.2))
                .foregroundColor(dangerColor)
                .clipShape(Capsule())
        }
        .padding(16)
    }

    private var dangerColor: Color {
        TacticalPalette.dangerColor(forLevel: context.state.dangerLevel)
    }
}
