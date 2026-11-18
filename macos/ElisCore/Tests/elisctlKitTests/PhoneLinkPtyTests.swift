#if os(macOS)
import Foundation
@testable import elisctlKit
import Testing

// shortcut: macOS only, because Swift's Glibc does not export posix_openpt; port when the relay runs on Linux.
struct PhoneLinkPtyTests {
    /// Recorder collects what a pty reports; `exited` signals once onExit fires.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var status: Int32?
        let exited = DispatchSemaphore(value: 0)

        var output: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
        var exitStatus: Int32? { lock.withLock { status } }

        func spawn(_ argv: [String]) throws -> PhoneLinkPty {
            try PhoneLinkPty.spawn(argv, cols: 80, rows: 24,
                                   onOutput: { chunk in self.lock.withLock { self.data.append(chunk) } },
                                   onExit: { code in
                                       self.lock.withLock { self.status = code }
                                       self.exited.signal()
                                   })
        }

        /// waitExit blocks on a plain thread, bounded for a slow CI runner.
        func waitExit(_ seconds: Double = 30) async -> Bool {
            await withCheckedContinuation { continuation in
                Thread { continuation.resume(returning: self.exited.wait(timeout: .now() + seconds) == .success) }.start()
            }
        }
    }

    @Test func deliversOutput() async throws {
        let recorder = Recorder()
        _ = try recorder.spawn(["/bin/sh", "-c", "stty size; echo marker-$TERM; : </dev/tty && echo has-ctty"])
        #expect(await recorder.waitExit())
        #expect(recorder.output.contains("marker-xterm-256color"), "output: \(recorder.output)")
        #expect(recorder.output.contains("24 80"), "output: \(recorder.output)")
        // /dev/tty opens only for a process with a controlling terminal
        #expect(recorder.output.contains("has-ctty"), "output: \(recorder.output)")
    }

    @Test func reportsExitStatus() async throws {
        let recorder = Recorder()
        _ = try recorder.spawn(["/bin/sh", "-c", "exit 7"])
        #expect(await recorder.waitExit())
        #expect(recorder.exitStatus == 7)
    }

    @Test func terminateEndsAChildThatIgnoresTerm() async throws {
        let recorder = Recorder()
        let pty = try recorder.spawn(["/bin/sh", "-c", "trap '' TERM HUP; echo ready; while :; do sleep 1; done"])
        #expect(await eventually { recorder.output.contains("ready") })
        pty.terminate()
        #expect(await recorder.waitExit())
        #expect(recorder.exitStatus != 0)
    }

    @Test func terminateEndsAPipelineThatHoldsTheTerminal() async throws {
        let recorder = Recorder()
        // every member ignores SIGHUP, so only a signal to the whole group ends the sleep that holds no terminal
        let pty = try recorder.spawn(["/bin/sh", "-c", "trap '' HUP; sleep 60 </dev/null >/dev/null 2>&1 & echo pid=$!; cat"])
        #expect(await eventually { recorder.output.contains("\r\n") })
        let line = recorder.output.split(whereSeparator: \.isNewline).first { $0.hasPrefix("pid=") }
        let grandchild = try #require(line.flatMap { pid_t($0.dropFirst(4)) }, "output: \(recorder.output)")
        pty.terminate()
        // onExit fires after the reader thread leaves its loop, so it also proves the reader ended
        #expect(await recorder.waitExit())
        #expect(await eventually { kill(grandchild, 0) == -1 && errno == ESRCH }, "pid \(grandchild) outlived terminate()")
        kill(grandchild, SIGKILL)
    }

    @Test func badExecutableThrows() {
        #expect(throws: PhoneLinkPty.Failure.self) {
            _ = try PhoneLinkPty.spawn(["/nonexistent/elis-no-such-binary"], cols: 80, rows: 24,
                                       onOutput: { _ in }, onExit: { _ in })
        }
    }

    @Test func noOutputAfterTerminate() async throws {
        let recorder = Recorder()
        let pty = try recorder.spawn(["/bin/sh", "-c", "trap '' TERM HUP; echo ready; while :; do echo tick; sleep 0.05; done"])
        #expect(await eventually { recorder.output.contains("ready") })
        pty.terminate()
        let seen = recorder.output
        #expect(await recorder.waitExit())
        #expect(recorder.output == seen)
    }

    private func eventually(_ seconds: Double = 15, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}
#endif
