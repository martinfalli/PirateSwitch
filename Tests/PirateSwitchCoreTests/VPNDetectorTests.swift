import Testing
@testable import PirateSwitchCore

struct VPNDetectorTests {
    let wifi = NetworkInterface(name: "en0", isUp: true, ipv4: ["192.168.1.20"])
    let wireguard = NetworkInterface(name: "utun4", isUp: true, ipv4: ["10.64.0.2"])
    // macOS keeps several utun interfaces around with no IPv4 address.
    let systemTunnel = NetworkInterface(name: "utun0", isUp: true)

    @Test func automaticDetectsTunnelCarryingInternetTraffic() {
        let vpn = VPNDetector.detect(interfaces: [wifi, systemTunnel, wireguard], routeSourceIPv4: "10.64.0.2", selection: .automatic)
        #expect(vpn == VPNStatus(interface: "utun4", ipv4: "10.64.0.2"))
    }

    @Test func automaticIgnoresTunnelWhenTrafficGoesOverWiFi() {
        // e.g. Tailscale without an exit node: the tunnel exists but isn't the route.
        let vpn = VPNDetector.detect(interfaces: [wifi, wireguard], routeSourceIPv4: "192.168.1.20", selection: .automatic)
        #expect(vpn == nil)
    }

    @Test func automaticWithNoRoute() {
        #expect(VPNDetector.detect(interfaces: [wifi, wireguard], routeSourceIPv4: nil, selection: .automatic) == nil)
    }

    @Test func automaticIgnoresDownTunnel() {
        var down = wireguard
        down.isUp = false
        #expect(VPNDetector.detect(interfaces: [wifi, down], routeSourceIPv4: "10.64.0.2", selection: .automatic) == nil)
    }

    @Test func builtInIKEv2() {
        let ipsec = NetworkInterface(name: "ipsec0", isUp: true, ipv4: ["172.16.5.9"])
        let vpn = VPNDetector.detect(interfaces: [wifi, ipsec], routeSourceIPv4: "172.16.5.9", selection: .automatic)
        #expect(vpn == VPNStatus(interface: "ipsec0", ipv4: "172.16.5.9"))
    }

    @Test func pinnedInterface() {
        let vpn = VPNDetector.detect(interfaces: [wifi, wireguard], routeSourceIPv4: "192.168.1.20", selection: .interface("utun4"))
        #expect(vpn?.ipv4 == "10.64.0.2")
    }

    @Test func pinnedInterfaceMissing() {
        #expect(VPNDetector.detect(interfaces: [wifi], routeSourceIPv4: "192.168.1.20", selection: .interface("utun4")) == nil)
    }

    @Test func candidatesSkipSystemTunnels() {
        #expect(VPNDetector.candidates(in: [wifi, systemTunnel, wireguard]).map(\.name) == ["utun4"])
    }
}
