import Testing
@testable import PirateSwitchCore

struct BindingCheckTests {
    let vpnIPv4 = "10.64.0.2"
    let peer = SocketInfo(kind: .tcp, localAddress: "10.64.0.2", localPort: 50100, remoteAddress: "203.0.113.7", remotePort: 51413)
    let dht = SocketInfo(kind: .udp, localAddress: "10.64.0.2", localPort: 51413)
    let natpmp = SocketInfo(kind: .udp, localAddress: "192.168.1.20", localPort: 60000, remoteAddress: "192.168.1.1", remotePort: 5351)
    let lpd = SocketInfo(kind: .udp, localAddress: "0.0.0.0", localPort: 6771)
    let ipv6 = SocketInfo(kind: .tcp, localAddress: "2001:db8::5", localPort: 50200, remoteAddress: "2001:db8::9", remotePort: 443)

    @Test func socketsBoundToTheVPNPass() {
        let check = BindingCheck(sockets: [peer, dht], vpnIPv4: vpnIPv4)
        #expect(check.checked == 2)
        #expect(check.outsideVPN.isEmpty)
    }

    @Test func listeningAndLoopbackSocketsAreSkipped() {
        let check = BindingCheck(sockets: [
            SocketInfo(kind: .tcp, localAddress: "0.0.0.0", localPort: 9091),
            SocketInfo(kind: .udp, localAddress: "127.0.0.1", localPort: 50300),
            SocketInfo(kind: .tcp, localAddress: "::1", localPort: 50301, remoteAddress: "::1", remotePort: 9091),
        ], vpnIPv4: vpnIPv4)
        #expect(check.checked == 0)
    }

    @Test func socketsOutsideTheVPNAreFound() {
        let check = BindingCheck(sockets: [peer, natpmp, dht, lpd, ipv6], vpnIPv4: vpnIPv4)
        #expect(check.checked == 5)
        #expect(check.outsideVPN == [natpmp, lpd, ipv6])
    }

    @Test func ipv4MappedAddressesAreUnwrapped() {
        let mapped = SocketInfo(kind: .udp, localAddress: "::ffff:10.64.0.2", localPort: 51413)
        #expect(BindingCheck(sockets: [mapped], vpnIPv4: vpnIPv4).outsideVPN.isEmpty)
    }

    @Test func descriptionsAndHints() {
        #expect(natpmp.description == "UDP 192.168.1.20 → 192.168.1.1:5351")
        #expect(natpmp.hint == "port mapping (NAT-PMP or UPnP) with your router")
        #expect(lpd.description == "UDP 0.0.0.0:6771")
        #expect(lpd.hint == "local peer discovery")
        #expect(ipv6.description == "TCP 2001:db8::5 → [2001:db8::9]:443")
        #expect(ipv6.hint == nil)
    }
}
