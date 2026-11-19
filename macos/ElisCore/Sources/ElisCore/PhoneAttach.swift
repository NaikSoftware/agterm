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
    /// A claiming attach's `ZMX_MANAGED` value, which its zmx role reports echo; nil for a viewer.
    public let nonce: String?

    public init(argv: [String], paneID: String, screen: [String] = [], remote: Bool = false, nonce: String? = nil) {
        self.argv = argv
        self.paneID = paneID
        self.screen = screen
        self.remote = remote
        self.nonce = nonce
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        argv = try container.decode([String].self, forKey: .argv)
        paneID = try container.decode(String.self, forKey: .paneID)
        screen = try container.decodeIfPresent([String].self, forKey: .screen) ?? []
        remote = try container.decodeIfPresent(Bool.self, forKey: .remote) ?? false
        nonce = try container.decodeIfPresent(String.self, forKey: .nonce)
    }

    /// A passive attach: it never leads and starts from the visible screen.
    public static func viewer(_ source: LivePaneSource, paneID: String) throws -> ControlAttach {
        try make(source, paneID: paneID, lead: .viewer, nonce: nil)
    }

    /// Takes the lead from whichever client holds it; its own output is unused, so it skips the scrollback.
    public static func claimer(_ source: LivePaneSource, paneID: String) throws -> ControlAttach {
        let lead = ZmxLeadAttachment(claim: true, screenOnly: true)
        return try make(source, paneID: paneID, lead: lead, nonce: lead.nonce)
    }

    private static func make(_ source: LivePaneSource, paneID: String, lead: ZmxLeadAttachment, nonce: String?) throws -> ControlAttach {
        switch source {
        case let .local(endpoint, daemon):
            return ControlAttach(argv: try RemoteSession.zmxAttachArguments(endpoint: endpoint, daemon: daemon, lead: lead),
                                 paneID: paneID, screen: try RemoteSession.zmxScreenArguments(endpoint: endpoint, daemon: daemon),
                                 nonce: nonce)
        case let .remote(host, endpoint, daemon):
            // shortcut: each phone attach opens its own ssh connection; lease a pool channel released on phone.detached if connection count matters.
            let attach = try RemoteSession.attachCommand(host: host, endpoint: endpoint, daemon: daemon, lead: lead)
            return ControlAttach(argv: RemoteSession.keepingAlive(attach), paneID: paneID,
                                 screen: try RemoteSession.screenCommand(host: host, endpoint: endpoint, daemon: daemon),
                                 remote: true, nonce: nonce)
        }
    }
}
