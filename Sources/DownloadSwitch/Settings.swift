import Foundation
import DownloadSwitchCore

/// The app's own preferences.
struct Settings {
    private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [
            "enabled": true,
            "reopenOnReconnect": true,
        ])
    }

    var enabled: Bool {
        get { defaults.bool(forKey: "enabled") }
        nonmutating set { defaults.set(newValue, forKey: "enabled") }
    }

    var reopenOnReconnect: Bool {
        get { defaults.bool(forKey: "reopenOnReconnect") }
        nonmutating set { defaults.set(newValue, forKey: "reopenOnReconnect") }
    }

    var vpnSelection: VPNSelection {
        get { defaults.string(forKey: "vpnInterface").map(VPNSelection.interface) ?? .automatic }
        nonmutating set {
            switch newValue {
            case .automatic: defaults.removeObject(forKey: "vpnInterface")
            case .interface(let name): defaults.set(name, forKey: "vpnInterface")
            }
        }
    }
}
