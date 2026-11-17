import Foundation
import Testing
@testable import HangarCore

struct SurfaceEnvironmentTests {
    @Test func terminalIdentityBelongsToHangar() {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let windowID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        let sessionEnv = SurfaceEnvironment.session(
            sessionID: sessionID,
            windowID: windowID,
            workspaceID: nil,
            socketPath: "/tmp/hangar.sock",
            programVersion: "0.12.0"
        )
        let quickEnv = SurfaceEnvironment.quickTerminal(
            socketPath: "/tmp/hangar.sock",
            programVersion: "0.12.0"
        )

        for env in [sessionEnv, quickEnv] {
            #expect(env["TERM_PROGRAM"] == "hangar")
            #expect(env["TERM_PROGRAM_VERSION"] == "0.12.0")
        }
    }

    @Test func sessionEnvironmentCarriesAllKnownIdentifiers() {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let windowID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let workspaceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

        let env = SurfaceEnvironment.session(
            sessionID: sessionID,
            windowID: windowID,
            workspaceID: workspaceID,
            socketPath: "/tmp/hangar.sock",
            programVersion: "0.12.0"
        )

        #expect(env == [
            "HANGAR_ENABLED": "1",
            "HANGAR_SESSION_ID": "11111111-1111-1111-1111-111111111111",
            "HANGAR_WINDOW_ID": "22222222-2222-2222-2222-222222222222",
            "HANGAR_WORKSPACE_ID": "33333333-3333-3333-3333-333333333333",
            "HANGAR_SOCKET": "/tmp/hangar.sock",
            "TERM_PROGRAM": "hangar",
            "TERM_PROGRAM_VERSION": "0.12.0",
        ])
    }

    @Test func sessionEnvironmentOmitsUnknownWindowAndWorkspace() {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

        let env = SurfaceEnvironment.session(
            sessionID: sessionID,
            windowID: nil,
            workspaceID: nil,
            socketPath: "/tmp/hangar.sock",
            programVersion: "0.12.0"
        )

        #expect(env == [
            "HANGAR_ENABLED": "1",
            "HANGAR_SESSION_ID": "11111111-1111-1111-1111-111111111111",
            "HANGAR_SOCKET": "/tmp/hangar.sock",
            "TERM_PROGRAM": "hangar",
            "TERM_PROGRAM_VERSION": "0.12.0",
        ])
    }

    @Test(arguments: [
        (StatusPane.left, "left"),
        (StatusPane.right, "right"),
        (StatusPane.scratch, "scratch"),
    ])
    func sessionEnvironmentInjectsPaneWhenGiven(pane: StatusPane, expected: String) {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

        let env = SurfaceEnvironment.session(
            sessionID: sessionID,
            windowID: nil,
            workspaceID: nil,
            socketPath: "/tmp/hangar.sock",
            programVersion: "0.12.0",
            pane: pane
        )

        #expect(env["HANGAR_PANE"] == expected)
        #expect(env["HANGAR_ENABLED"] == "1")
        #expect(env["HANGAR_SESSION_ID"] == "11111111-1111-1111-1111-111111111111")
        #expect(env["HANGAR_SOCKET"] == "/tmp/hangar.sock")
    }

    @Test func sessionEnvironmentOmitsPaneWhenNil() {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let windowID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let workspaceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

        let env = SurfaceEnvironment.session(
            sessionID: sessionID,
            windowID: windowID,
            workspaceID: workspaceID,
            socketPath: "/tmp/hangar.sock",
            programVersion: "0.12.0",
            pane: nil
        )

        #expect(env["HANGAR_PANE"] == nil)
        #expect(env == [
            "HANGAR_ENABLED": "1",
            "HANGAR_SESSION_ID": "11111111-1111-1111-1111-111111111111",
            "HANGAR_WINDOW_ID": "22222222-2222-2222-2222-222222222222",
            "HANGAR_WORKSPACE_ID": "33333333-3333-3333-3333-333333333333",
            "HANGAR_SOCKET": "/tmp/hangar.sock",
            "TERM_PROGRAM": "hangar",
            "TERM_PROGRAM_VERSION": "0.12.0",
        ])
    }

    @Test func sessionEnvironmentInjectsPaneTokenWhenGiven() {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

        let env = SurfaceEnvironment.session(
            sessionID: sessionID,
            windowID: nil,
            workspaceID: nil,
            socketPath: "/tmp/hangar.sock",
            programVersion: "0.12.0",
            pane: .right,
            paneToken: "surface-token-abc"
        )

        #expect(env["HANGAR_PANE_ID"] == "surface-token-abc")
        #expect(env["HANGAR_PANE"] == "right")
    }

    @Test(arguments: [nil, ""])
    func sessionEnvironmentOmitsPaneTokenWhenNilOrEmpty(token: String?) {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

        let env = SurfaceEnvironment.session(
            sessionID: sessionID,
            windowID: nil,
            workspaceID: nil,
            socketPath: "/tmp/hangar.sock",
            programVersion: "0.12.0",
            pane: .left,
            paneToken: token
        )

        #expect(env["HANGAR_PANE_ID"] == nil)
    }

    /// The panel is one per app and belongs to no window, so it carries no window id either — an untargeted
    /// `hangarctl` run from it resolves the active window like any other caller.
    @Test func quickTerminalEnvironmentOmitsSessionWorkspaceAndWindowIdentifiers() {
        let env = SurfaceEnvironment.quickTerminal(
            socketPath: "/tmp/hangar.sock",
            programVersion: "0.12.0"
        )

        #expect(env == [
            "HANGAR_ENABLED": "1",
            "HANGAR_SOCKET": "/tmp/hangar.sock",
            "TERM_PROGRAM": "hangar",
            "TERM_PROGRAM_VERSION": "0.12.0",
        ])
        #expect(env["HANGAR_SESSION_ID"] == nil)
        #expect(env["HANGAR_WORKSPACE_ID"] == nil)
        #expect(env["HANGAR_WINDOW_ID"] == nil)
    }

    @Test func emptySocketPathIsStillEmitted() {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

        let env = SurfaceEnvironment.session(
            sessionID: sessionID,
            windowID: nil,
            workspaceID: nil,
            socketPath: "",
            programVersion: "0.12.0"
        )

        #expect(env["HANGAR_SOCKET"] == "")
    }

    /// both factories must always SET the variable. The shipped status hooks drop `--socket` when it is
    /// absent, and `hangarctl` then resolves the default path — another instance's.
    @Test func bothFactoriesAlwaysSetTheSocketVariable() {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let windowID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let unavailable = "/tmp/hangar.sock.unavailable"

        let sessionEnv = SurfaceEnvironment.session(
            sessionID: sessionID,
            windowID: nil,
            workspaceID: nil,
            socketPath: unavailable,
            programVersion: "0.12.0"
        )
        let quickEnv = SurfaceEnvironment.quickTerminal(
            socketPath: unavailable,
            programVersion: "0.12.0"
        )

        #expect(sessionEnv["HANGAR_SOCKET"] == unavailable)
        #expect(quickEnv["HANGAR_SOCKET"] == unavailable)
    }
}
