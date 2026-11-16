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

    private func fakeTool(_ body: String) throws -> URL {
        let url = dir.appendingPathComponent("fake-agtermctl")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func wait(_ timeout: TimeInterval = 10, until condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    func testARelayThatCannotListenShowsItsLastErrorLine() throws {
        let tool = try fakeTool("""
        echo '\(link)'
        echo 'agtermctl: cannot listen on *:18000: Address already in use' >&2
        exit 1
        """)
        let relay = PhoneRelay(stateDirectory: dir, tool: tool)
        relay.attach(socketPath: "/tmp/unused.sock")
        relay.setOn(true)

        XCTAssertTrue(wait { relay.error != nil })
        XCTAssertEqual(relay.error, "cannot listen on *:18000: Address already in use")
        XCTAssertNil(relay.link)
        XCTAssertTrue(PhoneDesktopState.load(stateDirectory: dir).on)
    }

    func testSwitchingOffStopsTheChildAtOnce() throws {
        let pidFile = dir.appendingPathComponent("pid")
        let tool = try fakeTool("""
        echo $$ > '\(pidFile.path)'
        echo '\(link)'
        echo 'agtermctl: phone connected from 10.0.0.9' >&2
        exec sleep 60
        """)
        let relay = PhoneRelay(stateDirectory: dir, tool: tool)
        relay.attach(socketPath: "/tmp/unused.sock")
        relay.setOn(true)
        XCTAssertTrue(wait { relay.link != nil && relay.lastEvent != nil })
        XCTAssertEqual(relay.link, link)
        XCTAssertEqual(relay.lastEvent, "phone connected from 10.0.0.9")
        relay.setHost("mac.tail.ts.net")
        XCTAssertEqual(relay.link, "agterm://pair?h=mac.tail.ts.net&p=18000&t=tok&f=ab&n=mac")
        let pid = try XCTUnwrap(Int32(String(decoding: Data(contentsOf: pidFile), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))

        let started = Date()
        relay.setOn(false)

        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertTrue(wait { kill(pid, 0) != 0 })
        XCTAssertNil(relay.link)
        XCTAssertNil(relay.error)
        XCTAssertEqual(PhoneDesktopState.load(stateDirectory: dir),
                       PhoneDesktopState(on: false, port: PhoneDesktopState.defaultPort, host: "mac.tail.ts.net"))
    }

    func testWithoutABoundSocketNothingStarts() {
        let relay = PhoneRelay(stateDirectory: dir, tool: URL(fileURLWithPath: "/usr/bin/false"))
        relay.attach(socketPath: nil)
        relay.setOn(true)
        XCTAssertEqual(relay.error, "The control socket is not available.")
    }
}
