import Foundation
import Combine

/// The one place that knows what a friend QR encodes and how to read one back.
///
/// The code carries an `https://` URL rather than the app's own `huntinggame://` scheme
/// because iOS Camera (and most third-party scanners) silently ignore unknown custom
/// schemes — an https link always offers a tap-through. That URL is served by the backend
/// (`GET /u/:username/:tag`), which immediately bounces to the custom scheme, so a scan
/// from outside the app still lands in the right place. A scan from *inside* the app never
/// makes the round trip: it parses the tag straight out of whichever form it sees.
enum FriendLink {
    static let scheme = "huntinggame"
    static let addFriendHost = "add-friend"

    /// Kept in sync with APIClient.baseURL — the backend serves the landing page this
    /// points at, so a QR minted against a different host would 404 on scan.
    static var webBase: URL { APIClient.shared.baseURL }

    static func shareURL(username: String, userTag: String) -> String {
        let name = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
        let tag = userTag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userTag
        return "\(webBase.absoluteString)/u/\(name)/\(tag)"
    }

    struct Handle: Equatable, Identifiable {
        let username: String
        let userTag: String
        var label: String { "\(username)#\(userTag)" }
        /// The tag pair is already the account's unique public handle, so it doubles as
        /// the identity SwiftUI needs to drive a `.sheet(item:)`.
        var id: String { label }
    }

    /// Accepts every shape a scan or deep link can arrive in: the https landing URL, the
    /// `huntinggame://add-friend?...` scheme it redirects to, or a bare "name#tag" (which
    /// is what a player would type by hand, and what the QR would degrade to if someone
    /// pasted the label instead of the link).
    static func parse(_ raw: String) -> Handle? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let components = URLComponents(string: trimmed) {
            if components.scheme == scheme, components.host == addFriendHost {
                let items = components.queryItems ?? []
                if let username = items.first(where: { $0.name == "username" })?.value,
                   let tag = items.first(where: { $0.name == "tag" })?.value,
                   !username.isEmpty, !tag.isEmpty {
                    return Handle(username: username, userTag: tag)
                }
                return nil
            }
            if components.scheme == "https" || components.scheme == "http" {
                // .../u/<username>/<tag> — tolerant of a trailing slash or extra path
                // prefix so the link survives being served from a subpath later.
                let parts = components.path.split(separator: "/").map(String.init)
                if let index = parts.firstIndex(of: "u"), parts.count > index + 2 {
                    return Handle(username: parts[index + 1], userTag: parts[index + 2])
                }
                return nil
            }
        }

        let pieces = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
        if pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty {
            return Handle(username: pieces[0], userTag: pieces[1])
        }
        return nil
    }
}

/// Carries a friend handle from wherever it was opened (a scanned code, or the app being
/// launched by the deep link itself) to whichever screen is in a position to act on it.
/// A published property rather than a direct call because the link can arrive while the
/// app is still starting up, before any view that could show a prompt exists yet.
@MainActor
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()

    @Published var pendingFriend: FriendLink.Handle?

    private init() {}

    func handle(_ url: URL) {
        guard let handle = FriendLink.parse(url.absoluteString) else { return }
        pendingFriend = handle
    }
}
