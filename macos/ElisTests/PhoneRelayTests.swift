import XCTest
@testable import Elis
import ElisCore

@MainActor
final class PhoneRelayTests: XCTestCase {
    private var dir: URL!
    private var relays: [PhoneRelay] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("phone-relay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        relays.forEach { $0.stopForQuit() }
        relays = []
        try? FileManager.default.removeItem(at: dir)
    }

    private let link = "elis://pair?h=10.0.0.1&p=18000&t=tok&f=ab&n=mac"
    private var log: URL { dir.appendingPathComponent("log") }

    private func fakeTool(_ body: String) throws -> URL {
        let url = dir.appendingPathComponent("fake-elisctl")
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
        echo 'elisctl: bluetooth: advertising' >&2
        echo 'elisctl: phone connected from 10.0.0.9' >&2
        echo 'elisctl: phone disconnected from 10.0.0.9' >&2
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

    private func made(_ tool: URL) -> PhoneRelay {
        let relay = PhoneRelay(stateDirectory: dir, tool: tool)
        relays.append(relay)
        return relay
    }

    private func started(_ tool: URL) -> PhoneRelay {
        let relay = made(tool)
        relay.attach(socketPath: "/tmp/unused.sock")
        relay.setOn(true)
        return relay
    }

    func testARelayThatCannotListenShowsItsLastErrorLine() throws {
        let relay = started(try fakeTool("""
        echo '\(link)'
        echo 'elisctl: cannot listen on *:18000: Address already in use' >&2
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
        XCTAssertEqual(relay.link, "elis://pair?h=mac.tail.ts.net&p=18000&t=tok&f=ab&n=mac")
        relay.setOn(false)
        XCTAssertTrue(wait { logLines().contains { $0.hasPrefix("gone ") } })
    }

    func testSwitchingOffReturnsAtOnceAndTheChildExitsAfter() throws {
        let relay = started(try slowServe())
        XCTAssertTrue(wait { relay.link != nil && relay.status.bluetooth == "advertising" })

        let begun = Date()
        relay.setOn(false)

        XCTAssertLessThan(Date().timeIntervalSince(begun), 3)
        XCTAssertNil(relay.link)
        XCTAssertNil(relay.status.bluetooth)
        XCTAssertTrue(wait { logLines().contains { $0.hasPrefix("gone ") } })
        XCTAssertNil(relay.error)
        XCTAssertFalse(PhoneDesktopState.load(stateDirectory: dir).on)
    }

    func testAPortChangeStartsTheNewChildOnlyAfterTheOldOneExited() throws {
        let relay = started(try slowServe())
        XCTAssertTrue(wait { relay.link != nil && relay.status.bluetooth == "advertising" })

        let begun = Date()
        relay.setPort(20000)

        XCTAssertLessThan(Date().timeIntervalSince(begun), 3)
        XCTAssertNil(relay.status.bluetooth)
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
        if [ "$2" = reset ]; then echo 'elisctl: cannot write the token' >&2; exit 1; fi
        """))
        XCTAssertTrue(wait { relay.link != nil })

        Task { await relay.revoke() }

        XCTAssertTrue(wait { relay.notice != nil })
        XCTAssertEqual(relay.notice, "elisctl: cannot write the token")
        XCTAssertNil(relay.error)
        XCTAssertNotNil(relay.link)
        relay.setOn(false)
        XCTAssertTrue(wait { logLines().contains { $0.hasPrefix("gone ") } })
    }

    /// Viewer lines count per pane without becoming `lastEvent`; a stray detach emits nothing, and stopping
    /// the relay detaches each viewer left, without an address.
    func testViewerLinesCountPanesAndStoppingTheRelayDetachesTheRest() throws {
        let relay = made(try slowServe(extra: """
        echo 'elisctl: phone attached from 10.0.0.9 pane a' >&2
        echo 'elisctl: phone attached from 10.0.0.9 pane a' >&2
        echo 'elisctl: phone attached from 10.0.0.9 pane b' >&2
        echo 'elisctl: phone detached from 10.0.0.9 pane b' >&2
        echo 'elisctl: phone detached from 10.0.0.9 pane b' >&2
        """))
        var events: [String] = []
        relay.onEvent = { kind, payload in events.append([kind.rawValue, payload.ip ?? "-", payload.paneID ?? "-"].joined(separator: " ")) }
        relay.attach(socketPath: "/tmp/unused.sock")
        relay.setOn(true)

        XCTAssertTrue(wait { relay.lastEvent == "phone disconnected from 10.0.0.9" })
        XCTAssertEqual(relay.viewers.count(paneID: "a"), 2)
        XCTAssertEqual(relay.viewers.count(paneID: "b"), 0)
        XCTAssertEqual(events.filter { !$0.hasPrefix("phone.connected") && !$0.hasPrefix("phone.disconnected") },
                       ["phone.attached 10.0.0.9 a", "phone.attached 10.0.0.9 a", "phone.attached 10.0.0.9 b",
                        "phone.detached 10.0.0.9 b"])

        relay.setOn(false)
        XCTAssertEqual(Array(events.suffix(2)), ["phone.detached - a", "phone.detached - a"])
        XCTAssertEqual(relay.viewers, PhoneViewers())
    }

    func testPhoneEnableAnswersOnceTheRelayListensAndTheTreeAndEventsKeepTheTokenOut() async throws {
        let library = WindowLibrary(directory: dir.appendingPathComponent("state", isDirectory: true))
        let server = ControlServer(library: library, actions: AppActions(library: library),
                                   settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: dir)),
                                   identity: AppIdentity(version: "test", commit: "test"), zmxClient: nil,
                                   socketPath: dir.appendingPathComponent("control.sock").path)
        let relay = made(try slowServe())
        relay.onEvent = { library.emitAppEvent(ControlEventDraft(kind: $0, payload: $1)) }
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
        XCTAssertEqual(tree?.result?.tree?.phone, ControlPhoneStatus(on: true, listening: true, port: 8765, host: "10.0.0.1",
                                                                         bluetooth: "advertising"))
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
        let relay = made(try slowServe(extra: #"if [ "$2" = reset ]; then exit 0; fi"#))
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

    func testSwitchingOnAFailedRelayStartsItAgain() throws {
        let tries = dir.appendingPathComponent("tries")
        let relay = started(try slowServe(extra: """
        echo try >> '\(tries.path)'
        if [ "$(wc -l < '\(tries.path)')" -eq 1 ]; then echo 'elisctl: cannot listen on *:8765: busy' >&2; exit 1; fi
        """))
        XCTAssertTrue(wait { relay.error != nil })
        XCTAssertTrue(relay.state.on)

        relay.setOn(true)

        XCTAssertTrue(wait { relay.link != nil })
        XCTAssertNil(relay.error)
        relay.setOn(false)
        XCTAssertTrue(wait { logLines().contains { $0.hasPrefix("gone ") } })
    }

    func testAPairingResetByHandRestartsTheRelayWithTheNewCode() throws {
        let tries = dir.appendingPathComponent("tries")
        let relay = started(try slowServe(extra: """
        echo try >> '\(tries.path)'
        if [ "$(wc -l < '\(tries.path)')" -eq 1 ]; then
          echo '\(link)'; echo 'elisctl: \(PhoneRelayLine.pairingReset)' >&2; exit 1
        fi
        """))

        XCTAssertTrue(wait { logLines().contains { $0.hasPrefix("start ") } && relay.link != nil })
        XCTAssertNil(relay.error)
        XCTAssertEqual(((try? String(contentsOf: tries, encoding: .utf8)) ?? "").split(separator: "\n").count, 2)
        relay.setOn(false)
        XCTAssertTrue(wait { logLines().contains { $0.hasPrefix("gone ") } })
    }

    func testTheBluetoothLineIsAStatusAndNeverTheExitError() throws {
        let seen = dir.appendingPathComponent("seen")
        let busy = dir.appendingPathComponent("busy")
        let relay = started(try fakeTool("""
        echo 'elisctl: bluetooth: advertising' >&2
        echo '\(link)'
        while [ ! -e '\(seen.path)' ]; do sleep 0.05; done
        echo 'elisctl: bluetooth: off (in use by another relay)' >&2
        while [ ! -e '\(busy.path)' ]; do sleep 0.05; done
        exit 1
        """))

        XCTAssertTrue(wait { relay.status.bluetooth == "advertising" })
        FileManager.default.createFile(atPath: seen.path, contents: nil)
        XCTAssertTrue(wait { relay.status.bluetooth == "busy" })
        XCTAssertEqual(relay.status.readback.bluetooth, "busy")
        FileManager.default.createFile(atPath: busy.path, contents: nil)
        XCTAssertTrue(wait { relay.error != nil })
        XCTAssertEqual(relay.error, "The relay stopped.")
        XCTAssertNil(relay.status.bluetooth)
    }

    func testABluetoothOnlyLinkWithoutAnAddressStillListens() throws {
        let radioOnly = "elis://pair?t=tok&f=ab&n=mac&b=1"
        let relay = started(try fakeTool("""
        echo '\(radioOnly)'
        while :; do sleep 0.05 & wait $!; done
        """))

        XCTAssertTrue(wait { relay.link != nil })
        XCTAssertEqual(relay.link, radioOnly)
        XCTAssertTrue(relay.status.listening)
        XCTAssertEqual(relay.status.host, "")
        XCTAssertEqual(relay.status.hosts, [])
        relay.setHost("127.0.0.1")
        XCTAssertEqual(relay.link, "elis://pair?h=127.0.0.1&p=8765&t=tok&f=ab&n=mac&b=1")
    }

    func testARelayWithoutABluetoothLineAnswersStartingAtTheDeadline() throws {
        let relay = started(try fakeTool("""
        echo '\(link)'
        while :; do sleep 0.05 & wait $!; done
        """))
        var answered = false
        Task { await relay.untilListening(within: .milliseconds(500)); answered = true }

        XCTAssertTrue(wait { answered })
        XCTAssertEqual(relay.link, link)
        XCTAssertEqual(relay.status.bluetooth, "starting")
        XCTAssertEqual(relay.status.readback.bluetooth, "starting")
    }

    func testWithoutABoundSocketNothingStarts() async {
        let relay = made(URL(fileURLWithPath: "/usr/bin/false"))
        relay.attach(socketPath: nil)
        relay.setOn(true)
        await relay.settled()
        XCTAssertEqual(relay.error, "The control socket is not available.")
    }
}
