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
    /// On a Personal Hotspot or Low Data Mode network, with freezing there
    /// turned on: Transmission is frozen so it doesn't use up mobile data.
    public var meteredNetwork: Bool
    /// The Mac is going to sleep. With `freezeWhileDown`, Transmission is
    /// frozen so that after waking it can't do anything until the VPN is
    /// confirmed to be back.
    public var sleeping: Bool

    public init(enabled: Bool, vpn: VPNStatus?, transmissionRunning: Bool, freezeWhileDown: Bool,
                meteredNetwork: Bool = false, sleeping: Bool = false) {
        self.enabled = enabled
        self.vpn = vpn
        self.transmissionRunning = transmissionRunning
        self.freezeWhileDown = freezeWhileDown
        self.meteredNetwork = meteredNetwork
        self.sleeping = sleeping
    }
}

public enum Event: Equatable {
    /// The VPN is down and Transmission was frozen.
    case frozen
    /// The Mac is on a hotspot or Low Data Mode network and Transmission was frozen.
    case frozenOnMeteredNetwork
    /// The VPN is back and Transmission was unfrozen.
    case resumed(ipv4: String)
    /// The Mac left the hotspot or Low Data Mode network and Transmission was unfrozen.
    case resumedOffMeteredNetwork
    /// Transmission isn't bound to the current VPN address; restarting it.
    case rebinding(ipv4: String)
    /// The kill switch was turned off; restarting Transmission without its binding.
    case unbinding
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

    private enum FreezeReason { case vpnDown, meteredNetwork }

    /// What the user was last told Transmission is frozen for; nil if nothing.
    private var notifiedFreeze: FreezeReason?
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
            notifiedFreeze = nil
            quitIssued = false
        }

        guard snapshot.enabled else {
            resume(&actions)
            if storedBinding != .unrestricted {
                storedBinding = .unrestricted
                actions.append(.writeBinding(.unrestricted))
            }
            if !snapshot.transmissionRunning {
                if relaunchPending {
                    relaunchPending = false
                    actions.append(.launchTransmission)
                }
            } else if runningBinding != .unrestricted && !quitIssued {
                // It keeps the binding it read at launch, so it would stay cut
                // off. Restart it so it picks up normal internet.
                actions.append(.notify(.unbinding))
                quit(force: false, &actions)
            }
            return actions
        }

        let desired = snapshot.vpn.map(Binding.vpn) ?? .blocked
        if storedBinding != desired {
            storedBinding = desired
            actions.append(.writeBinding(desired))
        }

        guard snapshot.transmissionRunning else {
            // Not while it would only be frozen right away.
            if relaunchPending && snapshot.vpn != nil && !snapshot.sleeping && !snapshot.meteredNetwork {
                relaunchPending = false
                actions.append(.launchTransmission)
            }
            return actions
        }

        if snapshot.sleeping && snapshot.freezeWhileDown {
            // Quietly: after waking it's resumed if the VPN is still there.
            freeze(nil, &actions)
            return actions
        }

        if snapshot.meteredNetwork {
            // Restarts wait too: it would only be frozen again.
            freeze(.meteredNetwork, &actions)
            return actions
        }

        guard let vpn = snapshot.vpn else {
            if snapshot.freezeWhileDown {
                freeze(.vpnDown, &actions)
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
                let notified = notifiedFreeze
                resume(&actions)
                switch notified {
                case .vpnDown: actions.append(.notify(.resumed(ipv4: vpn.ipv4)))
                case .meteredNetwork: actions.append(.notify(.resumedOffMeteredNetwork))
                case nil: break
                }
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

    /// This app is quitting, so nobody will be left to resume a frozen
    /// Transmission. `poweringOff`: logout or shutdown is under way.
    public func terminate(poweringOff: Bool) -> [Action] {
        guard frozen else { return [] }
        // Bound, it can still only use the VPN address. Not on logout/shutdown:
        // frozen it can't answer the quit request, and resumed it would look up
        // tracker names outside the VPN on its way out.
        if !poweringOff, runningBinding?.isRestricted ?? false {
            var actions: [Action] = []
            resume(&actions)
            return actions
        }
        // Unbound, nothing else would keep it off the internet. Not through
        // quit(), which would reopen it.
        return [.quitTransmission(force: true)]
    }

    /// `reason`: what to tell the user, once; nil to freeze quietly.
    private func freeze(_ reason: FreezeReason?, _ actions: inout [Action]) {
        // Re-sent every tick in case something else resumes it.
        frozen = true
        actions.append(.freezeTransmission)
        guard let reason, reason != notifiedFreeze else { return }
        notifiedFreeze = reason
        actions.append(.notify(reason == .vpnDown ? .frozen : .frozenOnMeteredNetwork))
    }

    private func resume(_ actions: inout [Action]) {
        guard frozen else { return }
        frozen = false
        notifiedFreeze = nil
        actions.append(.resumeTransmission)
    }

    private func quit(force: Bool, _ actions: inout [Action]) {
        guard !quitIssued else { return }
        quitIssued = true
        relaunchPending = true
        actions.append(.quitTransmission(force: force))
    }
}
