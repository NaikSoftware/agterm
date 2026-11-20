#if os(macOS)
import Darwin
import Foundation
import ElisCore

/// One `forward` channel: a TCP connection to a forwarded page's loopback address. Bytes from the phone are written
/// under a receive window and credited back; the server's bytes are read one read at a time, the next only while the
/// channel's queue is under `PhoneLinkPresenter.highWater`. Every method and callback runs on the relay queue; the
/// connect, the reads and the writes run off it.
final class PhoneLinkForward: @unchecked Sendable {
    /// How the forward reaches its link; all run on the relay queue.
    struct Link {
        /// Sends a frame that bypasses the scheduler (OPENED, CLOSE).
        let frame: (PhoneLinkFrame) -> Void
        /// Queues the server's bytes on the channel, under the phone's credit.
        let output: (Data) -> PhoneLinkScheduler.Enqueue
        /// Bytes of the channel waiting in the scheduler.
        let pending: () -> Int
        /// Sends CREDIT for `bytes`; `sent` runs once the frame has gone out.
        let credit: (_ bytes: UInt32, _ sent: @escaping () -> Void) -> Void
        /// The channel is over: the link forgets this forward.
        let ended: () -> Void
    }

    /// Bytes the phone may send ahead of CREDIT.
    static let window = 65536
    static let maxForwards = 16
    static let connectTimeout: TimeInterval = 5
    static let readSize = 16384
    static let flushGrace: TimeInterval = 2

    let channel: UInt32
    private let host: String
    private let port: UInt16
    private let queue: DispatchQueue
    private let link: Link
    private let writes: DispatchQueue
    /// Guards `fd` between a stop's shutdown and the one close, which runs on `writes` after the reader has ended.
    private let lock = NSLock()
    private var fd: Int32 = -1
    private let permit = DispatchSemaphore(value: 0)
    private var connected = false
    /// Phone bytes that came before the connect finished, written in order once it has.
    private var early: [Data] = []
    /// The reader waits for `drained()`.
    private var parked = false
    /// The server ended; CLOSE goes out once the channel's queue is empty.
    private var serverEnded = false
    private var stopped = false
    private var unacknowledged = 0
    private var owed = 0
    private var crediting = false

    init(channel: UInt32, host: String, port: UInt16, queue: DispatchQueue, link: Link) {
        self.channel = channel
        self.host = host
        self.port = port
        self.queue = queue
        self.link = link
        // shortcut: a write blocks a GCD thread while the server stops reading (`window` bounds it); use a Thread if forwards multiply
        writes = DispatchQueue(label: "phone-link-forward-writes")
    }

    func start() {
        let (host, port) = (host, port)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Self.connect(host: host, port: port, timeout: Self.connectTimeout)
            queue.async { [self] in opened(result) }
        }
    }

    /// Past `window` unacknowledged bytes the channel closes.
    func input(_ bytes: Data) {
        guard !stopped else { return }
        unacknowledged += bytes.count
        if unacknowledged > Self.window { return close(reason: "input overflow") }
        guard connected else { return early.append(bytes) }
        write(bytes)
    }

    /// The channel's queue went down: reads resume under `highWater`, and a server's end closes once it is empty.
    func drained() {
        guard !stopped else { return }
        if serverEnded {
            if link.pending() == 0 { close(reason: "closed") }
        } else if parked, link.pending() < PhoneLinkPresenter.highWater {
            parked = false
            permit.signal()
        }
    }

    /// Ends the forward without a word to the phone. Bytes the phone sent before go out first, unless the server stops
    /// reading them for `flushGrace`.
    func stop() {
        guard !stopped else { return }
        stopped = true
        early = []
        writes.async { [self] in shutdownSocket() }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.flushGrace) { [self] in shutdownSocket() }
    }

    /// Wakes a blocked read or write; a reader parked on the permit then reads the end.
    private func shutdownSocket() {
        lock.withLock { if fd >= 0 { UnixSocket.shutdown(fd) } }
        permit.signal()
    }

    private func opened(_ result: Result<Int32, SocketClientError>) {
        let socket: Int32
        switch result {
        case .failure(let error):
            guard !stopped else { return }
            return refuse("could not connect: \(error.description)")
        case .success(let fd):
            guard !stopped else { _ = Darwin.close(fd); return }
            socket = fd
        }
        lock.withLock { fd = socket }
        connected = true
        link.frame(.json(.opened, channel: channel, PhoneLinkOpened()))
        early.forEach(write)
        early = []
        let thread = Thread { [self] in readUntilEnd(socket) }
        thread.name = "phone-link-forward-reader"
        thread.start()
    }

    /// Reads one chunk per permit; the socket is closed here, after the last read and every queued write.
    private func readUntilEnd(_ socket: Int32) {
        var buffer = [UInt8](repeating: 0, count: Self.readSize)
        while true {
            let count = read(socket, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            let bytes = Data(buffer[0..<count])
            queue.async { [self] in received(bytes) }
            permit.wait()
        }
        queue.async { [self] in
            serverEnded = true
            drained()
        }
        writes.async { [self] in
            lock.withLock {
                Darwin.close(fd)
                fd = -1
            }
        }
    }

    private func received(_ bytes: Data) {
        guard !stopped else { return }
        switch link.output(bytes) {
        case .overflowed: return close(reason: "overflow")
        case .closed: return stop()
        case .queued: break
        }
        parked = true
        drained()
    }

    private func write(_ bytes: Data) {
        writes.async { [self] in
            // stable here: only this queue closes it
            let socket = lock.withLock { fd }
            var offset = 0
            while socket >= 0, offset < bytes.count {
                let count = bytes.withUnsafeBytes { UnixSocket.write(socket, $0.baseAddress! + offset, bytes.count - offset) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                offset += count
            }
            let total = offset
            queue.async { [self] in written(total) }
        }
    }

    private func written(_ count: Int) {
        guard !stopped, count > 0 else { return }
        owed += count
        sendCredit()
    }

    private func sendCredit() {
        guard !stopped, !crediting, owed > 0 else { return }
        let bytes = owed
        owed = 0
        unacknowledged -= bytes
        crediting = true
        link.credit(UInt32(bytes)) { [weak self] in
            self?.crediting = false
            self?.sendCredit()
        }
    }

    private func refuse(_ message: String) {
        stop()
        link.frame(.json(.opened, channel: channel, PhoneLinkOpened(error: message)))
        link.ended()
    }

    private func close(reason: String) {
        stop()
        link.frame(.json(.close, channel: channel, PhoneLinkClose(reason: reason)))
        link.ended()
    }

    /// Tries each address `host` resolves to, so `localhost` reaches a server bound to only one of `::1` and `127.0.0.1`.
    static func connect(host: String, port: UInt16, timeout: TimeInterval) -> Result<Int32, SocketClientError> {
        var hints = addrinfo(ai_flags: AI_NUMERICSERV, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        let resolved = getaddrinfo(host, String(port), &hints, &list)
        guard resolved == 0 else { return .failure(SocketClientError(String(cString: gai_strerror(resolved)))) }
        defer { freeaddrinfo(list) }
        let deadline = Date().addingTimeInterval(timeout)
        var failure = "no address"
        var entry = list
        while let info = entry?.pointee {
            entry = info.ai_next
            let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            guard fd >= 0 else { continue }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var error = Darwin.connect(fd, info.ai_addr, info.ai_addrlen) == 0 ? 0 : errno
            if error == EINPROGRESS {
                var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let wait = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
                if poll(&poller, 1, wait) == 1 {
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
                } else {
                    error = ETIMEDOUT
                }
            }
            if error == 0 {
                _ = fcntl(fd, F_SETFL, 0)
                return .success(fd)
            }
            failure = String(cString: strerror(error))
            Darwin.close(fd)
        }
        return .failure(SocketClientError(failure))
    }
}
#endif
