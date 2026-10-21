import AppKit
import Network
import ServiceManagement
import DownloadSwitchCore

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    private let settings = Settings()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let pathMonitor = NWPathMonitor()
    private var engine: KillSwitchEngine!
    private var timer: Timer?

    private var interfaces: [NetworkInterface] = []
    private var vpn: VPNStatus?
    private var iconSymbol = ""

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine = KillSwitchEngine(storedBinding: TransmissionPreferences.read(),
                                  transmissionRunning: Transmission.isRunning)
        Notifier.requestAuthorization()
        enableLaunchAtLoginOnFirstRun()

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        // React instantly to Transmission starting and to network changes...
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didWakeNotification] {
            workspace.addObserver(self, selector: #selector(tick(_:)), name: name, object: nil)
        }
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "DownloadSwitch.path"))

        // ...and poll every second as a safety net.
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(tick(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        refresh()
    }

    @objc private func tick(_ sender: Any?) {
        refresh()
    }

    private func refresh() {
        interfaces = SystemNetwork.interfaces()
        vpn = VPNDetector.detect(interfaces: interfaces,
                                 routeSourceIPv4: SystemNetwork.routeSourceIPv4(),
                                 selection: settings.vpnSelection)

        let snapshot = Snapshot(enabled: settings.enabled,
                                vpn: vpn,
                                transmissionRunning: Transmission.isRunning,
                                reopenOnReconnect: settings.reopenOnReconnect)
        for action in engine.update(snapshot) {
            switch action {
            case .writeBinding(let binding): TransmissionPreferences.write(binding)
            case .stopTransmission: Transmission.stop()
            case .launchTransmission: Transmission.launch()
            case .notify(let event): Notifier.post(event)
            }
        }
        updateIcon()
    }

    // MARK: - Status item

    private var iconState: (symbol: String, description: String) {
        if !settings.enabled { return ("shield.slash", "Kill switch off") }
        if vpn != nil { return ("lock.shield", "VPN connected") }
        return ("xmark.shield", "VPN down, Transmission blocked")
    }

    private func updateIcon() {
        let (symbol, description) = iconState
        guard let button = statusItem.button else { return }
        button.toolTip = "Download Switch: \(description)"
        guard symbol != iconSymbol else { return }
        iconSymbol = symbol

        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description) {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = settings.enabled ? (vpn != nil ? "VPN" : "BLOCK") : "OFF"
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()

        menu.addItem(label(vpnStatusText))
        menu.addItem(label(transmissionStatusText))
        menu.addItem(.separator())

        menu.addItem(item("Kill Switch", #selector(toggleEnabled), checked: settings.enabled))
        menu.addItem(item("Reopen Transmission When VPN Reconnects", #selector(toggleReopen),
                          checked: settings.reopenOnReconnect))
        menu.addItem(interfaceMenu())
        menu.addItem(.separator())

        let open = item(vpn == nil && settings.enabled ? "Open Transmission (needs VPN)" : "Open Transmission",
                        #selector(openTransmission))
        open.isEnabled = Transmission.isInstalled && (vpn != nil || !settings.enabled)
        menu.addItem(open)
        menu.addItem(item("Launch at Login", #selector(toggleLaunchAtLogin),
                          checked: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        menu.addItem(item("Quit Download Switch", #selector(quit), key: "q"))
    }

    private var vpnStatusText: String {
        guard let vpn else { return "VPN: not connected" }
        return "VPN: connected (\(vpn.interface), \(vpn.ipv4))"
    }

    private var transmissionStatusText: String {
        guard Transmission.isInstalled else { return "Transmission: not installed" }
        if Transmission.isRunning {
            guard settings.enabled else { return "Transmission: running (unprotected)" }
            return engine.isBound(to: vpn) ? "Transmission: running, VPN only" : "Transmission: stopping…"
        }
        if settings.enabled && vpn == nil { return "Transmission: blocked until VPN connects" }
        return "Transmission: not running"
    }

    private func interfaceMenu() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let selection = settings.vpnSelection

        let automatic = item("Automatic (whatever carries internet traffic)", #selector(selectInterface(_:)),
                             checked: selection == .automatic)
        submenu.addItem(automatic)
        submenu.addItem(.separator())

        var rows = VPNDetector.candidates(in: interfaces).map { ($0.name, "\($0.name) (\($0.ipv4[0]))") }
        if case .interface(let pinned) = selection, !rows.contains(where: { $0.0 == pinned }) {
            rows.append((pinned, "\(pinned) (not connected)"))
        }
        if rows.isEmpty {
            submenu.addItem(label("No VPN interfaces found"))
        }
        for (name, title) in rows {
            let row = item(title, #selector(selectInterface(_:)), checked: selection == .interface(name))
            row.representedObject = name
            submenu.addItem(row)
        }

        let parent = NSMenuItem(title: "VPN Interface", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    private func label(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, _ action: Selector, checked: Bool = false, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.state = checked ? .on : .off
        return item
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        settings.enabled = !settings.enabled
        refresh()
    }

    @objc private func toggleReopen() {
        settings.reopenOnReconnect = !settings.reopenOnReconnect
    }

    @objc private func selectInterface(_ sender: NSMenuItem) {
        settings.vpnSelection = (sender.representedObject as? String).map(VPNSelection.interface) ?? .automatic
        refresh()
    }

    @objc private func openTransmission() {
        Transmission.launch()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't change the login item"
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// A kill switch only helps if it's running, so start at login by default.
    private func enableLaunchAtLoginOnFirstRun() {
        let key = "didSetUpLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key), Bundle.main.bundleIdentifier != nil else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }
}
