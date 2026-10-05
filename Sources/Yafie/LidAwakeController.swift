import AppKit
import os

let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "yafie", category: "lid")

/// No lid sleep, while plugged in or on battery too
@MainActor
final class LidAwakeController {
    enum Status: Equatable {
        case off, waitingForPower, lowBattery, waitingForInternet, active(onBattery: Bool), needsSetup, restoreFailed
    }

    /// On battery, the Mac sleeps as usual from this charge down, in percent
    static let lowBattery = 10

    var onChange: (() -> Void)?

    private(set) var isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled) {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled) }
    }
    /// Only while plugged in, which is how it started out
    private(set) var requiresPower = UserDefaults.standard.object(forKey: Keys.requiresPower) as? Bool ?? true {
        didSet { UserDefaults.standard.set(requiresPower, forKey: Keys.requiresPower) }
    }
    /// Only while online, too
    private(set) var requiresInternet = UserDefaults.standard.bool(forKey: Keys.requiresInternet) {
        didSet { UserDefaults.standard.set(requiresInternet, forKey: Keys.requiresInternet) }
    }
    private var isOnACPower = PowerSource.isOnACPower
    private var batteryLevel = PowerSource.batteryLevel
    private lazy var connectivity = ConnectivityMonitor { [weak self] in self?.changed() }
    /// sudo rule missing or broken
    private var needsSetup = false
    /// Restore failed, user must retry
    private var restoreFailed = false
    /// Flag is ours to undo
    private var ownsSleepDisabled = UserDefaults.standard.bool(forKey: Keys.ownsSleepDisabled) {
        didSet {
            UserDefaults.standard.set(ownsSleepDisabled, forKey: Keys.ownsSleepDisabled)
            watchdog.ownsSleepDisabled = ownsSleepDisabled
        }
    }
    private let watchdog = Watchdog()
    /// nil if unknown or overridden
    private var lastWritten: Bool?
    /// Sleep Now, until next wake
    private var pausedUntilWake = false
    private var pausedAt = Date.distantPast
    private var writing = false
    private var settingUp = false
    private var terminating = false
    private var systemIsPoweringOff = false
    /// Cancels stale sleep retries
    private var sleepRequestGeneration = 0
    private var started = false
    private var powerMonitor: PowerSourceMonitor?
    private var recheckTimer: Timer?

    private enum Keys {
        static let enabled = "enabled"
        static let requiresPower = "requiresPower"
        static let requiresInternet = "requiresInternet"
        static let ownsSleepDisabled = "ownsSleepDisabled"
    }

    var status: Status {
        if restoreFailed { return .restoreFailed }
        guard isEnabled else { return .off }
        if needsSetup { return .needsSetup }
        if isWaitingForPower { return .waitingForPower }
        if isBatteryLow { return .lowBattery }
        return isOffline ? .waitingForInternet : .active(onBattery: !isOnACPower)
    }

    private var isWaitingForPower: Bool { requiresPower && !isOnACPower }
    private var isBatteryLow: Bool { !isOnACPower && (batteryLevel ?? 100) <= Self.lowBattery }
    private var isOffline: Bool { requiresInternet && !connectivity.isOnline }

    private var wantsSleepDisabled: Bool {
        isEnabled && !isWaitingForPower && !isBatteryLow && !isOffline && !needsSetup && !pausedUntilWake
    }

    // MARK: Lifecycle

    func start() {
        started = true
        watchdog.start(ownsSleepDisabled: ownsSleepDisabled)
        powerMonitor = PowerSourceMonitor { [weak self] in self?.powerSourceMayHaveChanged() }
        let notifications = NSWorkspace.shared.notificationCenter
        _ = notifications.addObserver(forName: NSWorkspace.didWakeNotification,
                                      object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        }
        _ = notifications.addObserver(forName: NSWorkspace.willPowerOffNotification,
                                      object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemIsPoweringOff = true }
        }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheck() }
        }
        RunLoop.main.add(timer, forMode: .common)  // fires while menu is open
        recheckTimer = timer
        // Also cleans up after crashes
        changed()
    }

    /// Synchronous, the app is exiting
    func stop() {
        terminating = true
        guard started, ownsSleepDisabled else { return }
        sleepRequestGeneration += 1
        if SleepSetting.setSynchronously(disabled: false) {
            ownsSleepDisabled = false
            logger.notice("Turned sleep back on before quitting")
        } else {
            restoreWithPassword()
        }
    }

    // MARK: Menu actions

    func setEnabled(_ enabled: Bool) {
        if enabled {
            Task { await setUpThenEnable() }
        } else {
            isEnabled = false
            needsSetup = false
            changed()
        }
    }

    func finishSetup() {
        Task { await setUpThenEnable() }
    }

    func retryRestore() {
        restoreFailed = false
        changed()
    }

    /// No sudoers rule yet, so turning on asks for a password
    var needsPasswordToEnable: Bool { !FileManager.default.fileExists(atPath: SleepSetting.rulePath) }

    func setRequiresPower(_ required: Bool) {
        requiresPower = required
        changed()
    }

    func setRequiresInternet(_ required: Bool) {
        requiresInternet = required
        changed()
    }

    /// Lifts flag for one sleep
    func sleepNow() {
        pausedUntilWake = true
        pausedAt = Date()
        changed()
        // In-flight write handles it
        if !writing { requestSleep(onlyForClosedLid: false) }
    }

    /// One-time password, then enable
    private func setUpThenEnable() async {
        guard !settingUp else { return }
        settingUp = true
        defer {
            settingUp = false
            onChange?()  // the switch catches up, even if setup was cancelled
        }

        let ready = await SleepSetting.isPasswordFree()
        if !ready {
            let prompt = "Yafie needs your password once, so it can turn lid sleep off and back on "
                + "without asking again."
            switch Administrator.run(SleepSetting.installRuleCommand, prompt: prompt) {
            case .done:
                break
            case .cancelled:
                return
            case .failed(let message):
                Alert.show("Setup didn't finish", message)
                return
            }
            guard await SleepSetting.isPasswordFree() else {
                Alert.show("Setup didn't finish",
                           "The permission was added, but changing the sleep setting still asks for a password.")
                return
            }
        }
        isEnabled = true
        needsSetup = false
        changed()
    }

    // MARK: Events

    /// Also how the battery running low is noticed, every 30 seconds at most
    private func powerSourceMayHaveChanged() {
        let wasLow = isBatteryLow
        let onAC = PowerSource.isOnACPower
        batteryLevel = PowerSource.batteryLevel
        let switched = onAC != isOnACPower
        isOnACPower = onAC
        if switched { logger.notice("Now running on \(onAC ? "the power adapter" : "battery", privacy: .public)") }
        if isBatteryLow, !wasLow, isEnabled, !requiresPower { logger.notice("The battery is low") }
        if switched || isBatteryLow != wasLow { changed() }
    }

    private func systemDidWake() {
        pausedUntilWake = false
        isOnACPower = PowerSource.isOnACPower
        batteryLevel = PowerSource.batteryLevel
        connectivity.recheck()
        changed()
    }

    /// Backstop for missed changes
    private func recheck() {
        if lastWritten == true, PowerManager.isSleepDisabled == false {
            logger.notice("Something else turned sleep back on")
            lastWritten = nil
        }
        // Unpause if Sleep Now didn't sleep
        if pausedUntilWake, Date().timeIntervalSince(pausedAt) > 60 {
            pausedUntilWake = false
        }
        powerSourceMayHaveChanged()
        changed()
    }

    private func changed() {
        connectivity.isWatching = isEnabled && requiresInternet && !isWaitingForPower
        reconcile()
        onChange?()
    }

    // MARK: Applying the setting

    /// Match the flag to intent
    private func reconcile() {
        guard started, !terminating, !writing else { return }
        if wantsSleepDisabled {
            if lastWritten != true { write(disabled: true) }
        } else if ownsSleepDisabled, !restoreFailed {
            // Kernel may lag, so write anyway
            write(disabled: false)
        }
    }

    private func write(disabled: Bool) {
        writing = true
        let ownedBefore = ownsSleepDisabled
        if disabled {
            ownsSleepDisabled = true      // before the write, crash-safe
            sleepRequestGeneration += 1   // cancel stale sleep retries
        }
        Task {
            let succeeded = await SleepSetting.set(disabled: disabled)
            writing = false
            guard !terminating else { return }
            if succeeded {
                lastWritten = disabled
                restoreFailed = false  // writes work again
                if disabled {
                    logger.notice("Lid sleep is off")
                } else {
                    ownsSleepDisabled = false
                    logger.notice("Lid sleep is back on")
                    requestSleep(onlyForClosedLid: !pausedUntilWake)
                }
            } else if disabled {
                logger.error("Couldn't turn sleep off without a password")
                ownsSleepDisabled = ownedBefore
                needsSetup = true
            } else {
                logger.error("Couldn't turn sleep back on without a password")
                restoreWithPassword()
            }
            changed()  // catch up
        }
    }

    /// Rule broke, ask for password
    private func restoreWithPassword() {
        // Skip if already back on
        if PowerManager.isSleepDisabled != false {
            guard !systemIsPoweringOff else {
                restoreFailed = true  // next launch retries
                return
            }
            let outcome = Administrator.run("/usr/bin/pmset disablesleep 0",
                                            prompt: "Yafie needs your password to turn sleep back on.")
            guard case .done = outcome else {
                restoreFailed = true
                return
            }
        }
        lastWritten = false
        ownsSleepDisabled = false
        restoreFailed = false
        if !terminating { requestSleep(onlyForClosedLid: !pausedUntilWake) }
    }

    /// macOS won't recheck lid once flag clears
    private func requestSleep(onlyForClosedLid: Bool, attempt: Int = 1) {
        if onlyForClosedLid {
            // Respect clamshell mode
            guard !wantsSleepDisabled, PowerManager.isLidClosed == true,
                  PowerManager.lidClosingCausesSleep != false else { return }
        }
        if PowerManager.sleepNow() {
            logger.notice("Asked macOS to sleep")
            return
        }
        guard attempt < 10 else {
            logger.error("macOS refused to sleep")
            if pausedUntilWake {
                pausedUntilWake = false
                changed()
            }
            return
        }
        // Kernel lags after clearing, retry
        let generation = sleepRequestGeneration
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard generation == sleepRequestGeneration, !terminating else { return }
            requestSleep(onlyForClosedLid: onlyForClosedLid, attempt: attempt + 1)
        }
    }
}
