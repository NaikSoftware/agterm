import Foundation
import Testing
@testable import HangarCore

struct DebugStateDirectoryTests {
    static let live = URL(fileURLWithPath: "/Users/me/Library/Application Support/hangar", isDirectory: true)

    @Test func anUnisolatedLaunchAdoptsASiblingOfTheLiveDirectory() {
        #expect(DebugStateDirectory.adopted(environment: [:], liveDirectory: Self.live)
            == "/Users/me/Library/Application Support/hangar-debug")
        #expect(DebugStateDirectory.adopted(environment: ["HANGAR_STATE_DIR": ""], liveDirectory: Self.live)
            == "/Users/me/Library/Application Support/hangar-debug")
    }

    @Test func anExplicitDirectoryIsKeptEvenWhenItIsTheLiveOne() {
        #expect(DebugStateDirectory.adopted(environment: ["HANGAR_STATE_DIR": "/tmp/s"], liveDirectory: Self.live) == nil)
        #expect(DebugStateDirectory.adopted(environment: ["HANGAR_STATE_DIR": Self.live.path],
                                            liveDirectory: Self.live) == nil)
    }

    @Test func theAdoptedDirectoryKeepsTheUsersConfigAndAnyOtherRedirectsIt() {
        let adopted = "/Users/me/Library/Application Support/hangar-debug"
        #expect(DebugStateDirectory.configStateDirectory(environment: ["HANGAR_STATE_DIR": adopted],
                                                         liveDirectory: Self.live) == nil)
        #expect(DebugStateDirectory.configStateDirectory(environment: [:], liveDirectory: Self.live) == nil)
        #expect(DebugStateDirectory.configStateDirectory(environment: ["HANGAR_STATE_DIR": "/tmp/s"],
                                                         liveDirectory: Self.live) == "/tmp/s")
        #expect(DebugStateDirectory.configStateDirectory(environment: ["HANGAR_STATE_DIR": Self.live.path],
                                                         liveDirectory: Self.live) == Self.live.path)
    }

    @Test func theAdoptedSocketPathFitsTheUnixSocketLimit() throws {
        let home = URL(fileURLWithPath: "/Users/averagelongusername/Library/Application Support/hangar", isDirectory: true)
        let adopted = try #require(DebugStateDirectory.adopted(environment: [:], liveDirectory: home))
        #expect(ControlResolve.socketPath(stateDir: adopted, appSupport: home.path).utf8.count < 104)
    }
}
