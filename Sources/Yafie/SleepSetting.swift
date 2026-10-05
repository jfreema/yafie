import Foundation

/// `pmset disablesleep` via sudoers rule
enum SleepSetting {
    static let rulePath = "/etc/sudoers.d/yafie"

    /// Keeps writes in order
    private static let queue = DispatchQueue(label: "yafie.sleep-setting")

    static func set(disabled: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: write(disabled)) }
        }
    }

    /// Runs after queued writes
    static func setSynchronously(disabled: Bool) -> Bool {
        queue.sync { write(disabled) }
    }

    /// Tests by rewriting current value
    static func isPasswordFree() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                guard FileManager.default.fileExists(atPath: rulePath),
                      let current = configuredValue() else {
                    return continuation.resume(returning: false)
                }
                continuation.resume(returning: write(current))
            }
        }
    }

    /// Bad sudoers file breaks sudo
    static var installRuleCommand: String {
        let rule = "#\(getuid()) ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0"
        let staged = rulePath + ".new"  // sudo skips dotted names
        return "/bin/mkdir -p /etc/sudoers.d"
            + " && /usr/bin/printf '%s\\n' '\(rule)' > \(staged)"
            + " && /usr/sbin/chown root:wheel \(staged) && /bin/chmod 0440 \(staged)"
            + " && /usr/sbin/visudo -cqf \(staged) && /bin/mv -f \(staged) \(rulePath)"
            + " || { /bin/rm -f \(staged); exit 1; }"
    }

    private static func write(_ disabled: Bool) -> Bool {
        Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "disablesleep", disabled ? "1" : "0"]).status == 0
    }

    /// Authoritative, kernel copy lags
    private static func configuredValue() -> Bool? {
        let result = Shell.run("/usr/bin/pmset", ["-g"])
        guard result.status == 0 else { return nil }
        for line in result.output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count == 2, fields[0] == "SleepDisabled" { return fields[1] == "1" }
        }
        return false
    }
}
