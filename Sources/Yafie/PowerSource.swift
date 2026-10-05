import Foundation
import IOKit.ps

enum PowerSource {
    /// Unknown counts as battery
    static var isOnACPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return source as String == kIOPMACPowerKey
    }
}

/// Adapter/battery change callback
@MainActor
final class PowerSourceMonitor {
    private let onChange: @MainActor () -> Void
    private var source: CFRunLoopSource?

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSCreateLimitedPowerNotification({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(context).takeUnretainedValue()
            // Fires on main run loop
            MainActor.assumeIsolated { monitor.onChange() }
        }, context)?.takeRetainedValue()
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }
}
