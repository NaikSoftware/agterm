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

    @Test func writeReachesTheProgram() async throws {
        let recorder = Recorder()
        let pty = try recorder.spawn(["/bin/cat"])
        let written = Written()
        pty.write(Data("hello\n".utf8)) { written.add($0) }
        #expect(await eventually { recorder.output.components(separatedBy: "hello").count == 3 }, "output: \(recorder.output)")
        #expect(await eventually { written.counts == [6] })
        pty.terminate()
        #expect(await recorder.waitExit())
    }

    @Test func writeAfterTerminateReportsZero() async throws {
        let recorder = Recorder()
        let pty = try recorder.spawn(["/bin/cat"])
        pty.terminate()
        let written = Written()
        pty.write(Data("late\n".utf8)) { written.add($0) }
        #expect(await eventually { written.counts == [0] })
        #expect(await recorder.waitExit())
    }

    @Test func writeAndResizeAfterTheChildExitedDoNothing() async throws {
        let recorder = Recorder()
        let pty = try recorder.spawn(["/bin/sh", "-c", "exit 0"])
        #expect(await recorder.waitExit())
        let written = Written()
        pty.write(Data("late\n".utf8)) { written.add($0) }
        pty.resize(cols: 100, rows: 40)
        #expect(await eventually { written.counts == [0] })
    }

    @Test func resizeChangesTheWindowSize() async throws {
        let recorder = Recorder()
        let pty = try recorder.spawn(["/bin/sh", "-c", "read line; stty size"])
        pty.resize(cols: 100, rows: 40)
        pty.write(Data("\n".utf8)) { _ in }
        #expect(await recorder.waitExit())
        #expect(recorder.output.contains("40 100"), "output: \(recorder.output)")
    }

    @Test func fullPtyDoesNotBlockTerminate() async throws {
        let recorder = Recorder()
        let pty = try recorder.spawn(["/bin/sh", "-c", "stty raw -echo; echo ready; exec sleep 60"])
        #expect(await eventually { recorder.output.contains("ready") })
        let written = Written()
        for _ in 0..<16 { pty.write(Data(repeating: 0x78, count: 65536)) { written.add($0) } }
        try await Task.sleep(for: .milliseconds(300))
        #expect(written.counts.isEmpty) // the program reads nothing, so the first write never completes
        let started = Date()
        pty.terminate()
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(await recorder.waitExit())
        #expect(await eventually { written.counts.count == 16 })
    }

    @Test func idleWriterSleepsAndEndsWithTerminate() async throws {
        let recorder = Recorder()
        let pty = try recorder.spawn(["/bin/cat"])
        let written = Written()
        pty.write(Data("x".utf8)) { written.add($0) }
        #expect(await eventually { written.counts == [1] })
        #expect(await eventually { pty.writerIdle })
        let idle = pty.writerWakeups
        try await Task.sleep(for: .milliseconds(500))
        #expect(pty.writerWakeups == idle)
        pty.terminate()
        #expect(await eventually(3) { !pty.writerRunning })
        #expect(await recorder.waitExit())
    }

    @Test func finishWritesWhatWasQueuedBeforeEnding() async throws {
        let recorder = Recorder()
        let file = NSTemporaryDirectory() + "elis-pty-\(UUID().uuidString.prefix(8))"
        defer { [file, file + ".early"].forEach { try? FileManager.default.removeItem(atPath: $0) } }
        // a SIGTERM before the program read its input leaves the marker; after the read, the TERM is ignored
        let script = "trap 'touch \(file).early; exit 1' TERM; stty raw -echo; echo ready; sleep 0.3; trap '' TERM; exec cat > '\(file)'"
        let pty = try recorder.spawn(["/bin/sh", "-c", script])
        #expect(await eventually { recorder.output.contains("ready") })
        let written = Written()
        pty.write(Data(repeating: 0x78, count: 100)) { written.add($0) }
        pty.finish(within: 30)
        #expect(await eventually { written.counts == [100] })
        #expect(await recorder.waitExit())
        #expect(!FileManager.default.fileExists(atPath: file + ".early"))
        #expect(await eventually { (try? Data(contentsOf: URL(fileURLWithPath: file)))?.count == 100 })
    }

    @Test func finishIsBoundedWhenTheProgramNeverReads() async throws {
        let recorder = Recorder()
        let pty = try recorder.spawn(["/bin/sh", "-c", "stty raw -echo; echo ready; exec sleep 60"])
        #expect(await eventually { recorder.output.contains("ready") })
        pty.write(Data(repeating: 0x78, count: 65536)) { _ in }
        let started = Date()
        pty.finish(within: 0.5)
        #expect(await recorder.waitExit())
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func finishWithNothingQueuedTerminatesAtOnce() async throws {
        let recorder = Recorder()
        let pty = try recorder.spawn(["/bin/cat"])
        pty.finish()
        #expect(await recorder.waitExit())
    }

    /// Written collects what each `write` reported, in completion order.
    private final class Written: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        func add(_ count: Int) { lock.withLock { values.append(count) } }
        var counts: [Int] { lock.withLock { values } }
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
