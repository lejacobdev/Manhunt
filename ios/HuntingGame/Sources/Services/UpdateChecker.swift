import Foundation

/// Compares the running build's version against the SideStore source's latest published
/// one and surfaces a dismissible in-app banner when a newer build exists — no push
/// notification, no App Store update prompt (there is no App Store listing to prompt from,
/// this app is sideloaded), just a passive nudge on the one screen every session passes
/// through anyway.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct AvailableUpdate: Equatable {
        let version: String
        let changelog: String
    }

    @Published private(set) var available: AvailableUpdate?

    /// Persists across launches so dismissing today's update doesn't re-nag every time the
    /// app opens — it only resurfaces once a version newer than the dismissed one ships.
    private let dismissedKey = "com.huntinggame.app.dismissedUpdateVersion"
    private var lastCheckedAt: Date?
    /// Cheap enough to check every foreground, but not worth doing twice in the same minute
    /// if the user is quickly backgrounding/reopening.
    private let minCheckInterval: TimeInterval = 60

    private init() {}

    func checkIfNeeded() async {
        if let lastCheckedAt, Date().timeIntervalSince(lastCheckedAt) < minCheckInterval { return }
        lastCheckedAt = Date()

        guard let runningVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return }

        var request = URLRequest(url: APIClient.shared.baseURL.appendingPathComponent("dist/source.json"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let source = try? JSONDecoder().decode(SideStoreSource.self, from: data),
              let latest = source.apps.first?.versions.first else { return }

        guard Self.isNewer(latest.version, than: runningVersion) else {
            available = nil
            return
        }

        let dismissed = UserDefaults.standard.string(forKey: dismissedKey)
        if let dismissed, !Self.isNewer(latest.version, than: dismissed) { return }

        available = AvailableUpdate(version: latest.version, changelog: latest.localizedDescription)
    }

    func dismiss() {
        guard let available else { return }
        UserDefaults.standard.set(available.version, forKey: dismissedKey)
        self.available = nil
    }

    /// "1.0.42" vs "1.0.41" — compares numerically component-by-component rather than as
    /// strings ("1.0.9" < "1.0.10" lexically, which is wrong), padding a shorter version
    /// with zeros so "1.0" vs "1.0.1" still compares sanely.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let partsA = a.split(separator: ".").compactMap { Int($0) }
        let partsB = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(partsA.count, partsB.count) {
            let x = i < partsA.count ? partsA[i] : 0
            let y = i < partsB.count ? partsB[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// Mirrors just the fields docker-build.sh writes into source.json — enough to read the
/// latest version's number and changelog, nothing else in that manifest is needed here.
private struct SideStoreSource: Decodable {
    struct App: Decodable {
        struct Version: Decodable {
            let version: String
            let localizedDescription: String
        }
        let versions: [Version]
    }
    let apps: [App]
}
