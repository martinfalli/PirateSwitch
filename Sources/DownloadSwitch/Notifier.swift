import Foundation
import UserNotifications
import DownloadSwitchCore

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
        case .vpnDropped:
            return ("VPN disconnected", "Transmission was stopped so nothing downloads outside the VPN.")
        case .launchBlocked:
            return ("Transmission blocked", "Connect to your VPN first. Transmission can't run without it.")
        case .rebinding(let ip):
            return ("Rebinding Transmission", "Restarting Transmission so it only uses the VPN (\(ip)).")
        case .reopened(let ip):
            return ("VPN connected", "Transmission was reopened, bound to \(ip).")
        }
    }
}
