import Foundation

/// Where a pane's zmx daemon runs, for a phone viewer attaching to it.
public enum LivePaneSource: Equatable, Sendable {
    case local(endpoint: ControlZmxEndpoint, daemon: String)
    case remote(host: String, endpoint: ControlZmxEndpoint, daemon: String)
}

/// A command the relay runs to read a pane's VT stream, and the pane it belongs to.
public struct ControlAttach: Codable, Sendable, Equatable {
    public let argv: [String]
    /// The token `tree` reports as `surfaces[].paneID`.
    public let paneID: String
    /// Runs `zmx screen` for the same daemon, for the grid; empty from an app that predates it.
    public let screen: [String]
    /// True when both commands go through ssh to another machine.
    public let remote: Bool

    public init(argv: [String], paneID: String, screen: [String] = [], remote: Bool = false) {
        self.argv = argv
        self.paneID = paneID
        self.screen = screen
        self.remote = remote
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        argv = try container.decode([String].self, forKey: .argv)
        paneID = try container.decode(String.self, forKey: .paneID)
        screen = try container.decodeIfPresent([String].self, forKey: .screen) ?? []
        remote = try container.decodeIfPresent(Bool.self, forKey: .remote) ?? false
    }

    /// A passive attach: it never leads and starts from the visible screen.
    public static func viewer(_ source: LivePaneSource, paneID: String) throws -> ControlAttach {
        switch source {
        case let .local(endpoint, daemon):
            return ControlAttach(argv: try RemoteSession.zmxAttachArguments(endpoint: endpoint, daemon: daemon, lead: .viewer),
                                 paneID: paneID, screen: try RemoteSession.zmxScreenArguments(endpoint: endpoint, daemon: daemon))
        case let .remote(host, endpoint, daemon):
            // shortcut: each phone attach opens its own ssh connection; lease a pool channel released on phone.detached if connection count matters.
            let attach = try RemoteSession.attachCommand(host: host, endpoint: endpoint, daemon: daemon, lead: .viewer)
            return ControlAttach(argv: RemoteSession.keepingAlive(attach), paneID: paneID,
                                 screen: try RemoteSession.screenCommand(host: host, endpoint: endpoint, daemon: daemon),
                                 remote: true)
        }
    }
}
