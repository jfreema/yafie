import Foundation
import Testing
@testable import Yafie

/// Shell scripts stand in for screencapture, which writes the snip to the file named last ($1 here)
@MainActor
struct SnipCaptureTests {
    private func run(_ script: String) async -> (outcome: SnipCapture.Outcome?, file: URL) {
        var outcome: SnipCapture.Outcome?
        let capture = SnipCapture(.init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script, "stand-in"])) {
            outcome = $0
        }
        for _ in 0..<250 where outcome == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return (outcome, capture.file)
    }

    @Test func readsTheSnipAndItsScale() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("yafie-test-\(UUID().uuidString).png")
        try SnipRenderer.data(SnipImages.plain(width: 64, height: 48), scale: 2)!.write(to: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let (outcome, file) = await run("cp '\(fixture.path)' \"$1\"")
        guard case .taken(let snip) = outcome else {
            Issue.record("Expected a snip, got \(String(describing: outcome))")
            return
        }
        #expect(snip.pixelSize == CGSize(width: 64, height: 48))
        #expect(snip.scale == 2)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func noFileMeansCancelled() async {
        let (outcome, _) = await run("exit 1")
        guard case .cancelled = outcome else {
            Issue.record("Expected cancelled, got \(String(describing: outcome))")
            return
        }
    }

    @Test func anUnreadableFileFails() async {
        let (outcome, file) = await run("echo nonsense > \"$1\"")
        guard case .failed = outcome else {
            Issue.record("Expected a failure, got \(String(describing: outcome))")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aToolThatWontStartFails() async {
        var outcome: SnipCapture.Outcome?
        _ = SnipCapture(.init(executable: URL(fileURLWithPath: "/nonexistent/screencapture"), arguments: [])) {
            outcome = $0
        }
        for _ in 0..<50 where outcome == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard case .failed = outcome else {
            Issue.record("Expected a failure, got \(String(describing: outcome))")
            return
        }
    }

    @Test func screencaptureSelectsWithoutShadowOrSound() {
        #expect(SnipCapture.Tool.screencapture.executable.path == "/usr/sbin/screencapture")
        #expect(SnipCapture.Tool.screencapture.arguments == ["-i", "-o", "-x"])
    }
}
