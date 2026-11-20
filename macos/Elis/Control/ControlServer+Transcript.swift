import Foundation
import ElisCore

extension ControlServer {
    func transcriptSource(_ target: String?, window: String?, pane: StatusPane?, paneID: String?) -> ControlTranscriptLookup {
        switch resolver.resolveSessionTarget(target, window: window) {
        case .failure(let refusal):
            return .refused(refusal)
        case .success(let (store, id)):
            guard let session = store.session(withID: id) else { return .refused(ControlResponse(ok: false, error: "session not found")) }
            switch session.transcriptSource(token: paneID, pane: pane, claudeDirectory: claudeDirectory) {
            case .success(let source): return .source(source)
            case .failure(let refusal): return .refused(ControlResponse(ok: false, error: refusal.message))
            }
        }
    }

    /// transcriptRoute sends a read on an attached row to its origin and on a server row to its server; nil reads here.
    func transcriptRoute(_ request: ControlRequest) -> RemoteRoute? {
        guard case .success(let (store, id)) = resolver.resolveSessionTarget(request.target, window: request.args?.window),
              let row = store.session(withID: id) else { return nil }
        let origin = AttachedOrigin(row)
        let serverHost = row.remotePresentation?.binding.catalogOwned == true ? catalogPool(forSession: id)?.host : nil
        guard let host = origin?.host ?? serverHost else { return nil }
        if let refusal = pageCompanionRefusal(request) { return .refused(refusal) }
        let arguments: ClaudeTranscriptArguments
        switch ControlDispatcher.transcriptArguments(request.args) {
        case .failure(let refusal): return .refused(refusal)
        case .success(let parsed): arguments = parsed
        }
        guard let origin else {
            return .transcript(host: host, row: id, words: TranscriptForward.words(session: id.uuidString, paneID: arguments.paneID,
                                                                                    pane: arguments.pane, arguments: arguments))
        }
        var paneID: String?
        if let token = arguments.paneID.flatMap({ $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }) {
            let local = UUID(uuidString: token).flatMap { [row.paneIdentity, row.splitPaneIdentity].contains($0) ? $0 : nil }
            guard let local, let mapped = AttachedOrigin.originPaneID(of: row, local: local) else {
                return .refused(ControlResponse(ok: false, error: "unknown pane id: \(token)"))
            }
            paneID = mapped
        }
        return .transcript(host: host, row: id, words: TranscriptForward.words(session: origin.session, paneID: paneID,
                                                                                pane: arguments.pane, arguments: arguments))
    }

    /// runTranscript runs the read on a pooled ssh channel and answers the host's reply unchanged.
    func runTranscript(host: String, row: UUID, words: [String]) async -> ControlResponse {
        let tooOld = ControlResponse(ok: false, error: "the Elis on \(host) is too old for session.transcript")
        let pool = catalogPool(forSession: row) ?? attachedTranscriptPool(host)
        let user = "transcript:\(row)"
        let path = pool.lease(user)
        defer { pool.release(user) }
        guard await pool.ready(path) else { return ControlResponse(ok: false, error: "\(host) did not answer") }
        guard let argv = try? RemoteSession.controlCommand(host: host, arguments: words, controlPath: path) else {
            return ControlResponse(ok: false, error: "\(host) cannot be addressed")
        }
        let result = await remoteRunner.run(argv, deadline: Self.remoteTreeDeadline)
        guard let reply = try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)),
              !reply.refusesUnknown(.sessionTranscript) else { return tooOld }
        return reply
    }

    // never closed: an idle master exits after its ControlPersist
    private func attachedTranscriptPool(_ host: String) -> SshConnectionPool {
        if let pool = attachedTranscriptPools[host] { return pool }
        let runner = remoteRunner
        let pool = SshConnectionPool(host: host, root: Self.sshPoolRoot, key: "\(socketPath)|transcript|\(host)") { argv in
            await runner.run(argv, deadline: 15).status
        }
        attachedTranscriptPools[host] = pool
        return pool
    }
}
