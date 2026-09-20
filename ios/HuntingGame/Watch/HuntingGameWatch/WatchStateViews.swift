import SwiftUI

// Everything that takes over the whole screen instead of being one page among four: not being in
// a match, being caught / in jail, being eliminated, and the three moments of the catch
// conversation between a hunter and a runner.

// MARK: - Not in a match

struct WatchIdleView: View {
    let isReachable: Bool
    @Environment(\.isLuminanceReduced) private var isDimmed
    @State private var sweep: Double = 0

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle().strokeBorder(WT.green.opacity(0.65), lineWidth: 2)
                Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1).padding(11)
                if !isDimmed {
                    Circle()
                        .fill(AngularGradient(
                            colors: [WT.green.opacity(0.35), .clear],
                            center: .center, startAngle: .degrees(0), endAngle: .degrees(75)
                        ))
                        .rotationEffect(.degrees(sweep))
                }
                Image(systemName: "figure.run")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(WT.green)
                    .shadow(color: WT.green.opacity(0.7), radius: 8)
            }
            .frame(width: 78, height: 78)

            Text("HUNTING GAME")
                .font(.wtRounded(15, weight: .black))
                .tracking(1.4)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text("Start or join a match on your iPhone and it appears here.")
                .font(.wtRounded(11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)

            HStack(spacing: 5) {
                Circle().fill(isReachable ? WT.green : WT.gray).frame(width: 6, height: 6)
                WTLabel(isReachable ? "IPHONE CONNECTED" : "OPEN THE IPHONE APP", size: 8)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 8)
        .onAppear {
            withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) { sweep = 360 }
        }
    }
}

// MARK: - Caught / in jail

struct WatchJailView: View {
    let snapshot: WatchGameSnapshot

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                WTIconBadge(symbol: snapshot.isJailed ? "lock.fill" : "hand.raised.fill", tint: tint, size: 42)

                Text(snapshot.isJailed ? "IN JAIL" : "YOU'RE CAUGHT")
                    .font(.wtRounded(19, weight: .black))
                    .tracking(1)
                    .foregroundStyle(.white)

                content

                if snapshot.maxHearts > 0 {
                    WTHearts(hearts: snapshot.hearts, maxHearts: snapshot.maxHearts, size: 13)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    private var tint: Color { snapshot.isJailed ? WT.amber : WT.red }

    @ViewBuilder
    private var content: some View {
        if snapshot.isJailed {
            if let escape = snapshot.jailEscapeCountdown {
                // Wandered out of the jail zone: a short clock to get back before it costs them.
                WTBanner(
                    symbol: "exclamationmark.triangle.fill", text: "LEAVE THE JAIL ZONE — GO BACK",
                    detail: snapshot.deadline(after: escape), tint: WT.red
                )
            } else {
                hint("Stay inside the jail area until a runner breaks you out.")
            }
        } else if let arrival = snapshot.jailArrivalRemaining {
            // Sentenced but not there yet — running this out is a disqualification.
            VStack(spacing: 2) {
                WTCountdown(until: snapshot.deadline(after: arrival), font: .wtRounded(30, weight: .black))
                    .foregroundStyle(WT.red)
                WTLabel("TO REACH THE JAIL", color: WT.red)
            }
            hint("Get to the jail area before the clock runs out.")
        } else {
            hint("Waiting for the match to continue.")
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.wtRounded(11, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
            .multilineTextAlignment(.center)
    }
}

// MARK: - Eliminated

struct WatchOutView: View {
    let snapshot: WatchGameSnapshot

    private var reason: String {
        switch snapshot.eliminationReason {
        case "GAMBLE": return "You gambled away your last heart."
        case "BOUNDARY": return "You ran out of hearts outside the play area."
        case "JAIL_BREACH": return "You didn't make it back to the jail zone in time."
        case "JAIL_NO_SHOW": return "You never made it to the jail."
        case "BAILOUT": return "That jailbreak cost you your last heart."
        case "CAUGHT": return "You were caught with your last heart."
        default: return "You've been eliminated."
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "xmark.seal.fill")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(WT.red)
                    .shadow(color: WT.red.opacity(0.7), radius: 10)

                Text("YOU'RE OUT")
                    .font(.wtRounded(20, weight: .black))
                    .tracking(1)
                    .foregroundStyle(.white)

                Text(reason)
                    .font(.wtRounded(12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)

                WTLabel("SPECTATE ON YOUR IPHONE", size: 8)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }
}

// MARK: - The catch conversation

/// Runner side: a hunter says they caught you. Answered on the wrist, so the phone can stay in a
/// pocket mid-chase.
struct WatchCatchRequestView: View {
    let hunter: String
    let onAccept: () -> Void
    let onDeny: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                WTIconBadge(symbol: "hand.raised.fill", tint: WT.red, size: 38)

                Text("DID YOU GET CAUGHT?")
                    .font(.wtMono(11))
                    .tracking(1)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text("\(hunter) says they caught you.")
                    .font(.wtRounded(12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)

                Button("YES, I WAS CAUGHT", action: onAccept)
                    .buttonStyle(WTButtonStyle(tint: WT.red))
                Button("NO, NOT A CATCH", action: onDeny)
                    .buttonStyle(WTButtonStyle(tint: .white, prominent: false))
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
    }
}

/// Hunter side: the request is out, the runner hasn't answered yet.
struct WatchWaitingView: View {
    let runner: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 9) {
            WTPulse(symbol: "scope", tint: WT.red)

            Text("WAITING FOR \(runner.uppercased())")
                .font(.wtMono(11))
                .tracking(1)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text("They're being asked to confirm the catch.")
                .font(.wtRounded(11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("CANCEL", action: onCancel)
                .buttonStyle(WTButtonStyle(tint: .white, prominent: false))
        }
        .padding(.horizontal, 8)
    }
}

/// Hunter side: the runner said it wasn't a catch, and the hunter says whether that was a slip.
struct WatchDenyConfirmView: View {
    let runner: String
    let onAccident: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                WTIconBadge(symbol: "xmark.circle.fill", tint: WT.amber, size: 38)

                Text("\(runner.uppercased()) SAYS THAT WASN'T A CATCH")
                    .font(.wtMono(11))
                    .tracking(0.8)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text("Was it an accident?")
                    .font(.wtRounded(12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))

                Button("YES, IT WAS AN ACCIDENT", action: onAccident)
                    .buttonStyle(WTButtonStyle(tint: WT.amber))
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
    }
}

// MARK: - Notices

/// A short message from the phone ("Physical distance exceeds 15m…") that fades in over the top
/// of whatever page is showing and clears itself.
struct WatchToast: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.wtRounded(11, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.88)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(WT.amber.opacity(0.6), lineWidth: 1))
            .padding(.horizontal, 8)
    }
}
