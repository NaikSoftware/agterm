import Foundation

/// One page shown on the phone; its fields sit beside `"t": "page"` in the line.
public struct PhonePage: Codable, Equatable, Sendable {
    public var id: String
    /// `file`, `url`, `content` or `forward` (a loopback page reached through the relay).
    public var kind: String
    /// A file page's absolute path on the origin.
    public var path: String?
    public var url: String?
    /// A file page's bridge adapter; a content page's HTML and script are fetched from `contentPath` and `scriptPath`.
    public var adapter: String?
    public var javascript: Bool
    public var chromeless: Bool
    public var browse: Bool
    public var hidden: Bool
    /// The identity strip's text.
    public var title: String
    public var sizePercent: Int?

    /// Reserved fetch paths the relay answers from memory as `res` chunks; never sent to the origin.
    /// No origin path lacks the leading `/`.
    public static let contentPath = "elis:content", scriptPath = "elis:script"

    public init(id: String, kind: String, path: String? = nil, url: String? = nil, adapter: String? = nil, javascript: Bool,
                chromeless: Bool, browse: Bool, hidden: Bool, title: String, sizePercent: Int? = nil) {
        self.id = id
        self.kind = kind
        self.path = path
        self.url = url
        self.adapter = adapter
        self.javascript = javascript
        self.chromeless = chromeless
        self.browse = browse
        self.hidden = hidden
        self.title = title
        self.sizePercent = sizePercent
    }
}

private enum PhonePageKey: String, CodingKey {
    case t, id, seq, action, sizePercent, mime, data, end, error, response, path, line
    case load, title, current, canGoBack, appliedSeq, hidden, dismissed
}

/// Relay to phone on a `present` channel.
public enum PhonePageDown: Codable, Equatable, Sendable {
    case page(PhonePage)
    /// `close`, `hide`, `show`, `reload`, `back`, `forward`, `resize` or `browser`; the phone ignores `browser` but applies its `seq`.
    case command(id: String, seq: Int, action: String, sizePercent: Int?)
    /// `data` holds at most `PageServeCodec.maxChunkBytes`.
    case res(id: String, seq: Int, mime: String?, data: Data?, end: Bool, error: String?)
    case reply(id: String, seq: Int, response: String?, error: String?)

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: PhonePageKey.self)
        let t = try c.decode(String.self, forKey: .t)
        switch t {
        case "page": self = .page(try PhonePage(from: decoder))
        case "command":
            self = .command(id: try c.decode(String.self, forKey: .id), seq: try c.decode(Int.self, forKey: .seq),
                            action: try c.decode(String.self, forKey: .action), sizePercent: try c.decodeIfPresent(Int.self, forKey: .sizePercent))
        case "res":
            self = .res(id: try c.decode(String.self, forKey: .id), seq: try c.decode(Int.self, forKey: .seq),
                        mime: try c.decodeIfPresent(String.self, forKey: .mime), data: try c.decodeIfPresent(Data.self, forKey: .data),
                        end: try c.decode(Bool.self, forKey: .end), error: try c.decodeIfPresent(String.self, forKey: .error))
        case "reply":
            self = .reply(id: try c.decode(String.self, forKey: .id), seq: try c.decode(Int.self, forKey: .seq),
                          response: try c.decodeIfPresent(String.self, forKey: .response), error: try c.decodeIfPresent(String.self, forKey: .error))
        default: throw DecodingError.dataCorruptedError(forKey: .t, in: c, debugDescription: "unknown page line \(t)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: PhonePageKey.self)
        switch self {
        case .page(let page):
            try c.encode("page", forKey: .t)
            try page.encode(to: encoder)
        case let .command(id, seq, action, sizePercent):
            try c.encode("command", forKey: .t)
            try c.encode(id, forKey: .id)
            try c.encode(seq, forKey: .seq)
            try c.encode(action, forKey: .action)
            try c.encodeIfPresent(sizePercent, forKey: .sizePercent)
        case let .res(id, seq, mime, data, end, error):
            try c.encode("res", forKey: .t)
            try c.encode(id, forKey: .id)
            try c.encode(seq, forKey: .seq)
            try c.encodeIfPresent(mime, forKey: .mime)
            try c.encodeIfPresent(data, forKey: .data)
            try c.encode(end, forKey: .end)
            try c.encodeIfPresent(error, forKey: .error)
        case let .reply(id, seq, response, error):
            try c.encode("reply", forKey: .t)
            try c.encode(id, forKey: .id)
            try c.encode(seq, forKey: .seq)
            try c.encodeIfPresent(response, forKey: .response)
            try c.encodeIfPresent(error, forKey: .error)
        }
    }
}

/// Phone to relay on a `present` channel.
public enum PhonePageUp: Codable, Equatable, Sendable {
    case fetch(id: String, seq: Int, path: String)
    case bridge(id: String, seq: Int, line: String)
    case state(id: String, load: String, title: String?, current: String?, canGoBack: Bool, appliedSeq: Int, hidden: Bool, error: String?)
    case closed(id: String, dismissed: Bool)

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: PhonePageKey.self)
        let t = try c.decode(String.self, forKey: .t)
        let id = try c.decode(String.self, forKey: .id)
        switch t {
        case "fetch": self = .fetch(id: id, seq: try c.decode(Int.self, forKey: .seq), path: try c.decode(String.self, forKey: .path))
        case "bridge": self = .bridge(id: id, seq: try c.decode(Int.self, forKey: .seq), line: try c.decode(String.self, forKey: .line))
        case "state":
            self = .state(id: id, load: try c.decode(String.self, forKey: .load), title: try c.decodeIfPresent(String.self, forKey: .title),
                          current: try c.decodeIfPresent(String.self, forKey: .current), canGoBack: try c.decode(Bool.self, forKey: .canGoBack),
                          appliedSeq: try c.decode(Int.self, forKey: .appliedSeq), hidden: try c.decode(Bool.self, forKey: .hidden),
                          error: try c.decodeIfPresent(String.self, forKey: .error))
        case "closed": self = .closed(id: id, dismissed: try c.decode(Bool.self, forKey: .dismissed))
        default: throw DecodingError.dataCorruptedError(forKey: .t, in: c, debugDescription: "unknown page line \(t)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: PhonePageKey.self)
        switch self {
        case let .fetch(id, seq, path):
            try c.encode("fetch", forKey: .t)
            try c.encode(id, forKey: .id)
            try c.encode(seq, forKey: .seq)
            try c.encode(path, forKey: .path)
        case let .bridge(id, seq, line):
            try c.encode("bridge", forKey: .t)
            try c.encode(id, forKey: .id)
            try c.encode(seq, forKey: .seq)
            try c.encode(line, forKey: .line)
        case let .state(id, load, title, current, canGoBack, appliedSeq, hidden, error):
            try c.encode("state", forKey: .t)
            try c.encode(id, forKey: .id)
            try c.encode(load, forKey: .load)
            try c.encodeIfPresent(title, forKey: .title)
            try c.encodeIfPresent(current, forKey: .current)
            try c.encode(canGoBack, forKey: .canGoBack)
            try c.encode(appliedSeq, forKey: .appliedSeq)
            try c.encode(hidden, forKey: .hidden)
            try c.encodeIfPresent(error, forKey: .error)
        case let .closed(id, dismissed):
            try c.encode("closed", forKey: .t)
            try c.encode(id, forKey: .id)
            try c.encode(dismissed, forKey: .dismissed)
        }
    }
}

public enum PhonePageCodec {
    /// Sorted keys and unescaped slashes, as `PhoneLinkFrame.json`; one line per message.
    public static func encode(_ line: PhonePageDown) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // shortcut: encoding cannot fail for these value types
        var data = (try? encoder.encode(line)) ?? Data()
        data.append(0x0A)
        return data
    }

    public static func decode(_ line: Data) throws -> PhonePageUp {
        try JSONDecoder().decode(PhonePageUp.self, from: line)
    }
}
