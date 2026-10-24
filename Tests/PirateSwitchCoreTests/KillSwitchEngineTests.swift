import Testing
@testable import PirateSwitchCore

struct KillSwitchEngineTests {
    let vpn = VPNStatus(interface: "utun4", ipv4: "10.64.0.2")
    let vpnBinding = Binding(ipv4: "10.64.0.2", ipv6: Binding.blockedIPv6)

    private func snap(vpn: VPNStatus?, running: Bool, enabled: Bool = true, freeze: Bool = true) -> Snapshot {
        Snapshot(enabled: enabled, vpn: vpn, transmissionRunning: running, freezeWhileDown: freeze)
    }

    /// Engine with Transmission already running and bound to `vpn`.
    private func boundEngine() -> KillSwitchEngine {
        let engine = KillSwitchEngine(storedBinding: .unrestricted, transmissionRunning: false)
        _ = engine.update(snap(vpn: vpn, running: false))
        #expect(engine.update(snap(vpn: vpn, running: true)) == [])
        #expect(engine.isBound(to: vpn))
        return engine
    }

    @Test func bindsToVPNWhenConnected() {
        let engine = KillSwitchEngine(storedBinding: .unrestricted, transmissionRunning: false)
        #expect(engine.update(snap(vpn: vpn, running: false)) == [.writeBinding(vpnBinding)])
        #expect(engine.update(snap(vpn: vpn, running: false)) == [])
    }

    @Test func vpnDropFreezesAndReconnectResumesWithoutRestart() {
        let engine = boundEngine()
        #expect(engine.update(snap(vpn: nil, running: true))
                == [.writeBinding(.blocked), .freezeTransmission, .notify(.frozen)])
        // Keep it frozen, notify once.
        #expect(engine.update(snap(vpn: nil, running: true)) == [.freezeTransmission])

        #expect(engine.update(snap(vpn: vpn, running: true))
                == [.writeBinding(vpnBinding), .resumeTransmission, .notify(.resumed(ipv4: "10.64.0.2"))])
        #expect(engine.update(snap(vpn: vpn, running: true)) == [])
    }

    @Test func reconnectWithNewAddressRestartsCleanly() {
        let engine = boundEngine()
        _ = engine.update(snap(vpn: nil, running: true))

        let newVPN = VPNStatus(interface: "utun5", ipv4: "10.64.0.9")
        #expect(engine.update(snap(vpn: newVPN, running: true))
                == [.writeBinding(.vpn(newVPN)), .notify(.rebinding(ipv4: "10.64.0.9")),
                    .resumeTransmission, .quitTransmission(force: false)])
        #expect(engine.update(snap(vpn: newVPN, running: true)) == [])
        #expect(engine.update(snap(vpn: newVPN, running: false)) == [.launchTransmission])
        #expect(engine.update(snap(vpn: newVPN, running: true)) == [])
        #expect(engine.isBound(to: newVPN))
    }

    @Test func openedWithoutVPNIsFrozenThenRestartedWhenVPNConnects() {
        let engine = KillSwitchEngine(storedBinding: .unrestricted, transmissionRunning: false)
        #expect(engine.update(snap(vpn: nil, running: false)) == [.writeBinding(.blocked)])
        #expect(engine.update(snap(vpn: nil, running: true)) == [.freezeTransmission, .notify(.frozen)])
        #expect(engine.update(snap(vpn: vpn, running: true))
                == [.writeBinding(vpnBinding), .notify(.rebinding(ipv4: "10.64.0.2")), .quitTransmission(force: true)])
        #expect(engine.update(snap(vpn: vpn, running: false)) == [.launchTransmission])
    }

    @Test func unboundTransmissionIsKilledAndRestartedOnStartup() {
        let engine = KillSwitchEngine(storedBinding: .unrestricted, transmissionRunning: true)
        #expect(engine.update(snap(vpn: vpn, running: true))
                == [.writeBinding(vpnBinding), .notify(.rebinding(ipv4: "10.64.0.2")), .quitTransmission(force: true)])
        #expect(engine.update(snap(vpn: vpn, running: false)) == [.launchTransmission])
        #expect(engine.update(snap(vpn: vpn, running: true)) == [])
        #expect(engine.isBound(to: vpn))
    }

    @Test func unboundTransmissionWithoutVPNIsFrozenImmediately() {
        let engine = KillSwitchEngine(storedBinding: .unrestricted, transmissionRunning: true)
        #expect(engine.update(snap(vpn: nil, running: true))
                == [.writeBinding(.blocked), .freezeTransmission, .notify(.frozen)])
    }

    @Test func startupResumesTransmissionLeftFrozen() {
        let engine = KillSwitchEngine(storedBinding: vpnBinding, transmissionRunning: true)
        #expect(engine.update(snap(vpn: vpn, running: true)) == [.resumeTransmission])
        #expect(engine.update(snap(vpn: vpn, running: true)) == [])
    }

    @Test func withoutFreezingBoundTransmissionKeepsRunning() {
        let engine = boundEngine()
        #expect(engine.update(snap(vpn: nil, running: true, freeze: false)) == [.writeBinding(.blocked)])
        #expect(engine.update(snap(vpn: vpn, running: true, freeze: false)) == [.writeBinding(vpnBinding)])
    }

    @Test func withoutFreezingUnboundTransmissionIsKilled() {
        let engine = KillSwitchEngine(storedBinding: .unrestricted, transmissionRunning: true)
        #expect(engine.update(snap(vpn: nil, running: true, freeze: false))
                == [.writeBinding(.blocked), .quitTransmission(force: true)])
    }

    @Test func disablingResumesAndRestartsTransmissionWithoutBinding() {
        let engine = boundEngine()
        _ = engine.update(snap(vpn: nil, running: true))
        #expect(engine.update(snap(vpn: nil, running: true, enabled: false))
                == [.resumeTransmission, .writeBinding(.unrestricted), .notify(.unbinding), .quitTransmission(force: false)])
        #expect(engine.update(snap(vpn: nil, running: true, enabled: false)) == [])
        #expect(engine.update(snap(vpn: nil, running: false, enabled: false)) == [.launchTransmission])
        #expect(engine.update(snap(vpn: nil, running: true, enabled: false)) == [])
        #expect(engine.runningBinding == .unrestricted)
    }

    @Test func disablingLeavesUnboundTransmissionRunning() {
        let engine = KillSwitchEngine(storedBinding: .unrestricted, transmissionRunning: false)
        #expect(engine.update(snap(vpn: nil, running: true, enabled: false)) == [])
    }

    @Test func disablingFinishesPendingRestart() {
        let engine = KillSwitchEngine(storedBinding: .unrestricted, transmissionRunning: true)
        _ = engine.update(snap(vpn: vpn, running: true))
        // It was quit to be rebound; reopen it rather than leave it closed.
        #expect(engine.update(snap(vpn: vpn, running: false, enabled: false))
                == [.writeBinding(.unrestricted), .launchTransmission])
        #expect(engine.update(snap(vpn: vpn, running: true, enabled: false)) == [])
    }

    @Test func quittingResumesBoundTransmission() {
        let engine = boundEngine()
        _ = engine.update(snap(vpn: nil, running: true))
        #expect(engine.terminate(poweringOff: false) == [.resumeTransmission])
    }

    @Test func quittingKillsUnboundTransmissionInsteadOfResumingIt() {
        let engine = KillSwitchEngine(storedBinding: .unrestricted, transmissionRunning: true)
        _ = engine.update(snap(vpn: nil, running: true))
        #expect(engine.frozen)
        #expect(engine.terminate(poweringOff: false) == [.quitTransmission(force: true)])
    }

    @Test func poweringOffKillsFrozenTransmission() {
        let engine = boundEngine()
        _ = engine.update(snap(vpn: nil, running: true))
        #expect(engine.terminate(poweringOff: true) == [.quitTransmission(force: true)])
    }

    @Test func quittingLeavesRunningTransmissionAlone() {
        let engine = boundEngine()
        #expect(engine.terminate(poweringOff: false) == [])
        #expect(engine.terminate(poweringOff: true) == [])
    }

    @Test func ipv6IsAlwaysBlocked() {
        #expect(Binding.vpn(vpn).ipv6 == Binding.blockedIPv6)
        #expect(Binding.vpn(vpn).isRestricted)
        #expect(!Binding.unrestricted.isRestricted)
    }
}
