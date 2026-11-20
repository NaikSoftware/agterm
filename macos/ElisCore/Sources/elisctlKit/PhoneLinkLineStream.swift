#if os(macOS)
import Foundation
import ElisCore

/// Newline-delimited lines both ways over a control-socket stream or a child process's stdio. One line is delivered,
/// and the next is read only after `resume()`. Callbacks run on `queue`.
/// A line over `maxLine` ends the stream, as the peer's end does: lines come from a peer the relay does not trust.
final class PhoneLinkLineStream: @unchecked Sendable {
    static let maxLine = PresentationCodec.maxFrameBytes

    private enum Transport {
        case socket(Int32)
        // the pipes are kept so their descriptors stay open until the stream goes away
        case process(Process, input: Pipe, output: Pipe)
    }

    private let transport: Transport
    private let readFD: Int32
    private let writeFD: Int32
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let resumed = DispatchSemaphore(value: 0)
    private let writable = DispatchSemaphore(value: 0)
    private let writerDone = DispatchSemaphore(value: 0)
    private var outbox: [Data] = []
    private var closed = false
    private var stopping = false

    private init(transport: Transport, readFD: Int32, writeFD: Int32, queue: DispatchQueue) {
        self.transport = transport
        self.readFD = readFD
        self.writeFD = writeFD
        self.queue = queue
    }

    /// Sends `request` on the app socket and waits for its ok reply (as `StreamBridge.open`), off `queue`.
    static func socket(path: String, request: ControlRequest, queue: DispatchQueue) throws -> PhoneLinkLineStream {
        let fd = try SocketClient(path: path).connect()
        do {
            try StreamBridge(socket: fd, input: -1, output: -1).open(request)
        } catch {
            Darwin.close(fd)
            throw error
        }
        return PhoneLinkLineStream(transport: .socket(fd), readFD: fd, writeFD: fd, queue: queue)
    }

    /// Runs `argv` with pipes on stdin and stdout; stderr is dropped.
    static func process(argv: [String], queue: DispatchQueue) throws -> PhoneLinkLineStream {
        guard let path = argv.first else { throw SocketClientError("no command to run") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = Array(argv.dropFirst())
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let writeFD = input.fileHandleForWriting.fileDescriptor
        // a child that stopped reading fails the write instead of raising SIGPIPE in the relay
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
        return PhoneLinkLineStream(transport: .process(process, input: input, output: output),
                                   readFD: output.fileHandleForReading.fileDescriptor, writeFD: writeFD, queue: queue)
    }

    func start(onLine: @escaping (Data) -> Void, onEnd: @escaping () -> Void) {
        let reader = Thread { [self] in
            read(onLine)
            stop()
            writerDone.wait()
            // closed only now that neither thread can touch the descriptor again
            if case .socket(let fd) = transport { Darwin.close(fd) }
            queue.async { [self] in
                guard lock.withLock({ () -> Bool in defer { closed = true }; return !closed }) else { return }
                onEnd()
            }
        }
        reader.name = "elisctl.linestream.read"
        let writer = Thread { [self] in
            write()
            writerDone.signal()
        }
        writer.name = "elisctl.linestream.write"
        writer.start()
        reader.start()
    }

    /// The newline is included by the caller.
    func send(_ line: Data) {
        guard lock.withLock({ () -> Bool in
            if !stopping { outbox.append(line) }
            return !stopping
        }) else { return }
        writable.signal()
    }

    func resume() { resumed.signal() }

    /// Terminates the process or shuts the socket; onEnd does not run after it.
    func close() {
        lock.withLock { closed = true }
        stop()
    }

    private func stop() {
        guard lock.withLock({ () -> Bool in defer { stopping = true }; return !stopping }) else { return }
        switch transport {
        case .socket(let fd): shutdown(fd, SHUT_RDWR)
        case .process(let process, _, _): if process.isRunning { process.terminate() }
        }
        writable.signal()
        resumed.signal()
    }

    /// Returns at the peer's end, a read error, a line over the cap, or `close()`.
    private func read(_ onLine: @escaping (Data) -> Void) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard line.count <= Self.maxLine else { return }
                queue.async { [self] in
                    if !lock.withLock({ closed }) { onLine(line) }
                }
                resumed.wait()
                if lock.withLock({ stopping }) { return }
            }
            guard buffer.count <= Self.maxLine else { return }
            let count = chunk.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    private func write() {
        while true {
            writable.wait()
            guard let line = lock.withLock({ stopping ? nil : outbox.removeFirst() }) else { return }
            guard StreamBridge.sendAll(writeFD, line) else { return stop() }
        }
    }
}
#endif
