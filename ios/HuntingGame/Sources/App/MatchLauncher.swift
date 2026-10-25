import SwiftUI

/// Lets a screen deep inside a match (the results overlay) open a different match, the rematch,
/// in place of the one on screen. Mission Control provides it, since it owns the presentation;
/// where nothing provides it the Rematch button simply isn't offered.
struct LaunchMatchAction {
    let launch: (_ player: GamePlayer, _ session: GameSession) -> Void
    func callAsFunction(_ player: GamePlayer, _ session: GameSession) { launch(player, session) }
}

private struct LaunchMatchKey: EnvironmentKey {
    static let defaultValue: LaunchMatchAction? = nil
}

extension EnvironmentValues {
    var launchMatch: LaunchMatchAction? {
        get { self[LaunchMatchKey.self] }
        set { self[LaunchMatchKey.self] = newValue }
    }
}

/// Asks for an App Store rating at most once per app version, and only right after someone won
/// a match, once they've finished a few. (iOS itself also caps how often the prompt can appear.)
enum ReviewPrompt {
    private static let finishedKey = "reviewPrompt.finishedMatches"
    private static let versionKey = "reviewPrompt.lastVersion"

    /// Call once per finished match. True when now is a good moment to ask.
    static func shouldAsk(afterWin won: Bool) -> Bool {
        let defaults = UserDefaults.standard
        let finished = defaults.integer(forKey: finishedKey) + 1
        defaults.set(finished, forKey: finishedKey)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard won, finished >= 2, defaults.string(forKey: versionKey) != version else { return false }
        defaults.set(version, forKey: versionKey)
        return true
    }
}
