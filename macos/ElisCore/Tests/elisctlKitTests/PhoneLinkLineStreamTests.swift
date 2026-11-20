#if os(macOS)
import Foundation
import ElisCore
@testable import elisctlKit
import Testing

struct PhoneLinkLineStreamTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var received: [String] = []
        private let changed = DispatchSemaphore(value: 0)
        private let ended = DispatchSemaphore(value: 0)

        var lines: [String] { lock.withLock { received } }

        func start(_ stream: PhoneLinkLineStream) {
            stream.start(onLine: { line in
                self.lock.withLock { self.received.append(String(decoding: line, as: UTF8.self)) }
                self.changed.signal()
            }, onEnd: { self.ended.signal() })
        }

        /// Blocks on a plain thread, bounded for a slow CI runner.
        func waitLines(_ count: Int, _ seconds: Double = 30) async -> Bool {
            await Self.offThread {
                let deadline = Date().addingTimeInterval(seconds)
                while self.lines.count < count {
                    if self.changed.wait(timeout: .now() + deadline.timeIntervalSinceNow) == .timedOut { return false }
                }
                return true
            }
        }

        func waitEnd(_ seconds: Double = 30) async -> Bool {
            await Self.offThread { self.ended.wait(timeout: .now() + seconds) == .success }
        }

        private static func offThread(_ body: @escaping @Sendable () -> Bool) async -> Bool {
            await withCheckedContinuation { continuation in Thread { continuation.resume(returning: body()) }.start() }
        }
    }

    private let queue = DispatchQueue(label: "line.stream.test")

    private func socketStream(answer: String) throws -> (RawStubServer, PhoneLinkLineStream) {
        let server = RawStubServer()
        try server.start()
        server.answerRaw("zmx.present", answer)
        do {
            return (server, try PhoneLinkLineStream.socket(path: server.path, request: ControlRequest(cmd: .zmxPresent), queue: queue))
        } catch {
            server.stop()
            throw error
        }
    }

    @Test func socketStreamDeliversLinesOneAtATime() async throws {
        let (server, stream) = try socketStream(answer: "{\"ok\":true}\nfirst\nsecond\n")
        defer { server.stop() }
        let recorder = Recorder()
        recorder.start(stream)
        #expect(await recorder.waitLines(1))
        #expect(!(await recorder.waitLines(2, 0.5)))
        #expect(recorder.lines == ["first"])
        stream.resume()
        #expect(await recorder.waitLines(2))
        #expect(recorder.lines == ["first", "second"])
        stream.resume()
        #expect(await recorder.waitEnd())
    }

    @Test func aRefusedRequestThrows() throws {
        #expect { try socketStream(answer: "{\"ok\":false,\"error\":\"no\"}\n") } throws: { "\($0)".contains("no") }
    }

    @Test func processStreamEndsWhenTheChildExits() async throws {
        let stream = try PhoneLinkLineStream.process(argv: ["/bin/sh", "-c", "echo a; exit 0"], queue: queue)
        let recorder = Recorder()
        recorder.start(stream)
        #expect(await recorder.waitLines(1))
        #expect(recorder.lines == ["a"])
        stream.resume()
        #expect(await recorder.waitEnd())
    }

    @Test func aBareCommandIsFoundOnPath() async throws {
        let stream = try PhoneLinkLineStream.process(argv: ["sh", "-c", "echo a"], queue: queue)
        let recorder = Recorder()
        recorder.start(stream)
        #expect(await recorder.waitLines(1))
        #expect(recorder.lines == ["a"])
    }

    @Test func processStreamCarriesWhatItSends() async throws {
        let stream = try PhoneLinkLineStream.process(argv: ["/bin/sh", "-c", "read line; echo got-$line"], queue: queue)
        let recorder = Recorder()
        recorder.start(stream)
        stream.send(Data("ping\n".utf8))
        #expect(await recorder.waitLines(1))
        #expect(recorder.lines == ["got-ping"])
    }

    // the child stays alive, so only the cap can end the stream
    @Test func aLineOverTheCapEndsTheStream() async throws {
        let script = "head -c \(PhoneLinkLineStream.maxLine + 1) /dev/zero | tr '\\0' x; echo; exec sleep 60"
        let stream = try PhoneLinkLineStream.process(argv: ["/bin/sh", "-c", script], queue: queue)
        defer { stream.close() }
        let recorder = Recorder()
        recorder.start(stream)
        #expect(await recorder.waitEnd())
        #expect(recorder.lines.isEmpty)
    }

    @Test func closeSkipsOnEnd() async throws {
        let stream = try PhoneLinkLineStream.process(argv: ["/bin/sh", "-c", "echo a; exec sleep 60"], queue: queue)
        defer { stream.close() }
        let recorder = Recorder()
        recorder.start(stream)
        #expect(await recorder.waitLines(1))
        queue.sync { stream.close() }
        #expect(!(await recorder.waitEnd(1)))
    }
}
#endif
