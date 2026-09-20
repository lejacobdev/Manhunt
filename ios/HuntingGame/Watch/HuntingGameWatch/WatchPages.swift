import SwiftUI

// The four pages of a live match, in the order the Digital Crown pages through them:
//   Radar (everyone)  ->  Targets (hunters)  ->  Gear (everyone)  ->  Match (everyone)

// MARK: - Radar

struct WatchRadarPage: View {
    let snapshot: WatchGameSnapshot

    private var nearest: WatchBlip? { snapshot.radarBlips.first }

    private var accent: Color {
        if let nearest { return WT.danger(nearest.distanceMeters) }
        return WT.accent(forRole: snapshot.roleRaw)
    }

    private var caption: String {
        if snapshot.isRadarJammed { return "JAMMED" }
        return nearest == nil ? "SCANNING" : "METERS"
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                WTRolePill(role: snapshot.roleRaw)
                Spacer(minLength: 2)
                if snapshot.maxHearts > 0 {
                    WTHearts(hearts: snapshot.hearts, maxHearts: snapshot.maxHearts)
                }
            }

            WTRadar(
                blips: snapshot.radarBlips,
                heading: snapshot.headingDegrees,
                accent: accent,
                centerValue: nearest.map { "\($0.distanceMeters)" } ?? "—",
                centerSymbol: (nearest == nil && snapshot.isRadarJammed) ? "bolt.slash.fill" : nil,
                centerCaption: caption
            )

            footer
        }
        .padding(.leading, 4)
        .padding(.trailing, 13)
    }

    /// One thing at the bottom: the most urgent warning if there is one, otherwise the clock and
    /// whatever effects are running.
    @ViewBuilder
    private var footer: some View {
        if snapshot.bailActive {
            WTBanner(
                symbol: "lock.open.fill", text: "FREEING PRISONERS",
                detail: snapshot.deadline(after: snapshot.bailRemainingSeconds), tint: WT.green
            )
        } else if snapshot.zoneOutside {
            WTBanner(
                symbol: "exclamationmark.triangle.fill",
                text: snapshot.zoneReason == "ZONE" ? "OUTSIDE THE ZONE — LOSING HEARTS" : "OUTSIDE THE AREA — LOSING HEARTS",
                tint: WT.amber
            )
        } else {
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    Image(systemName: "clock.fill").font(.system(size: 9))
                    if let endsAt = snapshot.matchEndsAt {
                        WTCountdown(until: endsAt, font: .wtMono(11))
                    } else {
                        Text("--:--").font(.wtMono(11))
                    }
                }
                .foregroundStyle(WT.gray)

                Spacer(minLength: 2)

                ForEach(snapshot.buffs.prefix(2)) { buff in
                    let gear = WatchGear.info(for: buff.raw)
                    HStack(spacing: 3) {
                        Image(systemName: gear.symbol).font(.system(size: 9, weight: .bold))
                        WTCountdown(until: snapshot.deadline(after: buff.remainingSeconds), font: .wtMono(10))
                    }
                    .foregroundStyle(gear.tint)
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

// MARK: - Targets (hunters)

struct WatchTargetsPage: View {
    let snapshot: WatchGameSnapshot
    let onRequest: (WatchBlip) -> Void

    /// The server refuses a catch beyond this (CATCH_VERIFICATION_RADIUS_METERS), so there's no
    /// point letting the hunter send one.
    private let catchRange = 15

    private var targets: [WatchBlip] { snapshot.radarBlips }

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                HStack {
                    WTLabel("TARGETS", color: WT.red)
                    Spacer()
                    WTLabel("\(targets.count) IN RANGE")
                }

                if targets.isEmpty {
                    emptyState
                } else {
                    ForEach(targets) { row($0) }
                    WTLabel("GET WITHIN \(catchRange) M TO CATCH", size: 8)
                        .padding(.top, 2)
                }
            }
            .padding(.leading, 4)
        .padding(.trailing, 13)
            .padding(.bottom, 8)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            WTIconBadge(symbol: "scope", tint: WT.gray, size: 40)
            Text(snapshot.isRadarJammed ? "Radar jammed." : "No runners in range.")
                .font(.wtRounded(13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.top, 16)
    }

    private func row(_ blip: WatchBlip) -> some View {
        let inRange = blip.distanceMeters <= catchRange
        let tint = inRange ? WT.red : WT.gray
        return Button {
            onRequest(blip)
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(tint.opacity(0.16))
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(tint)
                        .rotationEffect(.degrees(blip.bearingDegrees - (snapshot.headingDegrees ?? 0)))
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 1) {
                    Text(blip.username)
                        .font(.wtRounded(14))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    WTLabel(inRange ? "TAP TO CATCH" : "TOO FAR", color: inRange ? tint : WT.amber.opacity(0.9), size: 8)
                }
                Spacer(minLength: 2)
                VStack(alignment: .trailing, spacing: -2) {
                    Text("\(blip.distanceMeters)")
                        .font(.wtRounded(19, weight: .black))
                        .foregroundStyle(.white)
                    WTLabel("M", size: 7)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .wtCard(tint: tint, radius: 14)
        }
        .buttonStyle(.plain)
        // Not `.disabled`: that adds SwiftUI's own dimming on top, and the far rows became
        // unreadable. They stay legible, just visibly not the ones to tap.
        .allowsHitTesting(inRange)
        .opacity(inRange ? 1 : 0.85)
    }
}

// MARK: - Gear

private struct GearStack: Identifiable {
    let raw: String
    let count: Int
    var id: String { raw }
}

struct WatchGearPage: View {
    let snapshot: WatchGameSnapshot
    let onUse: (String) -> Void

    /// The tile that has been tapped once and is waiting for a second tap.
    @State private var armed: String?

    private var stacks: [GearStack] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for raw in snapshot.inventoryRaw {
            if counts[raw] == nil { order.append(raw) }
            counts[raw, default: 0] += 1
        }
        return order.map { GearStack(raw: $0, count: counts[$0] ?? 0) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                HStack {
                    WTLabel("EQUIPMENT", color: WT.cyan)
                    Spacer()
                    WTLabel("\(snapshot.inventoryRaw.count) HELD")
                }

                if !snapshot.buffs.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(snapshot.buffs) { buff in activeRow(buff) }
                    }
                }

                if stacks.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                        spacing: 6
                    ) {
                        ForEach(stacks) { tile($0) }
                    }
                    WTLabel("TAP TWICE TO USE", size: 8)
                }
            }
            .padding(.leading, 4)
        .padding(.trailing, 13)
            .padding(.bottom, 8)
        }
        // Un-arm after a few seconds so a stray tap earlier doesn't leave a power-up one touch
        // from being spent.
        .task(id: armed) {
            guard armed != nil else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { armed = nil }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            WTIconBadge(symbol: "shippingbox", tint: WT.gray, size: 40)
            Text("Nothing collected yet.")
                .font(.wtRounded(13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text("Pick up power-ups on the map.")
                .font(.wtRounded(11, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 10)
    }

    private func activeRow(_ buff: WatchBuff) -> some View {
        let gear = WatchGear.info(for: buff.raw)
        return HStack(spacing: 7) {
            Image(systemName: gear.symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(gear.tint)
            WTLabel(gear.name.uppercased(), color: .white, size: 8)
            Spacer(minLength: 2)
            WTCountdown(until: snapshot.deadline(after: buff.remainingSeconds), font: .wtMono(11))
                .foregroundStyle(gear.tint)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .wtCard(tint: gear.tint, radius: 10)
    }

    private func tile(_ stack: GearStack) -> some View {
        let gear = WatchGear.info(for: stack.raw)
        let isArmed = armed == stack.raw
        return Button {
            if isArmed {
                armed = nil
                onUse(stack.raw)
            } else {
                armed = stack.raw
            }
        } label: {
            VStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    if isArmed {
                        Image(systemName: gear.symbol)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Color.black)
                            .frame(width: 36, height: 36)
                    } else {
                        WTIconBadge(symbol: gear.symbol, tint: gear.tint, size: 36)
                    }
                    if stack.count > 1 {
                        Text("×\(stack.count)")
                            .font(.wtMono(8))
                            .foregroundStyle(.white)
                            .padding(.leading, 4)
        .padding(.trailing, 13)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.black.opacity(0.75)))
                            .offset(x: 7, y: -3)
                    }
                }
                Text(isArmed ? "TAP TO USE" : gear.name.uppercased())
                    .font(.wtMono(8))
                    .tracking(0.6)
                    .foregroundStyle(isArmed ? Color.black : gear.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(isArmed ? gear.tint : gear.tint.opacity(0.10)))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(gear.tint.opacity(isArmed ? 0 : 0.24), lineWidth: 1)
            )
            .shadow(color: isArmed ? gear.tint.opacity(0.5) : .clear, radius: 8)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isArmed)
    }
}

// MARK: - Match

struct WatchMatchPage: View {
    let snapshot: WatchGameSnapshot
    let isReachable: Bool

    private var modeName: String? {
        switch snapshot.modeRaw {
        case "STANDARD": return "Standard"
        case "INFECTION": return "Infection"
        case "SQUAD": return "Squad vs Squad"
        default: return nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 7) {
                HStack {
                    WTLabel("MATCH", color: WT.cyan)
                    Spacer()
                    Text(snapshot.gameCode)
                        .font(.wtMono(12))
                        .tracking(1.5)
                        .foregroundStyle(WT.cyan)
                }

                HStack(spacing: 5) {
                    stat("FREE", snapshot.runnersFree, WT.green)
                    stat("JAILED", snapshot.runnersJailed, WT.amber)
                    stat("HUNTERS", snapshot.huntersCount, WT.red)
                }

                if let modeName { infoRow("MODE", Text(modeName)) }

                if let endsAt = snapshot.matchEndsAt {
                    infoRow("TIME LEFT", WTCountdown(until: endsAt, font: .wtMono(12)))
                }

                if let radius = snapshot.zoneRadiusMeters {
                    infoRow("ZONE", Text("\(radius) m"))
                }

                HStack(spacing: 5) {
                    Circle().fill(isReachable ? WT.green : WT.gray).frame(width: 6, height: 6)
                    WTLabel(isReachable ? "IPHONE CONNECTED" : "IPHONE NOT REACHABLE", size: 8)
                }
                .padding(.top, 4)
            }
            .padding(.leading, 4)
        .padding(.trailing, 13)
            .padding(.bottom, 8)
        }
    }

    private func stat(_ title: String, _ value: Int, _ tint: Color) -> some View {
        VStack(spacing: 1) {
            Text("\(value)")
                .font(.wtRounded(21, weight: .black))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            WTLabel(title, size: 7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .wtCard(tint: tint, radius: 12)
    }

    private func infoRow<V: View>(_ title: String, _ value: V) -> some View {
        HStack {
            WTLabel(title)
            Spacer()
            value
                .font(.wtRounded(13, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .wtCard(radius: 12)
    }
}
