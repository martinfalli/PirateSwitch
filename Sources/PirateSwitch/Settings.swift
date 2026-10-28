import Foundation
import PirateSwitchCore

enum MenuBarIconStyle: String {
    case flagWithPole
    case flagOnly
}

/// The app's own preferences.
struct Settings {
    private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [
            "enabled": true,
            "freezeWhileDown": true,
            "freezeOnMeteredNetwork": true,
            "keepAwake": true,
        ])
    }

    var enabled: Bool {
        get { defaults.bool(forKey: "enabled") }
        nonmutating set { defaults.set(newValue, forKey: "enabled") }
    }

    var freezeWhileDown: Bool {
        get { defaults.bool(forKey: "freezeWhileDown") }
        nonmutating set { defaults.set(newValue, forKey: "freezeWhileDown") }
    }

    /// Freeze Transmission on a Personal Hotspot or Low Data Mode network.
    var freezeOnMeteredNetwork: Bool {
        get { defaults.bool(forKey: "freezeOnMeteredNetwork") }
        nonmutating set { defaults.set(newValue, forKey: "freezeOnMeteredNetwork") }
    }

    /// Stop the Mac from idle sleeping while Transmission can download.
    var keepAwake: Bool {
        get { defaults.bool(forKey: "keepAwake") }
        nonmutating set { defaults.set(newValue, forKey: "keepAwake") }
    }

    var menuBarIcon: MenuBarIconStyle {
        get { defaults.string(forKey: "menuBarIcon").flatMap(MenuBarIconStyle.init(rawValue:)) ?? .flagWithPole }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "menuBarIcon") }
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
