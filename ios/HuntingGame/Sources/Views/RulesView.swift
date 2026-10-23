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
                                .tacticalFont(.display, size: 24)
                                .foregroundColor(.white)
                            Text("Everyone plays by the same ones. You'll need to accept these before hosting or joining a match.")
                                .tacticalFont(.ui, size: 13, weight: .medium)
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
                            "A match needs at least one hunter and one runner to start.",
                        ]
                    )

                    section(
                        icon: "heart.fill",
                        title: "HEARTS",
                        tint: ADATheme.hunterRed,
                        lines: [
                            "Hearts are lives. Runners start with 3, hunters with 5.",
                            "A runner loses a heart every time they're caught. Hunters lose hearts outside the play area and to every jailbreak. Everyone loses them outside the zone.",
                            "Lose your last heart and you're out for the rest of the match — you stay on as a spectator. Adrenaline adds two.",
                        ]
                    )

                    section(
                        icon: "hand.raised.fill",
                        title: "GETTING CAUGHT",
                        tint: ADATheme.hunterRed,
                        lines: [
                            "A hunter has to get within about 15 metres and send a catch request.",
                            "You answer it on your own phone within 20 seconds — in the app, or with the Yes / No buttons on the lock-screen notification. No answer counts as caught.",
                            "Say no and the hunter decides: their mistake (no catch), or they insist. If they insist, the host rules. If the host is one of the two players, or doesn't rule within 45 seconds, the catch stands.",
                            "Every catch costs the runner one heart. Without jail mode you keep playing with a 30-second shield to get away; with jail mode you're sent to jail. Lose your last heart and you're out.",
                            "Runners get a head start at the beginning (the host sets how long, up to 5 minutes): hunters' radar stays dark and nobody can be caught.",
                        ]
                    )

                    section(
                        icon: "lock.fill",
                        title: "JAIL MODE",
                        tint: ADATheme.tacticalAmber,
                        lines: [
                            "If the host turned it on, a caught runner with hearts left is sent to jail.",
                            "You have to walk to the jail yourself, within the time the host set. Never turning up is a disqualification.",
                            "Once you're there, leaving gives you 10 seconds to get back inside before you're disqualified.",
                            "A runner who is still free can stand in the jail to break everyone out at once. It costs them a heart, and takes a heart off every hunter.",
                            "That bail-out clock only runs while someone's actually in the jail, and it restarts if the rescuer steps outside.",
                            "Freed runners are shielded for 30 seconds before they can be caught again.",
                            "The jail never costs hearts — even once the shrinking zone has passed it. Safe Zone Flares don't work there.",
                        ]
                    )

                    section(
                        icon: "map.fill",
                        title: "THE PLAY AREA",
                        lines: [
                            "The host draws the boundary, and a zone inside it shrinks as the match goes on: it holds for the first fifth of the match, closes slowly and then faster, and reaches its final size with a tenth of the time left.",
                            "Outside either one you get a warning, then lose a heart at a time — hunters and runners alike — until you're back inside.",
                            "The host also sets the radar ping: live, or every 10 seconds up to every 10 minutes. With a ping, radar and compass only update on each ping.",
                        ]
                    )

                    section(
                        icon: "shippingbox.fill",
                        title: "POWER-UPS",
                        lines: [
                            "Scattered around the play area. Walk to one to pick it up, then use it from your equipment panel. You only see the ones your side can use.",
                            "Invisibility (anyone, 60 s) — you vanish from the other side's radar or compass.",
                            "Thermal Vision (hunters, 45 s) — every runner within 300 m shows on your map as a heat signature, invisible ones included, and your radar tracks live between pings. Decoys have no heat.",
                            "Ghost Decoy (runners, 3 min) — a fake copy of you walks away from the direction you were heading. Hunters can't tell it from the real you until they reach it.",
                            "EMP Jammer (runners, 60 s) — every hunter within 200 m of you loses their radar at once and misses every ping until it wears off.",
                            "Adrenaline (runners, 90 s) — two extra hearts, and a higher top speed for anti-cheat.",
                            "Safe Zone Flare (anyone, 90 s) — a 30 m bubble around where you stood where nobody can be caught.",
                        ]
                    )

                    section(
                        icon: "person.3.fill",
                        title: "MODES",
                        lines: [
                            "Standard — hunters versus runners.",
                            "Infection — a caught runner switches sides and joins the hunt. The match ends when nobody is left running.",
                            "Squad — teams, each with hunters and runners. You only chase other squads' runners, and your radar and compass only show the other squads. The last squad with a runner still free wins; at time, the squad with the most runners free. Pick your squad when you join.",
                            "In Squad mode a jailbreak only frees your own squad, and only costs the other squads' hunters a heart.",
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

                    Link("Read the full rules online", destination: URL(string: "https://huntinggame.lejacob.dev/rules.html")!)
                        .tacticalFont(.ui, size: 12, weight: .semibold)
                        .tint(ADATheme.spatialCyan)

                    if isGate {
                        VStack(spacing: 10) {
                            Button("I ACCEPT THE RULES") { onAccept?() }
                                .buttonStyle(GlowButtonStyle(tint: ADATheme.runnerGreen))

                            Button("NOT RIGHT NOW") { onDecline?() }
                                .tacticalFont(.telemetry, size: 11)
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
                    .tacticalFont(.symbol, size: 13, weight: .bold)
                    .foregroundColor(tint)
                Text(title)
                    .tacticalFont(.telemetry, size: 11)
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
                        .tacticalFont(.ui, size: 13, weight: .medium)
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
