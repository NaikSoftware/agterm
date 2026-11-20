#if os(macOS)
import Foundation
import ElisCore

/// One page handed to the phone, from its request until it closes. Touched only on the relay queue.
final class PresentedPage: @unchecked Sendable {
    enum Waiting {
        case fetch(seq: Int)
        case bridge(seq: Int)
        /// The relay's own read of a content page's file, at most `limit` bytes.
        case read(Buffer, limit: Int, done: (Result<Data, SocketClientError>) -> Void)
    }

    /// A reference, so appending a chunk does not copy what was read before.
    final class Buffer { var data = Data() }

    let request: PresentationPage
    var pipe: PhoneLinkLineStream?
    /// The `page` line went out; commands before it wait in `held`.
    var shown = false
    var hidden = false
    var held: [PresentationPageCommand] = []
    var nextID = 1
    var waiting: [Int: Waiting] = [:]
    var html: Data?
    var script: Data?
    /// The pipe holds its next line until `pump()` resumes it; at most one pipe of a channel is not paused.
    var paused = true

    init(_ request: PresentationPage) { self.request = request }

    var id: String { request.page }
}

/// A content page's HTML or script, sent from memory as `res` chunks.
struct MemoryAnswer {
    let page: String
    let seq: Int
    let mime: String
    let data: Data
    var offset = 0
}

extension PhoneLinkPresenter {
    static let pipeGrace: TimeInterval = 2
    static let adapterHandler = "window.__elis"
    /// After the renderer, every link becomes its contents (text, pictures, code): the phone follows no markdown link.
    static let unlinkScript = """
        ;(() => {
          const page = document.getElementById('elis-page');
          if (!page) return;
          for (const link of Array.from(page.querySelectorAll('a'))) link.replaceWith(...link.childNodes);
        })();
        """

    /// The app bundle's `markdown` folder: `Bundle.main`, then beside the resolved executable (`Contents/MacOS`).
    static let bundledMarkdown: URL? = {
        let beside = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/markdown")
        return [Bundle.main.resourceURL?.appendingPathComponent("markdown"), beside].compactMap { $0 }.first(where: isDirectory)
    }()

    static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    // MARK: - from the origin

    func pageRequest(_ request: PresentationPage) {
        if let old = pages.removeValue(forKey: request.page) { old.pipe?.close() }
        let page = PresentedPage(request)
        switch request.source {
        case .url(let url):
            // a loopback address would name the phone itself
            guard !HtmlSource.isLoopback(url) else { return reject(page, "a loopback page cannot be shown on the phone") }
            pages[page.id] = page
            showPage(page, PhonePage(id: page.id, kind: "url", url: url, javascript: request.javascript, chromeless: request.chromeless,
                                     browse: request.browse, hidden: false, title: request.identity, sizePercent: request.sizePercent))
        case .forwarded:
            reject(page, "unsupported")
        case .markdown, .text:
            var files = MarkdownAssets.textFiles
            if case .markdown = request.source { files = MarkdownAssets.markdownFiles }
            let missing = files.filter { name in
                markdownDirectory.map { !FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path) } ?? true
            }
            guard missing.isEmpty else {
                log("phone page refused: the markdown renderer lacks \(missing.joined(separator: ", "))")
                return reject(page, "the markdown renderer is missing")
            }
            openPipe(page)
        case .file, .image, .document:
            openPipe(page)
        }
    }

    func pageClose(_ change: PresentationPageChange) {
        guard let page = pages.removeValue(forKey: change.page) else { return }
        page.pipe?.close()
        serving.removeAll { $0.page == page.id }
        if page.shown { output(.command(id: page.id, seq: 0, action: "close", sizePercent: nil)) }
        guard change.reason != PresentationPageChange.channelLost else { return }
        send(.pageClosed(PresentationPageChange(page: page.id, offer: page.request.offer)))
    }

    func pageCommand(_ command: PresentationPageCommand) {
        guard let page = pages[command.page], action(command) != nil else { return }
        guard page.shown else {
            if command.action == .hide || command.action == .show { page.hidden = command.action == .hide }
            return page.held.append(command)
        }
        sendCommand(page, command)
    }

    private func action(_ command: PresentationPageCommand) -> String? {
        switch command.action {
        case .hide, .show, .back, .forward, .browser, .resize: command.action.rawValue
        case .reloadOriginal, .reloadCurrent: "reload"
        // text actions go only to a presenter listing `page.text` or `page.files`
        case .follow, .search, .wrap, .changes, .files: nil
        }
    }

    private func sendCommand(_ page: PresentedPage, _ command: PresentationPageCommand) {
        guard let action = action(command) else { return }
        output(.command(id: page.id, seq: command.seq, action: action, sizePercent: command.action == .resize ? command.sizePercent : nil))
    }

    private func reject(_ page: PresentedPage, _ reason: String) {
        if pages[page.id] === page { pages[page.id] = nil }
        page.pipe?.close()
        send(.pageRejected(PresentationPageChange(page: page.id, reason: reason, offer: page.request.offer)))
    }

    private func showPage(_ page: PresentedPage, _ line: PhonePage) {
        var line = line
        line.hidden = page.hidden
        page.shown = true
        output(.page(line))
        let held = page.held
        page.held = []
        held.forEach { sendCommand(page, $0) }
    }

    // MARK: - the page pipe

    private func openPipe(_ page: PresentedPage) {
        guard let origin else { return reject(page, "unsupported") }
        pages[page.id] = page
        let token = page.request.token
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let opened = Result { try spawn(origin, token) }
            queue.async { [self] in pipeOpened(page, opened) }
        }
    }

    private func pipeOpened(_ page: PresentedPage, _ result: Result<PhoneLinkLineStream, Error>) {
        guard !stopped, pages[page.id] === page else {
            if case .success(let pipe) = result { pipe.close() }
            return
        }
        guard case .success(let pipe) = result else {
            if case .failure(let error) = result { log("phone page pipe failed: \(error)") }
            return reject(page, "could not open the page")
        }
        page.pipe = pipe
        pipe.start(paused: true, onLine: { [weak self] line in self?.pipeLine(page, line) }, onEnd: { [weak self] in self?.pipeEnded(page) })
        switch page.request.source {
        case .file(let path, _):
            let adapter = Self.adapterScript(javascript: page.request.javascript)
            showPage(page, PhonePage(id: page.id, kind: "file", path: path, adapter: adapter, javascript: page.request.javascript,
                                     chromeless: page.request.chromeless, browse: page.request.browse, hidden: false,
                                     title: page.request.identity, sizePercent: page.request.sizePercent))
        default:
            buildContent(page)
        }
    }

    static func adapterScript(javascript: Bool) -> String {
        let adapter = HtmlBridgeAdapter.script(handler: adapterHandler)
        return javascript ? adapter + "\n" + HtmlBridgeAdapter.helperScript(handler: adapterHandler) : adapter
    }

    /// The pipe ended under a page still open: the origin lost it, as the Mac's channel close reports.
    private func pipeEnded(_ page: PresentedPage) {
        guard !stopped, pages[page.id] === page else { return }
        pages[page.id] = nil
        serving.removeAll { $0.page == page.id }
        guard page.shown else { return reject(page, "the page channel ended") }
        output(.command(id: page.id, seq: 0, action: "close", sizePercent: nil))
        send(.pageClosed(PresentationPageChange(page: page.id, reason: PresentationPageChange.channelLost, offer: page.request.offer)))
    }

    private func pipeLine(_ page: PresentedPage, _ line: Data) {
        page.paused = true
        guard !stopped, pages[page.id] === page else { return }
        do {
            answer(page, try PageServeCodec.decode(line))
        } catch PresentationCodec.FrameError.oversize(let size) {
            log("phone page \(page.id): the origin sent a \(size)-byte chunk")
            page.pipe?.close()
            pipeEnded(page)
        } catch {
            log("phone page \(page.id): undecodable origin line: \(error)")
            let id = (try? JSONSerialization.jsonObject(with: line) as? [String: Any])?["id"] as? Int
            if let id { fail(page, id, Self.badAnswer) }
        }
        pump()
    }

    static let badAnswer = "bad answer from the origin"

    /// Ends the request `id` with `error` wherever it came from.
    private func fail(_ page: PresentedPage, _ id: Int, _ error: String) {
        guard let waiting = page.waiting.removeValue(forKey: id) else { return }
        switch waiting {
        case .fetch(let seq): output(.res(id: page.id, seq: seq, mime: nil, data: nil, end: true, error: error))
        case .bridge(let seq): output(.reply(id: page.id, seq: seq, response: nil, error: error))
        case .read(_, _, let finish): finish(.failure(SocketClientError(error)))
        }
    }

    private func answer(_ page: PresentedPage, _ frame: PageServeFrame) {
        guard let waiting = page.waiting[frame.id] else { return }
        let done = { page.waiting[frame.id] = nil }
        switch (waiting, frame) {
        case let (.fetch(seq), .head(_, mime)):
            guard mime.utf8.count <= Self.maxMime else { return fail(page, frame.id, Self.badAnswer) }
            output(.res(id: page.id, seq: seq, mime: mime, data: nil, end: false, error: nil))
        case let (.fetch(seq), .chunk(_, data)):
            output(.res(id: page.id, seq: seq, mime: nil, data: data, end: false, error: nil))
        case let (.fetch(seq), .end):
            done()
            output(.res(id: page.id, seq: seq, mime: nil, data: nil, end: true, error: nil))
        case let (.fetch(seq), .failure(_, error)):
            done()
            output(.res(id: page.id, seq: seq, mime: nil, data: nil, end: true, error: error))
        case let (.bridge(seq), .reply(_, response)):
            done()
            let reply = PhonePageDown.reply(id: page.id, seq: seq, response: response, error: nil)
            // escaping can grow a reply past the room `highWater` leaves for one line
            output(PhonePageCodec.encode(reply).count <= Self.maxPipeLine ? reply
                   : .reply(id: page.id, seq: seq, response: nil, error: "the answer is too large for the phone"))
        case let (.bridge(seq), .failure(_, error)):
            done()
            output(.reply(id: page.id, seq: seq, response: nil, error: error))
        case let (.read(buffer, limit, finish), .chunk(_, chunk)):
            buffer.data.append(chunk)
            guard buffer.data.count <= limit else {
                done()
                return finish(.failure(SocketClientError("the file is too large")))
            }
        case let (.read(buffer, _, finish), .end):
            done()
            finish(.success(buffer.data))
        case let (.read(_, _, finish), .failure(_, error)):
            done()
            finish(.failure(SocketClientError(error)))
        default:
            break
        }
    }

    private func pipeSend(_ page: PresentedPage, _ waiting: PresentedPage.Waiting, _ frame: (Int) -> PageServeFrame) {
        let id = page.nextID
        page.nextID += 1
        page.waiting[id] = waiting
        guard let line = try? PageServeCodec.encode(frame(id)) else { return }
        page.pipe?.send(line)
        pump()
    }

    /// Fills the channel up to `highWater`: memory answers, then one pipe's next line. Only one pipe is ever resumed, and
    /// only under `highWater`, so the lines in flight after the check (one chunk, one pipe line) fit the channel's buffer.
    func pump() {
        while !stopped, link.pending() < Self.highWater, !serving.isEmpty {
            var next = serving.removeFirst()
            let end = min(next.offset + PageServeCodec.maxChunkBytes, next.data.count)
            let last = end == next.data.count
            output(.res(id: next.page, seq: next.seq, mime: next.offset == 0 ? next.mime : nil,
                        data: next.data.subdata(in: next.offset..<end), end: last, error: nil))
            next.offset = end
            if !last { serving.insert(next, at: 0) }
        }
        guard !stopped, link.pending() < Self.highWater, !pages.values.contains(where: { !$0.paused }) else { return }
        let ready = pages.values.filter { $0.pipe != nil && !$0.waiting.isEmpty }.sorted { $0.id < $1.id }
        // round robin by id, so one long transfer does not starve the other pages
        guard let page = ready.first(where: { $0.id > lastPipe }) ?? ready.first else { return }
        lastPipe = page.id
        page.paused = false
        page.pipe?.resume()
    }

    /// The scheduler sent a frame: memory answers and paused pipes go on under `highWater`.
    func drained() {
        guard !stopped else { return }
        pump()
    }

    // MARK: - content pages

    private func buildContent(_ page: PresentedPage) {
        switch page.request.source {
        case .image(let path, _, _):
            read(page, path, limit: ImagePage.maxBytes) { [self] data in
                guard let mime = ImagePage.mimeType(sniffing: data) else { return reject(page, "not a picture") }
                contentReady(page, html: ImagePage.html(data: data, mimeType: mime), script: "")
            }
        case .document(let path):
            read(page, path, limit: DocumentPage.maxBytes) { [self] data in
                guard let html = DocumentPage.page(data) else { return reject(page, "not a text file") }
                contentReady(page, html: html, script: "")
            }
        case .text(let path, let line):
            read(page, path, limit: TextPage.maxBytes) { [self] data in
                guard let text = TextPage.validate(data) else { return reject(page, "not a text file") }
                contentReady(page, html: TextPage.html(text: text, language: TextPage.language(forFile: path), line: line,
                                                      style: assets.textStyle), script: assets.textScript)
            }
        case .markdown(let path):
            read(page, path, limit: MarkdownPage.maxBytes) { [self] data in
                guard let markdown = String(data: data, encoding: .utf8) else { return reject(page, "not a text file") }
                let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
                embed(page, MarkdownPage.remoteImageReferences(in: markdown, folder: folder)[...], Pictures()) { [self] embedded in
                    contentReady(page, html: MarkdownPage.html(markdown: markdown, images: embedded, style: assets.style),
                                 script: assets.script + Self.unlinkScript)
                }
            }
        case .file, .url, .forwarded:
            break
        }
    }

    /// The relay's own read over the pipe; a failure rejects the page.
    private func read(_ page: PresentedPage, _ path: String, limit: Int, then: @escaping (Data) -> Void) {
        pipeSend(page, .read(PresentedPage.Buffer(), limit: limit, done: { [self] result in
            switch result {
            case .success(let data): then(data)
            case .failure(let error): reject(page, error.description)
            }
        })) { .resource(id: $0, path: path) }
    }

    // shortcut: no decoded-pixel budget (ImageProbe is in the app target); add one if a page of huge-pixel pictures stalls the phone
    /// The markdown pictures one page embeds, each file once, under the page's count and byte budgets.
    private struct Pictures {
        var embedded = MarkdownPage.Embedded()
        var read: [String: Int?] = [:]
        var bytes = 0
    }

    /// Reads `images` one at a time over the pipe, then hands the embedded set on.
    private func embed(_ page: PresentedPage, _ images: ArraySlice<MarkdownPage.Image>, _ pictures: Pictures,
                       then: @escaping (MarkdownPage.Embedded) -> Void) {
        var pictures = pictures
        var rest = images
        while let image = rest.first {
            rest = rest.dropFirst()
            if let known = pictures.read[image.path] {
                if let known { pictures.embedded.references[image.reference] = known }
                continue
            }
            guard pictures.read.count < MarkdownPage.maxImages, pictures.bytes < MarkdownPage.maxImageBytes else { continue }
            let (before, remaining) = (pictures, rest)
            pipeSend(page, .read(PresentedPage.Buffer(), limit: MarkdownPage.maxImageBytes - pictures.bytes, done: { [self] result in
                var pictures = before
                if case .success(let data) = result, let mime = ImagePage.mimeType(sniffing: data) {
                    pictures.bytes += data.count
                    pictures.embedded.uris.append("data:\(mime);base64,\(data.base64EncodedString())")
                    pictures.read[image.path] = pictures.embedded.uris.count - 1
                    pictures.embedded.references[image.reference] = pictures.embedded.uris.count - 1
                } else {
                    pictures.read[image.path] = .some(nil)
                }
                embed(page, remaining, pictures, then: then)
            })) { .resource(id: $0, path: image.path) }
            return
        }
        then(pictures.embedded)
    }

    private func contentReady(_ page: PresentedPage, html: String, script: String) {
        guard pages[page.id] === page else { return }
        page.html = Data(html.utf8)
        page.script = Data(script.utf8)
        showPage(page, PhonePage(id: page.id, kind: "content", javascript: false, chromeless: page.request.chromeless,
                                 browse: false, hidden: false, title: page.request.identity, sizePercent: page.request.sizePercent))
    }

    // MARK: - from the phone

    /// DATA from the phone: `PhonePageUp` lines, possibly split across frames.
    func receive(_ bytes: Data) {
        guard !stopped else { return }
        phoneLine.append(bytes)
        while !stopped, let newline = phoneLine.firstIndex(of: 0x0A) {
            let line = Data(phoneLine[phoneLine.startIndex..<newline])
            phoneLine.removeSubrange(phoneLine.startIndex...newline)
            guard line.count <= ControlWire.maxRequestLineBytes, let up = try? PhonePageCodec.decode(line) else {
                return close(reason: "bad page line")
            }
            fromPhone(up)
        }
        if !stopped, phoneLine.count > ControlWire.maxRequestLineBytes { close(reason: "bad page line") }
    }

    private func fromPhone(_ up: PhonePageUp) {
        switch up {
        case let .fetch(id, seq, path):
            guard let page = pages[id], page.shown else {
                return output(.res(id: id, seq: seq, mime: nil, data: nil, end: true, error: "page not open"))
            }
            if let html = page.html {
                let answer: (String, Data)? = path == PhonePage.contentPath ? ("text/html; charset=utf-8", html)
                    : path == PhonePage.scriptPath ? ("text/javascript; charset=utf-8", page.script ?? Data()) : nil
                guard let (mime, data) = answer else {
                    return output(.res(id: id, seq: seq, mime: nil, data: nil, end: true, error: "not found"))
                }
                serving.append(MemoryAnswer(page: id, seq: seq, mime: mime, data: data))
                return pump()
            }
            guard case .file = page.request.source, page.pipe != nil, path != PhonePage.contentPath, path != PhonePage.scriptPath else {
                return output(.res(id: id, seq: seq, mime: nil, data: nil, end: true, error: "not found"))
            }
            guard page.waiting.count < Self.maxWaiting else {
                return output(.res(id: id, seq: seq, mime: nil, data: nil, end: true, error: PageServeFrame.busy))
            }
            pipeSend(page, .fetch(seq: seq)) { .resource(id: $0, path: path) }
        case let .bridge(id, seq, line):
            // a bridge line goes only to its page's pipe, where the origin judges it as a page's request
            guard let page = pages[id], case .file = page.request.source, page.pipe != nil else {
                return output(.reply(id: id, seq: seq, response: nil, error: "this page has no bridge"))
            }
            guard page.waiting.count < Self.maxWaiting else {
                return output(.reply(id: id, seq: seq, response: nil, error: PageServeFrame.busy))
            }
            pipeSend(page, .bridge(seq: seq)) { .bridge(id: $0, request: line) }
        case let .state(id, load, title, current, canGoBack, appliedSeq, hidden, error):
            guard let page = pages[id] else { return }
            send(.pageState(PresentationPageState(page: id, title: title, address: current, load: HtmlLoadState(rawValue: load) ?? .loading,
                                                  error: error, canGoBack: canGoBack, canGoForward: false, hidden: hidden,
                                                  appliedSeq: appliedSeq, offer: page.request.offer)))
        case let .closed(id, dismissed):
            guard let page = pages.removeValue(forKey: id) else { return }
            page.pipe?.close()
            serving.removeAll { $0.page == id }
            // a page the phone lost without the user goes back as a lost channel, never as dismissed
            send(.pageClosed(PresentationPageChange(page: id, reason: dismissed ? nil : PresentationPageChange.channelLost,
                                                    offer: page.request.offer)))
        }
    }
}

#endif
