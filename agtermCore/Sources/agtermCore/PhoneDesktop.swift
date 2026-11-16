import Foundation

/// The Connect a Phone window's state in `<stateDir>/mobile/desktop.json`. An empty `host` follows the relay's best guess.
public struct PhoneDesktopState: Codable, Equatable, Sendable {
    public static let defaultPort = 8765
    public var on = false
    public var port = PhoneDesktopState.defaultPort
    public var host = ""

    public init(on: Bool = false, port: Int = PhoneDesktopState.defaultPort, host: String = "") {
        self.on = on
        self.port = port
        self.host = host
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        on = (try? c.decodeIfPresent(Bool.self, forKey: .on)) ?? false
        let port = (try? c.decodeIfPresent(Int.self, forKey: .port)) ?? Self.defaultPort
        self.port = (1...65535).contains(port) ? port : Self.defaultPort
        host = (try? c.decodeIfPresent(String.self, forKey: .host)) ?? ""
    }

    public static func mobileDirectory(_ stateDirectory: URL) -> URL {
        stateDirectory.appendingPathComponent("mobile", isDirectory: true)
    }

    private static func file(_ stateDirectory: URL) -> URL {
        mobileDirectory(stateDirectory).appendingPathComponent("desktop.json")
    }

    public static func load(stateDirectory: URL) -> PhoneDesktopState {
        guard let data = try? Data(contentsOf: file(stateDirectory)),
              let state = try? JSONDecoder().decode(PhoneDesktopState.self, from: data) else { return PhoneDesktopState() }
        return state
    }

    /// The directory also holds the pairing token and key, so it is made 0700 before anything is written.
    public func save(stateDirectory: URL) throws {
        let dir = Self.mobileDirectory(stateDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: Self.file(stateDirectory), options: .atomic)
    }
}

/// `agterm://pair?h=…&p=…` links printed by `agtermctl mobile serve`.
public enum PhonePairLink {
    private static let hostAllowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:[]")

    public static func host(of link: String) -> String? {
        URLComponents(string: link)?.queryItems?.first { $0.name == "h" }?.value
    }

    /// `link` with its `h` value replaced and every other byte untouched: a `URLComponents` round trip would
    /// decode `%2B`/`%27` in `n` and re-emit them bare, which the phone reads differently.
    public static func withHost(_ link: String, host: String) -> String {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, let query = link.range(of: "?"),
              let encoded = host.addingPercentEncoding(withAllowedCharacters: hostAllowed) else { return link }
        var pairs = link[query.upperBound...].split(separator: "&", omittingEmptySubsequences: false).map(String.init)
        guard let index = pairs.firstIndex(where: { $0.hasPrefix("h=") }) else { return link }
        pairs[index] = "h=" + encoded
        return link[..<query.upperBound] + pairs.joined(separator: "&")
    }
}

/// One line of `agtermctl mobile serve --no-qr` output.
public enum PhoneRelayLine: Equatable {
    /// A connection event worth showing, or any other stderr line (the last one is the error when the relay exits).
    case event(String)
    case other(String)

    public static func link(_ line: String) -> String? {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.hasPrefix("agterm://") ? line : nil
    }

    public static func stderr(_ line: String) -> PhoneRelayLine? {
        var line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        if line.hasPrefix("agtermctl: ") { line.removeFirst("agtermctl: ".count) }
        return isEvent(line) ? .event(line) : .other(line)
    }

    public static func isEvent(_ line: String) -> Bool {
        ["phone connected ", "phone disconnected ", "refused "].contains { line.hasPrefix($0) }
    }
}
