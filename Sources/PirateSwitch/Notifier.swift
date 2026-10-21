import Foundation
import UserNotifications
import PirateSwitchCore

enum Notifier {
    /// UNUserNotificationCenter crashes outside an app bundle (e.g. `swift run`).
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ event: Event) {
        let (title, body) = text(for: event)
        guard available else {
            print("\(title): \(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static func text(for event: Event) -> (String, String) {
        switch event {
        case .frozen:
            return ("VPN down: Transmission frozen", "It can't send or receive anything until the VPN is back.")
        case .resumed(let ip):
            return ("VPN back: Transmission resumed", "Bound to \(ip).")
        case .rebinding(let ip):
            return ("Restarting Transmission", "Binding it to the VPN address \(ip).")
        }
    }
}
