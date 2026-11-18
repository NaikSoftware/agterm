import ElisCore
import Foundation

extension ControlServer {
    /// sessionAttach maps a Live pane to a phone viewer attach: this Mac's zmx, an attached row's origin, or a
    /// server window row's catalog pane. ElisCore shapes the argv.
    func sessionAttach(target: String?, pane: StatusPane, paneID: String?, window: String?) async -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "session not realized")
            }
            var role = pane
            if let paneID, !paneID.isEmpty {
                // the dispatcher always passes a pane, so an unknown token must refuse here, not fall back to it
                guard let resolved = session.paneRole(forToken: paneID), resolved != .scratch else { return Self.unknownPaneID(paneID) }
                role = resolved
            }
            let split = role == .right
            guard let identity = split ? (session.hasSplit ? session.splitPaneIdentity : nil) : session.paneIdentity else {
                return ControlResponse(ok: false, error: "session has no split pane")
            }
            // a pane never shown since launch has no surface, so no token and no zmx backing to read
            guard (split ? session.splitSurface : session.surface) != nil else {
                return ControlResponse(ok: false, error: "session not realized")
            }
            let refusal = ControlResponse(ok: false, error: "\(target ?? "active") is not a Live session")
            let token = session.paneToken(for: split ? .right : .left)
            guard !token.isEmpty, let source = liveSource(session, identity: identity, split: split) else { return refusal }
            if case .local(_, let daemon) = source, predatesZmxBuild(daemon) {
                return ControlResponse(ok: false, error: "session predates this version; restart it to watch it on the phone")
            }
            guard let attach = try? ControlAttach.viewer(source, paneID: token) else { return refusal }
            return ControlResponse(ok: true, result: ControlResult(attach: attach))
        }
    }

    /// An old zmx daemon ignores the viewer's skip-scrollback flag, so its replay would overflow the relay.
    /// A failed listing or a missing created time serves the attach, as `zmx list` marks no row outdated then.
    private func predatesZmxBuild(_ daemon: String) -> Bool {
        guard let cutoff = zmxOutdatedBefore, let records = zmxClient?.sessionRecords() else { return false }
        return LiveReset.isOutdated(created: records.first { $0.name == daemon }?.createdAt, cutoff: cutoff)
    }

    /// A remote row never falls back to this Mac's zmx: its panes run on the origin.
    private func liveSource(_ session: Session, identity: UUID, split: Bool) -> LivePaneSource? {
        guard let binding = session.remotePresentation?.binding else {
            guard session.zmxBacking(for: split ? .split : .primary) == true, let endpoint = zmxClient?.endpoint else { return nil }
            return .local(endpoint: endpoint, daemon: ZmxSupport.daemonName(for: identity))
        }
        guard let origin = binding.origin, !session.catalogPaneHeld(identity) else { return nil }
        if binding.catalogOwned {
            return session.catalogPane(identity).map { .remote(host: origin.host, endpoint: $0.endpoint, daemon: $0.daemon) }
        }
        return binding.daemon(forLocalPane: identity).map { .remote(host: origin.host, endpoint: origin.endpoint, daemon: $0) }
    }
}
