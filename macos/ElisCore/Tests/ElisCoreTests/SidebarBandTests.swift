import Testing
@testable import ElisCore

struct SidebarBandTests {
    @Test func edgeFollowsThePositionInTheGroup() {
        #expect(SidebarBand.edge(index: 0, count: 1) == .single)
        #expect((0..<3).map { SidebarBand.edge(index: $0, count: 3) } == [.first, .middle, .last])
        #expect((0..<2).map { SidebarBand.edge(index: $0, count: 2) } == [.first, .last])
    }

    @Test func edgeClampsAnOutOfRangeIndex() {
        #expect(SidebarBand.edge(index: -1, count: 3) == .first)
        #expect(SidebarBand.edge(index: 5, count: 3) == .last)
        #expect(SidebarBand.edge(index: 4, count: 0) == .single)
    }

    @Test(arguments: [AgentStatus.idle, .blocked, .completed])
    func waveOnlyForActive(status: AgentStatus) {
        #expect(SidebarBand.wave(status: status, sessionTintHex: "#111111", workspaceTintHex: nil,
                                 activeHex: "#AAAAAA", accentHex: "#BBBBBB") == nil)
    }

    @Test func waveBasePrefersSessionThenWorkspaceThenActive() {
        let both = SidebarBand.wave(status: .active, sessionTintHex: "#111111", workspaceTintHex: "#222222",
                                    activeHex: "#AAAAAA", accentHex: "#BBBBBB")
        #expect(both == SidebarWave(base: "#111111", second: "#AAAAAA"))
        let workspace = SidebarBand.wave(status: .active, sessionTintHex: nil, workspaceTintHex: "#222222",
                                         activeHex: "#AAAAAA", accentHex: "#BBBBBB")
        #expect(workspace == SidebarWave(base: "#222222", second: "#AAAAAA"))
        let plain = SidebarBand.wave(status: .active, sessionTintHex: nil, workspaceTintHex: nil,
                                     activeHex: "#AAAAAA", accentHex: "#BBBBBB")
        #expect(plain == SidebarWave(base: "#AAAAAA", second: "#BBBBBB"))
    }
}
