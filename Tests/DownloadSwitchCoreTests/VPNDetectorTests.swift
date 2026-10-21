import XCTest
@testable import DownloadSwitchCore

final class VPNDetectorTests: XCTestCase {
    let wifi = NetworkInterface(name: "en0", isUp: true, ipv4: ["192.168.1.20"], ipv6: ["fe80::1", "2001:db8::20"])
    let wireguard = NetworkInterface(name: "utun4", isUp: true, ipv4: ["10.64.0.2"], ipv6: ["fe80::abcd", "fc00:bbbb::2"])
    // macOS keeps several utun interfaces around with only link-local IPv6.
    let systemTunnel = NetworkInterface(name: "utun0", isUp: true, ipv6: ["fe80::1234"])

    func testAutomaticDetectsTunnelCarryingInternetTraffic() {
        let vpn = VPNDetector.detect(interfaces: [wifi, systemTunnel, wireguard], routeSourceIPv4: "10.64.0.2", selection: .automatic)
        XCTAssertEqual(vpn, VPNStatus(interface: "utun4", ipv4: "10.64.0.2", ipv6: "fc00:bbbb::2"))
    }

    func testAutomaticIgnoresTunnelWhenTrafficGoesOverWiFi() {
        // e.g. Tailscale without an exit node: the tunnel exists but isn't the route.
        let vpn = VPNDetector.detect(interfaces: [wifi, wireguard], routeSourceIPv4: "192.168.1.20", selection: .automatic)
        XCTAssertNil(vpn)
    }

    func testAutomaticWithNoRoute() {
        XCTAssertNil(VPNDetector.detect(interfaces: [wifi, wireguard], routeSourceIPv4: nil, selection: .automatic))
    }

    func testAutomaticIgnoresDownTunnel() {
        var down = wireguard
        down.isUp = false
        XCTAssertNil(VPNDetector.detect(interfaces: [wifi, down], routeSourceIPv4: "10.64.0.2", selection: .automatic))
    }

    func testIPv4OnlyVPNHasNoIPv6() {
        let ipsec = NetworkInterface(name: "ipsec0", isUp: true, ipv4: ["172.16.5.9"], ipv6: ["fe80::9"])
        let vpn = VPNDetector.detect(interfaces: [wifi, ipsec], routeSourceIPv4: "172.16.5.9", selection: .automatic)
        XCTAssertEqual(vpn, VPNStatus(interface: "ipsec0", ipv4: "172.16.5.9", ipv6: nil))
    }

    func testPinnedInterface() {
        let vpn = VPNDetector.detect(interfaces: [wifi, wireguard], routeSourceIPv4: "192.168.1.20", selection: .interface("utun4"))
        XCTAssertEqual(vpn?.ipv4, "10.64.0.2")
    }

    func testPinnedInterfaceMissing() {
        XCTAssertNil(VPNDetector.detect(interfaces: [wifi], routeSourceIPv4: "192.168.1.20", selection: .interface("utun4")))
    }

    func testCandidatesSkipSystemTunnels() {
        XCTAssertEqual(VPNDetector.candidates(in: [wifi, systemTunnel, wireguard]).map(\.name), ["utun4"])
    }
}
