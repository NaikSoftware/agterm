import Testing
@testable import agtermCore

struct SidebarBandTests {
    @Test func edgesFollowGroupSizesInOrder() {
        #expect(SidebarBand.edges(groupRowCounts: [1, 3]) == [.single, .first, .middle, .last])
        #expect(SidebarBand.edges(groupRowCounts: [2]) == [.first, .last])
        #expect(SidebarBand.edges(groupRowCounts: []) == [])
        #expect(SidebarBand.edges(groupRowCounts: [0, 1]) == [.single])
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
