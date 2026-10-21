import Foundation

/// Transmission's hidden `BindAddressIPv4` / `BindAddressIPv6` preferences.
/// nil means the key is absent, i.e. Transmission's default (any address).
///
/// This is the actual kill switch. Once Transmission's sockets are bound to the
/// VPN address, the macOS kernel only routes them through the VPN interface,
/// and when that address disappears it refuses to send anything from them
/// (TCP holds its data, UDP and new connections fail with EADDRNOTAVAIL).
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

    /// IPv4 through the VPN only; IPv6 always blocked so it can't bypass it.
    public static func vpn(_ status: VPNStatus) -> Binding {
        Binding(ipv4: status.ipv4, ipv6: blockedIPv6)
    }

    /// Both families are pinned to a specific address, so Transmission can't
    /// use the physical interfaces whatever the routing table says.
    public var isRestricted: Bool { ipv4 != nil && ipv6 != nil }
}

/// What the app observed on one tick.
public struct Snapshot: Equatable {
    public var enabled: Bool
    public var vpn: VPNStatus?
    public var transmissionRunning: Bool
    /// Freeze (SIGSTOP) Transmission while the VPN is down, so it can't even
    /// look up tracker names through the system resolver.
    public var freezeWhileDown: Bool

    public init(enabled: Bool, vpn: VPNStatus?, transmissionRunning: Bool, freezeWhileDown: Bool) {
        self.enabled = enabled
        self.vpn = vpn
        self.transmissionRunning = transmissionRunning
        self.freezeWhileDown = freezeWhileDown
    }
}

public enum Event: Equatable {
    /// The VPN is down and Transmission was frozen.
    case frozen
    /// The VPN is back and Transmission was unfrozen.
    case resumed(ipv4: String)
    /// Transmission isn't bound to the current VPN address; restarting it.
    case rebinding(ipv4: String)
}

public enum Action: Equatable {
    case writeBinding(Binding)
    case freezeTransmission
    case resumeTransmission
    /// `force`: kill now instead of a normal quit (which can take seconds).
    case quitTransmission(force: Bool)
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
    /// Transmission may be stopped. Assumed at startup, so an instance left
    /// frozen by an earlier run of this app gets resumed.
    public private(set) var frozen: Bool

    private var freezeNotified = false
    private var quitIssued = false
    private var relaunchPending = false

    public init(storedBinding: Binding, transmissionRunning: Bool) {
        self.storedBinding = storedBinding
        // Best guess for an instance started before we were: it read what's stored now.
        self.runningBinding = transmissionRunning ? storedBinding : nil
        self.frozen = transmissionRunning
    }

    /// True when the running Transmission can only use this VPN.
    public func isBound(to vpn: VPNStatus?) -> Bool {
        guard let vpn, let runningBinding else { return false }
        return runningBinding == .vpn(vpn)
    }

    public func update(_ snapshot: Snapshot) -> [Action] {
        var actions: [Action] = []

        // Track Transmission's lifecycle. A fresh instance read whatever is stored
        // right now, before any write below.
        if snapshot.transmissionRunning {
            if runningBinding == nil { runningBinding = storedBinding }
        } else {
            runningBinding = nil
            frozen = false
            freezeNotified = false
            quitIssued = false
        }

        guard snapshot.enabled else {
            relaunchPending = false
            resume(&actions)
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

        guard snapshot.transmissionRunning else {
            if relaunchPending && snapshot.vpn != nil {
                relaunchPending = false
                actions.append(.launchTransmission)
            }
            return actions
        }

        guard let vpn = snapshot.vpn else {
            if snapshot.freezeWhileDown {
                // Re-sent every tick in case something else resumes it.
                frozen = true
                actions.append(.freezeTransmission)
                if !freezeNotified {
                    freezeNotified = true
                    actions.append(.notify(.frozen))
                }
            } else if !(runningBinding?.isRestricted ?? false) {
                // Not frozen and not bound: nothing would stop it, so kill it.
                quit(force: true, &actions)
            } else {
                resume(&actions)
            }
            return actions
        }

        if runningBinding == desired {
            if frozen {
                let wasNotified = freezeNotified
                resume(&actions)
                if wasNotified { actions.append(.notify(.resumed(ipv4: vpn.ipv4))) }
            }
            return actions
        }

        // Bound to an address that's gone, or not bound at all. Transmission
        // only reads its binding at launch, so restart it.
        if !quitIssued {
            actions.append(.notify(.rebinding(ipv4: vpn.ipv4)))
            if let old = runningBinding, old.isRestricted, old != .blocked {
                // Bound to a previous VPN address: it can't reach anything
                // meanwhile, so let it quit cleanly and save its progress.
                resume(&actions)
                quit(force: false, &actions)
            } else {
                // Unbound (could leak), or opened without a VPN and has
                // nothing to save: kill it right away.
                quit(force: true, &actions)
            }
        }
        return actions
    }

    private func resume(_ actions: inout [Action]) {
        guard frozen else { return }
        frozen = false
        freezeNotified = false
        actions.append(.resumeTransmission)
    }

    private func quit(force: Bool, _ actions: inout [Action]) {
        guard !quitIssued else { return }
        quitIssued = true
        relaunchPending = true
        actions.append(.quitTransmission(force: force))
    }
}
