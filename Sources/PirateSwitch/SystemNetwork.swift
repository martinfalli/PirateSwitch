import Darwin
import PirateSwitchCore

/// Reads the live network state from the kernel.
enum SystemNetwork {
    static func interfaces() -> [NetworkInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [NetworkInterface] = []
        var index: [String: Int] = [:]

        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: entry.pointee.ifa_name)
            let flags = Int32(bitPattern: entry.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0

            let i: Int
            if let existing = index[name] {
                i = existing
            } else {
                i = result.count
                index[name] = i
                result.append(NetworkInterface(name: name, isUp: isUp))
            }

            guard let addr = entry.pointee.ifa_addr, Int32(addr.pointee.sa_family) == AF_INET,
                  let host = numericHost(addr)
            else { continue }
            result[i].ipv4.append(host)
        }
        return result
    }

    /// The source address the kernel would use to reach the public internet,
    /// i.e. which interface the routing table sends traffic through. Connecting
    /// a UDP socket only does the route lookup; no packet is sent.
    static func routeSourceIPv4(probe: String = "1.1.1.1") -> String? {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }

        var dst = sockaddr_in()
        dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port = in_port_t(53).bigEndian
        guard inet_pton(AF_INET, probe, &dst.sin_addr) == 1 else { return nil }

        let connected = withUnsafePointer(to: &dst) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        var src = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &src) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard named == 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &src.sin_addr, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer)
    }

    /// The TCP and UDP sockets a process has open, like `lsof -i -p <pid>`.
    static func sockets(pid: pid_t) -> [SocketInfo] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
        guard filled > 0 else { return [] }

        var result: [SocketInfo] = []
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride)
        where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize else { continue }

            let kind: SocketInfo.Kind
            let inet: in_sockinfo
            switch Int(info.psi.soi_kind) {
            case Int(SOCKINFO_TCP):
                kind = .tcp
                inet = info.psi.soi_proto.pri_tcp.tcpsi_ini
            case Int(SOCKINFO_IN) where info.psi.soi_protocol == IPPROTO_UDP:
                kind = .udp
                inet = info.psi.soi_proto.pri_in
            default:
                continue
            }

            // A dual-stack IPv6 socket has both flags; one connected to an
            // IPv4 peer has only the IPv4 one, with the address stored as IPv4.
            let isIPv4 = inet.insi_vflag & UInt8(INI_IPV6) == 0
            let remotePort = port(inet.insi_fport)
            result.append(SocketInfo(
                kind: kind,
                localAddress: isIPv4 ? text(inet.insi_laddr.ina_46.i46a_addr4) : text(inet.insi_laddr.ina_6),
                localPort: port(inet.insi_lport),
                remoteAddress: remotePort == 0 ? nil
                    : isIPv4 ? text(inet.insi_faddr.ina_46.i46a_addr4) : text(inet.insi_faddr.ina_6),
                remotePort: remotePort
            ))
        }
        return result
    }

    /// The kernel keeps ports in network byte order in the low 16 bits.
    private static func port(_ raw: Int32) -> Int {
        Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: raw)))
    }

    private static func text(_ address: in_addr) -> String {
        withUnsafePointer(to: address) { ntop(AF_INET, $0) }
    }

    private static func text(_ address: in6_addr) -> String {
        withUnsafePointer(to: address) { ntop(AF_INET6, $0) }
    }

    private static func ntop(_ family: Int32, _ address: UnsafeRawPointer) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(family, address, &buffer, socklen_t(buffer.count)) != nil else { return "?" }
        return String(cString: buffer)
    }

    private static func numericHost(_ addr: UnsafePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                          nil, 0, NI_NUMERICHOST) == 0
        else { return nil }
        return String(cString: host)
    }
}
