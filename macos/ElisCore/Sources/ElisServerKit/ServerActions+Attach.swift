import Foundation
import ElisCore

extension ServerActions {
    /// sessionAttach maps a pane to a phone viewer attach on the server's own zmx. ElisCore shapes the argv.
    public func sessionAttach(target: String?, pane: StatusPane, paneID: String?, window: String?) async -> ControlResponse {
        await sessionAttach(target: target, pane: pane, paneID: paneID, claim: false, window: window)
    }

    public func sessionAttach(target: String?, pane: StatusPane, paneID: String?, claim: Bool, window: String?) async -> ControlResponse {
        withSession(target, window: window) { session in
            var role = pane
            if let paneID, !paneID.isEmpty {
                // the dispatcher always passes a pane, so an unknown token must refuse here, not fall back to it
                guard let resolved = session.paneRole(forToken: paneID), resolved != .scratch else {
                    return ControlResponse(ok: false, error: "unknown pane id: \(paneID)")
                }
                role = resolved
            }
            guard role != .right || session.hasSplit else { return ControlResponse(ok: false, error: "session has no split pane") }
            let identity: UUID
            switch daemonPane(of: session, token: nil, pane: role) {
            case .success(let resolved): identity = resolved.identity
            case .failure(let refusal): return refusal.response
            }
            let endpoint = ControlZmxEndpoint(executable: panes.configuration.zmxPath,
                                              socketDirectory: panes.configuration.zmxSocketDirectory)
            // a daemon-backed pane's tree token is its identity
            let source = LivePaneSource.local(endpoint: endpoint, daemon: panes.daemonName(for: identity))
            let origin = ControlAttachOrigin(session: session.id.uuidString, pane: identity.uuidString, host: nil)
            guard let attach = try? claim ? ControlAttach.claimer(source, paneID: identity.uuidString, origin: origin)
                                          : ControlAttach.viewer(source, paneID: identity.uuidString, origin: origin) else {
                return ControlResponse(ok: false, error: "\(target ?? "active") is not a Live session")
            }
            return ControlResponse(ok: true, result: ControlResult(attach: attach))
        }
    }
}
