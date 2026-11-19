import ElisCore
import Foundation

/// Reads and scripted typing for a pane whose zmx client takes part in explicit leadership. A pane that
/// does not lead holds output laid out for another client's grid, and the daemon drops what it types, so
/// screen text and the cursor come from the daemon's terminal and typing goes through the daemon's
/// acknowledged path. This is what keeps pane-to-pane automation working on the Mac a session runs on
/// while another Mac leads it.
///
/// The role the app holds is a REPORT, a main-queue hop and up to 250 ms behind the daemon, so it is never
/// what guarantees delivery: a local managed pane always types and reads its cursor through the daemon.
extension ControlServer {
    enum PaneSource {
        /// The pane's zmx never reported a role, or the read is of the viewport of a pane that leads.
        case surface
        case daemon(name: String, client: ZmxClient)
        /// A covered pane of a row attached from another Mac or a server host, read from its daemon there.
        case remote(host: String, endpoint: ControlZmxEndpoint, daemon: String)
        case refused(String)
    }

    static let remotePaneRefusal = "pane is in use on the Mac it runs on; take the lead to drive it from here"
    static let remoteScreenLimit: TimeInterval = 5

    /// `viewport` is a default `session.text`: the one read whose meaning is the pane's own scrolled view,
    /// kept on the surface while the pane leads.
    /// `session` lets a covered remote pane answer `.remote`; without it that pane is refused.
    func paneSource(_ surface: GhosttySurfaceView, viewport: Bool = false, session: Session? = nil) -> PaneSource {
        let covered = surface.leadCovered
        guard covered || ZmxLeadBook.shared.role(pane: UUID(uuidString: surface.paneToken)) != nil else { return .surface }
        guard let name = surface.zmxSessionName, let client = zmxClient else {
            guard covered else { return .surface }
            let split = surface === session?.splitSurface
            if let session, split || surface === session.surface,
               let identity = split ? session.splitPaneIdentity : session.paneIdentity,
               case .remote(let host, let endpoint, let daemon)? = liveSource(session, identity: identity, split: split) {
                return .remote(host: host, endpoint: endpoint, daemon: daemon)
            }
            return .refused(Self.remotePaneRefusal)
        }
        return !covered && viewport ? .surface : .daemon(name: name, client: client)
    }

    /// The refusal for a command that acts on the pane's OWN surface, `session.paste`, `.selectall`, `.copy`
    /// and an opening or navigating `.search`: while covered, that surface holds output laid out for
    /// another grid and the daemon drops what it sends, so answering ok would report a paste that never
    /// landed or a selection of the wrong text. A pane that leads keeps the native action and its
    /// read-back, with no delivery acknowledgement: a role report trails the daemon by up to 250 ms.
    func coveredRefusal(_ surface: GhosttySurfaceView) -> ControlResponse? {
        guard surface.leadCovered else { return nil }
        return ControlResponse(ok: false, error: "pane is covered while another Mac leads it; take the lead first (session lead)")
    }

    /// `session.lead`: what a key press on the pane's cover does. A pane that already leads answers ok, so
    /// a caller can ask without reading `lead` first; one whose zmx never reported a role has no lead to
    /// take and says so rather than answering ok for nothing.
    func takeSessionLead(_ target: String?, window: String?, pane: StatusPane?) -> ControlResponse {
        return resolver.resolveSession(target, window: window) { store, id in
            let session = store.session(withID: id)
            if pane == .right, session?.splitSurface == nil {
                return ControlResponse(ok: false, error: "session has no split pane")
            }
            // only a Live scratch, here or on the origin, runs in a daemon another Mac can lead
            if pane == .scratch, (session?.scratchSurface as? GhosttySurfaceView)?.backedByZmx != true, session?.originScratch == nil {
                return ControlResponse(ok: false, error: "the scratch terminal has no lead")
            }
            let slot = switch pane {
            case .right: session?.splitSurface
            case .scratch: session?.scratchSurface
            default: session?.surface
            }
            guard let surface = slot as? GhosttySurfaceView,
                  let identity = UUID(uuidString: surface.paneToken) else {
                return ControlResponse(ok: false, error: "session not realized")
            }
            guard ZmxLeadBook.shared.role(pane: identity) != nil || surface.leadCovered else {
                return ControlResponse(ok: false, error: "pane has no lead to take")
            }
            if surface.leadCovered, !ZmxLeadBook.shared.reattaching(pane: identity) { PaneLead.reattach?(surface, true) }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// `session.text` answered by the daemon, nil when the pane's own surface is the source. The grid is the
    /// daemon's, which a covered surface does not hold. A covered remote pane is refused: its read is async.
    func coveredText(_ surface: GhosttySurfaceView, all: Bool, lines: Int?) -> ControlResponse? {
        let extent = all || lines != nil
        switch paneSource(surface, viewport: !extent) {
        case .surface: return nil
        case .refused(let reason): return ControlResponse(ok: false, error: reason)
        case .remote: return ControlResponse(ok: false, error: Self.remotePaneRefusal)
        case .daemon(let name, let client):
            return screenText(client.screen(name: name, all: extent), lines: lines, failure: "failed to read surface buffer")
        }
    }

    /// `coveredText` that also reads a covered remote pane from its daemon on the host it runs on.
    func coveredText(_ surface: GhosttySurfaceView, all: Bool, lines: Int?, session: Session) async -> ControlResponse? {
        let extent = all || lines != nil
        guard case .remote(let host, let endpoint, let daemon) = paneSource(surface, viewport: !extent, session: session) else {
            return coveredText(surface, all: all, lines: lines)
        }
        let failure = "could not read the pane on \(host)"
        guard let argv = try? RemoteSession.screenCommand(host: host, endpoint: endpoint, daemon: daemon, all: extent) else {
            return ControlResponse(ok: false, error: failure)
        }
        return screenText(await readRemoteScreen(argv).flatMap(ZmxScreen.init(output:)), lines: lines, failure: failure)
    }

    private func screenText(_ screen: ZmxScreen?, lines: Int?, failure: String) -> ControlResponse {
        guard let screen else { return ControlResponse(ok: false, error: failure) }
        var result = ControlResult(text: lines.map(screen.lastLines) ?? screen.text)
        result.columns = screen.columns
        result.rows = screen.rows
        return ControlResponse(ok: true, result: result)
    }

    /// One read per argv at a time: a request arriving while it runs waits for the same answer.
    private func readRemoteScreen(_ argv: [String]) async -> String? {
        if let running = remoteScreenReads[argv] { return await running.value }
        let run = remoteScreenRead
        let read = Task { await Self.offMain(run, argv) }
        remoteScreenReads[argv] = read
        let output = await read.value
        remoteScreenReads[argv] = nil
        return output
    }

    /// A plain thread, so a slow ssh holds neither the main actor nor a cooperative-pool thread.
    private nonisolated static func offMain(_ run: @escaping @Sendable ([String], TimeInterval) -> String?,
                                            _ argv: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread { continuation.resume(returning: run(argv, remoteScreenLimit)) }
        }
    }

    /// `surface.cursor` answered by the daemon, nil when the pane's own surface is the source.
    func coveredCursor(_ surface: GhosttySurfaceView, controlID: String) -> ControlResponse? {
        switch paneSource(surface) {
        case .surface: return nil
        case .refused(let reason): return ControlResponse(ok: false, error: reason)
        case .remote: return ControlResponse(ok: false, error: Self.remotePaneRefusal)
        case .daemon(let name, let client):
            guard let screen = client.screen(name: name, all: false) else {
                return ControlResponse(ok: false, error: "failed to read cursor position")
            }
            return ControlResponse(ok: true, result: ControlResult(id: controlID,
                                                                   cursor: ControlCursor(column: screen.cursorColumn)))
        }
    }

    /// `session.type` through the daemon, nil when the pane's own surface takes it.
    func coveredType(_ text: String, into surface: GhosttySurfaceView, session: UUID) -> ControlResponse? {
        switch paneSource(surface) {
        case .surface: return nil
        case .refused(let reason): return ControlResponse(ok: false, error: reason)
        case .remote: return ControlResponse(ok: false, error: Self.remotePaneRefusal)
        case .daemon(let name, let client):
            // a half-typed word goes first and on the same acknowledged path: left in place it would commit
            // after the scripted line, and committed through the surface the daemon may drop it
            let paced = KeystrokeSegments.paced(surface.pendingComposition + text)
            let bytes = KeystrokeSegments.ptyBytes(paced.head)
            guard bytes.isEmpty || client.type(name: name, bytes: bytes) else {
                return ControlResponse(ok: false, error: "the pane's zmx daemon did not accept the input")
            }
            surface.discardComposition()
            if paced.pacedReturn {
                Thread.sleep(forTimeInterval: KeystrokeSegments.submitGap)
                // a failed call does not prove the Return was dropped: the daemon queues before it answers
                guard client.type(name: name, bytes: [0x0D]) else {
                    return ControlResponse(ok: false, error: "text typed, but its final Return could not be confirmed; "
                        + "do not retype the text")
                }
            }
            // the pane-scoped status clear `injectAsUserInput` fires: the input a blocked agent waited for
            if !text.isEmpty { surface.onUserInputClearsStatus?(InterruptKeystroke.classify(text: text)) }
            return ControlResponse(ok: true, result: ControlResult(id: session.uuidString))
        }
    }
}
