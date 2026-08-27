import Foundation
import UserNotifications

// MARK: - Notifications

/// Posts notifications as the app itself, so they carry its name and icon.
/// macOS asks for notification permission the first time; if it is denied
/// the AppleScript route is used instead (attributed to Script Editor).
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    static func post(_ body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { fallback(body); return }
            let content = UNMutableNotificationContent()
            content.title = "Claude Agent HUD"
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request) { error in
                if error != nil { fallback(body) }
            }
        }
    }

    /// Show banners even while the HUD is the active app (e.g. Settings open).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    private static func fallback(_ body: String) {
        let cleaned = body.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\\", with: "")
        let script = "display notification \"\(cleaned)\" with title \"Claude Agent HUD\""
        DispatchQueue.global(qos: .utility).async {
            Shell.run("/usr/bin/osascript", ["-e", script])
        }
    }
}
