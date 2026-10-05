import IOKit
import IOKit.pwr_mgt

/// IOPMrootDomain state and sleep
enum PowerManager {
    /// nil without a lid
    static var isLidClosed: Bool? { flag(kAppleClamshellStateKey) }

    /// False in clamshell mode
    static var lidClosingCausesSleep: Bool? { flag(kAppleClamshellCausesSleepKey) }

    /// Kernel's copy, can lag
    static var isSleepDisabled: Bool? { flag("SleepDisabled") }

    /// False if refused
    static func sleepNow() -> Bool {
        let connection = IOPMFindPowerManagement(kIOMainPortDefault)
        guard connection != 0 else { return false }
        defer { IOServiceClose(connection) }
        return IOPMSleepSystem(connection) == kIOReturnSuccess
    }

    private static func flag(_ key: String) -> Bool? {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return nil }
        defer { IOObjectRelease(rootDomain) }
        return IORegistryEntryCreateCFProperty(rootDomain, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }
}
