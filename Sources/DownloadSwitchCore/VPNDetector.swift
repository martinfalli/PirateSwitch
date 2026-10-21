import Foundation

/// A snapshot of one network interface, as read from `getifaddrs`.
public struct NetworkInterface: Equatable {
    public var name: String
    /// IFF_UP and IFF_RUNNING are both set.
    public var isUp: Bool
    public var ipv4: [String]
    public var ipv6: [String]

    public init(name: String, isUp: Bool, ipv4: [String] = [], ipv6: [String] = []) {
        self.name = name
        self.isUp = isUp
        self.ipv4 = ipv4
        self.ipv6 = ipv6
    }

    /// Interfaces VPN clients create: utun (WireGuard, OpenVPN, most VPN apps),
    /// ipsec (built-in IKEv2), ppp (L2TP/PPTP), tun/tap (tuntaposx), wg.
    public static let tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "wg"]

    public var isTunnel: Bool {
        Self.tunnelPrefixes.contains { name.hasPrefix($0) }
    }

    /// IPv6 addresses that can reach beyond the link (no link-local, no loopback).
    public var routableIPv6: [String] {
        ipv6.filter { addr in
            let lower = addr.lowercased()
            return !lower.hasPrefix("fe8") && !lower.hasPrefix("fe9")
                && !lower.hasPrefix("fea") && !lower.hasPrefix("feb")
                && lower != "::1"
        }.sorted()
    }
}

/// Which interface counts as "the VPN".
public enum VPNSelection: Equatable {
    /// The tunnel interface that currently carries internet traffic.
    case automatic
    /// A specific interface chosen by the user, e.g. "utun4".
    case interface(String)
}

/// The VPN connection Transmission should be bound to.
public struct VPNStatus: Equatable {
    public var interface: String
    public var ipv4: String
    public var ipv6: String?

    public init(interface: String, ipv4: String, ipv6: String? = nil) {
        self.interface = interface
        self.ipv4 = ipv4
        self.ipv6 = ipv6
    }
}

public enum VPNDetector {
    /// - Parameters:
    ///   - interfaces: current interfaces.
    ///   - routeSourceIPv4: the source address the kernel picks for traffic to
    ///     the public internet, or nil if there is no route at all.
    /// - Returns: the active VPN, or nil if traffic would not go through one.
    public static func detect(
        interfaces: [NetworkInterface],
        routeSourceIPv4: String?,
        selection: VPNSelection
    ) -> VPNStatus? {
        switch selection {
        case .automatic:
            guard let source = routeSourceIPv4,
                  let iface = interfaces.first(where: { $0.ipv4.contains(source) }),
                  iface.isUp, iface.isTunnel
            else { return nil }
            return VPNStatus(interface: iface.name, ipv4: source, ipv6: iface.routableIPv6.first)

        case .interface(let name):
            guard let iface = interfaces.first(where: { $0.name == name }),
                  iface.isUp,
                  let ipv4 = iface.ipv4.first
            else { return nil }
            return VPNStatus(interface: iface.name, ipv4: ipv4, ipv6: iface.routableIPv6.first)
        }
    }

    /// Tunnel interfaces that look like a live VPN, for the interface picker.
    public static func candidates(in interfaces: [NetworkInterface]) -> [NetworkInterface] {
        interfaces.filter { $0.isTunnel && $0.isUp && !$0.ipv4.isEmpty }
    }
}
