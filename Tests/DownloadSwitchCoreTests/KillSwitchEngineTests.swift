import XCTest
@testable import DownloadSwitchCore

final class KillSwitchEngineTests: XCTestCase {
    let vpn = VPNStatus(interface: "utun4", ipv4: "10.64.0.2")
    let vpnBinding = Binding(ipv4: "10.64.0.2", ipv6: Binding.blockedIPv6)

    private func snap(vpn: VPNStatus?, running: Bool, enabled: Bool = true, freeze: Bool = true) -> Snapshot {
        Snapshot(enabled: enabled, vpn: vpn, transmissionRunning: running, freezeWhileDown: freeze)
    }

    /// Engine with Transmission already running and bound to `vpn`.
    private func boundEngine() -> KillSwitchEngine {
        let engine = KillSwitchEngine(storedBinding: .unrestricted, transmissionRunning: false)
        _ = engine.update(snap(vpn: vpn, running: false))
        XCTAssertEqual(engine.update(snap(vpn: vpn, running: true)), [])
        XCTAssertTrue(engine.isBound(to: vpn))
        return engine
    }

    func testBindsToVPNWhenConnected() {
        let engine = KillSwitchEngine(storedBinding: .unrestricted, transmissionRunning: false)
        XCTAssertEqual(engine.update(snap(vpn: vpn, running: false)), [.writeBinding(vpnBinding)])
        XCTAssertEqual(engine.update(snap(vpn: vpn, running: false)), [])
    }

    func testVPNDropFreezesAndReconnectResumesWithoutRestart() {
        let engine = boundEngine()
        XCTAssertEqual(engine.update(snap(vpn: nil, running: true)),
                       [.writeBinding(.blocked), .freezeTransmission, .notify(.frozen)])
        // Keep it frozen, notify once.
        XCTAssertEqual(engine.update(snap(vpn: nil, running: true)), [.freezeTransmission])

        XCTAssertEqual(engine.update(snap(vpn: vpn, running: true)),
                       [.writeBinding(vpnBinding), .resumeTransmission, .notify(.resumed(ipv4: "10.64.0.2"))])
        XCTAssertEqual(engine.update(snap(vpn: vpn, running: true)), [])
    }

    func testReconnectWithNewAddressRestartsCleanly() {
        let engine = boundEngine()
        _ = engine.update(snap(vpn: nil, running: true))

        let newVPN = VPNStatus(interface: "utun5", ipv4: "10.64.0.9")
        XCTAssertEqual(engine.update(snap(vpn: newVPN, running: true)),
                       [.writeBinding(.vpn(newVPN)), .notify(.rebinding(ipv4: "10.64.0.9")),
                        .resumeTransmission, .quitTransmission(force: false)])
        XCTAssertEqual(engine.update(snap(vpn: newVPN, running: true)), [])
        XCTAssertEqual(engine.update(snap(vpn: newVPN, running: false)), [.launchTransmission])
        XCTAssertEqual(engine.update(snap(vpn: newVPN, running: true)), [])
        XCTAssertTrue(engine.isBound(to: newVPN))
    }

    func testOpenedWithoutVPNIsFrozenThenRestartedWhenVPNConnects() {
        let engine = KillSwitchEngine(storedBinding: .unrestricted, transmissionRunning: false)
        XCTAssertEqual(engine.update(snap(vpn: nil, running: false)), [.writeBinding(.blocked)])
        XCTAssertEqual(engine.update(snap(vpn: nil, running: true)), [.freezeTransmission, .notify(.frozen)])
        XCTAssertEqual(engine.update(snap(vpn: vpn, running: true)),
                       [.writeBinding(vpnBinding), .notify(.rebinding(ipv4: "10.64.0.2")), .quitTransmission(force: true)])
        XCTAssertEqual(engine.update(snap(vpn: vpn, running: false)), [.launchTransmission])
    }

    func testUnboundTransmissionIsKilledAndRestartedOnStartup() {
        let engine = KillSwitchEngine(storedBinding: .unrestricted, transmissionRunning: true)
        XCTAssertEqual(engine.update(snap(vpn: vpn, running: true)),
                       [.writeBinding(vpnBinding), .notify(.rebinding(ipv4: "10.64.0.2")), .quitTransmission(force: true)])
        XCTAssertEqual(engine.update(snap(vpn: vpn, running: false)), [.launchTransmission])
        XCTAssertEqual(engine.update(snap(vpn: vpn, running: true)), [])
        XCTAssertTrue(engine.isBound(to: vpn))
    }

    func testUnboundTransmissionWithoutVPNIsFrozenImmediately() {
        let engine = KillSwitchEngine(storedBinding: .unrestricted, transmissionRunning: true)
        XCTAssertEqual(engine.update(snap(vpn: nil, running: true)),
                       [.writeBinding(.blocked), .freezeTransmission, .notify(.frozen)])
    }

    func testStartupResumesTransmissionLeftFrozen() {
        let engine = KillSwitchEngine(storedBinding: vpnBinding, transmissionRunning: true)
        XCTAssertEqual(engine.update(snap(vpn: vpn, running: true)), [.resumeTransmission])
        XCTAssertEqual(engine.update(snap(vpn: vpn, running: true)), [])
    }

    func testWithoutFreezingBoundTransmissionKeepsRunning() {
        let engine = boundEngine()
        XCTAssertEqual(engine.update(snap(vpn: nil, running: true, freeze: false)), [.writeBinding(.blocked)])
        XCTAssertEqual(engine.update(snap(vpn: vpn, running: true, freeze: false)), [.writeBinding(vpnBinding)])
    }

    func testWithoutFreezingUnboundTransmissionIsKilled() {
        let engine = KillSwitchEngine(storedBinding: .unrestricted, transmissionRunning: true)
        XCTAssertEqual(engine.update(snap(vpn: nil, running: true, freeze: false)),
                       [.writeBinding(.blocked), .quitTransmission(force: true)])
    }

    func testDisablingResumesAndRestoresDefaults() {
        let engine = boundEngine()
        _ = engine.update(snap(vpn: nil, running: true))
        XCTAssertEqual(engine.update(snap(vpn: nil, running: true, enabled: false)),
                       [.resumeTransmission, .writeBinding(.unrestricted)])
        XCTAssertEqual(engine.update(snap(vpn: nil, running: true, enabled: false)), [])
    }

    func testDisablingCancelsPendingRelaunch() {
        let engine = KillSwitchEngine(storedBinding: .unrestricted, transmissionRunning: true)
        _ = engine.update(snap(vpn: vpn, running: true))
        XCTAssertEqual(engine.update(snap(vpn: vpn, running: false, enabled: false)), [.writeBinding(.unrestricted)])
        XCTAssertEqual(engine.update(snap(vpn: vpn, running: false)), [.writeBinding(vpnBinding)])
    }

    func testIPv6IsAlwaysBlocked() {
        XCTAssertEqual(Binding.vpn(vpn).ipv6, Binding.blockedIPv6)
        XCTAssertTrue(Binding.vpn(vpn).isRestricted)
        XCTAssertFalse(Binding.unrestricted.isRestricted)
    }
}
