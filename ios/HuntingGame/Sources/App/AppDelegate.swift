import UIKit
import UserNotifications

/// A thin UIKit shim SwiftUI still needs — `didRegisterForRemoteNotificationsWithDeviceToken`
/// and its failure counterpart have no SwiftUI equivalent. Everything past capturing that
/// callback lives in PushNotificationManager; this class owns no state of its own.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = PushNotificationManager.shared
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        PushNotificationManager.shared.didRegister(token: token)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushNotificationManager.shared.didFailToRegister(error: error)
    }
}
