import Foundation

/// Per-link send queues. Channels 0 and 1 need no credit and are never capped; opened channels have both.
public struct PhoneLinkScheduler: Sendable {
    public enum Enqueue: Equatable, Sendable { case queued, overflowed }

    private let window: UInt32
    private let bufferLimit: Int
    private var queues: [UInt32: Data] = [:]
    private var credits: [UInt32: UInt32] = [:]
    private var opened: [UInt32] = []
    private var cursor = 0

    public init(window: UInt32, bufferLimit: Int) {
        self.window = window
        self.bufferLimit = bufferLimit
    }

    public var pendingBytes: Int { queues.values.reduce(0) { $0 + $1.count } }

    public mutating func enqueue(channel: UInt32, _ bytes: Data) -> Enqueue {
        if channel < 2 {
            queues[channel, default: Data()].append(bytes)
            return .queued
        }
        track(channel)
        if queues[channel, default: Data()].count + bytes.count > bufferLimit {
            queues[channel] = Data()
            return .overflowed
        }
        queues[channel, default: Data()].append(bytes)
        return .queued
    }

    public mutating func grant(channel: UInt32, bytes: UInt32) {
        guard channel >= 2 else { return }
        track(channel)
        let (sum, overflow) = credits[channel, default: window].addingReportingOverflow(bytes)
        credits[channel] = overflow ? .max : sum
    }

    public mutating func close(channel: UInt32) {
        queues[channel] = nil
        credits[channel] = nil
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
        for step in 0..<opened.count {
            let index = (cursor + step) % opened.count
            let channel = opened[index]
            let limit = min(cap, Int(credits[channel] ?? 0))
            if let frame = take(channel: channel, limit: limit) {
                credits[channel, default: 0] -= UInt32(frame.payload.count)
                cursor = (index + 1) % opened.count
                return frame
            }
        }
        return nil
    }

    private mutating func track(_ channel: UInt32) {
        guard credits[channel] == nil else { return }
        credits[channel] = window
        opened.append(channel)
    }

    private mutating func take(channel: UInt32, limit: Int) -> PhoneLinkFrame? {
        guard let queue = queues[channel], !queue.isEmpty, limit > 0 else { return nil }
        let count = min(limit, queue.count)
        let chunk = Data(queue.prefix(count))
        queues[channel] = Data(queue.dropFirst(count))
        return .data(channel: channel, chunk)
    }
}
