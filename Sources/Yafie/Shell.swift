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

    /// A child process's output, a line at a time, on a thread of its own, since reading a pipe blocks. Ends with nil
    /// when the child does.
    static func readLines(from reader: FileHandle, _ deliver: @escaping @Sendable (String?) -> Void) {
        Thread.detachNewThread {
            var pending = [UInt8]()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(reader.fileDescriptor, &chunk, chunk.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                pending += chunk[..<count]
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    deliver(String(decoding: pending[..<newline], as: UTF8.self))
                    pending.removeSubrange(...newline)
                }
            }
            deliver(nil)
        }
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
