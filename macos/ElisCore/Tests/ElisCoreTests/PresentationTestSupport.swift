import Foundation
import Testing
@testable import ElisCore

/// Viewers subscribes test viewers, the phone relay among them, to a hub. A namespace, since each suite's own
/// `viewer`, `lead` and `setLead` members would shadow free functions of the same name.
@MainActor
enum Viewers {
    final class Sink: PresentationSink {
        var frames: [PresentationFrame] = []

        func offer(_ frame: PresentationFrame) -> Bool {
            frames.append(frame)
            return true
        }

        func close(_: PresentationHub.CloseReason) {}

        var bodies: [PresentationFrame.Body] { frames.map(\.body) }
        var asks: [PresentationAsk] { bodies.compactMap { if case .askRequest(let r) = $0 { r } else { nil } } }
        var picks: [PresentationPick] { bodies.compactMap { if case .pickRequest(let r) = $0 { r } else { nil } } }
        var pages: [PresentationPage] { bodies.compactMap { if case .pageRequest(let r) = $0 { r } else { nil } } }
        var overlays: [PresentationOverlay] { bodies.compactMap { if case .overlayRequest(let r) = $0 { r } else { nil } } }
        var sounds: [PresentationSound] { bodies.compactMap { if case .sound(let r) = $0 { r } else { nil } } }
    }

    struct Viewer {
        let id: PresentationHub.SubscriberID
        let gen: Int
        let sink: Sink
    }

    static let phoneKinds = PresentationHub.pageKinds + [
        PresentationHub.leadReportKind, PresentationHub.pageContentKind, PresentationHub.pageDocumentKind,
        PresentationHub.pendingSnapshotKind, PresentationHub.jobTokenKind, PresentationHub.offerIdentityKind,
        PresentationHub.viewerPhoneKind,
    ]

    /// origin is a session on `store`, a Mac origin, whose primary pane follows.
    static func origin(_ store: AppStore, hub: PresentationHub) throws -> Session {
        store.presentationHub = hub
        let session = try #require(store.addSession(toWorkspace: store.addWorkspace(name: "work").id, cwd: "/tmp"))
        setLead(.follower, pane: session.paneIdentity)
        return session
    }

    static func viewer(_ hub: PresentationHub, _ session: Session, leads: Bool = false, acquire: Bool = false,
                       kinds: [String] = PresentationHub.supportedKinds) throws -> Viewer {
        let sink = Sink()
        let hello = PresentationHello(version: 1, kinds: kinds, mode: .presenter)
        let id = try hub.subscribe(session: session.id, hello: hello, sink: sink) { PresentationSnapshot(status: nil, hud: nil) }
        let viewer = Viewer(id: id, gen: sink.frames[0].gen, sink: sink)
        if acquire { hub.receive(PresentationFrame(gen: viewer.gen, rev: 0, body: .presenterAcquire), from: id) }
        if leads { lead(hub, viewer, [session.paneIdentity]) }
        return viewer
    }

    /// phone is the phone relay leading `session`'s primary pane.
    static func phone(_ hub: PresentationHub, _ session: Session, kinds: [String] = phoneKinds) throws -> Viewer {
        try viewer(hub, session, leads: true, kinds: kinds)
    }

    static func lead(_ hub: PresentationHub, _ viewer: Viewer, _ panes: [UUID]) {
        hub.receive(PresentationFrame(gen: viewer.gen, rev: 0, body: .leadReport(PresentationLeadReport(leaders: panes))), from: viewer.id)
    }

    static func setLead(_ role: ZmxLeadRole, pane: UUID) {
        let attachment = ZmxLeadAttachment(claim: false)
        ZmxLeadBook.shared.begin(attachment, pane: pane)
        _ = ZmxLeadNotice(title: "zmx-role;\(attachment.nonce):\(role.rawValue):1").map { ZmxLeadBook.shared.apply($0, pane: pane) }
    }
}
