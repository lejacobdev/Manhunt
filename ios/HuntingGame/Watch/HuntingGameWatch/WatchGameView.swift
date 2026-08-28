import SwiftUI

struct WatchGameView: View {
    @ObservedObject var connectivity: WatchConnectivityManager
    @State private var catchTarget: WatchRunnerBlip?
    @State private var lastProximityPulseAt: Date = .distantPast

    private var snapshot: WatchGameSnapshot { connectivity.snapshot }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    header

                    if !snapshot.isActive {
                        idleState
                    } else if snapshot.isCaught {
                        caughtState
                    } else if snapshot.roleRaw == "RUNNER" {
                        runnerCompass
                        inventoryList
                    } else if snapshot.roleRaw == "HUNTER" {
                        hunterRunnerList
                        inventoryList
                    } else {
                        Text("Spectating — no live threat data for this role.")
                            .font(.footnote)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
            .navigationTitle(snapshot.isActive ? "GAME \(snapshot.gameCode)" : "HUNTING GAME")
            .sheet(item: $catchTarget) { target in
                WatchCatchSheet(target: target) { code in
                    WatchHaptics.lightTap()
                    connectivity.send(.init(type: .attemptCatch, targetRunnerId: target.id, arrestCode: code))
                    catchTarget = nil
                }
            }
            .onChange(of: snapshot.nearestDistanceMeters) { newValue in
                handleProximity(newValue)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(TacticalPalette.dangerColor(forLevel: dangerLevel))
                .frame(width: 8, height: 8)
            Text(snapshot.isActive ? snapshot.roleRaw : "NOT IN A GAME")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
            Spacer()
            if !connectivity.isReachable {
                Image(systemName: "iphone.slash")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }
        }
    }

    private var idleState: some View {
        VStack(spacing: 6) {
            Image(systemName: "figure.run.circle")
                .font(.system(size: 32))
                .foregroundColor(.gray)
            Text("Open Hunting Game on your iPhone and join a match to see it here.")
                .font(.footnote)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 20)
    }

    private var caughtState: some View {
        VStack(spacing: 6) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 28))
                .foregroundColor(TacticalPalette.hunterRed)
            Text("YOU'RE CAUGHT")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
        }
        .padding(.top, 16)
    }

    private var runnerCompass: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(TacticalPalette.dangerColor(forLevel: dangerLevel).opacity(0.4), lineWidth: 3)
                    .frame(width: 90, height: 90)
                if let bearing = snapshot.nearestBearingDegrees {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(TacticalPalette.dangerColor(forLevel: dangerLevel))
                        .rotationEffect(.degrees(bearing))
                        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: bearing)
                }
                VStack(spacing: 0) {
                    Text(snapshot.nearestDistanceMeters.map { "\($0)" } ?? "--")
                        .font(.system(size: 20, weight: .black, design: .rounded))
                    Text("METERS")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                }
            }
            if snapshot.isRadarJammed {
                Text("JAMMED")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(TacticalPalette.tacticalAmber)
            }
            Text("CODE \(snapshot.arrestCode)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.gray)
        }
    }

    private var hunterRunnerList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("VISIBLE RUNNERS")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(TacticalPalette.hunterRed)

            if snapshot.visibleRunners.isEmpty {
                Text(snapshot.isRadarJammed ? "Radar jammed." : "None in range.")
                    .font(.footnote)
                    .foregroundColor(.gray)
            } else {
                ForEach(snapshot.visibleRunners) { runner in
                    Button(runner.username.uppercased()) {
                        WatchHaptics.lightTap()
                        catchTarget = runner
                    }
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tint(TacticalPalette.hunterRed)
                }
            }
        }
    }

    private var inventoryList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("EQUIPMENT")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.gray)
            if snapshot.inventoryRaw.isEmpty {
                Text("None collected yet.")
                    .font(.footnote)
                    .foregroundColor(.gray)
            } else {
                ForEach(Array(snapshot.inventoryRaw.enumerated()), id: \.offset) { _, raw in
                    Button {
                        WatchHaptics.powerUpActivated()
                        connectivity.send(.init(type: .usePowerUp, powerUpTypeRaw: raw))
                    } label: {
                        Text(raw.replacingOccurrences(of: "_", with: " "))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    private var dangerLevel: String {
        guard let distance = snapshot.nearestDistanceMeters else { return "SAFE" }
        if distance < 15 { return "CRITICAL" }
        if distance < 50 { return "WARNING" }
        return "SAFE"
    }

    private func handleProximity(_ distance: Int?) {
        guard snapshot.roleRaw == "RUNNER", let distance, distance < 25 else { return }
        let now = Date()
        guard now.timeIntervalSince(lastProximityPulseAt) >= 2.0 else { return }
        lastProximityPulseAt = now
        WatchHaptics.proximityAlert()
    }
}
