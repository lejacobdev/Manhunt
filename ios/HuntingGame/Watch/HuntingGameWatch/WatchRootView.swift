import SwiftUI

/// The pages of a live match, top to bottom.
enum WatchPage: String, Hashable {
    case radar, targets, gear, match
}

/// A catch request the wearer (a hunter) just sent, shown immediately rather than waiting for the
/// phone to confirm it — so a tap gives instant feedback even over a slow link.
private struct LocalWaiting: Equatable {
    let name: String
    let since: Date
}

struct WatchRootView: View {
    @ObservedObject var connectivity: WatchConnectivityManager

    @State private var page: WatchPage
    @State private var damageFlash: Double = 0
    @State private var toast: String?
    @State private var answeredCatchRequestId: String?
    @State private var localWaiting: LocalWaiting?
    @State private var lastProximityPulseAt: Date = .distantPast

    init(connectivity: WatchConnectivityManager, initialPage: WatchPage = .radar) {
        self.connectivity = connectivity
        _page = State(initialValue: initialPage)
    }

    private var snapshot: WatchGameSnapshot { connectivity.snapshot }

    var body: some View {
        ZStack {
            gameContent

            // The catch conversation takes over the whole screen, ahead of everything else.
            if let request = openCatchRequest {
                fullScreen(accent: WT.red) {
                    WatchCatchRequestView(
                        hunter: request.hunterUsername,
                        onAccept: { answer(request, accept: true) },
                        onDeny: { answer(request, accept: false) }
                    )
                }
            } else if let runner = waitingRunner {
                fullScreen(accent: WT.red) {
                    WatchWaitingView(runner: runner, onCancel: cancelRequest)
                }
            } else if let deny = snapshot.denyConfirm, snapshot.isActive {
                fullScreen(accent: WT.amber) {
                    WatchDenyConfirmView(runner: deny.runnerUsername) {
                        WatchHaptics.lightTap()
                        connectivity.send(.init(type: .acknowledgeDeny))
                    }
                }
            }

            if let toast {
                VStack {
                    WatchToast(text: toast)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
            }

            // Edge flash on every heart lost — the wrist twin of the iPhone's damage vignette.
            Rectangle()
                .fill(RadialGradient(colors: [.clear, WT.red], center: .center, startRadius: 50, endRadius: 150))
                .opacity(damageFlash)
                .allowsHitTesting(false)
                .ignoresSafeArea()
        }
        .animation(.easeInOut(duration: 0.25), value: overlayKey)
        // Time the two self-clearing bits of state out.
        .task(id: toast) {
            guard toast != nil else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { withAnimation { toast = nil } }
        }
        .task(id: localWaiting) {
            guard localWaiting != nil else { return }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled { localWaiting = nil }
        }
        // Feedback for what just changed.
        .onChange(of: snapshot.hearts) { old, new in
            guard snapshot.isActive, old > 0, new < old else { return }
            WatchHaptics.heartLost()
            flashDamage()
        }
        .onChange(of: snapshot.incomingCatch?.requestId) { _, new in
            if new != nil { WatchHaptics.catchRequest() }
        }
        .onChange(of: snapshot.denyConfirm?.requestId) { _, new in
            if new != nil { WatchHaptics.catchRequest() }
        }
        .onChange(of: snapshot.isCaught) { _, caught in
            if caught { WatchHaptics.caught() }
        }
        .onChange(of: snapshot.isOut) { _, out in
            if out { WatchHaptics.caught() }
        }
        .onChange(of: snapshot.zoneOutside) { _, outside in
            if outside { WatchHaptics.warning() }
        }
        .onChange(of: snapshot.notice) { _, notice in
            guard !notice.isEmpty else { return }
            WatchHaptics.failure()
            withAnimation { toast = notice }
        }
        .onChange(of: snapshot.nearestBlip?.distanceMeters) { old, new in
            handleProximity(from: old, to: new)
        }
        // A request that has been answered (or refused) is no longer "waiting".
        .onChange(of: snapshot.pendingCatchTargetName) { old, new in
            if old != nil && new == nil { localWaiting = nil }
        }
        .onChange(of: snapshot.denyConfirm?.requestId) { _, new in
            if new != nil { localWaiting = nil }
        }
        // Infection turns a caught runner into a hunter; the Targets page appears or disappears.
        .onChange(of: snapshot.roleRaw) { _, _ in page = .radar }
    }

    // MARK: - What to show

    @ViewBuilder
    private var gameContent: some View {
        if !snapshot.isActive {
            screen(accent: WT.green, strength: 0.25) { WatchIdleView(isReachable: connectivity.isReachable) }
        } else if snapshot.isOut {
            screen(accent: WT.red) { WatchOutView(snapshot: snapshot) }
        } else if snapshot.isJailed || snapshot.isCaught {
            screen(accent: snapshot.isJailed ? WT.amber : WT.red) { WatchJailView(snapshot: snapshot) }
        } else if snapshot.isSpectator {
            screen(accent: WT.cyan) { WatchMatchPage(snapshot: snapshot, isReachable: connectivity.isReachable) }
        } else {
            pagedGame
        }
    }

    private var pagedGame: some View {
        TabView(selection: $page) {
            WatchRadarPage(snapshot: snapshot)
                .tag(WatchPage.radar)

            if snapshot.isHunter {
                WatchTargetsPage(snapshot: snapshot, onRequest: requestCatch)
                    .tag(WatchPage.targets)
            }

            WatchGearPage(snapshot: snapshot, onUse: useGear)
                .tag(WatchPage.gear)

            WatchMatchPage(snapshot: snapshot, isReachable: connectivity.isReachable)
                .tag(WatchPage.match)
        }
        .tabViewStyle(.verticalPage)
        .containerBackground(for: .tabView) {
            WTBackground(accent: pageAccent)
        }
    }

    /// The backdrop glow follows the danger on the radar page, and the role's own colour elsewhere.
    private var pageAccent: Color {
        if page == .radar, let nearest = snapshot.nearestBlip {
            return WT.danger(nearest.distanceMeters)
        }
        return WT.accent(forRole: snapshot.roleRaw)
    }

    private func screen<Content: View>(accent: Color, strength: Double = 0.30, @ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            WTBackground(accent: accent, strength: strength)
            content()
        }
    }

    private func fullScreen<Content: View>(accent: Color, @ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            WTBackground(accent: accent, strength: 0.5)
            content()
        }
        .transition(.opacity)
    }

    // MARK: - Catch conversation state

    /// A request from a hunter that this wrist hasn't answered yet.
    private var openCatchRequest: WatchCatchRequest? {
        guard snapshot.isActive, !snapshot.isCaught, let request = snapshot.incomingCatch,
              request.requestId != answeredCatchRequestId else { return nil }
        return request
    }

    /// Who the wearer (a hunter) is waiting on — the phone's word if it has one, else our own note
    /// of the tap we just made.
    private var waitingRunner: String? {
        guard snapshot.isActive else { return nil }
        if let name = snapshot.pendingCatchTargetName { return name }
        return localWaiting?.name
    }

    /// Changes whenever a different overlay should be showing, so they animate in and out.
    private var overlayKey: String {
        "\(openCatchRequest?.requestId ?? "")|\(waitingRunner ?? "")|\(snapshot.denyConfirm?.requestId ?? "")"
    }

    // MARK: - Actions

    private func requestCatch(_ blip: WatchBlip) {
        guard connectivity.send(.init(type: .requestCatch, targetRunnerId: blip.id)) else {
            deliveryFailed()
            return
        }
        WatchHaptics.lightTap()
        localWaiting = LocalWaiting(name: blip.username, since: Date())
    }

    private func cancelRequest() {
        WatchHaptics.lightTap()
        localWaiting = nil
        connectivity.send(.init(type: .cancelCatchRequest))
    }

    private func answer(_ request: WatchCatchRequest, accept: Bool) {
        guard connectivity.send(.init(type: accept ? .acceptCatch : .denyCatch)) else {
            deliveryFailed()
            return
        }
        // Hide it now; the phone's confirmation follows a moment later.
        answeredCatchRequestId = request.requestId
        if accept { WatchHaptics.caught() } else { WatchHaptics.lightTap() }
    }

    private func useGear(_ raw: String) {
        guard connectivity.send(.init(type: .usePowerUp, powerUpTypeRaw: raw)) else {
            deliveryFailed()
            return
        }
        WatchHaptics.powerUpActivated()
    }

    private func deliveryFailed() {
        WatchHaptics.failure()
        withAnimation { toast = "iPhone not reachable. Open Hunting Game on your iPhone." }
    }

    // MARK: - Feedback

    private func flashDamage() {
        // Snap on, ease off — a symmetric fade reads as a soft glow rather than a hit.
        withAnimation(.easeIn(duration: 0.07)) { damageFlash = 0.55 }
        withAnimation(.easeOut(duration: 0.6).delay(0.07)) { damageFlash = 0 }
    }

    private func handleProximity(from old: Int?, to new: Int?) {
        guard let new else { return }

        if snapshot.isHunter {
            // Just came within catching range of someone.
            if new <= 15, (old ?? Int.max) > 15 { WatchHaptics.inRange() }
            return
        }

        guard snapshot.isRunner, new < 25 else { return }
        let interval: TimeInterval = new < 10 ? 1.0 : 2.0
        let now = Date()
        guard now.timeIntervalSince(lastProximityPulseAt) >= interval else { return }
        lastProximityPulseAt = now
        if new < 10 { WatchHaptics.dangerClose() } else { WatchHaptics.proximityAlert() }
    }
}
