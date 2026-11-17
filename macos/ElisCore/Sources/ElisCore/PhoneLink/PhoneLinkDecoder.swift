import Foundation

public enum PhoneLinkError: Error, Equatable, Sendable {
    case unknownKind(UInt8)
    case payloadTooLarge(UInt32)
    case badPayload(PhoneLinkKind, Int)
}

/// Reassembles frames from arbitrary byte chunks. After an error it is spent and rethrows it on every feed.
public struct PhoneLinkDecoder: Sendable {
    private var buffer = Data()
    private var failure: PhoneLinkError?

    public init() {}

    public mutating func feed(_ bytes: Data) throws(PhoneLinkError) -> [PhoneLinkFrame] {
        if let failure { throw failure }
        buffer.append(bytes)
        var frames: [PhoneLinkFrame] = []
        var offset = 0
        do {
            while let frame = try Self.next(in: buffer, at: &offset) { frames.append(frame) }
        } catch {
            failure = error
            buffer = Data()
            throw error
        }
        buffer = Data(buffer.dropFirst(offset))
        return frames
    }

    private static func next(in data: Data, at offset: inout Int) throws(PhoneLinkError) -> PhoneLinkFrame? {
        let start = data.startIndex + offset
        guard data.endIndex - start >= PhoneLinkFrame.headerSize else { return nil }
        guard let kind = PhoneLinkKind(rawValue: data[start]) else { throw .unknownKind(data[start]) }
        let channel = be32(data, start + 1)
        let length = be32(data, start + 5)
        guard length <= UInt32(PhoneLinkFrame.maxPayload) else { throw .payloadTooLarge(length) }
        let end = start + PhoneLinkFrame.headerSize + Int(length)
        guard data.endIndex >= end else { return nil }
        let fixed: Int? = switch kind {
        case .credit, .resize, .grid: 4
        case .resync: 0
        case .open, .opened, .data, .lead, .close: nil
        }
        if let fixed, fixed != Int(length) { throw .badPayload(kind, Int(length)) }
        offset = end - data.startIndex
        return PhoneLinkFrame(kind: kind, channel: channel, payload: Data(data[(start + PhoneLinkFrame.headerSize)..<end]))
    }

    private static func be32(_ data: Data, _ index: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 << 8 | UInt32(data[index + $1]) }
    }
}
