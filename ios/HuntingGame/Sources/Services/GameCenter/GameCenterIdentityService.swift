import Foundation
import GameKit

/// Gets a Game Center identity the server can verify.
///
/// `fetchItems(forIdentityVerificationSignature:)` is the documented way to prove to your own
/// server which Game Center player this is. It returns a public key URL, a signature, a salt and a
/// timestamp; the server reassembles the signed buffer from those plus the player id and the bundle
/// id and checks the signature (backend `services/GameCenterIdentity.ts`).
///
/// `teamPlayerID` is the identifier, not `gamePlayerID`: Apple documents the team-scoped one for
/// this signature (the per-game one is for Apple Arcade), and it is also the one that stays the same
/// across everything we ship, which is what makes it usable as an account key.
@MainActor
enum GameCenterIdentityService {
    struct Payload: Encodable {
        let playerId: String
        let publicKeyUrl: String
        let signature: String
        let salt: String
        /// Milliseconds since the Unix epoch, exactly as GameKit produced it.
        let timestamp: UInt64
    }

    enum Failure: LocalizedError {
        case notSignedIn
        case restricted
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "You're not signed in to Game Center on this device. Open Settings, then Game Center, to sign in."
            case .restricted:
                return "This Apple Account can't use Game Center, so it can't be used to sign in here."
            case .cancelled:
                return nil // The sheet was dismissed deliberately.
            case .failed(let message):
                return message
            }
        }
    }

    /// Signs in to Game Center if needed, then produces a verifiable identity.
    static func fetchIdentity() async throws -> Payload {
        let status = await GameCenterManager.shared.authenticateForSignIn()
        switch status {
        case .connected:
            break
        case .restricted:
            throw Failure.restricted
        case .needsSignIn, .unknown:
            // The sheet was offered and never resolved — almost always dismissed without signing in.
            throw Failure.cancelled
        case .signedOut:
            throw Failure.notSignedIn
        }

        let player = GKLocalPlayer.local
        let teamPlayerId = player.teamPlayerID
        guard !teamPlayerId.isEmpty else { throw Failure.notSignedIn }

        let items: (url: URL, signature: Data, salt: Data, timestamp: UInt64)
        items = try await withCheckedThrowingContinuation { continuation in
            player.fetchItems(forIdentityVerificationSignature: { url, signature, salt, timestamp, error in
                if let error {
                    continuation.resume(throwing: Failure.failed("Game Center couldn't verify you: \(error.localizedDescription)"))
                    return
                }
                guard let url, let signature, let salt else {
                    continuation.resume(throwing: Failure.failed("Game Center didn't return everything needed to verify you."))
                    return
                }
                continuation.resume(returning: (url, signature, salt, timestamp))
            })
        }

        return Payload(
            playerId: teamPlayerId,
            publicKeyUrl: items.url.absoluteString,
            signature: items.signature.base64EncodedString(),
            salt: items.salt.base64EncodedString(),
            timestamp: items.timestamp
        )
    }
}
