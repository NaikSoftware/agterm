import Foundation

public enum PhoneLinkKind: UInt8, Sendable, CaseIterable {
    case open = 1, opened, data, credit, resize, grid, resync, lead, close
}

/// One mux frame: kind (1) | channel (4, big-endian) | payload length (4, big-endian) | payload.
public struct PhoneLinkFrame: Equatable, Sendable {
    public static let maxPayload = 65536
    public static let headerSize = 9

    public let kind: PhoneLinkKind
    public let channel: UInt32
    public let payload: Data

    public init(kind: PhoneLinkKind, channel: UInt32, payload: Data) {
        self.kind = kind
        self.channel = channel
        self.payload = payload
    }

    /// Does not validate; the decoder does.
    public func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + payload.count)
        out.append(kind.rawValue)
        out.append(contentsOf: Self.be32(channel))
        out.append(contentsOf: Self.be32(UInt32(truncatingIfNeeded: payload.count)))
        out.append(payload)
        return out
    }

    public static func data(channel: UInt32, _ bytes: Data) -> PhoneLinkFrame {
        PhoneLinkFrame(kind: .data, channel: channel, payload: bytes)
    }

    public static func credit(channel: UInt32, bytes: UInt32) -> PhoneLinkFrame {
        PhoneLinkFrame(kind: .credit, channel: channel, payload: Data(be32(bytes)))
    }

    public static func grid(channel: UInt32, cols: UInt16, rows: UInt16) -> PhoneLinkFrame {
        PhoneLinkFrame(kind: .grid, channel: channel, payload: Data(be16(cols) + be16(rows)))
    }

    public static func resize(channel: UInt32, cols: UInt16, rows: UInt16) -> PhoneLinkFrame {
        PhoneLinkFrame(kind: .resize, channel: channel, payload: Data(be16(cols) + be16(rows)))
    }

    public static func resync(channel: UInt32) -> PhoneLinkFrame {
        PhoneLinkFrame(kind: .resync, channel: channel, payload: Data())
    }

    private static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    private static func be16(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xff)]
    }
}
