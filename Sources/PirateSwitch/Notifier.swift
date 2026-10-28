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
        post(title: title, body: body)
    }

    /// `count`: how many new ones were found; `socket` is the first.
    static func postOutsideVPN(_ socket: SocketInfo, count: Int) {
        let title = count == 1 ? "Transmission connection outside the VPN"
                               : "\(count) Transmission connections outside the VPN"
        var body = socket.description
        if let hint = socket.hint {
            body += ", probably its \(hint). You can turn that off in Transmission's settings."
        }
        post(title: title, body: body)
    }

    /// The titles say what happened on their own, so they double as the Recent Events text.
    static func text(for event: Event) -> (title: String, body: String) {
        switch event {
        case .frozen:
            return ("VPN down: Transmission frozen", "It can't send or receive anything until the VPN is back.")
        case .frozenOnMeteredNetwork:
            return ("Hotspot or Low Data Mode: Transmission frozen",
                    "So it doesn't use up mobile data. It resumes on another network.")
        case .resumed(let ip):
            return ("VPN back: Transmission resumed", "Bound to \(ip).")
        case .resumedOffMeteredNetwork:
            return ("Off the hotspot: Transmission resumed", "You're no longer on a hotspot or Low Data Mode network.")
        case .rebinding(let ip):
            return ("Restarting Transmission to bind it to \(ip)", "It only reads its VPN binding when it starts.")
        case .unbinding:
            return ("Kill switch off: restarting Transmission", "So it can use the internet without the VPN.")
        }
    }

    private static func post(title: String, body: String) {
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
}
