/// Where a row sits in its workspace group's tint band, which rounds and insets only the group's outer edges.
public enum SidebarBandEdge: Sendable, Equatable {
    case single, first, middle, last
}

/// The two hex colors of an active row's wave.
public struct SidebarWave: Sendable, Equatable {
    public let base: String
    public let second: String

    public init(base: String, second: String) {
        self.base = base
        self.second = second
    }
}

public enum SidebarBand {
    /// edges gives one edge per row for groups laid out in order.
    public static func edges(groupRowCounts: [Int]) -> [SidebarBandEdge] {
        groupRowCounts.flatMap { count -> [SidebarBandEdge] in
            guard count > 1 else { return count == 1 ? [.single] : [] }
            return [.first] + Array(repeating: .middle, count: count - 2) + [.last]
        }
    }

    /// wave is nil unless active. A tinted base pairs with the active color, an untinted one with the accent.
    public static func wave(status: AgentStatus, sessionTintHex: String?, workspaceTintHex: String?,
                            activeHex: String, accentHex: String) -> SidebarWave? {
        guard status == .active else { return nil }
        guard let tint = sessionTintHex ?? workspaceTintHex else { return SidebarWave(base: activeHex, second: accentHex) }
        return SidebarWave(base: tint, second: activeHex)
    }
}
