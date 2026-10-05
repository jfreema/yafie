import AppKit

enum Shell {
    struct Result {
        var status: Int32
        var output: String
    }

    /// Blocks until exit or timeout
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 15) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: error.localizedDescription)
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return Result(status: -1, output: "\(path) timed out")
        }
        // Small output, pipe won't fill
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

/// Root, via the password dialog
@MainActor
enum Administrator {
    enum Outcome { case done, cancelled, failed(String) }

    static func run(_ command: String, prompt: String) -> Outcome {
        // Else the password dialog opens behind windows
        NSApp.activateRegardless()
        let source = "do shell script \(literal(command)) with administrator privileges with prompt \(literal(prompt))"
        guard let script = NSAppleScript(source: source) else { return .failed("Couldn't prepare the request.") }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        guard let error else { return .done }
        if error[NSAppleScript.errorNumber] as? Int == -128 { return .cancelled }
        return .failed(error[NSAppleScript.errorMessage] as? String ?? "Unknown error")
    }

    private static func literal(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
