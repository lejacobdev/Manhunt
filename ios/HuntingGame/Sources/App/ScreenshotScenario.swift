#if DEBUG
import SwiftUI

/// Fixed screens with sample data for the simulator, so every important screen can be looked at —
/// and screenshotted at different text sizes by .github/workflows/iphone-screens.yml — without a
/// server, an account or a match in progress. Debug builds only; a release build contains none of it.
///
///   xcrun simctl launch <sim> com.huntinggame.app -UIScenario hud-hunter
enum ScreenshotScenario: String, CaseIterable {
    case auth
    case rules
    case hudHunter = "hud-hunter"
    case hudRunner = "hud-runner"
    case summary
    case cosmetics

    static var current: ScreenshotScenario? {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-UIScenario"), args.indices.contains(flag + 1) else { return nil }
        return ScreenshotScenario(rawValue: args[flag + 1])
    }

    @ViewBuilder
    var view: some View {
        switch self {
        case .auth:
            AuthView()
        case .rules:
            RulesView(onAccept: {}, onDecline: {})
        case .hudHunter:
            ScenarioGame(role: .hunter)
        case .hudRunner:
            ScenarioGame(role: .runner)
        case .summary:
            MatchSummaryView(sessionCode: "K7Q2", myUserId: "u-me", preloaded: Self.sampleSummary)
        case .cosmetics:
            NavigationStack { CosmeticsView(isPreview: true) }
                .onAppear { Task { @MainActor in CosmeticsStore.shared.loadPreview(Self.sampleCosmetics) } }
        }
    }

    // MARK: - Sample data

    static func decode<T: Decodable>(_ json: String) -> T {
        try! JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    static let center = (lat: 50.9375, lng: 6.9603)

    static var sampleSummary: MatchSummary {
        decode("""
        {"code":"K7Q2","mode":"STANDARD","durationSeconds":1820,"endReason":"TIME_EXPIRED","winningSquad":null,
         "players":[
          {"gamePlayerId":"p1","userId":"u-me","username":"jacob","role":"RUNNER","startedAs":"RUNNER","squad":null,"hearts":2,"survived":true,"isOut":false,"outReason":null,"distanceMeters":3420,"catches":0,"timesCaught":1,"jailbreaks":1,"freedOthers":2,"powerUpsCollected":3,"powerUpsUsed":{"Ghost Decoy":1,"EMP Jammer":1}},
          {"gamePlayerId":"p2","userId":"u2","username":"mira","role":"HUNTER","startedAs":"HUNTER","squad":null,"hearts":3,"survived":false,"isOut":false,"outReason":null,"distanceMeters":4110,"catches":3,"timesCaught":0,"jailbreaks":0,"freedOthers":0,"powerUpsCollected":2,"powerUpsUsed":{"Thermal Vision":2}},
          {"gamePlayerId":"p3","userId":"u3","username":"leon","role":"RUNNER","startedAs":"RUNNER","squad":null,"hearts":0,"survived":false,"isOut":true,"outReason":"caught on their last heart","distanceMeters":2650,"catches":0,"timesCaught":3,"jailbreaks":0,"freedOthers":0,"powerUpsCollected":1,"powerUpsUsed":{}}
         ],
         "highlights":[
          {"title":"Top hunter","username":"mira","gamePlayerId":"p2","value":"3 catches"},
          {"title":"Furthest run","username":"mira","gamePlayerId":"p2","value":"4.11 km"},
          {"title":"Jailbreaker","username":"jacob","gamePlayerId":"p1","value":"freed 2"},
          {"title":"Power player","username":"mira","gamePlayerId":"p2","value":"2 power-ups"}
         ],
         "timeline":[
          {"at":95,"kind":"powerup","text":"mira used Thermal Vision"},
          {"at":212,"kind":"catch","text":"mira caught leon — sent to jail"},
          {"at":530,"kind":"jailbreak","text":"jacob broke 2 out of jail"},
          {"at":1490,"kind":"out","text":"leon is out — caught on their last heart"}
         ]}
        """)
    }
}

/// The live match screen with a believable mid-match state.
private struct ScenarioGame: View {
    let role: PlayerRole

    var body: some View {
        GameView(gamePlayer: player, session: session, isPreview: true)
            .onAppear(perform: fill)
    }

    private var player: GamePlayer {
        ScreenshotScenario.decode("""
        {"id":"p-me","sessionId":"s1","userId":"u-me","role":"\(role.rawValue)","squad":null,"isCaught":false,"arrestCode":"4821","hearts":\(role == .hunter ? 5 : 2)}
        """)
    }

    private var session: GameSession {
        let c = ScreenshotScenario.center
        let d = 0.006
        return ScreenshotScenario.decode("""
        {"id":"s1","code":"K7Q2","status":"ACTIVE","mode":"STANDARD","hostId":"u-me","startedAt":null,"endedAt":null,
         "settings":{"durationMinutes":30,"boundsPolygon":[{"lat":\(c.lat - d),"lng":\(c.lng - d)},{"lat":\(c.lat - d),"lng":\(c.lng + d)},{"lat":\(c.lat + d),"lng":\(c.lng + d)},{"lat":\(c.lat + d),"lng":\(c.lng - d)}],
          "jailEnabled":true,"jailPolygon":[{"lat":\(c.lat + 0.003),"lng":\(c.lng - 0.002)},{"lat":\(c.lat + 0.003),"lng":\(c.lng - 0.001)},{"lat":\(c.lat + 0.0038),"lng":\(c.lng - 0.001)},{"lat":\(c.lat + 0.0038),"lng":\(c.lng - 0.002)}],
          "radarIntervalSeconds":30,"headStartSeconds":0}}
        """)
    }

    private func fill() {
        let socket = SocketService.shared
        let c = ScreenshotScenario.center
        socket.matchStartedAt = Date().addingTimeInterval(-7 * 60 - 12)
        socket.inventory = role == .hunter ? [.thermalVision, .invisibility] : [.ghostDecoy, .empJammer, .safeZoneFlare]
        socket.zone = ScreenshotScenario.decode("""
        {"center":{"lat":\(c.lat),"lng":\(c.lng)},"radiusMeters":520,"fullRadiusMeters":940,"finalRadiusMeters":75,"progress":0.24}
        """)
        if role == .hunter {
            socket.radar = ScreenshotScenario.decode("""
            {"runners":[],"runnerBearings":[
              {"runnerId":"r1","username":"leon","distanceMeters":64,"bearingDegrees":35},
              {"runnerId":"r2","username":"jacob","distanceMeters":212,"bearingDegrees":250}],
             "decoys":[],"jammed":false,"heat":[{"id":"r1","lat":\(c.lat + 0.0005),"lng":\(c.lng + 0.0004)}],"live":false}
            """)
        } else {
            socket.compass = ScreenshotScenario.decode("""
            {"distanceMeters":48,"bearingDegrees":120,"hunters":[{"hunterId":"h1","username":"mira","distanceMeters":48,"bearingDegrees":120}]}
            """)
        }
    }
}
#endif
