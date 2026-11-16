import XCTest
@testable import agterm
import agtermCore

@MainActor
final class PhoneRelayTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("phone-relay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private let link = "agterm://pair?h=10.0.0.1&p=18000&t=tok&f=ab&n=mac"
    private var log: URL { dir.appendingPathComponent("log") }

    private func fakeTool(_ body: String) throws -> URL {
        let url = dir.appendingPathComponent("fake-agtermctl")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// A serve that logs its life and takes 0.5 s to exit on SIGTERM, as the real one does while it releases grids.
    private func slowServe(extra: String = "") throws -> URL {
        try fakeTool("""
        \(extra)
        echo "start $$" >> '\(log.path)'
        trap 'echo "stop $$" >> "\(log.path)"; sleep 0.5; echo "gone $$" >> "\(log.path)"; exit 0' TERM
        echo '\(link)'
        echo 'agtermctl: phone connected from 10.0.0.9' >&2
        echo 'agtermctl: phone disconnected from 10.0.0.9' >&2
        while :; do sleep 0.05 & wait $!; done
        """)
    }

    private func logLines() -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func wait(_ timeout: TimeInterval = 10, until condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    private func started(_ tool: URL) -> PhoneRelay {
        let relay = PhoneRelay(stateDirectory: dir, tool: tool)
        relay.attach(socketPath: "/tmp/unused.sock")
        relay.setOn(true)
        return relay
    }

    func testARelayThatCannotListenShowsItsLastErrorLine() throws {
        let relay = started(try fakeTool("""
        echo '\(link)'
        echo 'agtermctl: cannot listen on *:18000: Address already in use' >&2
        exit 1
        """))

        XCTAssertTrue(wait { relay.error != nil })
        XCTAssertEqual(relay.error, "cannot listen on *:18000: Address already in use")
        XCTAssertNil(relay.link)
        XCTAssertTrue(PhoneDesktopState.load(stateDirectory: dir).on)
    }

    func testTheLastEventIsTheDisconnectAndAHostRewritesTheLink() throws {
        let relay = started(try slowServe())
        XCTAssertTrue(wait { relay.lastEvent == "phone disconnected from 10.0.0.9" })
        XCTAssertEqual(relay.link, link)
        relay.setHost("mac.tail.ts.net")
        XCTAssertEqual(relay.link, "agterm://pair?h=mac.tail.ts.net&p=18000&t=tok&f=ab&n=mac")
        relay.setOn(false)
        XCTAssertTrue(wait { logLines().contains { $0.hasPrefix("gone ") } })
    }

    func testSwitchingOffReturnsAtOnceAndTheChildExitsAfter() throws {
        let relay = started(try slowServe())
        XCTAssertTrue(wait { relay.link != nil })

        let begun = Date()
        relay.setOn(false)

        XCTAssertLessThan(Date().timeIntervalSince(begun), 0.3)
        XCTAssertNil(relay.link)
        XCTAssertTrue(wait { logLines().contains { $0.hasPrefix("gone ") } })
        XCTAssertNil(relay.error)
        XCTAssertFalse(PhoneDesktopState.load(stateDirectory: dir).on)
    }

    func testAPortChangeStartsTheNewChildOnlyAfterTheOldOneExited() throws {
        let relay = started(try slowServe())
        XCTAssertTrue(wait { relay.link != nil })

        let begun = Date()
        relay.setPort(20000)

        XCTAssertLessThan(Date().timeIntervalSince(begun), 0.3)
        XCTAssertTrue(wait { logLines().count >= 4 && relay.link != nil })
        let events = logLines().map { $0.split(separator: " ").first.map(String.init) ?? "" }
        XCTAssertEqual(Array(events.prefix(4)), ["start", "stop", "gone", "start"])
        relay.setOn(false)
        XCTAssertTrue(wait { logLines().filter { $0.hasPrefix("gone ") }.count == 2 })
    }

    func testQuitWaitsForTheChildWhileMainKeepsRunning() throws {
        let relay = started(try slowServe())
        XCTAssertTrue(wait { relay.link != nil })
        var mainRan = false
        Task { @MainActor in mainRan = true }

        relay.stopForQuit()

        XCTAssertTrue(mainRan)
        XCTAssertTrue(logLines().contains { $0.hasPrefix("gone ") })
    }

    func testAFailedRevokeIsANoticeAndTheRelayKeepsListening() throws {
        let relay = started(try slowServe(extra: """
        if [ "$2" = reset ]; then echo 'agtermctl: cannot write the token' >&2; exit 1; fi
        """))
        XCTAssertTrue(wait { relay.link != nil })

        Task { await relay.revoke() }

        XCTAssertTrue(wait { relay.notice != nil })
        XCTAssertEqual(relay.notice, "agtermctl: cannot write the token")
        XCTAssertNil(relay.error)
        XCTAssertNotNil(relay.link)
        relay.setOn(false)
        XCTAssertTrue(wait { logLines().contains { $0.hasPrefix("gone ") } })
    }

    func testPhoneEnableAnswersOnceTheRelayListensAndTheTreeAndEventsKeepTheTokenOut() async throws {
        let library = WindowLibrary(directory: dir.appendingPathComponent("state", isDirectory: true))
        let server = ControlServer(library: library, actions: AppActions(library: library),
                                   settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: dir)),
                                   identity: AppIdentity(version: "test", commit: "test"), zmxClient: nil,
                                   socketPath: dir.appendingPathComponent("control.sock").path)
        let relay = PhoneRelay(stateDirectory: dir, tool: try slowServe())
        relay.onEvent = { kind, ip in library.emitAppEvent(ControlEventDraft(kind: kind, payload: ControlEventPayload(ip: ip))) }
        relay.attach(socketPath: "/tmp/unused.sock")
        server.phoneRelay = relay
        let dispatcher = ControlDispatcher(actions: server)
        let anchor = try XCTUnwrap(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 1)).result?.events)
        var on = ControlArgs()
        on.mode = "on"

        let enabled = await dispatcher.dispatch(ControlRequest(cmd: .phoneEnable, args: on))

        let answer = try XCTUnwrap(enabled?.result?.phone)
        XCTAssertEqual(enabled?.ok, true)
        XCTAssertTrue(answer.on && answer.listening)
        XCTAssertEqual(answer.hosts, ["10.0.0.1"])
        XCTAssertNil(answer.link)
        let status = await dispatcher.dispatch(ControlRequest(cmd: .phoneStatus))
        XCTAssertEqual(status?.result?.phone?.link, link)
        let tree = await dispatcher.dispatch(ControlRequest(cmd: .tree))
        XCTAssertEqual(tree?.result?.tree?.phone, ControlPhoneStatus(on: true, listening: true, port: 8765, host: "10.0.0.1"))
        func phoneEvents() -> [ControlEvent] {
            library.readEvents(ControlEventReadOptions(cursor: ControlEventCursor(run: anchor.run, after: anchor.next),
                                                       kinds: [.phoneConnected, .phoneDisconnected], limit: 10))
                .result?.events?.items ?? []
        }
        let deadline = Date().addingTimeInterval(10)
        while phoneEvents().count < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(phoneEvents().map(\.kind), [.phoneConnected, .phoneDisconnected])
        XCTAssertEqual(phoneEvents().map(\.payload.ip), ["10.0.0.9", "10.0.0.9"])

        var off = ControlArgs()
        off.mode = "off"
        let disabled = await dispatcher.dispatch(ControlRequest(cmd: .phoneEnable, args: off))
        XCTAssertEqual(disabled?.result?.phone, ControlPhoneStatus(on: false, listening: false, port: 8765, host: "", hosts: []))
        await relay.settled()
        XCTAssertTrue(logLines().contains { $0.hasPrefix("gone ") })
    }

    func testAPageCannotReachThePhoneRelayOrItsLink() async throws {
        let library = WindowLibrary(directory: dir.appendingPathComponent("state", isDirectory: true))
        let server = ControlServer(library: library, actions: AppActions(library: library),
                                   settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: dir)),
                                   identity: AppIdentity(version: "test", commit: "test"), zmxClient: nil,
                                   socketPath: dir.appendingPathComponent("control.sock").path)
        let relay = PhoneRelay(stateDirectory: dir, tool: try slowServe(extra: #"if [ "$2" = reset ]; then exit 0; fi"#))
        relay.attach(socketPath: "/tmp/unused.sock")
        relay.setOn(true)
        server.phoneRelay = relay
        defer { relay.stopForQuit() }
        let deadline = Date().addingTimeInterval(10)
        while relay.link == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(relay.link, link)
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID), cwd: NSTemporaryDirectory()))
        let file = dir.appendingPathComponent("page.html")
        try "<title>P</title>".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(server.openSessionOverlay(session.id.uuidString, window: nil, options: ControlSessionOverlayOpenOptions(
            command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil, follow: false, pane: nil,
            page: .file(path: file.path, grantRoot: nil))).ok)
        defer { store.closeOverlay(session.id) }
        let page = HtmlOverlayRegistry.shared.page(for: try XCTUnwrap(session.htmlOverlay), store: store)

        for cmd in ["phone.status", "phone.enable", "phone.port", "phone.host", "phone.revoke"] {
            var replies: [(Any?, String?)] = []
            page.handleBridgeRequest(["cmd": cmd], mainFrame: true) { replies.append(($0, $1)) }
            let answered = Date().addingTimeInterval(5)
            while replies.isEmpty, Date() < answered { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(replies.count, 1, cmd)
            XCTAssertEqual(replies.first?.1, "\(cmd) cannot be sent from a page")
            XCTAssertFalse(String(describing: replies.first?.0 as Any).contains("t=tok"), cmd)
        }
        XCTAssertTrue(relay.state.on)
        XCTAssertEqual(relay.link, link)
    }

    func testWithoutABoundSocketNothingStarts() async {
        let relay = PhoneRelay(stateDirectory: dir, tool: URL(fileURLWithPath: "/usr/bin/false"))
        relay.attach(socketPath: nil)
        relay.setOn(true)
        await relay.settled()
        XCTAssertEqual(relay.error, "The control socket is not available.")
    }
}
