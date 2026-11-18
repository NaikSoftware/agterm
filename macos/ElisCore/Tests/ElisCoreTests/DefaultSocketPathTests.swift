import Foundation
import Testing
@testable import ElisCore

// macOS only: the app resolves via Application Support; Linux's elis-server uses `defaultStateDirectory` (XDG state dir).
#if os(macOS)
struct DefaultSocketPathTests {
    // The CLI side mirrors `BasicOptions.socketPath`; the app side mirrors `ControlServer.defaultSocketPath`.
    @Test func testCLIAndAppDefaultSocketMatch() {
        let home = NSHomeDirectory()
        let cli = ControlResolve.socketPath(stateDir: nil,
                                            appSupport: ControlResolve.defaultStateDirectory(environment: ["HOME": home]))
        let app = ControlResolve.socketPath(stateDir: nil, appSupport: PersistenceStore.defaultDirectory.path)
        #expect(cli == home + "/Library/Application Support/elis/elis.sock")
        #expect(app == cli)
    }
}
#endif
