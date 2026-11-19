import Foundation

/// The Connect a Phone window's state in `<stateDir>/mobile/desktop.json`. An empty `host` follows the relay's best guess.
public struct PhoneDesktopState: Codable, Equatable, Sendable {
    public static let defaultPort = 8765
    /// The one port rule for the window, `phone.port`, `elisctl phone port` and `mobile serve --port`.
    public static let portRange = 1024...65535
    public static let portError = "port must be 1024...65535"
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
        self.port = Self.portRange.contains(port) ? port : Self.defaultPort
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

/// `elis://pair?h=…&p=…` links printed by `elisctl mobile serve`.
public enum PhonePairLink {
    private static let hostAllowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:[]")

    public static func host(of link: String) -> String? {
        URLComponents(string: link)?.queryItems?.first { $0.name == "h" }?.value
    }

    /// `link` with its `h` value replaced and every other byte untouched: a `URLComponents` round trip would
    /// decode `%2B`/`%27` in `n` and re-emit them bare, which the phone reads differently.
    /// A Bluetooth-only link has no `h`; with `port` it gains `h` and `p` (adb reverse to 127.0.0.1 needs them).
    public static func withHost(_ link: String, host: String, port: Int? = nil) -> String {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, let query = link.range(of: "?"),
              let encoded = host.addingPercentEncoding(withAllowedCharacters: hostAllowed) else { return link }
        var pairs = link[query.upperBound...].split(separator: "&", omittingEmptySubsequences: false).map(String.init)
        if let index = pairs.firstIndex(where: { $0.hasPrefix("h=") }) {
            pairs[index] = "h=" + encoded
        } else {
            guard let port else { return link }
            let hasPort = pairs.contains { $0.hasPrefix("p=") }
            pairs.insert(contentsOf: ["h=" + encoded] + (hasPort ? [] : ["p=\(port)"]), at: 0)
        }
        return link[..<query.upperBound] + pairs.joined(separator: "&")
    }
}

/// One line of `elisctl mobile serve --no-qr` output.
public enum PhoneRelayLine: Equatable {
    /// A connection event worth showing, or any other stderr line (the last one is the error when the relay exits).
    case event(String)
    case other(String)
    /// `bluetooth: advertising | off (<reason>)`, as the `phone.status` value.
    case bluetooth(String)
    /// `phone attached|detached from <ip> pane <paneID>`: the phone opened or closed a pane. Not relay status.
    case viewer(attached: Bool, ip: String, paneID: String)
    /// `phone leads|released from <ip> pane <paneID>`: the phone took or gave up a pane's lead.
    case lead(leading: Bool, ip: String, paneID: String)

    /// address reads a `viewer` or `lead` line's `ip`, where the relay prints `-` for an unknown address, as nil.
    public static func address(_ ip: String) -> String? { ip == "-" ? nil : ip }

    /// Serve's `off (<reason>)` reasons and the value each one reads back as.
    public static let bluetoothReasons = ["powered off": "off", "unauthorized": "unauthorized", "unsupported": "unsupported",
                                          "in use by another relay": "busy", "disabled": "disabled"]

    /// The window's text for a `bluetooth` value.
    public static func bluetoothText(_ value: String) -> String {
        if value == "advertising" { return "Advertising" }
        if value == "starting" { return "Starting…" }
        return "Off: " + (bluetoothReasons.first { $0.value == value }?.key ?? value)
    }

    /// What serve exits with when `mobile reset` replaced the token it printed; the window restarts it once.
    public static let pairingReset = "the pairing was reset; restart to show the new code"

    public static func link(_ line: String) -> String? {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.hasPrefix("elis://") ? line : nil
    }

    public static func stderr(_ line: String) -> PhoneRelayLine? {
        var line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        if line.hasPrefix("elisctl: ") { line.removeFirst("elisctl: ".count) }
        if line == "bluetooth: advertising" { return .bluetooth("advertising") }
        if line.hasPrefix("bluetooth: off ("), line.hasSuffix(")"),
           let value = bluetoothReasons[String(line.dropFirst("bluetooth: off (".count).dropLast())] {
            return .bluetooth(value)
        }
        let panes: [(String, (String, String) -> PhoneRelayLine)] = [
            ("phone attached from ", { .viewer(attached: true, ip: $0, paneID: $1) }),
            ("phone detached from ", { .viewer(attached: false, ip: $0, paneID: $1) }),
            ("phone leads from ", { .lead(leading: true, ip: $0, paneID: $1) }),
            ("phone released from ", { .lead(leading: false, ip: $0, paneID: $1) }),
        ]
        for (prefix, make) in panes where line.hasPrefix(prefix) {
            let parts = line.dropFirst(prefix.count).components(separatedBy: " pane ")
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty { return make(parts[0], parts[1]) }
        }
        return isEvent(line) ? .event(line) : .other(line)
    }

    public static func isEvent(_ line: String) -> Bool {
        ["phone connected ", "phone disconnected ", "refused "].contains { line.hasPrefix($0) }
    }
}
