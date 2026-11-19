import Foundation
import Testing
@testable import ElisCore

struct PhoneAttachTests {
    let endpoint = ControlZmxEndpoint(executable: "/Applications/Elis.app/zmx", socketDirectory: "/tmp/zmx-x")
    let daemon = ZmxSupport.daemonName(for: UUID())

    @Test func viewerLeadSetsScreenOnlyAndFollowNotClaim() {
        let viewer = ZmxLeadAttachment.viewer

        #expect(viewer.environment ==
                ["ZMX_MANAGED": viewer.nonce, "ZMX_MANAGED_SCREEN_ONLY": "1", "ZMX_MANAGED_FOLLOW": "1"])
        #expect(!viewer.claim)
        #expect(ZmxLeadAttachment.viewer.nonce != viewer.nonce)
    }

    @Test func attachCommandOutputIsUnchanged() throws {
        let fixed = ControlZmxEndpoint(executable: "/opt/zmx", socketDirectory: "/tmp/zd")
        let tail = "'/opt/zmx' 'attach' 'elis-00000000000000000000000000000001' '/bin/sh' '-c' "
            + "'printf '\\''%s\\n'\\'' '\\''elis: remote session is gone'\\''; exit 1'"
        let env = "'/usr/bin/env' 'ZMX_SESSION=' 'ZMX_SESSION_PREFIX=' 'ZMX_NO_DETACH_KEY=1' 'ZMX_DIR=/tmp/zd' "
        let pinnedDaemon = "elis-00000000000000000000000000000001"
        let head = ["ssh", "-tt", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR", "buildbox"]

        let plain = try RemoteSession.attachCommand(host: "buildbox", endpoint: fixed, daemon: pinnedDaemon)
        #expect(plain == head + [env + tail])

        let lead = ZmxLeadAttachment(nonce: "n0nce", claim: false, screenOnly: true, follow: true)
        let viewer = try RemoteSession.attachCommand(host: "buildbox", endpoint: fixed, daemon: pinnedDaemon,
                                                    lead: lead)
        let words = "'ZMX_MANAGED=n0nce' 'ZMX_MANAGED_FOLLOW=1' 'ZMX_MANAGED_SCREEN_ONLY=1' "
        #expect(viewer == head + [env + words + tail])

        let source = LivePaneSource.remote(host: "buildbox", endpoint: fixed, daemon: pinnedDaemon)
        let attach = try ControlAttach.viewer(source, paneID: "p")
        let keepAlive = "ka=; 'ssh' '-G' '-tt' '-o' 'BatchMode=yes' '-o' 'ConnectTimeout=5' '-o' 'LogLevel=ERROR' 'buildbox'"
            + " 2>/dev/null | grep -qx 'serveraliveinterval 0' && ka='-o ServerAliveInterval=5 -o ServerAliveCountMax=2'; "
        let attachLine = "exec 'ssh' '-tt' '-o' 'BatchMode=yes' '-o' 'ConnectTimeout=5' '-o' 'LogLevel=ERROR' $ka 'buildbox' "
            + CommandRestore.shellQuotedLine([env + "'ZMX_MANAGED=*' 'ZMX_MANAGED_FOLLOW=1' 'ZMX_MANAGED_SCREEN_ONLY=1' " + tail])
        let masked = attach.argv.map {
            $0.replacingOccurrences(of: "ZMX_MANAGED=[0-9a-f]+", with: "ZMX_MANAGED=*", options: .regularExpression)
        }
        #expect(masked == ["/bin/sh", "-c", keepAlive + attachLine])
        let screenKeepAlive = "ka=; 'ssh' '-G' '-T' '-o' 'BatchMode=yes' '-o' 'ConnectTimeout=5' 'buildbox'"
            + " 2>/dev/null | grep -qx 'serveraliveinterval 0' && ka='-o ServerAliveInterval=5 -o ServerAliveCountMax=2'; "
        let screenLine = "exec 'ssh' '-T' '-o' 'BatchMode=yes' '-o' 'ConnectTimeout=5' $ka 'buildbox' "
            + CommandRestore.shellQuotedLine(["'/usr/bin/env' 'ZMX_SESSION=' 'ZMX_SESSION_PREFIX=' 'ZMX_DIR=/tmp/zd' "
                                              + "'/opt/zmx' 'screen' 'elis-00000000000000000000000000000001'"])
        #expect(attach.screen == ["/bin/sh", "-c", screenKeepAlive + screenLine])
        #expect(attach.remote)
    }

    @Test func screenArgvForLocalPane() throws {
        let attach = try ControlAttach.viewer(.local(endpoint: endpoint, daemon: daemon), paneID: "p1")

        #expect(attach.screen == ["/usr/bin/env", "ZMX_SESSION=", "ZMX_SESSION_PREFIX=", "ZMX_DIR=/tmp/zmx-x",
                                  "/Applications/Elis.app/zmx", "screen", daemon])
        #expect(!attach.screen.contains("ssh"))
        #expect(!attach.remote)
    }

    @Test func remoteViewerUsesKeepAlive() throws {
        let attach = try ControlAttach.viewer(.remote(host: "buildbox", endpoint: endpoint, daemon: daemon), paneID: "p2")

        for argv in [attach.argv, attach.screen] {
            #expect(Array(argv.prefix(2)) == ["/bin/sh", "-c"])
            #expect(argv.count == 3)
            #expect(argv.last?.contains("ServerAliveInterval=5") == true)
        }
        #expect(attach.screen.last?.contains("'screen'") == true)
        #expect(attach.remote)
    }

    @Test func oldAnswerDecodesWithDefaults() throws {
        let old = try JSONDecoder().decode(ControlAttach.self, from: Data(#"{"argv":["zmx"],"paneID":"p"}"#.utf8))
        #expect(old == ControlAttach(argv: ["zmx"], paneID: "p", screen: [], remote: false))

        let new = ControlAttach(argv: ["a"], paneID: "p", screen: ["s"], remote: true)
        #expect(try JSONDecoder().decode(ControlAttach.self, from: JSONEncoder().encode(new)) == new)
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
        let source = LivePaneSource.remote(host: "buildbox", endpoint: endpoint, daemon: daemon)
        let attach = try ControlAttach.viewer(source, paneID: "p2")

        let script = try #require(attach.argv.last)
        #expect(script.contains("'ssh'") && script.contains("'buildbox'"))
        #expect(!script.contains("ControlPath"))
        #expect(script.contains("ZMX_MANAGED_SCREEN_ONLY=1") && script.contains("ZMX_MANAGED_FOLLOW=1"))
    }

    @Test func claimerSetsClaimAndScreenOnlyAndNonce() throws {
        let attach = try ControlAttach.claimer(.local(endpoint: endpoint, daemon: daemon), paneID: "p1")

        let nonce = try #require(attach.nonce)
        #expect(attach.argv.contains("ZMX_MANAGED=\(nonce)"))
        #expect(attach.argv.contains("ZMX_MANAGED_CLAIM=1"))
        #expect(attach.argv.contains("ZMX_MANAGED_SCREEN_ONLY=1"))
        #expect(!attach.argv.contains("ZMX_MANAGED_FOLLOW=1"))
        #expect(attach.paneID == "p1")
        #expect(attach.screen == (try ControlAttach.viewer(.local(endpoint: endpoint, daemon: daemon), paneID: "p1")).screen)
        #expect(!attach.remote)
    }

    @Test func remoteClaimerKeepsTheKeepalive() throws {
        let attach = try ControlAttach.claimer(.remote(host: "buildbox", endpoint: endpoint, daemon: daemon), paneID: "p2")

        let nonce = try #require(attach.nonce)
        let script = try #require(attach.argv.last)
        #expect(Array(attach.argv.prefix(2)) == ["/bin/sh", "-c"])
        #expect(script.contains("ServerAliveInterval=5"))
        #expect(script.contains("ZMX_MANAGED=\(nonce)") && script.contains("ZMX_MANAGED_CLAIM=1"))
        #expect(!script.contains("ZMX_MANAGED_FOLLOW"))
        #expect(attach.screen.last?.contains("'screen'") == true)
        #expect(attach.remote)
    }

    @Test func attachWithoutNonceDecodes() throws {
        let old = try JSONDecoder().decode(ControlAttach.self, from: Data(#"{"argv":["zmx"],"paneID":"p"}"#.utf8))
        #expect(old.nonce == nil)
        #expect(try ControlAttach.viewer(.local(endpoint: endpoint, daemon: daemon), paneID: "p").nonce == nil)

        let claimed = ControlAttach(argv: ["a"], paneID: "p", nonce: "n1")
        #expect(try JSONDecoder().decode(ControlAttach.self, from: JSONEncoder().encode(claimed)) == claimed)
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
