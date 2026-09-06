import SwiftUI

/// The gamble duel's coin. Tosses the coin up on an arc, tumbles it end over end while the
/// server decides, then catches it and settles on whichever face the server actually
/// flipped (never a client-chosen outcome, so both devices always agree).
///
/// A gamble runs round after round until one side is out of hearts, so this view doubles as
/// the between-rounds prompt: the runner calls the next toss from here and can't leave until
/// the duel has a loser.
struct CoinFlipView: View {
    let myChoice: GambleChoice?
    let outcome: GambleResult?
    let isSelf: String
    /// True while the duel is live and this player owes the next call.
    let awaitingCall: Bool
    let onCall: (GambleChoice) -> Void
    let onContinue: () -> Void

    /// Accumulated tumble, in degrees. Each toss adds a whole number of half-turns so the
    /// coin always lands squarely on a face rather than on its edge.
    @State private var tumble: Double = 0
    @State private var tossHeight: CGFloat = 0
    @State private var coinScale: CGFloat = 1

    /// The face currently pointing at the viewer: mid-tumble the coin reads off its own
    /// rotation so both sides genuinely flash past, and once settled it shows the result.
    private var showingHeads: Bool {
        if let outcome, !isFlipping { return outcome.result == "heads" }
        return Int((tumble / 180).rounded()) % 2 == 0
    }

    private var isFlipping: Bool { outcome == nil }

    var body: some View {
        VStack(spacing: 18) {
            Text(headerText)
                .font(ADATheme.telemetryFont(size: 13))
                .foregroundColor(.white.opacity(0.6))
                .tracking(2)

            coin
                .frame(height: 130)

            if let myChoice, isFlipping {
                Text("YOU CALLED \(myChoice.rawValue.uppercased())")
                    .font(ADATheme.uiFont(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
            }

            if let outcome {
                Text(outcomeTitle(outcome))
                    .font(ADATheme.displayFont(size: 18))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                Text(outcomeSubtitle(outcome))
                    .font(ADATheme.uiFont(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)

                if awaitingCall {
                    Text("CALL THE NEXT TOSS")
                        .font(ADATheme.telemetryFont(size: 11))
                        .foregroundColor(ADATheme.tacticalAmber)
                        .tracking(1.5)
                        .padding(.top, 2)

                    HStack(spacing: 10) {
                        Button { onCall(.heads) } label: {
                            HStack { Image(systemName: "crown.fill"); Text("HEADS") }
                        }
                        .buttonStyle(GlowButtonStyle(tint: ADATheme.tacticalAmber))

                        Button { onCall(.tails) } label: {
                            HStack { Image(systemName: "leaf.fill"); Text("TAILS") }
                        }
                        .buttonStyle(GlowButtonStyle(tint: ADATheme.spatialCyan))
                    }
                } else {
                    Button("CONTINUE") { onContinue() }
                        .buttonStyle(GlowButtonStyle(tint: ADATheme.tacticalAmber))
                }
            }
        }
        .padding(28)
        .glassCard(cornerRadius: ADATheme.sheetCornerRadius, tint: ADATheme.tacticalAmber)
        .padding(.horizontal, 40)
        .onAppear { toss() }
        .onChange(of: outcome?.round) { _ in settle() }
        .onChange(of: awaitingCall) { isAwaiting in
            // A fresh round starts its own toss rather than resuming the settled coin.
            if !isAwaiting && outcome == nil { toss() }
        }
    }

    private var coin: some View {
        ZStack {
            Circle()
                .fill(faceColor.opacity(0.28))
            Circle()
                .strokeBorder(faceColor, lineWidth: 3)
            // The rim's inner ridge — sells the coin as an object rather than a flat disc.
            Circle()
                .strokeBorder(faceColor.opacity(0.45), lineWidth: 1)
                .padding(9)

            Image(systemName: showingHeads ? "crown.fill" : "leaf.fill")
                .font(.system(size: 38, weight: .bold))
                .foregroundColor(faceColor)
                // Counter-flips the glyph on the back face so it's never mirrored.
                .rotation3DEffect(.degrees(showingHeads ? 0 : 180), axis: (x: 1, y: 0, z: 0))
        }
        .frame(width: 110, height: 110)
        .shadow(color: faceColor.opacity(0.5), radius: 18)
        .rotation3DEffect(.degrees(tumble), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
        .scaleEffect(coinScale)
        .offset(y: -tossHeight)
    }

    private var faceColor: Color {
        showingHeads ? ADATheme.tacticalAmber : ADATheme.spatialCyan
    }

    private var headerText: String {
        guard let outcome else { return "TOSSING…" }
        return "ROUND \(outcome.round)"
    }

    /// Throws the coin up and starts it tumbling. Deliberately not a `repeatForever` spin:
    /// the coin rises, turns over several times, and hangs at the top of its arc waiting on
    /// the server, so a slow round reads as a coin in the air rather than a loading spinner.
    private func toss() {
        tossHeight = 0
        coinScale = 1
        withAnimation(.easeOut(duration: 0.45)) {
            tossHeight = 54
            coinScale = 0.82
        }
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false)) {
            tumble += 1800
        }
    }

    /// Catches the coin: drops it back down while the tumble decelerates onto the face the
    /// server flipped, with a small bounce on landing.
    private func settle() {
        guard let outcome else { return }
        // Land on the nearest whole rotation that shows the right face, always turning
        // forward so the coin never visibly rewinds.
        let halfTurns = (tumble / 180).rounded(.up)
        let wantsEvenHalfTurns = outcome.result == "heads"
        let isEven = Int(halfTurns) % 2 == 0
        let target = (halfTurns + (isEven == wantsEvenHalfTurns ? 4 : 5)) * 180

        withAnimation(.timingCurve(0.2, 0.9, 0.25, 1.0, duration: 1.1)) {
            tumble = target
            tossHeight = 0
            coinScale = 1
        }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.45).delay(1.05)) {
            coinScale = 1.12
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(1.25)) {
            coinScale = 1
        }
        HapticsEngine.shared.powerUpCollected()
    }

    private func outcomeTitle(_ outcome: GambleResult) -> String {
        let iAmHunter = outcome.hunterId == isSelf
        let iAmRunner = outcome.runnerId == isSelf
        let iLost = (outcome.heartsLostBy == "HUNTER" && iAmHunter) || (outcome.heartsLostBy == "RUNNER" && iAmRunner)

        if !outcome.continues {
            if iLost { return "YOU'RE OUT OF HEARTS" }
            if iAmHunter || iAmRunner { return "THEY'RE OUT OF HEARTS" }
            return outcome.heartsLostBy == "HUNTER" ? "THE HUNTER IS OUT" : "THE RUNNER IS OUT"
        }
        if iLost { return "YOU LOST A HEART" }
        if iAmHunter || iAmRunner { return "THEY LOST A HEART" }
        return outcome.heartsLostBy == "HUNTER" ? "THE HUNTER LOST A HEART" : "THE RUNNER LOST A HEART"
    }

    private func outcomeSubtitle(_ outcome: GambleResult) -> String {
        let landed = "The coin landed on \(outcome.result.uppercased())."
        guard outcome.continues else { return landed }
        return "\(landed) \(outcome.hunterHeartsRemaining) vs \(outcome.runnerHeartsRemaining) — it runs until someone's out."
    }
}
