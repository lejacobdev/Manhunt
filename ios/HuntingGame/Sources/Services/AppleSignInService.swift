import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Runs a Sign in with Apple request and hands back only what the server can verify.
///
/// The credential Apple returns also carries a user identifier, and on the very first
/// authorization a name and email. None of those are sent anywhere: the server trusts the signed
/// `identityToken` and nothing else (see backend `services/AppleIdentity.ts`), and the app never
/// asks for an email address it has promised in the privacy policy not to collect. So the scope
/// requested here is deliberately empty.
@MainActor
final class AppleSignInService: NSObject {
    static let shared = AppleSignInService()

    struct Credential {
        /// The JWT Apple signed. The only thing worth sending.
        let identityToken: String
        /// SHA-256 of the raw nonce, in the exact form Apple echoes back inside the token.
        let nonce: String
    }

    enum Failure: LocalizedError {
        case cancelled
        case noIdentityToken
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return nil // Nothing to show: the person closed the sheet on purpose.
            case .noIdentityToken:
                return "Apple didn't return a sign-in token. Please try again."
            case .failed(let message):
                return message
            }
        }
    }

    private var activeContinuation: CheckedContinuation<Credential, Error>?
    private var activeNonce: String?

    // MARK: - Used with SwiftUI's SignInWithAppleButton
    //
    // The sign-in screen uses Apple's own button rather than a lookalike, because that is what
    // Apple's guidelines require of a Sign in with Apple entry point. That button runs the request
    // itself, so these two let it share this file's nonce handling and token extraction instead of
    // growing a second copy in the view.

    /// Configures a request from `SignInWithAppleButton`'s `onRequest`, remembering the nonce so
    /// `credential(from:)` can report the value the server must match.
    func configure(_ request: ASAuthorizationAppleIDRequest) {
        let hashedNonce = Self.sha256Hex(Self.randomNonceString())
        activeNonce = hashedNonce
        request.requestedScopes = []
        request.nonce = hashedNonce
    }

    /// Pulls the one trustworthy field out of what the button's `onCompletion` handed back.
    func credential(from authorization: ASAuthorization) throws -> Credential {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8),
              !token.isEmpty else {
            throw Failure.noIdentityToken
        }
        let nonce = activeNonce
        activeNonce = nil
        return Credential(identityToken: token, nonce: nonce ?? "")
    }

    /// Turns whatever Apple's button reports into something worth showing — or nothing at all when
    /// the person simply closed the sheet.
    func failure(from error: Error) -> Failure {
        if let authError = error as? ASAuthorizationError, authError.code == .canceled {
            return .cancelled
        }
        return .failed("Apple sign-in didn't complete: \(error.localizedDescription)")
    }

    /// Presents Apple's sheet and waits for it.
    ///
    /// About the nonce: Apple puts whatever string is in `request.nonce` into the token's `nonce`
    /// claim, and the server checks the two match. Since this app generates it, that binds the
    /// token to this particular request — it is NOT a server-issued replay defence, because a
    /// captured token would travel with the value it was minted for. What actually limits replay is
    /// the token's own short expiry and TLS. It is included because the check costs nothing and
    /// rules out a token minted for some other request of ours being pasted into this one.
    func requestCredential() async throws -> Credential {
        if activeContinuation != nil {
            throw Failure.failed("A sign-in is already in progress.")
        }

        let request = ASAuthorizationAppleIDProvider().createRequest()
        configure(request)

        return try await withCheckedThrowingContinuation { continuation in
            activeContinuation = continuation

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<Credential, Error>) {
        guard let continuation = activeContinuation else { return }
        activeContinuation = nil
        activeNonce = nil
        continuation.resume(with: result)
    }

    // MARK: - Nonce

    private static func randomNonceString(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // Never observed in practice; a UUID pair is still unguessable enough to bind one
            // request to one token, which is all the nonce does here.
            return UUID().uuidString + UUID().uuidString
        }
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    private static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension AppleSignInService: ASAuthorizationControllerDelegate {
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        finish(Result { try credential(from: authorization) })
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        finish(.failure(failure(from: error)))
    }
}

extension AppleSignInService: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // The key window, found the same way the Game Center presentation does it, so this works
        // from the sign-in screen and from Profile alike.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        return window ?? ASPresentationAnchor()
    }
}
