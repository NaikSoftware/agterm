#if os(macOS)
import CoreImage
import CryptoKit
import Darwin
import Foundation
import Network
import Security
import Testing
import agtermCore
@testable import agtermctlKit

struct MobileCommandsTests {
    @Test func pairLinkEncodesEveryValueTheWayThePhoneDecodesIt() throws {
        let fingerprint = String(repeating: "ab", count: 32)
        let link = MobilePairing.pairLink(host: "192.168.1.5", port: 8765, token: "tok-en_" + String(repeating: "x", count: 30),
                                          fingerprint: fingerprint, name: "Nick's Mac+Book Pro")
        #expect(link.hasPrefix("agterm://pair?h=192.168.1.5&p=8765&t="))
        #expect(!link.contains(" ") && !link.contains("'") && !link.contains("+"))
        let components = try #require(URLComponents(string: link))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(components.scheme == "agterm" && components.host == "pair")
        #expect(query["n"] == "Nick's Mac+Book Pro")
        #expect(query["t"] == "tok-en_" + String(repeating: "x", count: 30))
        #expect(query["f"]?.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
        #expect(query["p"] == "8765")
    }

    @Test func lanAddressesPutVirtualInterfacesLast() {
        let ordered = MobilePairing.orderedLAN([("bridge100", "192.168.64.1"), ("utun3", "10.8.0.2"), ("en0", "192.168.1.5"),
                                                 ("vmnet8", "172.16.0.1"), ("en1", "192.168.1.5"), ("en7", "10.0.0.9")])
        #expect(ordered == ["192.168.1.5", "10.0.0.9", "192.168.64.1", "10.8.0.2", "172.16.0.1"])
    }

    @Test func tokenIsPrivateBase64URLAndResetReplacesIt() throws {
        let dir = try MobileFixture.privateDirectory()
        defer { try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent) }
        let token = try MobilePairing.loadToken(in: dir)
        #expect(token.count >= 32 && token.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil)
        #expect(try MobilePairing.loadToken(in: dir) == token)
        #expect(MobileFixture.mode(dir + "/token") == 0o600)
        #expect(MobileFixture.mode(dir) == 0o700)
        let fresh = try MobilePairing.loadToken(in: dir, fresh: true)
        #expect(fresh != token && MobilePairing.currentToken(in: dir) == fresh)
        #expect(MobileFixture.mode(dir + "/token") == 0o600)
    }

    @Test func sameSecretComparesWholeValues() {
        #expect(MobilePairing.sameSecret("abc", "abc"))
        #expect(!MobilePairing.sameSecret("abc", "abd"))
        #expect(!MobilePairing.sameSecret("abc", "abcd"))
        #expect(!MobilePairing.sameSecret("", "a"))
    }

    @Test func qrHasFinderPatternsInTheThreeUprightCorners() throws {
        let matrix = try MobilePairing.qrMatrix("agterm://pair?h=10.0.0.1&p=8765")
        let size = matrix.count
        #expect(size >= 21 && matrix.allSatisfy { $0.count == size })
        let finderRow = { (row: Int, from: Int) in (from..<from + 7).allSatisfy { matrix[row][$0] } }
        #expect(finderRow(0, 0) && finderRow(0, size - 7) && finderRow(size - 1, 0))
        #expect(!finderRow(size - 1, size - 7))
        #expect(MobileFixture.decodeQR(matrix) == "agterm://pair?h=10.0.0.1&p=8765")
        let rows = MobilePairing.qrRows(matrix)
        #expect(rows.count == (size + 4 + 1) / 2)
        #expect(rows[0].hasPrefix("\u{1b}[97;107m▀"))
    }

    @Test func relayAuthenticatesForwardsAndTagsAnswers() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let client = try fixture.connect()
        #expect(client.peerFingerprint == fixture.fingerprint)
        client.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        let hello = try #require(client.readJSON())
        #expect(hello["ok"] as? Bool == true && hello["id"] as? Int == 1)
        let result = try #require(hello["result"] as? [String: Any])
        #expect(result["host"] as? String == "test-mac" && result["version"] as? String == "9.9.9")

        client.send(#"{"cmd":"tree","id":7,"args":{"unknownArg":1}}"#)
        let answer = try #require(client.readJSON())
        #expect(answer["id"] as? Int == 7 && answer["ok"] as? Bool == true)
        #expect((answer["result"] as? [String: Any])?["echo"] as? String == "tree")
        #expect(fixture.server.requests().last == #"{"args":{"unknownArg":1},"cmd":"tree"}"#)
    }

    @Test func aPhoneCannotDriveTheRelayItself() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let client = try fixture.connect()
        client.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(client.readJSON()?["ok"] as? Bool == true)
        let before = fixture.server.requests().count
        for (id, cmd) in ["phone.status", "phone.enable", "phone.revoke"].enumerated() {
            client.send(#"{"cmd":"\#(cmd)","id":\#(id + 2)}"#)
            let refusal = try #require(client.readJSON())
            #expect(refusal["ok"] as? Bool == false && refusal["id"] as? Int == id + 2)
            #expect(refusal["error"] as? String == "phone.* is not available from a phone")
        }
        client.send(#"{"cmd":"tree","id":9}"#)
        #expect(client.readJSON()?["id"] as? Int == 9)
        #expect(Array(fixture.server.requests().dropFirst(before)) == [#"{"cmd":"tree"}"#])
    }

    @Test(arguments: ["0", "1023"])
    func servePortsBelow1024AreRefused(_ port: String) {
        var message: String?
        do { _ = try Agtermctl.parseAsRoot(["mobile", "serve", "--port", port]) } catch { message = Agtermctl.message(for: error) }
        #expect(message == "port must be 1024...65535")
    }

    @Test func wrongTokenIsRefusedAndClosed() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let client = try fixture.connect()
        client.send(#"{"auth":"\#(String(repeating: "z", count: 43))","id":3}"#)
        let refusal = try #require(client.readJSON())
        #expect(refusal["ok"] as? Bool == false && refusal["id"] as? Int == 3 && refusal["error"] as? String == "unauthorized")
        #expect(client.waitClosed())
        #expect(fixture.logged().contains { $0.hasPrefix("refused ") && $0.hasSuffix(": wrong token") })
        #expect(!fixture.logged().contains { $0.hasPrefix("phone disconnected") })
    }

    @Test func preAuthGarbageClosesTheConnection() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let client = try fixture.connect()
        client.send(String(repeating: "g", count: 5000), newline: false)
        #expect(client.waitClosed())
        #expect(client.readJSON(timeout: 0.1) == nil)
    }

    @Test func resettingTheTokenDropsAnIdlePhone() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let client = try fixture.connect()
        client.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(client.readJSON()?["ok"] as? Bool == true)
        _ = try MobilePairing.loadToken(in: fixture.mobileDir, fresh: true)
        #expect(client.waitClosed())
    }

    @Test func aDisconnectingPhoneGivesBackTheGridsItForced() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let client = try fixture.connect()
        client.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(client.readJSON()?["ok"] as? Bool == true)
        client.send(#"{"cmd":"session.grid","target":"S1","args":{"pane":"right","columns":40,"rows":20},"id":2}"#)
        client.send(#"{"cmd":"session.grid","target":"S2","args":{"columns":40,"rows":20},"id":3}"#)
        client.send(#"{"cmd":"session.grid","target":"S2","args":{"reset":true},"id":4}"#)
        client.send(#"{"cmd":"session.grid","target":"active","args":{"columns":40,"rows":20},"id":5}"#)
        client.send(#"{"cmd":"session.grid","args":{"columns":40,"rows":20},"id":6}"#)
        let answers = (0..<5).compactMap { _ in client.readJSON()?["id"] as? Int }
        #expect(answers == [2, 3, 4, 5, 6])
        let before = fixture.server.requests().count
        client.close()
        let resets = [#"{"args":{"pane":"left","reset":true},"cmd":"session.grid","target":"S1"}"#,
                      #"{"args":{"pane":"right","reset":true},"cmd":"session.grid","target":"S1"}"#]
        #expect(fixture.server.waitFor(resets[1], after: before))
        let sentinel = #"{"cmd":"sentinel"}"#
        _ = try SocketClient(path: fixture.server.path).sendRaw(Data(sentinel.utf8))
        #expect(Array(fixture.server.requests().dropFirst(before)) == resets + [sentinel])
    }

    @Test func anAuthenticatedPhoneLeavingIsLoggedOnce() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let client = try fixture.connect()
        client.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(client.readJSON()?["ok"] as? Bool == true)
        client.close()
        let deadline = Date().addingTimeInterval(30)
        while !fixture.logged().contains(where: { $0.hasPrefix("phone disconnected from ") }), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        Thread.sleep(forTimeInterval: 0.2)
        #expect(fixture.logged().filter { $0.hasPrefix("phone disconnected from ") }.count == 1)
    }

    @Test func aStoppingRelayGivesBackItsPhonesGrids() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let client = try fixture.connect()
        client.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(client.readJSON()?["ok"] as? Bool == true)
        client.send(#"{"cmd":"session.grid","target":"S1","args":{"columns":40,"rows":20},"id":2}"#)
        #expect(client.readJSON()?["ok"] as? Bool == true)
        let before = fixture.server.requests().count
        fixture.relay.releaseAllGrids()
        #expect(Array(fixture.server.requests().dropFirst(before)).sorted() == [#"{"args":{"pane":"left","reset":true},"cmd":"session.grid","target":"S1"}"#,
                                                                               #"{"args":{"pane":"right","reset":true},"cmd":"session.grid","target":"S1"}"#])
    }

    @Test(arguments: ["delete", "unreadable", "short"])
    func aMissingOrInvalidTokenDropsAPairedPhone(_ change: String) throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let client = try fixture.connect()
        client.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(client.readJSON()?["ok"] as? Bool == true)
        let path = fixture.mobileDir + "/token"
        switch change {
        case "delete": unlink(path)
        case "unreadable": chmod(path, 0)
        default: try Data("short\n".utf8).write(to: URL(fileURLWithPath: path))
        }
        #expect(client.waitClosed())
    }

    @Test func onlyResourceErrorsCountAsTransient() {
        #expect([EMFILE, ENFILE, EINTR, EAGAIN].allSatisfy(MobilePairing.isTransient))
        #expect(![ENOENT, EACCES, ENOTDIR].contains(where: MobilePairing.isTransient))
    }

    @Test func aFullPreAuthCapEvictsTheOldestConnection() throws {
        let fixture = try MobileFixture(maxUnauthenticated: 1)
        defer { fixture.stop() }
        let stale = try fixture.connect()
        let phone = try fixture.connect()
        #expect(stale.waitClosed())
        phone.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(phone.readJSON()?["ok"] as? Bool == true)
    }

    // a separate process: serve ends by exit
    @Test func serveExitsWhenThePairingIsResetUnderIt() throws {
        let dir = try MobileFixture.privateDirectory()
        defer { try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent) }
        let server = RawStubServer()
        try server.start()
        defer { server.stop() }
        // the products directory holds the test bundle and the built agtermctl
        let tool = Bundle(for: MobileFixture.self).bundleURL.deletingLastPathComponent().appendingPathComponent("agtermctl")
        try #require(FileManager.default.isExecutableFile(atPath: tool.path), "\(tool.path)")
        var process = Process(), printed = LogLines(), err = Pipe()
        // below the ephemeral range the in-process fixtures bind through port 0; a taken port gets another try
        for _ in 0..<3 {
            process = Process()
            printed = LogLines()
            err = Pipe()
            process.executableURL = tool
            process.arguments = ["mobile", "serve", "--port", String(Int.random(in: 20000...32767)), "--bind", "127.0.0.1", "--no-qr",
                                 "--no-bluetooth", "--socket", server.path]
            process.environment = ProcessInfo.processInfo.environment.merging(
                ["AGTERM_STATE_DIR": (dir as NSString).deletingLastPathComponent]) { $1 }
            let out = Pipe(), lines = printed
            process.standardOutput = out
            process.standardError = err
            out.fileHandleForReading.readabilityHandler = { lines.append(String(decoding: $0.availableData, as: UTF8.self)) }
            try process.run()
            let listening = Date().addingTimeInterval(30)
            while !printed.all().joined().contains("Listening on"), process.isRunning, Date() < listening { usleep(20_000) }
            if process.isRunning { break }
            out.fileHandleForReading.readabilityHandler = nil
            let failure = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard failure.contains("Address already in use") else { break }
        }
        let served = process
        defer { if served.isRunning { kill(served.processIdentifier, SIGKILL); served.waitUntilExit() } }
        try #require(process.isRunning)

        _ = try MobilePairing.loadToken(in: dir, fresh: true)

        let exited = Date().addingTimeInterval(30)
        while process.isRunning, Date() < exited { usleep(20_000) }
        try #require(!process.isRunning)
        #expect(process.terminationStatus == 1)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(stderr.contains("agtermctl: \(PhoneRelayLine.pairingReset)\n"))
        #expect(stderr.contains("agtermctl: bluetooth: off (disabled)\n"))
        #expect(!printed.all().joined().contains("b=1"))
    }

    @Test func anInMemoryPhoneAuthenticatesForwardsAndReleasesItsGridOnClose() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let phone = MemoryPhone(queue: fixture.relay.queue)
        fixture.relay.queue.sync { fixture.relay.accept(phone) }
        phone.deliver(#"{"auth":"\#(fixture.token)","id":1}"# + "\n")
        #expect(phone.readJSON()?["ok"] as? Bool == true)
        phone.deliver(#"{"cmd":"session.grid","target":"S1","args":{"columns":40,"rows":20},"id":2}"# + "\n")
        let answer = try #require(phone.readJSON())
        #expect(answer["id"] as? Int == 2 && (answer["result"] as? [String: Any])?["echo"] as? String == "session.grid")
        let before = fixture.server.requests().count
        phone.peerLeft()
        let right = #"{"args":{"pane":"right","reset":true},"cmd":"session.grid","target":"S1"}"#
        #expect(fixture.server.waitFor(right, after: before))
        #expect(fixture.logged().contains("phone disconnected from mem:1"))
        #expect(phone.closed())
    }

    @Test func secondRelayOnTheSamePortFails() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let other = MobileRelay(identity: fixture.identity, port: fixture.port, bind: nil, mobileDir: fixture.mobileDir,
                                socketPath: fixture.server.path, hostName: "test-mac")
        #expect(throws: (any Error).self) { try other.start() }
        other.stop()
    }
}

struct MobileBluetoothTests {
    @Test func pairLinkOffersBluetoothAndOmitsAMissingHost() {
        let link = MobilePairing.pairLink(host: "10.0.0.2", port: 8765, token: "T", fingerprint: "ab", name: "Mac", bluetooth: true)
        #expect(link == "agterm://pair?h=10.0.0.2&p=8765&t=T&f=ab&n=Mac&b=1")
        let radioOnly = MobilePairing.pairLink(host: nil, port: 8765, token: "T", fingerprint: "ab", name: "Mac", bluetooth: true)
        #expect(radioOnly == "agterm://pair?t=T&f=ab&n=Mac&b=1")
        #expect(!MobilePairing.pairLink(host: "h", port: 1, token: "T", fingerprint: "ab", name: "Mac", bluetooth: false).contains("b="))
    }

    @Test func aPairedPhoneHandshakesForwardsAndGivesBackItsGrid() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let phone = try BlePhone(fixture)
        try phone.handshake(token: fixture.token)
        phone.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(phone.readJSON()?["ok"] as? Bool == true)
        phone.send(#"{"cmd":"session.grid","target":"S1","args":{"columns":40,"rows":20},"id":2}"#)
        #expect(phone.readJSON()?["id"] as? Int == 2)
        let before = fixture.server.requests().count
        phone.close()
        let right = #"{"args":{"pane":"right","reset":true},"cmd":"session.grid","target":"S1"}"#
        #expect(fixture.server.waitFor(right, after: before))
        let label = "bt:" + phone.message1.prefix(2).map { String(format: "%02x", $0) }.joined()
        #expect(fixture.logged().contains("phone connected from \(label)"))
        #expect(fixture.waitLogged("phone disconnected from \(label)"))
    }

    @Test func aWrongKeyGetsTheRejectFrameBeforeTheClose() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let phone = try BlePhone(fixture)
        try phone.sendMessage1(token: String(repeating: "z", count: 43))
        #expect(phone.readFrame() == Data([0x01]))
        #expect(phone.waitClosed())
    }

    @Test func aPhoneOverTheCapGetsBusy() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let radio = MobileBluetooth(relay: fixture.relay, token: fixture.token, maxPhones: 1, status: { _ in })
        let first = try BlePhone(fixture, radio)
        try first.handshake(token: fixture.token)
        first.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(first.readJSON()?["ok"] as? Bool == true)
        let second = try BlePhone(fixture, radio)
        try second.sendMessage1(token: fixture.token)
        #expect(second.readFrame() == Data([0x02]))
        #expect(second.waitClosed())
    }

    @Test func theUnauthorizedAnswerArrivesBeforeTheClose() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let phone = try BlePhone(fixture)
        try phone.handshake(token: fixture.token)
        phone.send(#"{"auth":"\#(String(repeating: "z", count: 43))","id":3}"#)
        #expect(phone.readJSON()?["error"] as? String == "unauthorized")
        #expect(phone.waitClosed())
    }

    @Test func aLongLineCrossesFramesIntactBothWays() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let phone = try BlePhone(fixture)
        try phone.handshake(token: fixture.token)
        phone.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(phone.readJSON()?["ok"] as? Bool == true)
        // random letters barely deflate, so the answer outruns the socket buffer
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let cmd = String((0..<20000).map { _ in alphabet.randomElement() ?? "a" })
        phone.send(#"{"cmd":"\#(cmd)","id":2}"#)
        let answer = try #require(phone.readJSON())
        #expect((answer["result"] as? [String: Any])?["echo"] as? String == cmd)
        #expect(phone.framesOpened > 5)
    }

    @Test func aTamperedFrameClosesWithoutForwarding() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let phone = try BlePhone(fixture)
        try phone.handshake(token: fixture.token)
        phone.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(phone.readJSON()?["ok"] as? Bool == true)
        let before = fixture.server.requests().count
        var frame = try phone.seal(#"{"cmd":"tree","id":2}"# + "\n")
        frame[frame.count - 1] ^= 0x01
        phone.write(BleFramer.frame(frame))
        #expect(phone.waitClosed())
        #expect(fixture.server.requests().count == before)
    }

    @Test func replayedHandshakesDoNotHoldTheCapFromAPairedPhone() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let radio = MobileBluetooth(relay: fixture.relay, token: fixture.token, maxPhones: 1, status: { _ in })
        let sniffed = try BlePhone(fixture, radio)
        try sniffed.handshake(token: fixture.token)
        let replay = try BlePhone(fixture, radio)
        replay.write(BleFramer.frame(sniffed.message1))
        #expect(replay.readFrame()?.count == 48)
        let paired = try BlePhone(fixture, radio)
        try paired.handshake(token: fixture.token)
        paired.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(paired.readJSON()?["ok"] as? Bool == true)
        let late = try BlePhone(fixture, radio)
        try late.sendMessage1(token: fixture.token)
        #expect(late.readFrame() == Data([0x02]))
    }

    @Test func outputDrainsWhenTheStreamStopsReportingSpace() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let phone = try BlePhone(fixture, output: FakeOutput())
        try phone.handshake(token: fixture.token)
        phone.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(phone.readJSON()?["ok"] as? Bool == true)
    }

    @Test func aPhoneThatStopsReadingIsDropped() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let radio = MobileBluetooth(relay: fixture.relay, token: fixture.token, limits: .init(maxPending: 64 << 10), status: { _ in })
        let phone = try BlePhone(fixture, radio)
        try phone.handshake(token: fixture.token)
        phone.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(phone.readJSON()?["ok"] as? Bool == true)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        for id in 2..<14 {
            let cmd = String((0..<20000).map { _ in alphabet.randomElement() ?? "a" })
            phone.send(#"{"cmd":"\#(cmd)","id":\#(id)}"#)
        }
        #expect(fixture.waitLogged("phone disconnected from \(phone.label)"))
    }

    @Test func poweringOffDropsBluetoothPhonesAndTheirGrids() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let lines = LogLines()
        let radio = MobileBluetooth(relay: fixture.relay, token: fixture.token, status: { lines.append($0) })
        let phone = try BlePhone(fixture, radio)
        try phone.handshake(token: fixture.token)
        phone.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(phone.readJSON()?["ok"] as? Bool == true)
        phone.send(#"{"cmd":"session.grid","target":"S1","args":{"columns":40,"rows":20},"id":2}"#)
        #expect(phone.readJSON()?["id"] as? Int == 2)
        let before = fixture.server.requests().count
        fixture.relay.queue.sync { radio.off("powered off") }
        #expect(phone.waitClosed())
        #expect(fixture.server.waitFor(#"{"args":{"pane":"right","reset":true},"cmd":"session.grid","target":"S1"}"#, after: before))
        #expect(lines.all() == ["off (powered off)"])
    }

    @Test func aFailedRotationKeepsOpenPhones() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let lines = LogLines()
        let radio = MobileBluetooth(relay: fixture.relay, token: fixture.token, status: { lines.append($0) })
        let phone = try BlePhone(fixture, radio)
        try phone.handshake(token: fixture.token)
        phone.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(phone.readJSON()?["ok"] as? Bool == true)
        fixture.relay.queue.sync { radio.advertisingFailed("service", CocoaError(.featureUnsupported)) }
        phone.send(#"{"cmd":"tree","id":2}"#)
        #expect(phone.readJSON()?["id"] as? Int == 2)
        #expect(lines.all() == ["off (unsupported)"])
        #expect(fixture.logged().contains { $0.hasPrefix("bluetooth service failed: ") })
    }

    @Test func aCloseStopsWaitingForAPhoneThatStopsReading() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let radio = MobileBluetooth(relay: fixture.relay, token: fixture.token, limits: .init(flushTimeout: 0.3), status: { _ in })
        let output = FakeOutput()
        let phone = try BlePhone(fixture, radio, output: output)
        try phone.handshake(token: fixture.token)
        output.stall()
        phone.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        try #require(fixture.waitLogged("phone connected from \(phone.label)"))
        fixture.relay.queue.sync { radio.off("powered off") }
        #expect(output.waitClosed())
    }

    @Test func anUnopenableLockIsNotReportedAsBusy() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        try FileManager.default.createDirectory(atPath: fixture.mobileDir + "/bluetooth.lock", withIntermediateDirectories: false)
        let lines = LogLines()
        #expect(!MobileBluetooth(relay: fixture.relay, token: fixture.token, status: { lines.append($0) }).start())
        #expect(lines.all() == ["off (unsupported)"])
        #expect(fixture.logged().contains { $0.hasPrefix("bluetooth: cannot open ") })
    }

    @Test func aHeldLockLeavesBluetoothOffForThisRelay() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let held = open(fixture.mobileDir + "/bluetooth.lock", O_RDWR | O_CREAT, 0o600)
        defer { close(held) }
        try #require(flock(held, LOCK_EX | LOCK_NB) == 0)
        let lines = LogLines()
        // never reaches CoreBluetooth: the lock is taken first
        MobileBluetooth(relay: fixture.relay, token: fixture.token, status: { lines.append($0) }).start()
        #expect(lines.all() == ["off (in use by another relay)"])
    }
}

// MARK: - fixtures

/// The phone's end of an L2CAP channel: a socket pair whose other end the relay reads as streams.
private final class BlePhone: @unchecked Sendable {
    private(set) var message1 = Data()
    private(set) var framesOpened = 0
    private let fd: Int32
    private var framer = BleFramer()
    private var frames: [Data] = []
    private var keys: BleTransportKeys?
    private var lines = Data()
    private var closed = false
    private let radio: MobileBluetooth
    private let fake: FakeOutput?

    /// With `output`, the relay writes into that fake instead of the socket.
    init(_ fixture: MobileFixture, _ radio: MobileBluetooth? = nil, output: FakeOutput? = nil) throws {
        let radio = radio ?? MobileBluetooth(relay: fixture.relay, token: fixture.token, status: { _ in })
        self.radio = radio
        fake = output
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        fd = fds[1]
        var on: Int32 = 1
        for end in fds { setsockopt(end, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) }
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var input: Unmanaged<CFReadStream>?, output: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocket(nil, fds[0], &input, &output)
        let read = try #require(input).takeRetainedValue(), write = try #require(output).takeRetainedValue()
        CFReadStreamSetProperty(read, CFStreamPropertyKey(kCFStreamPropertyShouldCloseNativeSocket), kCFBooleanTrue)
        fixture.relay.queue.sync { radio.accept(input: read as InputStream, output: fake ?? write as OutputStream, holding: nil) }
    }

    var label: String { "bt:" + message1.prefix(2).map { String(format: "%02x", $0) }.joined() }

    func sendMessage1(token: String) throws {
        var initiator = BleInitiator(psk: BleIDs.psk(token: token))
        message1 = try initiator.start()
        write(BleFramer.frame(message1))
    }

    func handshake(token: String) throws {
        var initiator = BleInitiator(psk: BleIDs.psk(token: token))
        message1 = try initiator.start()
        write(BleFramer.frame(message1))
        keys = try initiator.finish(try #require(readFrame()))
    }

    func seal(_ text: String) throws -> Data {
        var sealing = try #require(keys)
        defer { keys = sealing }
        return try sealing.seal(Data(text.utf8))
    }

    func send(_ text: String) {
        let data = Data((text + "\n").utf8)
        for start in stride(from: 0, to: data.count, by: BleTransportKeys.maxChunk) {
            let sealed = try? keys?.seal(data.subdata(in: start..<min(start + BleTransportKeys.maxChunk, data.count)))
            write(BleFramer.frame(sealed ?? Data()))
        }
    }

    func write(_ data: Data) {
        _ = StreamBridge.writeAll(fd, data)
    }

    /// The next frame body, or nil at end of stream or after the read timeout.
    func readFrame() -> Data? {
        var bytes = [UInt8](repeating: 0, count: 4096)
        while frames.isEmpty {
            if let fake {
                guard let data = fake.next() else { return nil }
                frames += framer.push(data)
                continue
            }
            let count = read(fd, &bytes, bytes.count)
            guard count > 0 else { return nil }
            frames += framer.push(Data(bytes[..<count]))
        }
        return frames.removeFirst()
    }

    func readJSON() -> [String: Any]? {
        while true {
            if let newline = lines.firstIndex(of: 0x0A) {
                let line = Data(lines[lines.startIndex..<newline])
                lines = Data(lines[(newline + 1)...])
                return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            }
            guard let frame = readFrame(), let plain = try? keys?.open(frame) else { return nil }
            framesOpened += 1
            lines.append(plain)
        }
    }

    /// True once the relay closed its end; a frame still unread counts against it.
    func waitClosed() -> Bool {
        var byte: UInt8 = 0
        return frames.isEmpty && read(fd, &byte, 1) == 0
    }

    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }

    deinit { close() }
}

/// An output stream that never reports events, so only the relay's own retries move bytes: it takes `chunk` bytes
/// per write and reports no space right after one, and none at all once stalled.
private final class FakeOutput: OutputStream, @unchecked Sendable {
    private let lock = NSLock()
    private let changed = DispatchSemaphore(value: 0)
    private let chunk: Int
    private var written = Data()
    private var taken = 0
    private var justWrote = false
    private var stalled = false
    private var isClosed = false
    private weak var watcher: (any StreamDelegate)?

    init(chunk: Int = 8) {
        self.chunk = chunk
        super.init(toMemory: ())
    }

    override var delegate: (any StreamDelegate)? {
        get { watcher }
        set { watcher = newValue }
    }

    override func open() {}
    override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
    override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
    override var streamStatus: Stream.Status { lock.withLock { isClosed ? .closed : .open } }

    override var hasSpaceAvailable: Bool {
        lock.withLock {
            defer { justWrote = false }
            return !stalled && !justWrote && !isClosed
        }
    }

    override func write(_ buffer: UnsafePointer<UInt8>, maxLength len: Int) -> Int {
        let count = lock.withLock {
            let count = min(len, chunk)
            written.append(buffer, count: count)
            justWrote = true
            return count
        }
        changed.signal()
        return count
    }

    override func close() {
        lock.withLock { isClosed = true }
        changed.signal()
    }

    func stall() { lock.withLock { stalled = true } }
    func closed() -> Bool { lock.withLock { isClosed } }

    /// Bytes written since the last call; nil once closed with nothing new, or after 30 s.
    func next() -> Data? {
        let deadline = Date().addingTimeInterval(30)
        while true {
            let (data, done): (Data, Bool) = lock.withLock {
                defer { taken = written.count }
                return (written.subdata(in: taken..<written.count), isClosed)
            }
            if !data.isEmpty { return data }
            if done || changed.wait(timeout: .now() + deadline.timeIntervalSinceNow) == .timedOut { return nil }
        }
    }

    func waitClosed() -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while !closed() {
            if Date() > deadline { return false }
            usleep(20_000)
        }
        return true
    }
}

private final class MobileFixture: @unchecked Sendable {
    let mobileDir: String
    let token: String
    let identity: SecIdentity
    let fingerprint: String
    let server = RawStubServer()
    let relay: MobileRelay
    let port: UInt16
    private let lines = LogLines()

    init(maxUnauthenticated: Int = 32) throws {
        mobileDir = try Self.privateDirectory()
        token = try MobilePairing.loadToken(in: mobileDir)
        try MobilePairing.ensureCertificate(in: mobileDir)
        (identity, fingerprint) = try MobilePairing.identity(in: mobileDir)
        try server.start()
        let lines = lines
        relay = MobileRelay(identity: identity, port: 0, bind: "127.0.0.1", mobileDir: mobileDir, socketPath: server.path,
                            // a release bound a loaded runner cannot run out; the stub answers at once
                            hostName: "test-mac", revokeInterval: 0.3, maxUnauthenticated: maxUnauthenticated, releaseTimeout: 30,
                            log: { lines.append($0) })
        port = try relay.start()
    }

    func logged() -> [String] { lines.all() }

    func waitLogged(_ line: String) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while !logged().contains(line) {
            if Date() > deadline { return false }
            usleep(20_000)
        }
        return true
    }

    func connect() throws -> TLSLineClient { try TLSLineClient(port: port) }

    func stop() {
        relay.stop()
        server.stop()
        try? FileManager.default.removeItem(atPath: (mobileDir as NSString).deletingLastPathComponent)
    }

    static func privateDirectory() throws -> String {
        let base = NSTemporaryDirectory() + "agterm-mobile-\(UUID().uuidString.prefix(8))"
        let dir = base + "/mobile"
        try MobilePairing.ensurePrivateDirectory(dir)
        return dir
    }

    /// Reads the matrix back through CoreImage's own QR detector, at 8 pixels a module with a 4-module quiet zone.
    static func decodeQR(_ matrix: [[Bool]]) -> String? {
        let scale = 8, side = (matrix.count + 8) * scale
        var pixels = [UInt8](repeating: 255, count: side * side)
        for (y, row) in matrix.enumerated() {
            for (x, dark) in row.enumerated() where dark {
                for dy in 0..<scale { for dx in 0..<scale { pixels[((y + 4) * scale + dy) * side + (x + 4) * scale + dx] = 0 } }
            }
        }
        let image = CIImage(bitmapData: Data(pixels), bytesPerRow: side, size: CGSize(width: side, height: side),
                            format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil)
        return (detector?.features(in: image).first as? CIQRCodeFeature)?.messageString
    }

    static func mode(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? Int ?? -1) & 0o777
    }
}

/// A blocking line client over TLS that trusts any certificate and records the one it saw.
private final class TLSLineClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "mobile.test.client")
    private let lock = NSLock()
    private let changed = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var closed = false
    private(set) var peerFingerprint: String?

    init(port: UInt16) throws {
        let tls = NWProtocolTLS.Options()
        let fingerprintBox = FingerprintBox()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
            if let leaf = chain?.first {
                fingerprintBox.value = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
            }
            complete(true)
        }, queue)
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                  using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        let ready = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: ready.signal()
            case .failed, .cancelled, .waiting: self?.markClosed(); ready.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        guard ready.wait(timeout: .now() + 30) == .success, connection.state == .ready else {
            connection.cancel()
            throw CocoaError(.fileReadUnknown)
        }
        peerFingerprint = fingerprintBox.value
        receive()
    }

    deinit { connection.cancel() }

    func close() { connection.cancel() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            lock.withLock { if let data { buffer.append(data) } }
            changed.signal()
            if done || error != nil { markClosed() } else { receive() }
        }
    }

    private func markClosed() {
        lock.withLock { closed = true }
        changed.signal()
    }

    func send(_ text: String, newline: Bool = true) {
        connection.send(content: Data((newline ? text + "\n" : text).utf8), completion: .idempotent)
    }

    func readJSON(timeout: TimeInterval = 30) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let line: Data? = lock.withLock {
                guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                return Data(line)
            }
            if let line { return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] }
            if lock.withLock({ closed }) || changed.wait(timeout: .now() + deadline.timeIntervalSinceNow) == .timedOut { return nil }
        }
    }

    func waitClosed(timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !lock.withLock({ closed }) {
            if changed.wait(timeout: .now() + deadline.timeIntervalSinceNow) == .timedOut { return false }
        }
        return true
    }
}

/// A phone connection with no transport: the test feeds bytes in on the relay queue and reads the lines sent back.
private final class MemoryPhone: PhoneTransportConnection, @unchecked Sendable {
    let peerLabel = "mem:1"
    var onReceive: ((Data) -> Void)?
    var onClose: (() -> Void)?
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let changed = DispatchSemaphore(value: 0)
    private var sent: [Data] = []
    private var isClosed = false

    init(queue: DispatchQueue) { self.queue = queue }

    func deliver(_ text: String) { queue.async { self.onReceive?(Data(text.utf8)) } }
    func peerLeft() { queue.async { self.onClose?() } }
    func closed() -> Bool { lock.withLock { isClosed } }

    func send(_ data: Data, completion: @escaping () -> Void) {
        lock.withLock { sent.append(data) }
        changed.signal()
        completion()
    }

    func close() { lock.withLock { isClosed = true } }

    func readJSON(timeout: TimeInterval = 30) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let line = lock.withLock({ sent.isEmpty ? nil : sent.removeFirst() }) {
                return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            }
            if changed.wait(timeout: .now() + deadline.timeIntervalSinceNow) == .timedOut { return nil }
        }
    }
}

private final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    func all() -> [String] { lock.withLock { lines } }
}

private final class FingerprintBox: @unchecked Sendable { var value: String? }

/// A control socket stub that answers `version` with 9.9.9 and every other line with `{"echo":cmd}`, keeping the raw lines.
private final class RawStubServer: @unchecked Sendable {
    let path = "/tmp/agm-\(UUID().uuidString.prefix(8)).sock"
    private let lock = NSLock()
    private var received: [String] = []
    private var stopped = false

    func requests() -> [String] { lock.withLock { received } }

    /// Whether `line` arrives among the requests after the first `count`, within a slow-runner bound.
    func waitFor(_ line: String, after count: Int) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while !requests().dropFirst(count).contains(line) {
            if Date() > deadline { return false }
            usleep(20_000)
        }
        return true
    }

    func start() throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            path.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard fd >= 0, bound == 0, listen(fd, 8) == 0 else { close(fd); throw CocoaError(.fileWriteUnknown) }
        Thread.detachNewThread { [self] in
            while true {
                let conn = accept(fd, nil, nil)
                // stop() wakes this accept with a connection of its own; the fd closes here, never under a blocked accept
                if conn < 0 || lock.withLock({ stopped }) {
                    if conn >= 0 { close(conn) }
                    close(fd)
                    return
                }
                serve(conn)
                close(conn)
            }
        }
    }

    private func serve(_ conn: Int32) {
        var line = Data()
        var byte: UInt8 = 0
        while read(conn, &byte, 1) == 1, byte != 0x0A { line.append(byte) }
        guard byte == 0x0A, let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        lock.withLock { received.append(String(decoding: line, as: UTF8.self)) }
        let cmd = object["cmd"] as? String ?? ""
        let reply = cmd == "version" ? #"{"ok":true,"result":{"app":{"version":"9.9.9"}}}"# : #"{"ok":true,"result":{"echo":"\#(cmd)"}}"#
        let data = Data((reply + "\n").utf8)
        data.withUnsafeBytes { _ = UnixSocket.write(conn, $0.baseAddress!, data.count) }
    }

    func stop() {
        lock.withLock { stopped = true }
        if let wake = try? SocketClient(path: path).connect() { close(wake) }
        unlink(path)
    }
}
#endif
