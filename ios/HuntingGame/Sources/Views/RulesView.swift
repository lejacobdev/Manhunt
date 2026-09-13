import SwiftUI

/// The game's rules, in two guises. With `onAccept`/`onDecline` supplied it's a gate —
/// shown once after the terms screen on a fresh install, and again on any attempt to host
/// or join while the rules are still unaccepted. Without them it's plain reference, pushed
/// from the Profile tab so anyone can re-read the rules mid-match.
struct RulesView: View {
    var onAccept: (() -> Void)?
    var onDecline: (() -> Void)?

    private var isGate: Bool { onAccept != nil }

    var body: some View {
        ZStack {
            RadarSweepBackdrop(accent: ADATheme.tacticalAmber)
                .edgesIgnoringSafeArea(.all)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if isGate {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("THE RULES")
                                .font(ADATheme.displayFont(size: 24))
                                .foregroundColor(.white)
                            Text("Everyone plays by the same ones. You'll need to accept these before hosting or joining a match.")
                                .font(ADATheme.uiFont(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.55))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 8)
                    }

                    section(
                        icon: "flag.checkered",
                        title: "THE GOAL",
                        lines: [
                            "Hunters chase runners down. Runners survive until the clock runs out.",
                            "Hunters win once every runner is caught, jailed or eliminated. Runners win if even one is still free at time — or if every hunter is eliminated.",
                        ]
                    )

                    section(
                        icon: "heart.fill",
                        title: "HEARTS",
                        tint: ADATheme.hunterRed,
                        lines: [
                            "Runners start with 3 hearts, hunters with 5.",
                            "Lose them all and you're out for the rest of the match — you stay on as a spectator.",
                        ]
                    )

                    section(
                        icon: "hand.raised.fill",
                        title: "GETTING CAUGHT",
                        tint: ADATheme.hunterRed,
                        lines: [
                            "A hunter has to get within about 15 metres and send a catch request.",
                            "You answer it on your own phone: yes, or no. Say no and the hunter is asked whether it was an accident. A genuine disagreement is the host's to settle.",
                            "Every catch costs the runner one heart. Lose your last one to a catch and no rescue can bring you back.",
                        ]
                    )

                    section(
                        icon: "lock.fill",
                        title: "JAIL MODE",
                        tint: ADATheme.tacticalAmber,
                        lines: [
                            "If the host turned it on, being caught sends you to jail instead of ending your match.",
                            "You have to walk to the jail yourself, within the time the host set. Never turning up is a disqualification.",
                            "Once you're there, leaving gives you 10 seconds to get back inside before you're disqualified.",
                            "A runner who is still free can stand in the jail to break everyone out at once. It costs them a heart, and takes a heart off every hunter.",
                            "That bail-out clock only runs while someone's actually in the jail, and it restarts if the rescuer steps outside.",
                        ]
                    )

                    section(
                        icon: "map.fill",
                        title: "THE PLAY AREA",
                        lines: [
                            "The host draws the boundary, and a zone inside it shrinks as the match goes on.",
                            "Outside either one you get a warning, then lose a heart at a time — hunters and runners alike — until you're back inside.",
                        ]
                    )

                    section(
                        icon: "shippingbox.fill",
                        title: "POWER-UPS",
                        lines: [
                            "Scattered around the play area and picked up by walking to them: invisibility, a decoy trail, a radar jammer, thermal vision, adrenaline, and a flare that makes a bubble where nobody can be caught.",
                        ]
                    )

                    section(
                        icon: "person.3.fill",
                        title: "MODES",
                        lines: [
                            "Standard — hunters versus runners.",
                            "Infection — a caught runner switches sides and joins the hunt.",
                            "Squad — teams. You can only tag other squads, and squadmates can revive each other. Pick your squad when you join.",
                        ]
                    )

                    section(
                        icon: "exclamationmark.triangle.fill",
                        title: "PLAY SAFE, PLAY FAIR",
                        tint: ADATheme.tacticalAmber,
                        lines: [
                            "This happens in real, public places. Obey traffic laws, don't trespass, and don't let the app pull your attention off what's around you.",
                            "No fake GPS, no cars when the match is on foot, and never use location to follow someone who isn't playing with you.",
                            "Any player can be reported or blocked from their profile.",
                        ]
                    )

                    Link("Read the full rules on lejacob.dev", destination: URL(string: "https://lejacob.dev/rules.html")!)
                        .font(ADATheme.uiFont(size: 12, weight: .semibold))
                        .tint(ADATheme.spatialCyan)

                    if isGate {
                        VStack(spacing: 10) {
                            Button("I ACCEPT THE RULES") { onAccept?() }
                                .buttonStyle(GlowButtonStyle(tint: ADATheme.runnerGreen))

                            Button("NOT RIGHT NOW") { onDecline?() }
                                .font(ADATheme.telemetryFont(size: 11))
                                .foregroundColor(.white.opacity(0.4))
                                .tracking(1.5)
                        }
                        .padding(.top, 4)
                    }

                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .adaptiveContentWidth()
            }
        }
        .obsidianBackdrop()
        .navigationTitle(isGate ? "" : "Game Rules")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private func section(icon: String, title: String, tint: Color = ADATheme.spatialCyan, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(tint)
                Text(title)
                    .font(ADATheme.telemetryFont(size: 11))
                    .foregroundColor(tint)
                    .tracking(1.5)
            }

            ForEach(lines, id: \.self) { line in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(.white.opacity(0.25))
                        .frame(width: 4, height: 4)
                        .padding(.top, 7)
                    Text(line)
                        .font(ADATheme.uiFont(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(cornerRadius: ADATheme.cardCornerRadius, tint: tint)
    }
}
