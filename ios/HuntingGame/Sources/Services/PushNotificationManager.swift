import Foundation
import UserNotifications
import UIKit

/// Owns the whole push-notification lifecycle: requesting permission, registering with
/// APNs, and uploading whatever device token comes back to the backend (see PushService.ts
/// server-side). Kept separate from AppDelegate — none of this actually needs AppDelegate's
/// lifecycle, just the didRegister... callback surface SwiftUI can't receive directly.
final class PushNotificationManager: NSObject, ObservableObject {
    static let shared = PushNotificationManager()

    /// The `type` from the payload of a notification the user actually tapped. Published so
    /// the UI can take them where the notification was about — a tap that just opens the app
    /// on whatever screen it was last on is barely better than no notification at all.
    @Published var tappedType: String?

    /// Set when a device token arrives before sign-in has finished (e.g. a very fast first
    /// launch) — flushed once there's a session to attach it to.
    private var pendingToken: String?
    /// Remembered purely so sign-out can unregister the exact token this device last
    /// reported, rather than needing the OS to hand it back again.
    private var lastRegisteredToken: String?

    static let catchCategory = "CATCH_REQUEST"
    static let catchYes = "CATCH_YES"
    static let catchNo = "CATCH_NO"

    private override init() {
        super.init()
        // A catch request arrives with Yes / No buttons, answerable from the lock screen
        // without opening the app: silence counts as caught, and a runner mid-sprint with the
        // phone in a pocket otherwise can't answer in time.
        let yes = UNNotificationAction(identifier: Self.catchYes, title: "Yes, I was caught", options: [.destructive])
        let no = UNNotificationAction(identifier: Self.catchNo, title: "No, not caught", options: [])
        let category = UNNotificationCategory(identifier: Self.catchCategory, actions: [yes, no], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Clears a catch request's notification once it's been answered in the app.
    func clearCatchNotification(requestId: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [requestId])
    }

    /// Call once signed in — registering before that would have nowhere to attach the
    /// token server-side. Safe to call repeatedly: re-requesting an already-decided
    /// permission is a no-op, and a granted permission re-registers for remote
    /// notifications (and re-delivers the same token to didRegister) harmlessly.
    func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            Task {
                await APIClient.shared.pushDiagnostic(
                    stage: granted ? "authorization-granted" : "authorization-denied",
                    detail: error?.localizedDescription
                )
            }
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
                Task { await APIClient.shared.pushDiagnostic(stage: "apns-register-called", detail: nil) }
            }
        }
    }

    func didRegister(token: String) {
        lastRegisteredToken = token
        Task { await APIClient.shared.pushDiagnostic(stage: "apns-token-received", detail: "\(token.count) chars") }
        guard AuthSession.shared.token != nil else {
            pendingToken = token
            return
        }
        Task { try? await APIClient.shared.registerDeviceToken(token) }
    }

    func didFailToRegister(error: Error) {
        // Not surfaced to the player — it's a best-effort feature and there's nothing they
        // could do about it. Reported to the server instead, because swallowing this
        // entirely is what made a broken push setup impossible to diagnose from either end:
        // the app looked like it simply never tried.
        Task {
            await APIClient.shared.pushDiagnostic(
                stage: "apns-register-failed",
                detail: (error as NSError).localizedDescription + " [\((error as NSError).domain) \((error as NSError).code)]"
            )
        }
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
        // A catch request while the app is open is already on screen as the in-app popup.
        if notification.request.content.userInfo["type"] as? String == "catch_request" {
            completionHandler([])
            return
        }
        // .list as well as .banner so it's still in Notification Centre afterwards — a
        // banner that vanishes unread is the same as never having sent it.
        completionHandler([.banner, .sound, .list])
    }

    /// Handles the user tapping a notification, foreground or cold start. The payload's
    /// `type` is set by PushService on the server (friend_request, game_invite,
    /// report_response, announcement…), and the UI routes on it from here.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if response.actionIdentifier == Self.catchYes || response.actionIdentifier == Self.catchNo,
           let code = info["roomCode"] as? String, let requestId = info["requestId"] as? String {
            // Answered from the lock screen: straight to the server, the app may not even be
            // running. The system gives a short window to finish; hold it open until it does.
            let accept = response.actionIdentifier == Self.catchYes
            let task = UIApplication.shared.beginBackgroundTask(withName: "catch-response")
            Task {
                try? await APIClient.shared.respondToCatchFromNotification(code: code, requestId: requestId, accept: accept)
                await MainActor.run {
                    UIApplication.shared.endBackgroundTask(task)
                    completionHandler()
                }
            }
            return
        }
        if let type = info["type"] as? String {
            DispatchQueue.main.async { self.tappedType = type }
        }
        completionHandler()
    }
}
