import Foundation
import UserNotifications
import UIKit

/// Owns the whole push-notification lifecycle: requesting permission, registering with
/// APNs, and uploading whatever device token comes back to the backend (see PushService.ts
/// server-side). Kept separate from AppDelegate — none of this actually needs AppDelegate's
/// lifecycle, just the didRegister... callback surface SwiftUI can't receive directly.
final class PushNotificationManager: NSObject, ObservableObject {
    static let shared = PushNotificationManager()

    /// Set when a device token arrives before sign-in has finished (e.g. a very fast first
    /// launch) — flushed once there's a session to attach it to.
    private var pendingToken: String?
    /// Remembered purely so sign-out can unregister the exact token this device last
    /// reported, rather than needing the OS to hand it back again.
    private var lastRegisteredToken: String?

    private override init() {
        super.init()
    }

    /// Call once signed in — registering before that would have nowhere to attach the
    /// token server-side. Safe to call repeatedly: re-requesting an already-decided
    /// permission is a no-op, and a granted permission re-registers for remote
    /// notifications (and re-delivers the same token to didRegister) harmlessly.
    func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func didRegister(token: String) {
        lastRegisteredToken = token
        guard AuthSession.shared.token != nil else {
            pendingToken = token
            return
        }
        Task { try? await APIClient.shared.registerDeviceToken(token) }
    }

    func didFailToRegister(error: Error) {
        // Expected on the simulator and in some build configurations without a live APNs
        // entitlement — this is a best-effort feature, not worth surfacing to the player.
    }

    /// Uploads a token that arrived before sign-in completed. Call right after AuthSession
    /// gains a token (see RootView).
    func flushPendingTokenIfNeeded() {
        guard let token = pendingToken else { return }
        pendingToken = nil
        Task { try? await APIClient.shared.registerDeviceToken(token) }
    }

    /// Call right before signing out, while the auth token is still valid to make the call
    /// with — a signed-out device shouldn't keep receiving this account's pushes.
    func unregisterCurrentToken() async {
        guard let token = lastRegisteredToken else { return }
        try? await APIClient.shared.unregisterDeviceToken(token)
    }
}

extension PushNotificationManager: UNUserNotificationCenterDelegate {
    /// Shows the banner/sound even while the app is in the foreground — the system default
    /// suppresses it, but a friend request or invite arriving while Mission Control is open
    /// shouldn't be invisible just because the app happens to already be frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
