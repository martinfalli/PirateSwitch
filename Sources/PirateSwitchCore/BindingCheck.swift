import Foundation

/// One of Transmission's open TCP or UDP sockets, as read from the kernel.
public struct SocketInfo: Equatable {
    public enum Kind: String { case tcp = "TCP", udp = "UDP" }

    public var kind: Kind
    public var localAddress: String
    public var localPort: Int
    /// nil when not connected to anything (listening, or UDP sending anywhere).
    public var remoteAddress: String?
    public var remotePort: Int

    public init(kind: Kind, localAddress: String, localPort: Int, remoteAddress: String? = nil, remotePort: Int = 0) {
        self.kind = kind
        self.localAddress = localAddress
        self.localPort = localPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
    }

    /// e.g. "UDP 192.168.1.20 → 192.168.1.1:5351", or "UDP 0.0.0.0:6771".
    public var description: String {
        guard let remoteAddress else { return "\(kind.rawValue) \(Self.endpoint(localAddress, localPort))" }
        return "\(kind.rawValue) \(localAddress) → \(Self.endpoint(remoteAddress, remotePort))"
    }

    /// What it probably is, for the connections Transmission makes on its own.
    public var hint: String? {
        let ports = [localPort, remotePort]
        if ports.contains(5351) || ports.contains(1900) { return "port mapping (NAT-PMP or UPnP) with your router" }
        if ports.contains(6771) { return "local peer discovery" }
        return nil
    }

    private static func endpoint(_ address: String, _ port: Int) -> String {
        address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }
}

/// Confirms from Transmission's open sockets that it only uses the VPN, rather
/// than trusting that it honored its bind-address preferences.
public struct BindingCheck: Equatable {
    /// How many sockets could send anything: connected TCP and all UDP,
    /// leaving out loopback. Listening sockets are skipped, since whatever
    /// they accept shows up as a connected socket.
    public var checked: Int
    /// Those not bound to the VPN address.
    public var outsideVPN: [SocketInfo]

    public init(sockets: [SocketInfo], vpnIPv4: String) {
        let relevant = sockets.filter { socket in
            if socket.kind == .tcp && socket.remoteAddress == nil { return false }
            if Self.isLoopback(socket.localAddress) { return false }
            if let remote = socket.remoteAddress, Self.isLoopback(remote) { return false }
            return true
        }
        checked = relevant.count
        outsideVPN = relevant.filter { Self.ipv4(of: $0.localAddress) != vpnIPv4 }
    }

    /// Unwraps IPv4-mapped IPv6 addresses: "::ffff:10.64.0.2" → "10.64.0.2".
    private static func ipv4(of address: String) -> String {
        address.hasPrefix("::ffff:") ? String(address.dropFirst(7)) : address
    }

    private static func isLoopback(_ address: String) -> Bool {
        ipv4(of: address).hasPrefix("127.") || address == "::1"
    }
}
