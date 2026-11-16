import AppKit
import GhosttyKit

/// A forced grid (`session.grid`) holds the program at a caller's size apart from the view. Any view size
/// change the grid did not cause hands it back to the view (`setFrameSize`), and a font change re-derives
/// its pixels (`GHOSTTY_ACTION_CELL_SIZE`).
extension GhosttySurfaceView {
    /// The grid libghostty holds now, forced or fitted to the view; zero before the surface exists.
    func gridSize() -> (columns: Int, rows: Int) {
        guard let surface else { return (0, 0) }
        let size = ghostty_surface_size(surface)
        return (Int(size.columns), Int(size.rows))
    }

    /// Forces `grid` on the program, or hands the pane back to its view with nil.
    func setForcedGrid(_ grid: (columns: Int, rows: Int)?) {
        recordForcedGrid(grid)
        updateMetalLayerSize()
    }

    /// Sets the grid and the session's flag without a size push, for `setFrameSize`, which pushes its own.
    func recordForcedGrid(_ grid: (columns: Int, rows: Int)?) {
        forcedGrid = grid
        guard let session else { return }
        let forced = [session.surface, session.splitSurface].contains { ($0 as? GhosttySurfaceView)?.forcedGrid != nil }
        if session.hasForcedGrid != forced { session.hasForcedGrid = forced }
    }

    func pushSize(_ surface: ghostty_surface_t?, viewPixels: CGSize) {
        let forced = forcedPixelSize(surface)
        ghostty_surface_set_size(surface, forced?.width ?? UInt32(viewPixels.width), forced?.height ?? UInt32(viewPixels.height))
    }

    /// The forced grid's cells plus the padding and slack the current size holds beyond its own grid.
    private func forcedPixelSize(_ surface: ghostty_surface_t?) -> (width: UInt32, height: UInt32)? {
        guard let forcedGrid else { return nil }
        let size = ghostty_surface_size(surface)
        let cellWidth = Int(size.cell_width_px), cellHeight = Int(size.cell_height_px)
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        let width = forcedGrid.columns * cellWidth + max(0, Int(size.width_px) - Int(size.columns) * cellWidth)
        let height = forcedGrid.rows * cellHeight + max(0, Int(size.height_px) - Int(size.rows) * cellHeight)
        return (UInt32(width), UInt32(height))
    }

    /// Wheels the pane as a mouse over the centre of its screen would: `lines` < 0 scrolls toward older output.
    /// The screen, not the view: a point past a small forced grid is dropped by a mouse-reporting program.
    func scrollNotches(_ lines: Int) {
        guard let surface else { return }
        let size = ghostty_surface_size(surface)
        let screen = convertFromBacking(NSSize(width: Double(size.width_px), height: Double(size.height_px)))
        let centre = NSPoint(x: min(screen.width, bounds.width) / 2, y: min(screen.height, bounds.height) / 2)
        if centre != lastReportedMousePoint {
            ghostty_surface_mouse_pos(surface, centre.x, centre.y, GHOSTTY_MODS_NONE)
            lastReportedMousePoint = centre
        }
        let notches = max(1, (abs(lines) + 1) / 3)
        ghostty_surface_mouse_scroll(surface, 0, Double(lines < 0 ? notches : -notches), 0)
    }
}
