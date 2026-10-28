import Foundation

/// The last things that happened, kept across launches, for the Recent Events
/// menu. Handy for spotting a VPN that keeps dropping.
final class EventLog {
    struct Entry {
        let date: Date
        let text: String
    }

    private static let key = "recentEvents"
    private static let limit = 50
    private let defaults = UserDefaults.standard

    private(set) var entries: [Entry]

    init() {
        let stored = defaults.array(forKey: Self.key) as? [[String: Any]] ?? []
        entries = stored.compactMap { entry in
            guard let date = entry["date"] as? Date, let text = entry["text"] as? String else { return nil }
            return Entry(date: date, text: text)
        }
    }

    func add(_ text: String) {
        entries.append(Entry(date: Date(), text: text))
        entries = Array(entries.suffix(Self.limit))
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        defaults.set(entries.map { ["date": $0.date, "text": $0.text] }, forKey: Self.key)
    }
}
