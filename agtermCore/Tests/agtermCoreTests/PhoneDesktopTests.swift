import Foundation
import Testing
@testable import agtermCore

struct PhoneDesktopTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("phone-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func missingFileIsOffOnTheDefaultPort() {
        #expect(PhoneDesktopState.load(stateDirectory: tempDir()) == PhoneDesktopState())
        #expect(PhoneDesktopState().on == false)
        #expect(PhoneDesktopState().port == 8765)
    }

    @Test func savedStateRoundTripsInAPrivateDirectory() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = PhoneDesktopState(on: true, port: 9001, host: "mac.tail1234.ts.net")
        try state.save(stateDirectory: dir)
        #expect(PhoneDesktopState.load(stateDirectory: dir) == state)
        let mobile = dir.appendingPathComponent("mobile").path
        let mode = try FileManager.default.attributesOfItem(atPath: mobile)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o700)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: mobile + "/desktop.json")))
        #expect((json as? [String: Any])?.keys.sorted() == ["host", "on", "port"])
    }

    @Test func partialOrOutOfRangeFileFallsBackPerField() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("mobile"), withIntermediateDirectories: true)
        try Data(#"{"on":true,"port":70000}"#.utf8).write(to: dir.appendingPathComponent("mobile/desktop.json"))
        #expect(PhoneDesktopState.load(stateDirectory: dir) == PhoneDesktopState(on: true, port: 8765, host: ""))
    }

    private let link = "agterm://pair?h=192.168.0.5&p=8765&t=abc-_x&f=0a1b&n=Nick%27s%20Mac%2BBook%20Pro"

    @Test func hostReplacementKeepsEveryOtherByte() {
        let swapped = PhonePairLink.withHost(link, host: " mac.tail1234.ts.net ")
        #expect(swapped == "agterm://pair?h=mac.tail1234.ts.net&p=8765&t=abc-_x&f=0a1b&n=Nick%27s%20Mac%2BBook%20Pro")
        #expect(PhonePairLink.host(of: swapped) == "mac.tail1234.ts.net")
    }

    @Test func blankHostOrLinkWithoutHostIsUnchanged() {
        #expect(PhonePairLink.withHost(link, host: "  ") == link)
        #expect(PhonePairLink.withHost("agterm://pair?p=1", host: "x") == "agterm://pair?p=1")
    }

    @Test func hostIsPercentEncoded() {
        #expect(PhonePairLink.withHost(link, host: "a&b c").hasPrefix("agterm://pair?h=a%26b%20c&p=8765"))
        #expect(PhonePairLink.host(of: link) == "192.168.0.5")
    }

    @Test func relayLinesAreClassified() {
        #expect(PhoneRelayLine.link(link) == link)
        #expect(PhoneRelayLine.link("Listening on *:8765.") == nil)
        #expect(PhoneRelayLine.stderr("agtermctl: phone connected from 10.0.0.2") == .event("phone connected from 10.0.0.2"))
        #expect(PhoneRelayLine.stderr("agtermctl: refused 10.0.0.3: wrong token") == .event("refused 10.0.0.3: wrong token"))
        #expect(PhoneRelayLine.stderr("agtermctl: cannot listen on *:8765: Address already in use")
                == .other("cannot listen on *:8765: Address already in use"))
        #expect(PhoneRelayLine.stderr("   ") == nil)
    }
}
