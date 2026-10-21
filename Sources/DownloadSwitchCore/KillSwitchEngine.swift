import Foundation

/// Transmission's hidden `BindAddressIPv4` / `BindAddressIPv6` preferences.
/// nil means the key is absent, i.e. Transmission's default (any address).
public struct Binding: Equatable {
    public var ipv4: String?
    public var ipv6: String?

    public init(ipv4: String?, ipv6: String?) {
        self.ipv4 = ipv4
        self.ipv6 = ipv6
    }

    /// Transmission's own default: listen and connect on every interface.
    public static let unrestricted = Binding(ipv4: nil, ipv6: nil)

    /// Addresses that are never assigned to this Mac (TEST-NET-1 and the IPv6
    /// discard prefix). Binding to them fails, so Transmission has no network.
    public static let blockedIPv4 = "192.0.2.1"
    public static let blockedIPv6 = "100::1"
    public static let blocked = Binding(ipv4: blockedIPv4, ipv6: blockedIPv6)

    /// Bind to the VPN only. IPv6 is blocked unless the VPN itself has IPv6,
    /// so it can't leak over the physical interface.
    public static func vpn(_ status: VPNStatus) -> Binding {
        Binding(ipv4: status.ipv4, ipv6: status.ipv6 ?? blockedIPv6)
    }
}

/// What the app observed on one tick.
public struct Snapshot: Equatable {
    public var enabled: Bool
    public var vpn: VPNStatus?
    public var transmissionRunning: Bool
    public var reopenOnReconnect: Bool

    public init(enabled: Bool, vpn: VPNStatus?, transmissionRunning: Bool, reopenOnReconnect: Bool) {
        self.enabled = enabled
        self.vpn = vpn
        self.transmissionRunning = transmissionRunning
        self.reopenOnReconnect = reopenOnReconnect
    }
}

public enum Event: Equatable {
    /// The VPN dropped while Transmission was running; it was stopped.
    case vpnDropped
    /// Transmission was opened while the VPN was down; it was stopped.
    case launchBlocked
    /// Transmission was running without the current VPN binding; restarting it.
    case rebinding(ipv4: String)
    /// The VPN is back and Transmission was reopened.
    case reopened(ipv4: String)
}

public enum Action: Equatable {
    case writeBinding(Binding)
    case stopTransmission
    case launchTransmission
    case notify(Event)
}

/// Decides what to do with Transmission given the VPN state. Pure logic: the
/// app feeds it a `Snapshot` every tick and performs the returned actions.
public final class KillSwitchEngine {
    /// What is currently stored in Transmission's preferences.
    public private(set) var storedBinding: Binding
    /// What the running Transmission read at launch; nil when not running.
    public private(set) var runningBinding: Binding?
    /// Reopen Transmission once the VPN is up.
    public private(set) var reopenPending = false

    private var stopIssued = false
    private var vpnWasUp = false

    public init(storedBinding: Binding, transmissionRunning: Bool) {
        self.storedBinding = storedBinding
        // Best guess for an instance started before we were: it read what's stored now.
        self.runningBinding = transmissionRunning ? storedBinding : nil
    }

    /// True when the running Transmission can only use the VPN.
    public func isBound(to vpn: VPNStatus?) -> Bool {
        guard let vpn, let runningBinding else { return false }
        return runningBinding == .vpn(vpn)
    }

    public func update(_ snapshot: Snapshot) -> [Action] {
        defer { vpnWasUp = snapshot.vpn != nil }
        var actions: [Action] = []

        // Track Transmission's lifecycle. A fresh instance read whatever is stored
        // right now, before any write below.
        if snapshot.transmissionRunning {
            if runningBinding == nil { runningBinding = storedBinding }
        } else {
            runningBinding = nil
            stopIssued = false
        }

        guard snapshot.enabled else {
            reopenPending = false
            if storedBinding != .unrestricted {
                storedBinding = .unrestricted
                actions.append(.writeBinding(.unrestricted))
            }
            return actions
        }

        let desired = snapshot.vpn.map(Binding.vpn) ?? .blocked
        if storedBinding != desired {
            storedBinding = desired
            actions.append(.writeBinding(desired))
        }

        if snapshot.transmissionRunning {
            // Allowed only while the VPN is up and Transmission is bound to it.
            // Otherwise stop it, repeating every tick until it's gone.
            if snapshot.vpn != nil && runningBinding == desired { return actions }
            actions.append(.stopTransmission)
            if !stopIssued {
                stopIssued = true
                if let vpn = snapshot.vpn {
                    reopenPending = true
                    actions.append(.notify(.rebinding(ipv4: vpn.ipv4)))
                } else {
                    reopenPending = snapshot.reopenOnReconnect
                    actions.append(.notify(vpnWasUp ? .vpnDropped : .launchBlocked))
                }
            }
        } else if reopenPending, let vpn = snapshot.vpn {
            reopenPending = false
            actions.append(.launchTransmission)
            actions.append(.notify(.reopened(ipv4: vpn.ipv4)))
        }

        return actions
    }
}
