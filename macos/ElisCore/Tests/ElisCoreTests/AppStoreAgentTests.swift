import Foundation
import Testing
@testable import ElisCore

@MainActor
struct AppStoreAgentTests {
    private final class RecordingSink: PresentationSink {
        var frames: [PresentationFrame] = []
        func offer(_ frame: PresentationFrame) -> Bool {
            frames.append(frame)
            return true
        }
        func close(_ reason: PresentationHub.CloseReason) {}

        var agents: [PresentationAgent?] {
            frames.compactMap { if case .agent(let agent) = $0.body { return .some(agent) } else { return nil } }
        }
    }

    private static func json(_ id: String) -> Data {
        Data(#"{"sessionId":"\#(id)","cwd":"/repo"}"#.utf8)
    }

    private func session() throws -> (AppStore, Session) {
        let store = makeStore()
        let session = try #require(store.addSession(toWorkspace: store.addWorkspace(name: "work").id, cwd: "/repo"))
        return (store, session)
    }

    @Test func focusedPaneAgentWins() throws {
        let (store, session) = try session()

        store.applyAgentSamples([AgentPaneSample(pane: .left, agent: .claude, claudeSessionJSON: Self.json("c1")),
                                 AgentPaneSample(pane: .right, agent: .codex, claudeSessionJSON: nil)],
                                focused: .right, forSession: session.id)

        #expect(session.runningAgent == .codex)
        #expect(session.agentPane == .right)
    }

    @Test func theIDComesFromTheWinningPane() throws {
        let (store, session) = try session()

        store.applyAgentSamples([AgentPaneSample(pane: .left, agent: .claude, claudeSessionJSON: Self.json("c1")),
                                 AgentPaneSample(pane: .right, agent: .claude, claudeSessionJSON: Self.json("c2"))],
                                focused: .right, forSession: session.id)

        #expect(session.agentPane == .right)
        #expect(session.agentSessionID == "c2")
    }

    @Test func otherPaneAgentKeepsClaude() throws {
        let (store, session) = try session()

        store.applyAgentSamples([AgentPaneSample(pane: .left, agent: .claude, claudeSessionJSON: Self.json("c1")),
                                 AgentPaneSample(pane: .right, agent: nil, claudeSessionJSON: nil)],
                                focused: .right, forSession: session.id)

        #expect(session.runningAgent == .claude)
        #expect(session.agentPane == .left)
        #expect(session.agentSessionID == "c1")
        #expect(session.resumeLine?.hasSuffix("claude --resume c1") == true)
    }

    @Test func noAgentClearsPaneButKeepsID() throws {
        let (store, session) = try session()
        store.applyAgentSamples([AgentPaneSample(pane: .left, agent: .claude, claudeSessionJSON: Self.json("c1"))],
                                focused: .left, forSession: session.id)

        store.applyAgentSamples([AgentPaneSample(pane: .left, agent: nil, claudeSessionJSON: nil)],
                                focused: .left, forSession: session.id)

        #expect(session.runningAgent == nil)
        #expect(session.agentPane == nil)
        #expect(session.agentSessionID == "c1")
    }

    @Test func otherAgentClearsID() throws {
        let (store, session) = try session()
        store.applyAgentSamples([AgentPaneSample(pane: .left, agent: .claude, claudeSessionJSON: Self.json("c1"))],
                                focused: .left, forSession: session.id)

        store.applyAgentSamples([AgentPaneSample(pane: .left, agent: .codex, claudeSessionJSON: nil)],
                                focused: .left, forSession: session.id)

        #expect(session.agentSessionID == nil)
    }

    @Test func runningAgentChangePublishesAndSchedulesTree() throws {
        var events: [ControlEventKind] = []
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(persistence: PersistenceStore(directory: directory),
                             controlEventSink: { events.append($0.kind) }, paneFinalizer: nil)
        let hub = PresentationHub(staleTimeout: 30)
        store.presentationHub = hub
        let session = try #require(store.addSession(toWorkspace: store.addWorkspace(name: "work").id, cwd: "/repo"))
        let sink = RecordingSink()
        try hub.subscribe(session: session.id, hello: PresentationHello(version: 1, kinds: [], mode: .mirror),
                          sink: sink) { store.presentationSnapshot(forSession: session.id) }
        events.removeAll()

        store.setRunningAgent(.claude, pane: .left, forSession: session.id)
        store.setRunningAgent(.claude, pane: .left, forSession: session.id)

        #expect(sink.agents == [PresentationAgent(name: "claude", pane: "left")])
        #expect(events == [.treeChanged])
        #expect(store.presentationSnapshot(forSession: session.id).agent == PresentationAgent(name: "claude", pane: "left"))
    }

    @Test func treeCarriesAgentPaneAndOmitsNil() throws {
        let (store, session) = try session()
        let encoded = { String(decoding: try JSONEncoder().encode(store.controlTree().workspaces[0].sessions[0]), as: UTF8.self) }
        #expect(try !encoded().contains("agentPane"))

        store.setRunningAgent(.claude, pane: .left, forSession: session.id)

        #expect(try encoded().contains(#""agentPane":"left""#))
    }

    @Test func remoteAgentLandsOnlyOnAnAttachedRowAndUnknownReadsAsNone() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let row = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", remoteHost: "buildbox"))
        store.bindRemote(RemoteBinding(remoteSessionID: "s1", daemonsByLocalPane: [:], presentationVersion: 1), forSession: row.id)
        let local = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))

        store.applyRemoteAgent(PresentationAgent(name: "claude", pane: "right"), forSession: row.id)
        store.applyRemoteAgent(PresentationAgent(name: "claude", pane: "right"), forSession: local.id)

        #expect(row.runningAgent == .claude)
        #expect(row.agentPane == .right)
        #expect(local.runningAgent == nil)

        store.applyRemoteAgent(PresentationAgent(name: "terminal", pane: "left"), forSession: row.id)
        #expect(row.runningAgent == nil)
        #expect(row.agentPane == nil)

        store.applyRemoteAgent(PresentationAgent(name: "claude", pane: "scratch"), forSession: row.id)
        #expect(row.runningAgent == nil)
    }

    @Test func transcriptSourceNeedsRunningClaudeInThatPane() throws {
        let (store, session) = try session()
        session.agentSessionID = "c1"
        #expect(session.transcriptSource(token: nil, pane: nil, claudeDirectory: "/c") == .failure(ControlTranscriptRefusal(message: "no adapter")))

        store.setRunningAgent(.claude, pane: .left, forSession: session.id)

        #expect(session.transcriptSource(token: nil, pane: .right, claudeDirectory: "/c") == .failure(ControlTranscriptRefusal(message: "no adapter")))
        #expect(session.transcriptSource(token: nil, pane: nil, claudeDirectory: "/c")
            == .success(ControlTranscriptSource(claudeSessionID: "c1", pane: .left, claudeDirectory: "/c")))
        #expect(session.transcriptSource(token: "nope", pane: nil, claudeDirectory: "/c")
            == .failure(ControlTranscriptRefusal(message: "unknown pane id: nope")))
    }
}
