import AppKit
import DownloadSwitchCore

/// Starts and stops Transmission.app.
enum Transmission {
    static let bundleIdentifier = "org.m0k.transmission"

    static var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    static var isInstalled: Bool { appURL != nil }

    private static var instances: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated }
    }

    static var isRunning: Bool { !instances.isEmpty }

    /// Kills Transmission immediately. A polite quit can stall on its
    /// "quit with active transfers?" dialog, which would defeat a kill switch.
    static func stop() {
        for app in instances {
            if !app.forceTerminate() {
                kill(app.processIdentifier, SIGKILL)
            }
        }
    }

    static func launch() {
        guard let url = appURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}

/// Transmission's hidden bind-address preferences, read once at its launch.
enum TransmissionPreferences {
    private static let domain = Transmission.bundleIdentifier as CFString
    private static let ipv4Key = "BindAddressIPv4" as CFString
    private static let ipv6Key = "BindAddressIPv6" as CFString

    static func read() -> Binding {
        CFPreferencesAppSynchronize(domain)
        return Binding(
            ipv4: CFPreferencesCopyAppValue(ipv4Key, domain) as? String,
            ipv6: CFPreferencesCopyAppValue(ipv6Key, domain) as? String
        )
    }

    /// nil values delete the key, restoring Transmission's default.
    static func write(_ binding: Binding) {
        CFPreferencesSetAppValue(ipv4Key, binding.ipv4.map { $0 as CFString }, domain)
        CFPreferencesSetAppValue(ipv6Key, binding.ipv6.map { $0 as CFString }, domain)
        CFPreferencesAppSynchronize(domain)
    }
}
