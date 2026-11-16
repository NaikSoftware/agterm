#if os(macOS)
import CoreBluetooth
import Foundation

/// The relay's Bluetooth transport: a BLE peripheral advertising the token's rotating service UUID, whose L2CAP
/// channels become phones of the relay. Every mutable property is touched on `relay.queue`, which is also
/// CoreBluetooth's.
final class MobileBluetooth: NSObject, CBPeripheralManagerDelegate, @unchecked Sendable {
    private let relay: MobileRelay
    private let token: String
    /// Authenticated Bluetooth phones at once; a handshake past it gets the busy frame. Links that passed the
    /// handshake but never authenticate (a replayed message 1) are the relay's unauthenticated cap's to evict.
    private let maxPhones: Int
    private let limits: BlePhoneLink.Limits
    private let status: @Sendable (String) -> Void
    private var shown: String?
    private var links: [ObjectIdentifier: BlePhoneLink] = [:]
    private var manager: CBPeripheralManager?
    private var psm: CBL2CAPPSM?
    private var service: CBMutableService?
    private var rotation: (any DispatchSourceTimer)?
    private var lock: Int32 = -1

    /// `status` gets `advertising` or `off (<reason>)`, once per change.
    init(relay: MobileRelay, token: String, maxPhones: Int = 8, limits: BlePhoneLink.Limits = .init(),
         status: @escaping @Sendable (String) -> Void) {
        self.relay = relay
        self.token = token
        self.maxPhones = maxPhones
        self.limits = limits
        self.status = status
    }

    /// Takes the per-state-directory lock and starts the peripheral; false when this relay will not offer
    /// Bluetooth. The lock is held for the life of the process.
    @discardableResult
    func start() -> Bool {
        let path = relay.settings.mobileDir + "/bluetooth.lock"
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            relay.settings.log("bluetooth: cannot open \(path): \(String(cString: strerror(errno)))")
            relay.queue.sync { report("off (unsupported)") }
            return false
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            relay.queue.sync { report("off (in use by another relay)") }
            return false
        }
        relay.queue.sync {
            lock = fd
            manager = CBPeripheralManager(delegate: self, queue: relay.queue)
        }
        return true
    }

    /// Serves one L2CAP channel's streams; `channel` is kept alive with them. Call on `relay.queue`.
    func accept(input: InputStream, output: OutputStream, holding channel: AnyObject?) {
        let link = BlePhoneLink(input: input, output: output, holding: channel, queue: relay.queue,
                                mobileDir: relay.settings.mobileDir, limits: limits) { [weak self] in
            guard let self else { return false }
            return relay.authenticatedPhones { $0 is BlePhoneLink } < maxPhones
        }
        link.onEnd = { [weak self] in self?.links[ObjectIdentifier($0)] = nil }
        links[ObjectIdentifier(link)] = link
        // the session's auth timeout and unauthenticated cap also cover a channel that never sends message 1
        relay.accept(link)
        link.start()
    }

    /// The radio went away: every Bluetooth phone is dropped, so its session gives back its grids. Call on `relay.queue`.
    func off(_ reason: String) {
        report("off (\(reason))")
        rotation?.cancel()
        rotation = nil
        if let psm { manager?.unpublishL2CAPChannel(psm) }
        psm = nil
        service = nil
        links.values.forEach { $0.drop() }
    }

    private func report(_ state: String) {
        guard state != shown else { return }
        shown = state
        status(state)
    }

    private func failed(_ step: String, _ error: any Error) {
        relay.settings.log("bluetooth \(step) failed: \(error.localizedDescription)")
        off("unsupported")
    }

    /// Registering or advertising failed: open channels and the PSM stay, and the next try comes in 30 s.
    /// Call on `relay.queue`.
    func advertisingFailed(_ step: String, _ error: any Error) {
        relay.settings.log("bluetooth \(step) failed: \(error.localizedDescription)")
        report("off (unsupported)")
        schedule(after: 30)
    }

    private func schedule(after delay: TimeInterval) {
        let rotation = DispatchSource.makeTimerSource(queue: relay.queue)
        rotation.schedule(wallDeadline: .now() + delay)
        rotation.setEventHandler { [weak self] in self?.advertise() }
        rotation.resume()
        self.rotation?.cancel()
        self.rotation = rotation
    }

    /// Registers the PSM characteristic under this epoch's UUID and advertises it, then again at the next boundary.
    /// Open channels are not touched.
    private func advertise() {
        guard let manager, let psm else { return }
        manager.stopAdvertising()
        if let service { manager.remove(service) }
        let now = Date()
        let epoch = BleIDs.epoch(at: now)
        let value = withUnsafeBytes(of: psm.littleEndian) { Data($0) }
        let characteristic = CBMutableCharacteristic(type: CBUUID(nsuuid: BleIDs.psmCharacteristic), properties: .read,
                                                     value: value, permissions: .readable)
        let service = CBMutableService(type: CBUUID(nsuuid: BleIDs.serviceUUID(token: token, epoch: epoch)), primary: true)
        service.characteristics = [characteristic]
        self.service = service
        manager.add(service)
        schedule(after: Double(epoch + 1) * BleIDs.epochSeconds - now.timeIntervalSince1970)
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            // the radio coming back finds the old channel and service gone; unverified on hardware, see Task 8
            peripheral.removeAllServices()
            peripheral.publishL2CAPChannel(withEncryption: false)
        case .poweredOff, .resetting: off("powered off")
        case .unauthorized: off("unauthorized")
        case .unsupported: off("unsupported")
        default: break
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: (any Error)?) {
        if let error { return failed("publish", error) }
        psm = PSM
        advertise()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: (any Error)?) {
        if let error { return advertisingFailed("service", error) }
        // the service UUID only: a local name would expose the Mac's name
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [service.uuid]])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: (any Error)?) {
        if let error { return advertisingFailed("advertising", error) }
        report("advertising")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: (any Error)?) {
        guard let channel, let input = channel.inputStream, let output = channel.outputStream else { return }
        accept(input: input, output: output, holding: channel)
    }
}

/// One L2CAP channel as a relay phone: the Noise handshake, then sealed frames of the line stream.
/// Protocol state lives on `queue`; the streams live on `StreamThread`.
final class BlePhoneLink: NSObject, PhoneTransportConnection, StreamDelegate, @unchecked Sendable {
    struct Limits: Sendable {
        /// Output not yet written; past it the phone is not reading and is dropped.
        var maxPending = 8 << 20
        /// How long a close waits for queued output to drain.
        var flushTimeout: TimeInterval = 5
        /// The spike saw an L2CAP stream stop reporting space mid-transfer, so pending output is also retried on a timer.
        var pumpInterval: TimeInterval = 0.02
    }

    private(set) var peerLabel = "bt"
    var onReceive: ((Data) -> Void)?
    var onClose: (() -> Void)?
    var onEnd: ((BlePhoneLink) -> Void)?
    private let queue: DispatchQueue
    private let mobileDir: String
    private let limits: Limits
    private let admit: () -> Bool
    private var framer = BleFramer()
    private var keys: BleTransportKeys?
    private var ended = false

    // stream thread only
    private let input: InputStream
    private let output: OutputStream
    /// The channel, and this link itself while its streams are open: a stream's delegate is not retained.
    private var held: [AnyObject] = []
    private var pending = Data()
    private var flushed = 0
    private var sends: [(end: Int, completion: () -> Void)] = []
    private var closing = false
    private var pumpTimer: Timer?

    /// `admit` says whether one more phone may pass the handshake.
    init(input: InputStream, output: OutputStream, holding channel: AnyObject?, queue: DispatchQueue, mobileDir: String,
         limits: Limits, admit: @escaping () -> Bool) {
        self.input = input
        self.output = output
        self.queue = queue
        self.mobileDir = mobileDir
        self.limits = limits
        self.admit = admit
        super.init()
        held = [channel, self].compactMap { $0 }
    }

    func start() {
        StreamThread.shared.perform { [self] in
            for stream in [input, output] as [Stream] {
                stream.delegate = self
                stream.schedule(in: .current, forMode: .default)
                stream.open()
            }
        }
    }

    // MARK: relay queue

    func send(_ data: Data, completion: @escaping () -> Void) {
        guard !ended, var sealing = keys else { return queue.async(execute: completion) }
        var wire = Data()
        do {
            // seal in call order on this queue: the nonce order is the wire order
            for offset in stride(from: 0, to: data.count, by: BleTransportKeys.maxChunk) {
                let start = data.startIndex + offset
                wire += BleFramer.frame(try sealing.seal(Data(data[start..<min(start + BleTransportKeys.maxChunk, data.endIndex)])))
            }
        } catch {
            queue.async(execute: completion)
            return drop()
        }
        keys = sealing
        write(wire, completion)
    }

    func close() {
        guard !ended else { return }
        ended = true
        onEnd?(self)
        StreamThread.shared.perform { [self] in
            closing = true
            guard !pending.isEmpty, !held.isEmpty else { return shut() }
            // a phone that stops reading cannot hold the channel open
            DispatchQueue.global().asyncAfter(deadline: .now() + limits.flushTimeout) { StreamThread.shared.perform { self.shut() } }
        }
    }

    /// The peer is gone or broke the link: closes after any reject frame drains, and tells the session.
    func drop() {
        close()
        onClose?()
    }

    private func received(_ data: Data) {
        for body in framer.push(data) {
            guard !ended else { return }
            guard keys != nil else {
                handshake(body)
                continue
            }
            do {
                if let plain = try keys?.open(body) { onReceive?(plain) }
            } catch {
                return drop()
            }
        }
    }

    /// Any handshake failure gets the wrong-key frame, so a stranger learns nothing about why.
    private func handshake(_ message: Data) {
        peerLabel = "bt:" + message.prefix(2).map { String(format: "%02x", $0) }.joined()
        guard let token = MobilePairing.currentToken(in: mobileDir),
              let accepted = try? BleResponder(psk: BleIDs.psk(token: token)).readInitiator(message) else { return reject(0x01) }
        guard admit() else { return reject(0x02) }
        keys = accepted.transport
        write(BleFramer.frame(accepted.reply)) {}
    }

    private func reject(_ code: UInt8) {
        write(BleFramer.frame(Data([code]))) {}
        drop()
    }

    private func write(_ bytes: Data, _ completion: @escaping () -> Void) {
        StreamThread.shared.perform { [self] in
            guard !held.isEmpty else { return queue.async(execute: completion) }
            pending += bytes
            sends.append((flushed + pending.count, completion))
            guard pending.count <= limits.maxPending else {
                shut()
                return queue.async { self.drop() }
            }
            pump()
        }
    }

    // MARK: stream thread

    func stream(_ stream: Stream, handle event: Stream.Event) {
        switch event {
        case .hasBytesAvailable: read()
        case .hasSpaceAvailable: pump()
        case .errorOccurred, .endEncountered:
            shut()
            queue.async { self.drop() }
        default: break
        }
    }

    private func read() {
        var bytes = [UInt8](repeating: 0, count: 16384)
        var data = Data()
        while input.hasBytesAvailable {
            let count = input.read(&bytes, maxLength: bytes.count)
            guard count > 0 else { break }
            data.append(bytes, count: count)
        }
        if !data.isEmpty { queue.async { self.received(data) } }
    }

    private func pump() {
        while !pending.isEmpty, output.hasSpaceAvailable {
            let count = pending.withUnsafeBytes { output.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: $0.count) }
            guard count > 0 else { break } // a failure arrives as an event
            pending.removeFirst(count)
            flushed += count
        }
        let done = sends.prefix { $0.end <= flushed }
        sends.removeFirst(done.count)
        done.forEach { queue.async(execute: $0.completion) }
        if closing, pending.isEmpty { return shut() }
        if pending.isEmpty {
            pumpTimer?.invalidate()
            pumpTimer = nil
        } else if pumpTimer == nil {
            let timer = Timer(timeInterval: limits.pumpInterval, repeats: true) { [weak self] _ in self?.pump() }
            RunLoop.current.add(timer, forMode: .default)
            pumpTimer = timer
        }
    }

    /// Closes the streams; every send still waiting completes, as the session's contract needs.
    private func shut() {
        guard !held.isEmpty else { return }
        pumpTimer?.invalidate()
        pumpTimer = nil
        for stream in [input, output] as [Stream] {
            stream.delegate = nil
            stream.close()
            stream.remove(from: .current, forMode: .default)
        }
        sends.forEach { queue.async(execute: $0.completion) }
        sends = []
        pending = Data()
        held = []
    }
}

/// NSStream events need a run loop, and serve parks the main thread in `dispatchMain`: one thread runs the run
/// loop every Bluetooth link's streams are scheduled on.
private final class StreamThread: @unchecked Sendable {
    static let shared = StreamThread()
    private var loop: CFRunLoop?

    private init() {
        let started = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            loop = CFRunLoopGetCurrent()
            RunLoop.current.add(Port(), forMode: .default) // a run loop without a source returns at once
            started.signal()
            while true { RunLoop.current.run() }
        }
        thread.name = "agtermctl.mobile.bluetooth"
        thread.start()
        started.wait()
    }

    /// Blocks run in order on the stream thread, which is what serializes the stream-side state.
    func perform(_ block: @escaping () -> Void) {
        nonisolated(unsafe) let work = block
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { work() }
        CFRunLoopWakeUp(loop)
    }
}
#endif
