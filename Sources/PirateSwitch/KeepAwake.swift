import IOKit.pwr_mgt

/// Stops the Mac from going to sleep on its own, like Amphetamine or
/// `caffeinate -i`. The display can still sleep, and closing the lid or
/// choosing Sleep still puts the Mac to sleep.
final class KeepAwake {
    private var assertion: IOPMAssertionID?

    var isOn: Bool {
        get { assertion != nil }
        set {
            if newValue, assertion == nil {
                var id = IOPMAssertionID(0)
                let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                         IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                         "PirateSwitch: Transmission is on the VPN" as CFString, &id)
                if result == kIOReturnSuccess { assertion = id }
            } else if !newValue, let id = assertion {
                IOPMAssertionRelease(id)
                assertion = nil
            }
        }
    }
}
