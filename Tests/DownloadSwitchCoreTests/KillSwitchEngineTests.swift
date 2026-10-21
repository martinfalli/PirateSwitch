import XCTest
@testable import DownloadSwitchCore

final class KillSwitchEngineTests: XCTestCase {
    let vpn = VPNStatus(interface: "utun4", ipv4: "10.64.0.2")
    let vpnBinding = Binding(ipv4: "10.64.0.2", ipv6: Binding.blockedIPv6)

    private func snap(vpn: VPNStatus?, running: Bool, enabled: Bool = true, reopen: Bool = true) -> Snapshot {
        Snapshot(enabled: enabled, vpn: vpn, transmissionRunning: running, reopenOnReconnect: reopen)
    }

    func testBindsToVPNWhenConnected() {
        let engine = KillSwitchEngine(storedBinding: .unrestricted, transmissionRunning: false)
        XCTAssertEqual(engine.update(snap(vpn: vpn, running: false)), [.writeBinding(vpnBinding)])
        // Nothing to do on the next tick.
        XCTAssertEqual(engine.update(snap(vpn: vpn, running: false)), [])
    }

    func testTransmissionLaunchedWhileVPNUpIsLeftAlone() {
        let engine = KillSwitchEngine(storedBinding: .unrestricted, transmissionRunning: false)
        _ = engine.update(snap(vpn: vpn, running: false))
        XCTAssertEqual(engine.update(snap(vpn: vpn, running: true)), [])
        XCTAssertTrue(engine.isBound(to: vpn))
    }

    func testVPNDropStopsTransmissionAndReopensOnReconnect() {
        let engine = KillSwitchEngine(storedBinding: vpnBinding, transmissionRunning: true)
        XCTAssertEqual(engine.update(snap(vpn: vpn, running: true)), [])

        XCTAssertEqual(engine.update(snap(vpn: nil, running: true)),
                       [.writeBinding(.blocked), .stopTransmission, .notify(.vpnDropped)])
        // Still shutting down: keep stopping, don't notify again.
        XCTAssertEqual(engine.update(snap(vpn: nil, running: true)), [.stopTransmission])
        XCTAssertEqual(engine.update(snap(vpn: nil, running: false)), [])

        XCTAssertEqual(engine.update(snap(vpn: vpn, running: false)),
                       [.writeBinding(vpnBinding), .launchTransmission, .notify(.reopened(ipv4: "10.64.0.2"))])
        XCTAssertEqual(engine.update(snap(vpn: vpn, running: true)), [])
    }

    func testNoReopenWhenDisabledInSettings() {
        let engine = KillSwitchEngine(storedBinding: vpnBinding, transmissionRunning: true)
        _ = engine.update(snap(vpn: vpn, running: true, reopen: false))
        _ = engine.update(snap(vpn: nil, running: true, reopen: false))
        _ = engine.update(snap(vpn: nil, running: false, reopen: false))
        XCTAssertEqual(engine.update(snap(vpn: vpn, running: false, reopen: false)), [.writeBinding(vpnBinding)])
    }

    func testLaunchWithoutVPNIsBlocked() {
        let engine = KillSwitchEngine(storedBinding: .unrestricted, transmissionRunning: false)
        XCTAssertEqual(engine.update(snap(vpn: nil, running: false)), [.writeBinding(.blocked)])
        XCTAssertEqual(engine.update(snap(vpn: nil, running: true)), [.stopTransmission, .notify(.launchBlocked)])
    }

    func testUnboundTransmissionIsRestartedOnStartup() {
        // Transmission was already running, bound to everything, when we started.
        let engine = KillSwitchEngine(storedBinding: .unrestricted, transmissionRunning: true)
        XCTAssertEqual(engine.update(snap(vpn: vpn, running: true)),
                       [.writeBinding(vpnBinding), .stopTransmission, .notify(.rebinding(ipv4: "10.64.0.2"))])
        XCTAssertEqual(engine.update(snap(vpn: vpn, running: false)),
                       [.launchTransmission, .notify(.reopened(ipv4: "10.64.0.2"))])
        XCTAssertEqual(engine.update(snap(vpn: vpn, running: true)), [])
        XCTAssertTrue(engine.isBound(to: vpn))
    }

    func testVPNAddressChangeRestartsTransmission() {
        let engine = KillSwitchEngine(storedBinding: vpnBinding, transmissionRunning: true)
        let newVPN = VPNStatus(interface: "utun5", ipv4: "10.64.0.9")
        XCTAssertEqual(engine.update(snap(vpn: newVPN, running: true)),
                       [.writeBinding(.vpn(newVPN)), .stopTransmission, .notify(.rebinding(ipv4: "10.64.0.9"))])
    }

    func testDisablingRestoresDefaultsAndNeverStops() {
        let engine = KillSwitchEngine(storedBinding: vpnBinding, transmissionRunning: true)
        XCTAssertEqual(engine.update(snap(vpn: nil, running: true, enabled: false)), [.writeBinding(.unrestricted)])
        XCTAssertEqual(engine.update(snap(vpn: nil, running: true, enabled: false)), [])
    }

    func testDisablingCancelsPendingReopen() {
        let engine = KillSwitchEngine(storedBinding: vpnBinding, transmissionRunning: true)
        _ = engine.update(snap(vpn: nil, running: true))
        _ = engine.update(snap(vpn: nil, running: false))
        _ = engine.update(snap(vpn: nil, running: false, enabled: false))
        XCTAssertEqual(engine.update(snap(vpn: vpn, running: false)), [.writeBinding(vpnBinding)])
    }

    func testVPNWithIPv6BindsBoth() {
        let dual = VPNStatus(interface: "utun4", ipv4: "10.64.0.2", ipv6: "fc00:bbbb::2")
        XCTAssertEqual(Binding.vpn(dual), Binding(ipv4: "10.64.0.2", ipv6: "fc00:bbbb::2"))
    }
}
