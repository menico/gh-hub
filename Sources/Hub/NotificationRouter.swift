import AppKit
import UserNotifications

/// Takes a click on one of Hub's notifications and hands its target to the
/// window, which opens the pull request, issue or run it was about.
@MainActor
final class NotificationRouter: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()
    static let targetKey = "target"

    /// Set once the window is up. A click that arrives earlier (one that
    /// launched Hub) waits in `pending` until then.
    var action: ((String) -> Void)? {
        didSet { if let action, let target = pending { pending = nil; action(target) } }
    }
    private var pending: String?

    func install() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let target = response.notification.request.content.userInfo[Self.targetKey] as? String {
            if let action { action(target) } else { pending = target }
        }
        completionHandler()
    }

    /// Still show the banner when Hub is the app in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
