import Foundation
import Testing
@testable import HangarCore

struct DefaultSocketPathTests {
    // The CLI side mirrors `BasicOptions.socketPath`; the app side mirrors `ControlServer.defaultSocketPath`.
    @Test func testCLIAndAppDefaultSocketMatch() {
        let home = NSHomeDirectory()
        let cli = ControlResolve.socketPath(stateDir: nil,
                                            appSupport: ControlResolve.defaultStateDirectory(environment: ["HOME": home]))
        let app = ControlResolve.socketPath(stateDir: nil, appSupport: PersistenceStore.defaultDirectory.path)
        #expect(cli == home + "/Library/Application Support/hangar/hangar.sock")
        #expect(app == cli)
    }
}
