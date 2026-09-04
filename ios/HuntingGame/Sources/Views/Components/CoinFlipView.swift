import SwiftUI

/// The animated coin flip for a gamble — spins continuously while waiting on the
/// server-authoritative result, then settles on whichever side the server actually
/// flipped (never a client-chosen outcome, so both the hunter's and runner's devices
/// always agree).
struct CoinFlipView: View {
    let myChoice: GambleChoice?
    let outcome: GambleResult?
    let isSelf: String
    let onContinue: () -> Void

    @State private var rotation: Double = 0

    var body: some View {
        VStack(spacing: 18) {
            Text("GAMBLE")
                .font(ADATheme.telemetryFont(size: 13))
                .foregroundColor(.white.opacity(0.6))
                .tracking(2)

            ZStack {
                Circle()
                    .fill(ADATheme.tacticalAmber.opacity(0.25))
                    .frame(width: 110, height: 110)
                Circle()
                    .strokeBorder(ADATheme.tacticalAmber, lineWidth: 3)
                    .frame(width: 110, height: 110)
                Image(systemName: coinSymbol)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(ADATheme.tacticalAmber)
            }
            .rotation3DEffect(.degrees(rotation), axis: (x: 0, y: 1, z: 0))

            if let myChoice, outcome == nil {
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

                Button("CONTINUE") { onContinue() }
                    .buttonStyle(GlowButtonStyle(tint: ADATheme.tacticalAmber))
            }
        }
        .padding(28)
        .glassCard(cornerRadius: ADATheme.sheetCornerRadius, tint: ADATheme.tacticalAmber)
        .padding(.horizontal, 40)
        .onAppear { startSpin() }
        .onChange(of: outcome?.result) { newValue in
            guard newValue != nil else { return }
            settle(on: outcome)
        }
    }

    private var coinSymbol: String {
        guard let outcome else { return "circle.fill" }
        return outcome.result == "heads" ? "circle.fill" : "circle"
    }

    private func startSpin() {
        withAnimation(.linear(duration: 0.5).repeatForever(autoreverses: false)) {
            rotation = 360 * 6
        }
    }

    private func settle(on outcome: GambleResult?) {
        guard let outcome else { return }
        let finalSpins: Double = outcome.result == "heads" ? 0 : 180
        withAnimation(.easeOut(duration: 0.9)) {
            rotation = 360 * 8 + finalSpins
        }
    }

    private func outcomeTitle(_ outcome: GambleResult) -> String {
        let iAmHunter = outcome.hunterId == isSelf
        let iAmRunner = outcome.runnerId == isSelf
        let iLost = (outcome.heartsLostBy == "HUNTER" && iAmHunter) || (outcome.heartsLostBy == "RUNNER" && iAmRunner)
        if outcome.heartsLostBy == "HUNTER" {
            return iAmHunter ? "THE HUNTER SHRUGGED IT OFF" : "THE HUNTER TOOK A HIT"
        }
        return iLost ? "YOU LOST A HEART" : "THEY LOST A HEART"
    }

    private func outcomeSubtitle(_ outcome: GambleResult) -> String {
        "The coin landed on \(outcome.result.uppercased())."
    }
}
