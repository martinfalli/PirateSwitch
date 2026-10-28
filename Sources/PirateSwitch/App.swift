import AppKit
import Network
import ServiceManagement
import PirateSwitchCore

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
    private let keepAwake = KeepAwake()
    private let eventLog = EventLog()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let pathMonitor = NWPathMonitor()
    private var physicalPathMonitor: NWPathMonitor?
    private var engine: KillSwitchEngine!
    private var timer: Timer?
    private var appsObservation: NSKeyValueObservation?

    private var interfaces: [NetworkInterface] = []
    private var vpn: VPNStatus?
    private var poweringOff = false
    /// When the Mac said it's going to sleep, on a clock that stops while it sleeps.
    private var sleptAt: UInt64?
    private var pathIsMetered = false
    private var physicalPathIsMetered = false
    private var bindingCheck: BindingCheck?
    /// Connections outside the VPN already notified about, while Transmission runs.
    private var reportedOutsideVPN: Set<String> = []

    private var iconCache: [String: NSImage] = [:]

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine = KillSwitchEngine(storedBinding: TransmissionPreferences.read(),
                                  transmissionRunning: Transmission.isRunning)
        Notifier.requestAuthorization()
        enableLaunchAtLoginOnFirstRun()
        eventLog.add("PirateSwitch started")

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        // React instantly to network changes and to apps starting. The running
        // apps list changes as soon as a process registers, before it has
        // finished launching, so Transmission is caught early.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let metered = path.isExpensive || path.isConstrained
            DispatchQueue.main.async {
                self?.pathIsMetered = metered
                self?.refresh()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "PirateSwitch.path"))
        // Some VPNs hide that the network underneath is a hotspot, so also
        // watch the path that leaves out tunnels.
        if #available(macOS 14, *) {
            let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.other])
            monitor.pathUpdateHandler = { [weak self] path in
                let metered = path.isExpensive || path.isConstrained
                DispatchQueue.main.async {
                    self?.physicalPathIsMetered = metered
                    self?.refresh()
                }
            }
            monitor.start(queue: DispatchQueue(label: "PirateSwitch.physicalPath"))
            physicalPathMonitor = monitor
        }
        appsObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(willPowerOff(_:)),
                              name: NSWorkspace.willPowerOffNotification, object: nil)

        // ...and poll every second as a safety net.
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(tick(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        eventLog.add("PirateSwitch quit")
        // Don't leave Transmission frozen with nobody to resume it.
        if !poweringOff { perform(engine.terminate(poweringOff: false)) }
    }

    @objc private func willPowerOff(_ notification: Notification) {
        poweringOff = true
        perform(engine.terminate(poweringOff: true))
    }

    @objc private func willSleep(_ notification: Notification) {
        sleptAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        eventLog.add("Mac went to sleep")
        refresh()
    }

    @objc private func didWake(_ notification: Notification) {
        sleptAt = nil
        eventLog.add("Mac woke up")
        refresh()
    }

    @objc private func tick(_ sender: Any?) {
        refresh()
    }

    private var onMeteredNetwork: Bool { pathIsMetered || physicalPathIsMetered }

    private func refresh() {
        // That clock stops during sleep. If it ran on for a minute, the sleep
        // never happened, so don't wait for a wake that won't come.
        if let sleptAt, clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - sleptAt > 60_000_000_000 {
            self.sleptAt = nil
        }

        interfaces = SystemNetwork.interfaces()
        let previousVPN = vpn
        vpn = VPNDetector.detect(interfaces: interfaces,
                                 routeSourceIPv4: SystemNetwork.routeSourceIPv4(),
                                 selection: settings.vpnSelection)
        if vpn != previousVPN {
            eventLog.add(vpn.map { "VPN connected (\($0.interface), \($0.ipv4))" } ?? "VPN disconnected")
        }

        let transmissionRunning = Transmission.isRunning
        let snapshot = Snapshot(enabled: settings.enabled,
                                vpn: vpn,
                                transmissionRunning: transmissionRunning,
                                freezeWhileDown: settings.freezeWhileDown,
                                meteredNetwork: settings.freezeOnMeteredNetwork && onMeteredNetwork,
                                sleeping: sleptAt != nil)
        perform(engine.update(snapshot))
        checkBinding(transmissionRunning: transmissionRunning)
        // So downloads keep going while you're away from the Mac.
        keepAwake.isOn = settings.enabled && settings.keepAwake && vpn != nil
            && transmissionRunning && !engine.frozen
        updateIcon()
    }

    private func perform(_ actions: [Action]) {
        for action in actions {
            switch action {
            case .writeBinding(let binding): TransmissionPreferences.write(binding)
            case .freezeTransmission: Transmission.freeze()
            case .resumeTransmission: Transmission.resume()
            case .quitTransmission(let force): Transmission.quit(force: force)
            case .launchTransmission: Transmission.launch()
            case .notify(let event):
                Notifier.post(event)
                eventLog.add(Notifier.text(for: event).title)
            }
        }
    }

    /// Confirms from Transmission's open sockets that it really only uses the
    /// VPN, and warns about any connection that doesn't.
    private func checkBinding(transmissionRunning: Bool) {
        if !transmissionRunning { reportedOutsideVPN = [] }
        guard settings.enabled, let vpn, engine.isBound(to: vpn) else {
            bindingCheck = nil
            return
        }
        let sockets = Transmission.processIdentifiers.flatMap(SystemNetwork.sockets(pid:))
        let check = BindingCheck(sockets: sockets, vpnIPv4: vpn.ipv4)
        bindingCheck = check

        // Once per destination, not for every new local port.
        let new = check.outsideVPN.filter { socket in
            let key = "\(socket.kind) \(socket.remoteAddress ?? socket.localAddress):\(socket.remoteAddress == nil ? socket.localPort : socket.remotePort)"
            return reportedOutsideVPN.insert(key).inserted
        }
        guard let first = new.first else { return }
        for socket in new { eventLog.add("Connection outside the VPN: \(socket.description)") }
        Notifier.postOutsideVPN(first, count: new.count)
    }

    // MARK: - Status item

    /// Pirate flag artwork bundled as PDFs; SF Symbols when run unbundled (`swift run`).
    private func menuBarIcon(_ style: MenuBarIconStyle, slashed: Bool) -> NSImage? {
        let name = (style == .flagOnly ? "MenuBarFlagOnly" : "MenuBarFlag") + (slashed ? "Slash" : "")
        if let icon = iconCache[name] { return icon }
        let image = Bundle.main.image(forResource: name)
        image?.size = NSSize(width: 18, height: 18)
        let icon = image ?? NSImage(systemSymbolName: slashed ? "flag.slash.fill" : "flag.fill",
                                    accessibilityDescription: nil)
        icon?.isTemplate = true
        iconCache[name] = icon
        return icon
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let description: String
        if !settings.enabled {
            description = "Kill switch off"
        } else if vpn != nil {
            description = bindingCheck?.outsideVPN.isEmpty == false
                ? "VPN connected, but Transmission has connections outside it" : "VPN connected"
        } else {
            description = "VPN down, Transmission cut off"
        }
        button.toolTip = "PirateSwitch: \(description)"
        button.setAccessibilityLabel(description)

        // Flag while protected, struck through while the VPN is down, greyed out when off.
        let image = menuBarIcon(settings.menuBarIcon, slashed: settings.enabled && vpn == nil)
        if button.image !== image { button.image = image }
        if image == nil { button.title = "☠︎" }
        if button.appearsDisabled == settings.enabled {
            button.appearsDisabled = !settings.enabled
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()

        menu.addItem(label(vpnStatusText))
        menu.addItem(label(transmissionStatusText))
        for socket in bindingCheck?.outsideVPN.prefix(5) ?? [] {
            let row = label(socket.description)
            row.indentationLevel = 1
            menu.addItem(row)
        }
        menu.addItem(.separator())

        menu.addItem(item("Kill Switch", #selector(toggleEnabled), checked: settings.enabled))
        menu.addItem(item("Freeze Transmission While VPN Is Down", #selector(toggleFreeze),
                          checked: settings.freezeWhileDown))
        menu.addItem(item("Freeze Transmission on Hotspot or Low Data Mode", #selector(toggleFreezeOnMeteredNetwork),
                          checked: settings.freezeOnMeteredNetwork))
        menu.addItem(item("Keep Mac Awake While Downloading", #selector(toggleKeepAwake),
                          checked: settings.keepAwake))
        menu.addItem(interfaceMenu())
        menu.addItem(iconStyleMenu())
        menu.addItem(.separator())

        menu.addItem(eventsMenu())
        let open = item("Open Transmission", #selector(openTransmission))
        open.isEnabled = Transmission.isInstalled
        menu.addItem(open)
        menu.addItem(item("Launch at Login", #selector(toggleLaunchAtLogin),
                          checked: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        menu.addItem(item("Quit PirateSwitch", #selector(quit), key: "q"))
    }

    private var vpnStatusText: String {
        guard let vpn else { return "VPN: not connected" }
        return "VPN: connected (\(vpn.interface), \(vpn.ipv4))"
    }

    private var transmissionStatusText: String {
        guard Transmission.isInstalled else { return "Transmission: not installed" }
        guard Transmission.isRunning else { return "Transmission: not running" }
        guard settings.enabled else {
            if engine.runningBinding == .unrestricted { return "Transmission: running, kill switch off" }
            return "Transmission: restarting without the VPN binding…"
        }
        if engine.frozen && settings.freezeOnMeteredNetwork && onMeteredNetwork {
            return "Transmission: frozen on a hotspot or Low Data Mode network"
        }
        if engine.isBound(to: vpn) {
            guard let bindingCheck, bindingCheck.checked > 0 else { return "Transmission: VPN only" }
            let outside = bindingCheck.outsideVPN.count
            if outside > 0 { return "Transmission: \(connections(outside)) outside the VPN" }
            return "Transmission: VPN only (\(connections(bindingCheck.checked)) checked)"
        }
        if vpn == nil { return engine.frozen ? "Transmission: frozen until VPN is back" : "Transmission: cut off until VPN is back" }
        return "Transmission: restarting to bind to VPN…"
    }

    private func connections(_ count: Int) -> String {
        count == 1 ? "1 connection" : "\(count) connections"
    }

    private func eventsMenu() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let entries = eventLog.entries.suffix(20).reversed()
        if entries.isEmpty {
            submenu.addItem(label("No events yet"))
        }
        for entry in entries {
            let time = Calendar.current.isDateInToday(entry.date)
                ? entry.date.formatted(date: .omitted, time: .shortened)
                : entry.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            submenu.addItem(label("\(time)   \(entry.text)"))
        }
        if !entries.isEmpty {
            submenu.addItem(.separator())
            submenu.addItem(item("Clear", #selector(clearEvents)))
        }

        let parent = NSMenuItem(title: "Recent Events", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    private func interfaceMenu() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let selection = settings.vpnSelection

        submenu.addItem(item("Automatic (whatever carries internet traffic)", #selector(selectInterface(_:)),
                             checked: selection == .automatic))
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

    private func iconStyleMenu() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (style, title) in [(MenuBarIconStyle.flagWithPole, "Flag with Pole"), (MenuBarIconStyle.flagOnly, "Flag Only")] {
            let row = item(title, #selector(selectIconStyle(_:)), checked: settings.menuBarIcon == style)
            row.representedObject = style.rawValue
            row.image = menuBarIcon(style, slashed: false)
            submenu.addItem(row)
        }

        let parent = NSMenuItem(title: "Menu Bar Icon", action: nil, keyEquivalent: "")
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

    @objc private func toggleFreeze() {
        settings.freezeWhileDown = !settings.freezeWhileDown
        refresh()
    }

    @objc private func toggleFreezeOnMeteredNetwork() {
        settings.freezeOnMeteredNetwork = !settings.freezeOnMeteredNetwork
        refresh()
    }

    @objc private func toggleKeepAwake() {
        settings.keepAwake = !settings.keepAwake
        refresh()
    }

    @objc private func clearEvents() {
        eventLog.clear()
    }

    @objc private func selectInterface(_ sender: NSMenuItem) {
        settings.vpnSelection = (sender.representedObject as? String).map(VPNSelection.interface) ?? .automatic
        refresh()
    }

    @objc private func selectIconStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = MenuBarIconStyle(rawValue: raw)
        else { return }
        settings.menuBarIcon = style
        updateIcon()
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
