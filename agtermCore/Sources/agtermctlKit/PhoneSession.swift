#if os(macOS)
import Foundation
import agtermCore

/// One phone's byte stream, whatever carries it. Callbacks and completions run on the relay's queue, and every
/// method is called there, so a connection may deliver as soon as it is created on that queue.
protocol PhoneTransportConnection: AnyObject {
    /// Names the phone in relay log lines: the IP for TLS, `bt:<4 hex>` for Bluetooth.
    var peerLabel: String { get }
    /// `completion` runs once the bytes are handed off or the connection failed.
    func send(_ data: Data, completion: @escaping () -> Void)
    /// Ends the connection; a send whose completion ran still reaches the peer, so a transport flushes before closing.
    func close()
    var onReceive: ((Data) -> Void)? { get set }
    /// The peer left or the transport failed; may come more than once, and after `close()`.
    var onClose: (() -> Void)? { get set }
}

extension PhoneTransportConnection {
    func send(_ data: Data) { send(data, completion: {}) }
}

/// Everything the relay does for one phone: the auth line, token re-checks, the serial forward queue and grid
/// claims. Every mutable property is touched on `queue` only. Requests run in order on the phone's own serial
/// queue, because `SocketClient` blocks, and hop back to answer.
final class PhoneSession: @unchecked Sendable {
    struct Settings: Sendable {
        let mobileDir: String
        let socketPath: String
        let hostName: String
        let authTimeout: TimeInterval
        let revokeInterval: TimeInterval
        let log: @Sendable (String) -> Void
    }

    /// The pre-auth cap: the auth line is about 60 bytes.
    static let preAuthBytes = 4096

    /// Accept order, for evicting the oldest unauthenticated connection.
    let order: Int
    var authenticated: Bool { token != nil }
    private let connection: any PhoneTransportConnection
    private let queue: DispatchQueue
    private let settings: Settings
    private let onEnd: (PhoneSession) -> Void
    private var buffer = Data()
    private var token: String?
    private var closing = false
    private var ended = false
    private var revoke: (any DispatchSourceTimer)?
    /// The reset request for every grid this phone forced, by (target, pane).
    private var grids: [String: [Data]] = [:]
    /// Keeps pipelined requests in order, and holds a hung app to one blocked thread per phone.
    private let work = DispatchQueue(label: "agtermctl.mobile.phone")

    /// `onEnd` runs once, on `queue`, when the session closes.
    init(_ connection: any PhoneTransportConnection, order: Int, queue: DispatchQueue, settings: Settings,
         onEnd: @escaping (PhoneSession) -> Void) {
        self.connection = connection
        self.order = order
        self.queue = queue
        self.settings = settings
        self.onEnd = onEnd
    }

    /// Call on `queue`.
    func start() {
        connection.onReceive = { [weak self] in self?.receive($0) }
        connection.onClose = { [weak self] in self?.close() }
        // counted from accept, so a peer that never finishes the transport handshake gives its slot back too
        queue.asyncAfter(deadline: .now() + settings.authTimeout) { [weak self] in
            if let self, token == nil { close() }
        }
        // `mobile reset` reaches idle phones too, not only at their next request
        let revoke = DispatchSource.makeTimerSource(queue: queue)
        revoke.schedule(deadline: .now() + settings.revokeInterval, repeating: settings.revokeInterval)
        revoke.setEventHandler { [weak self] in
            guard let self, let token else { return }
            if revoked(token) { close() }
        }
        revoke.resume()
        self.revoke = revoke
    }

    /// Hands back the resets for every grid this phone forced and forgets them; for a relay told to stop.
    func takeResets() -> [Data] {
        defer { grids = [:] }
        return Self.uniqueResets(grids)
    }

    func close() {
        guard !ended else { return }
        ended = true
        if token != nil { settings.log("phone disconnected from \(connection.peerLabel)") }
        closing = true
        revoke?.cancel()
        connection.onReceive = nil
        connection.onClose = nil
        connection.close()
        releaseGrids()
        onEnd(self)
    }

    private func receive(_ data: Data) {
        guard !closing else { return }
        buffer.append(data)
        while !closing, let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line)
        }
        if !closing, buffer.count > (token == nil ? Self.preAuthBytes : ControlWire.maxRequestLineBytes) { close() }
    }

    private func handle(_ line: Data) {
        var object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
        let id = (try? JSONSerialization.data(withJSONObject: object.removeValue(forKey: "id") ?? NSNull(),
                                               options: .fragmentsAllowed)) ?? Data("null".utf8)
        if let token {
            if revoked(token) { return close() } // by `mobile reset`
            forward(object, id: id)
            return
        }
        guard let offered = object["auth"] as? String, tokenMatches(offered) else {
            settings.log("refused \(connection.peerLabel): wrong token")
            closing = true // lines already sent are not more attempts
            let refusal = Self.encode(ControlResponse(ok: false, error: "unauthorized"))
            connection.send(Self.tagged(refusal, id: id)) { [weak self] in self?.close() }
            return
        }
        token = offered
        settings.log("phone connected from \(connection.peerLabel)")
        let host = settings.hostName, socketPath = settings.socketPath
        work.async { [self] in
            let version = (try? SocketClient(path: socketPath).sendRaw(Data(#"{"cmd":"version"}"#.utf8)))
                .flatMap { try? JSONDecoder().decode(ControlResponse.self, from: $0) }?.result?.app?.version ?? "unknown"
            let hello = (try? JSONSerialization.data(withJSONObject: ["ok": true, "result": ["host": host, "version": version]])) ?? Data()
            queue.async { self.send(Self.tagged(hello, id: id)) }
        }
    }

    private func forward(_ request: [String: Any], id: Data) {
        let body = (try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        let socketPath = settings.socketPath
        let grid = Self.gridClaim(request)
        // a paired phone must not switch the relay off, revoke its pairing or read the link
        let refused = (request["cmd"] as? String)?.hasPrefix("phone.") == true
        // holds the session: a request queued before the phone left still runs, and its grid is then released
        work.async { [self] in
            let answer: Data
            do {
                // on the phone's queue, so the refusal keeps its place among earlier answers
                answer = refused ? Self.encode(ControlResponse(ok: false, error: "phone.* is not available from a phone"))
                    : try SocketClient(path: socketPath).sendRaw(body)
            } catch {
                answer = Self.encode(ControlResponse(ok: false, error: "agterm is not reachable: \(error)"))
            }
            let ok = ((try? JSONSerialization.jsonObject(with: answer)) as? [String: Any])?["ok"] as? Bool == true
            queue.async {
                if let grid {
                    if grid.reset == nil {
                        self.grids[grid.key] = nil
                    } else if ok {
                        self.grids[grid.key] = grid.reset
                        if self.closing { self.releaseGrids() } // the phone left while this one was in flight
                    }
                }
                self.send(Self.tagged(answer, id: id))
            }
        }
    }

    /// For a `session.grid` request, its (target, pane) key and the requests that undo it; a nil `reset`
    /// means the request is itself a reset. Both panes are reset: a swap or a promotion moves a grid to the other role.
    private static func gridClaim(_ request: [String: Any]) -> (key: String, reset: [Data]?)? {
        guard request["cmd"] as? String == Command.sessionGrid.rawValue else { return nil }
        let args = request["args"] as? [String: Any] ?? [:]
        // only an explicit session is tracked: `active` or no target may name another session by close time
        guard let target = request["target"] as? String, !target.isEmpty, target.lowercased() != "active" else { return nil }
        let pane = args["pane"] as? String
        let key = "\(target)\u{0}\(pane ?? "")"
        if args["reset"] as? Bool == true { return (key, nil) }
        let resets = ["left", "right"].compactMap { side -> Data? in
            var resetArgs: [String: Any] = ["reset": true, "pane": side]
            resetArgs["window"] = args["window"]
            let reset: [String: Any] = ["cmd": Command.sessionGrid.rawValue, "target": target, "args": resetArgs]
            return try? JSONSerialization.data(withJSONObject: reset, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        return (key, resets)
    }

    /// Each target's pair once, though both of its panes were claimed.
    private static func uniqueResets(_ grids: [String: [Data]]) -> [Data] {
        var seen = Set<Data>()
        return grids.values.flatMap { $0 }.filter { seen.insert($0).inserted }
    }

    /// A forced grid must not outlive the phone that set it; failures are ignored, the session may be gone.
    private func releaseGrids() {
        let resets = takeResets()
        let socketPath = settings.socketPath
        // after any request still in flight on this phone's queue
        work.async {
            for reset in resets { _ = try? SocketClient(path: socketPath).sendRaw(reset) }
        }
    }

    private func send(_ line: Data) {
        guard !closing else { return }
        connection.send(line)
    }

    private func tokenMatches(_ token: String) -> Bool {
        guard let current = MobilePairing.currentToken(in: settings.mobileDir) else { return false }
        return MobilePairing.sameSecret(token, current)
    }

    /// Fails closed: a missing or invalid token revokes, and only a transient read error (EMFILE under a
    /// connection flood) keeps paired phones.
    private func revoked(_ token: String) -> Bool {
        switch MobilePairing.readToken(in: settings.mobileDir) {
        case let .token(current): return !MobilePairing.sameSecret(token, current)
        case .absent: return true
        case .unavailable: return false
        }
    }

    /// The control reply with the phone's `id` spliced in as its first key, the rest of the bytes untouched.
    static func tagged(_ answer: Data, id: Data) -> Data {
        guard answer.first == UInt8(ascii: "{"), answer.count > 2 else {
            return tagged(encode(ControlResponse(ok: false, error: "malformed reply from agterm")), id: id)
        }
        return Data(#"{"id":"#.utf8) + id + Data(",".utf8) + answer.dropFirst() + Data("\n".utf8)
    }

    private static func encode(_ response: ControlResponse) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data(#"{"ok":false}"#.utf8)
    }
}
#endif
