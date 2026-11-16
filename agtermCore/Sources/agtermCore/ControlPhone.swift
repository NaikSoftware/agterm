import Foundation

/// ControlPhoneStatus is the phone relay as `phone.*` answers it. `link` holds the pairing token, so only
/// `phone.status` fills it, and `tree` carries `readback`.
public struct ControlPhoneStatus: Codable, Sendable, Equatable {
    public var on: Bool
    public var listening: Bool
    public var port: Int
    /// The address the link names: the fixed one, or the relay's best guess while `host` follows the network.
    public var host: String
    public var hosts: [String]?
    public var lastEvent: String?
    /// Why the relay is not listening.
    public var error: String?
    public var link: String?
    /// `advertising|off|unauthorized|unsupported|busy|disabled` from serve's last Bluetooth line; nil while no relay runs.
    /// A string, not an enum, so an older CLI still decodes a value added later.
    public var bluetooth: String?

    public init(on: Bool, listening: Bool, port: Int, host: String, hosts: [String]? = nil,
                lastEvent: String? = nil, error: String? = nil, link: String? = nil, bluetooth: String? = nil) {
        self.on = on
        self.listening = listening
        self.port = port
        self.host = host
        self.hosts = hosts
        self.lastEvent = lastEvent
        self.error = error
        self.link = link
        self.bluetooth = bluetooth
    }

    public var readback: ControlPhoneStatus {
        ControlPhoneStatus(on: on, listening: listening, port: port, host: host, bluetooth: bluetooth)
    }
}

public extension PhoneRelayLine {
    /// The control event behind a relay stderr line (the `agtermctl: ` prefix already removed), with the phone's address.
    static func controlEvent(_ line: String) -> (kind: ControlEventKind, ip: String)? {
        let forms: [(String, ControlEventKind)] = [("phone connected from ", .phoneConnected),
                                                  ("phone disconnected from ", .phoneDisconnected),
                                                  ("refused ", .phoneRefused)]
        for (prefix, kind) in forms where line.hasPrefix(prefix) {
            // `refused <ip>: <reason>`; an IPv6 address holds colons but never ": "
            let ip = line.dropFirst(prefix.count).components(separatedBy: ": ")[0]
            return ip.isEmpty ? nil : (kind, ip)
        }
        return nil
    }
}
