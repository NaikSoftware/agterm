import Foundation

/// Per-link send queues. Channels 0 and 1 need no credit and are never capped; opened channels have both.
public struct PhoneLinkScheduler: Sendable {
    public enum Enqueue: Equatable, Sendable { case queued, overflowed, closed }

    private let window: UInt32
    private let bufferLimit: Int
    private var queues: [UInt32: Data] = [:]
    private var credits: [UInt32: UInt32] = [:]
    /// Bytes sent on each vt channel since the phone's last CREDIT there; a reopen keeps it.
    private var sentSinceGrant: [UInt32: Int] = [:]
    private var opened: [UInt32] = []
    private var low: Set<UInt32> = []
    /// Normal frames sent in a row while a low channel could send; at `lowShareEvery` a low frame goes next.
    private var normalStreak = 0
    private static let lowShareEvery = 8
    private var cursor = 0

    public init(window: UInt32, bufferLimit: Int) {
        self.window = window
        self.bufferLimit = bufferLimit
    }

    public var pendingBytes: Int { queues.values.reduce(0) { $0 + $1.count } }
    public func pendingBytes(channel: UInt32) -> Int { queues[channel]?.count ?? 0 }

    public mutating func enqueue(channel: UInt32, _ bytes: Data) -> Enqueue {
        if channel < 2 {
            queues[channel, default: Data()].append(bytes)
            return .queued
        }
        guard credits[channel] != nil else { return .closed }
        if queues[channel, default: Data()].count + bytes.count > bufferLimit {
            queues[channel] = Data()
            return .overflowed
        }
        queues[channel, default: Data()].append(bytes)
        return .queued
    }

    /// Starts the channel at the initial window; reopening resets its queue and credit.
    /// A low channel is served when no other opened channel can send, and once after every 8 normal frames.
    public mutating func open(channel: UInt32, low: Bool = false) {
        guard channel >= 2 else { return }
        queues[channel] = nil
        credits[channel] = window
        if low { self.low.insert(channel) } else { self.low.remove(channel) }
        if !opened.contains(channel) { opened.append(channel) }
    }

    /// Whether a full window went out on `channel` since the phone's last CREDIT there (since open if none came).
    public func windowSpent(channel: UInt32) -> Bool { (sentSinceGrant[channel] ?? 0) >= Int(window) }

    public mutating func grant(channel: UInt32, bytes: UInt32) {
        guard channel >= 2, let current = credits[channel] else { return }
        sentSinceGrant[channel] = 0
        let (sum, overflow) = current.addingReportingOverflow(bytes)
        credits[channel] = overflow ? .max : sum
    }

    public mutating func close(channel: UInt32) {
        guard channel >= 2 else { return }
        queues[channel] = nil
        credits[channel] = nil
        sentSinceGrant[channel] = nil
        low.remove(channel)
        if let index = opened.firstIndex(of: channel) {
            opened.remove(at: index)
            if index < cursor { cursor -= 1 }
        }
    }

    public mutating func next(maxChunk: Int) -> PhoneLinkFrame? {
        let cap = min(maxChunk, PhoneLinkFrame.maxPayload)
        for channel: UInt32 in 0...1 {
            if let frame = take(channel: channel, limit: cap) { return frame }
        }
        if normalStreak >= Self.lowShareEvery, let frame = nextOpened(cap: cap, low: true) {
            normalStreak = 0
            return frame
        }
        if let frame = nextOpened(cap: cap, low: false) {
            normalStreak = lowCanSend ? normalStreak + 1 : 0
            return frame
        }
        normalStreak = 0
        return nextOpened(cap: cap, low: true)
    }

    private var lowCanSend: Bool {
        low.contains { (credits[$0] ?? 0) > 0 && !(queues[$0]?.isEmpty ?? true) }
    }

    private mutating func nextOpened(cap: Int, low isLow: Bool) -> PhoneLinkFrame? {
        for step in 0..<opened.count {
            let index = (cursor + step) % opened.count
            let channel = opened[index]
            guard low.contains(channel) == isLow else { continue }
            let limit = min(cap, Int(credits[channel] ?? 0))
            if let frame = take(channel: channel, limit: limit) {
                credits[channel, default: 0] -= UInt32(frame.payload.count)
                sentSinceGrant[channel, default: 0] += frame.payload.count
                cursor = (index + 1) % opened.count
                return frame
            }
        }
        return nil
    }

    private mutating func take(channel: UInt32, limit: Int) -> PhoneLinkFrame? {
        guard let queue = queues[channel], !queue.isEmpty, limit > 0 else { return nil }
        let count = min(limit, queue.count)
        let chunk = Data(queue.prefix(count))
        queues[channel] = Data(queue.dropFirst(count))
        return .data(channel: channel, chunk)
    }
}
