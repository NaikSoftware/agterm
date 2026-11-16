/// ControlGrid is a terminal grid in cells.
public struct ControlGrid: Codable, Sendable, Equatable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    /// The bounds `session.grid` accepts, the phone app's own.
    public static let columnRange = 20...1000
    public static let rowRange = 5...1000
}

/// ControlPaneGrids is the read side of `session.grid`: a pane is listed only while a caller's grid holds it.
public struct ControlPaneGrids: Codable, Sendable, Equatable {
    public var left: ControlGrid?
    public var right: ControlGrid?

    public init(left: ControlGrid? = nil, right: ControlGrid? = nil) {
        self.left = left
        self.right = right
    }
}
