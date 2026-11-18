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

    public init(argv: [String], paneID: String) {
        self.argv = argv
        self.paneID = paneID
    }

    /// A passive attach: it never leads and starts from the visible screen.
    public static func viewer(_ source: LivePaneSource, paneID: String) throws -> ControlAttach {
        let argv: [String]
        switch source {
        case let .local(endpoint, daemon):
            argv = try RemoteSession.zmxAttachArguments(endpoint: endpoint, daemon: daemon, lead: .viewer)
        case let .remote(host, endpoint, daemon):
            // shortcut: each phone attach opens its own ssh connection; lease a pool channel released on phone.detached if connection count matters.
            argv = try RemoteSession.attachCommand(host: host, endpoint: endpoint, daemon: daemon, lead: .viewer)
        }
        return ControlAttach(argv: argv, paneID: paneID)
    }
}
