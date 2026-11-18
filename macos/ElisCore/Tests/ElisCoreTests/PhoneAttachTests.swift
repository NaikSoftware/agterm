import Foundation
import Testing
@testable import ElisCore

struct PhoneAttachTests {
    let endpoint = ControlZmxEndpoint(executable: "/Applications/Elis.app/zmx", socketDirectory: "/tmp/zmx-x")
    let daemon = ZmxSupport.daemonName(for: UUID())

    @Test func viewerLeadSetsScreenOnlyAndFollowNotClaim() {
        let viewer = ZmxLeadAttachment.viewer

        #expect(viewer.environment == ["ZMX_MANAGED": viewer.nonce, "ZMX_MANAGED_SCREEN_ONLY": "1", "ZMX_MANAGED_FOLLOW": "1"])
        #expect(!viewer.claim)
        #expect(ZmxLeadAttachment.viewer.nonce != viewer.nonce)
    }

    @Test func attachCommandOutputIsUnchanged() throws {
        let argv = try RemoteSession.attachCommand(host: "buildbox", endpoint: endpoint, daemon: daemon)
        let guardScript = "printf '%s\\n' 'elis: remote session is gone'; exit 1"
        let remote = CommandRestore.shellQuotedLine([
            "/usr/bin/env", "ZMX_SESSION=", "ZMX_SESSION_PREFIX=", "ZMX_NO_DETACH_KEY=1", "ZMX_DIR=/tmp/zmx-x",
            "/Applications/Elis.app/zmx", "attach", daemon, "/bin/sh", "-c", guardScript,
        ])

        #expect(argv.last == remote)
        #expect(argv.prefix(9) == ["ssh", "-tt", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                                   "-o", "LogLevel=ERROR", "buildbox"])
    }

    @Test func localViewerArgvRunsZmxDirectly() throws {
        let attach = try ControlAttach.viewer(.local(endpoint: endpoint, daemon: daemon), paneID: "p1")

        #expect(attach.paneID == "p1")
        #expect(attach.argv.first == "/usr/bin/env")
        #expect(attach.argv.contains("attach"))
        #expect(attach.argv.contains(daemon))
        #expect(attach.argv.contains("ZMX_MANAGED_SCREEN_ONLY=1"))
        #expect(attach.argv.contains("ZMX_MANAGED_FOLLOW=1"))
        #expect(!attach.argv.contains("ssh"))
    }

    @Test func remoteViewerArgvUsesSshWithoutControlPath() throws {
        let attach = try ControlAttach.viewer(.remote(host: "buildbox", endpoint: endpoint, daemon: daemon), paneID: "p2")

        #expect(attach.argv.first == "ssh")
        #expect(attach.argv.contains("buildbox"))
        #expect(!attach.argv.contains { $0.hasPrefix("ControlPath") })
        let remote = try #require(attach.argv.last)
        #expect(remote.contains("ZMX_MANAGED_SCREEN_ONLY=1") && remote.contains("ZMX_MANAGED_FOLLOW=1"))
    }

    @Test func invalidDaemonIsRejected() {
        #expect(throws: RemoteSession.InvocationError.invalidSession) {
            try ControlAttach.viewer(.local(endpoint: endpoint, daemon: "notes"), paneID: "p")
        }
        #expect(throws: RemoteSession.InvocationError.invalidSession) {
            try ControlAttach.viewer(.remote(host: "buildbox", endpoint: endpoint, daemon: "notes"), paneID: "p")
        }
    }
}
