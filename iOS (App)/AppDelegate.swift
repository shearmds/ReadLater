import UIKit
import UserNotifications

@main
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Notification permission is requested lazily, the first time there's
        // actually something to remind about — see ReadLaterStore.reconcileStaleReminders.
        UNUserNotificationCenter.current().delegate = self
        ReadLaterStore.shared.syncWithCloud()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    // Tapping a stale-item reminder opens the article and marks it read,
    // matching the widget's tap behavior.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let urlString = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: urlString) {
            ReadLaterStore.shared.markRead(url: urlString)
            ReadLaterStore.shared.syncWithCloud()
            UIApplication.shared.open(url)
        }
        completionHandler()
    }
}
