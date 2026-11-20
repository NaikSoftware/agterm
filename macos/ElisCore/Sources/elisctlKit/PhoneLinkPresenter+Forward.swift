#if os(macOS)
import Darwin
import Foundation
import ElisCore

extension PhoneLinkPresenter {
    /// How long a remote row's ssh listener has to accept before the page is rejected.
    static let forwardReady: TimeInterval = 10

    /// Where a forward channel for `page` connects, nil when the page is not an open forwarded page of this presenter.
    func forwardTarget(page: String) -> (host: String, port: UInt16)? {
        guard !stopped, let page = pages[page], page.shown else { return nil }
        return page.forward
    }

    /// A local row's page is reached at its own address; a remote row's through an ssh listener on this Mac's loopback.
    func openForward(_ page: PresentedPage, _ url: String) {
        guard let forwarded = ForwardedPage(url), let port = UInt16(exactly: forwarded.port), port != 0 else {
            return reject(page, "only a loopback page can be forwarded")
        }
        guard let origin else { return reject(page, "unsupported") }
        pages[page.id] = page
        guard let host = origin.host else { return showForward(page, url, host: forwarded.host, port: port) }
        guard let local = Self.freeLoopbackPort() else { return reject(page, "no free local port for the page's forward") }
        let spec = forwarded.spec(localPort: Int(local), bindAddress: "127.0.0.1")
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let opened = Result { try forwardSpawn(RemoteSession.forwardCommand(host: host, spec: spec)) }
            queue.async { [self] in listenerOpened(page, url, local: local, opened) }
        }
    }

    private func listenerOpened(_ page: PresentedPage, _ url: String, local: UInt16, _ result: Result<PhoneLinkLineStream, Error>) {
        guard !stopped, pages[page.id] === page else {
            if case .success(let listener) = result { listener.close() }
            return
        }
        guard case .success(let listener) = result else {
            if case .failure(let error) = result { log("phone page forward failed: \(error)") }
            return reject(page, "could not start the page's forward")
        }
        page.pipe = listener
        listener.start(paused: true, onLine: { _ in }, onEnd: { [weak self] in self?.pipeEnded(page) })
        awaitListener(page, url, local: local, deadline: Date().addingTimeInterval(Self.forwardReady))
    }

    private func awaitListener(_ page: PresentedPage, _ url: String, local: UInt16, deadline: Date) {
        guard !stopped, pages[page.id] === page, !page.shown else { return }
        if Self.loopbackAccepts(local) { return showForward(page, url, host: "127.0.0.1", port: local) }
        guard Date() < deadline else { return reject(page, "the page's forward did not come up") }
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.awaitListener(page, url, local: local, deadline: deadline) }
    }

    private func showForward(_ page: PresentedPage, _ url: String, host: String, port: UInt16) {
        page.forward = (host, port)
        let request = page.request
        showPage(page, PhonePage(id: page.id, kind: "forward", url: url, javascript: request.javascript, chromeless: request.chromeless,
                                 browse: request.browse, hidden: false, title: request.identity, sizePercent: request.sizePercent))
    }

    /// Runs `argv` until the relay's end of stdin closes, so a relay killed outright leaves no `ssh -N` behind; a stop's
    /// SIGTERM reaches the child, and the child's own end ends the wrapper. Stdin is kept on fd 3 because `sh` gives an
    /// asynchronous list /dev/null as stdin.
    static func tiedToInput(_ argv: [String]) -> [String] {
        let script = #"exec 3<&0; "$@" </dev/null >/dev/null 3<&- & pid=$!; (read -r _ <&3; kill $pid) >/dev/null 2>&1 & reader=$!; "#
            + #"trap 'kill $pid' TERM; wait $pid; kill $reader 2>/dev/null"#
        return ["/bin/sh", "-c", script, "sh"] + argv
    }

    // shortcut: IPv4 copies of the app target's RemotePortForward.freePort/accepts; hoist both to ElisCore if a third caller appears
    /// A port nothing listens on at 127.0.0.1; ExitOnForwardFailure fails the forward if another process takes it first.
    static func freeLoopbackPort() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var address = loopback(port: 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        return named ? UInt16(bigEndian: address.sin_port) : nil
    }

    static func loopbackAccepts(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var address = loopback(port: port)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    private static func loopback(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }
}
#endif
