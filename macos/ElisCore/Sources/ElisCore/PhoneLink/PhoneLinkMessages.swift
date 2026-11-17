import Foundation

public struct PhoneLinkOpen: Codable, Equatable, Sendable {
    public var type: String
    public var target: String
    public var pane: String?
    public var claim: Bool?
    public var cols: UInt16?
    public var rows: UInt16?

    public init(type: String, target: String, pane: String? = nil, claim: Bool? = nil, cols: UInt16? = nil, rows: UInt16? = nil) {
        self.type = type
        self.target = target
        self.pane = pane
        self.claim = claim
        self.cols = cols
        self.rows = rows
    }
}

public struct PhoneLinkOpened: Codable, Equatable, Sendable {
    public var cols: UInt16?
    public var rows: UInt16?
    public var error: String?

    public init(cols: UInt16? = nil, rows: UInt16? = nil, error: String? = nil) {
        self.cols = cols
        self.rows = rows
        self.error = error
    }
}

public struct PhoneLinkLead: Codable, Equatable, Sendable {
    public var role: String

    public init(role: String) { self.role = role }
}

public struct PhoneLinkClose: Codable, Equatable, Sendable {
    public var reason: String

    public init(reason: String) { self.reason = reason }
}

public extension PhoneLinkFrame {
    /// Sorted keys and unescaped slashes keep the bytes identical to the Dart encoder's.
    static func json<T: Encodable>(_ kind: PhoneLinkKind, channel: UInt32, _ value: T) -> PhoneLinkFrame {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // shortcut: the payload types are plain Codable structs, so encoding cannot fail
        let payload = (try? encoder.encode(value)) ?? Data()
        return PhoneLinkFrame(kind: kind, channel: channel, payload: payload)
    }

    func decodeJSON<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: payload)
    }
}

public enum PhoneLinkUpgrade {
    public static let request = Data("{\"mux\":1}\n".utf8)
    public static let answer = Data("{\"ok\":true,\"mux\":1}\n".utf8)

    public static func isRequest(_ line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let mux = object["mux"] as? Int else { return false }
        return mux == 1
    }
}
