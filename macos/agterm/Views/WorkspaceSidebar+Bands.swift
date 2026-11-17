import agtermCore
import AppKit

/// Row decorations that depend on a row's neighbors or on global theme colors: the workspace group's tint
/// band, a tinted session's wash and the active-row wave. A row reload does not rebuild its row view, so every
/// path that can move a group's edges or colors re-runs `applyRowDecorations` instead of relying on the diff.
extension WorkspaceSidebar.Coordinator {
    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard let rowView = rowView as? SidebarRowView else { return }
        decorate(rowView, row: row, in: groupRange(containing: row, in: outlineView), outline: outlineView)
    }

    /// applyRowDecorations re-decorates every row view on screen.
    func applyRowDecorations() {
        guard let outline = outlineView else { return }
        var start = 0
        while start < outline.numberOfRows {
            let group = groupRange(containing: start, in: outline)
            for row in group {
                guard let rowView = outline.rowView(atRow: row, makeIfNecessary: false) as? SidebarRowView else { continue }
                decorate(rowView, row: row, in: group, outline: outline)
            }
            start = group.upperBound
        }
    }

    /// refreshGroupGeometry re-asks every row's height, since a fold or rebuild moves a group's last row and
    /// with it the edge extras, then re-decorates.
    func refreshGroupGeometry() {
        guard let outline = outlineView else { return }
        // a view-based table animates a height change by default, leaving row views at their old frames meanwhile
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            outline.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<outline.numberOfRows))
        }
        applyRowDecorations()
    }

    /// groupEdge is a row's place in its workspace group, tinted or not: nil where no workspace rows render. One
    /// rule feeds the row height, the cell frame and the drawing, so they cannot disagree.
    func groupEdge(for node: SidebarNode) -> SidebarBandEdge? {
        guard rendersWorkspaceRows, let outline = outlineView else { return nil }
        // from the model, not `parent(forItem:)`: the outline asks heights while its own row map is being built
        let workspaceID = node.kind == .workspace ? node.id : store.workspace(forSession: node.id)?.id
        guard let workspaceID, let workspace = nodeCache[workspaceID] else { return nil }
        var last = workspace
        if outline.isItemExpanded(workspace), let child = workspace.children.last {
            last = outline.isItemExpanded(child) ? child.children.last ?? child : child
        }
        switch (node === workspace, node === last) {
        case (true, true): return .single
        case (true, false): return .first
        case (false, true): return .last
        case (false, false): return .middle
        }
    }

    /// edgeExtras is the space a row adds above and below its content for the group gap and padding.
    func edgeExtras(forRow row: Int) -> (top: CGFloat, bottom: CGFloat) {
        guard let node = outlineView?.item(atRow: row) as? SidebarNode else { return (0, 0) }
        return SidebarRowView.edgeExtras(groupEdge(for: node))
    }

    /// groupRange is the rows of the top-level item holding `row` and everything shown under it.
    private func groupRange(containing row: Int, in outline: NSOutlineView) -> Range<Int> {
        var start = row
        while start > 0, outline.level(forRow: start) > 0 { start -= 1 }
        var end = row + 1
        while end < outline.numberOfRows, outline.level(forRow: end) > 0 { end += 1 }
        return start..<end
    }

    private func decorate(_ rowView: SidebarRowView, row: Int, in group: Range<Int>, outline: NSOutlineView) {
        guard let node = outline.item(atRow: row) as? SidebarNode else {
            rowView.band = nil
            rowView.groupEdge = nil
            rowView.rowWash = nil
            rowView.selectionTint = nil
            return rowView.setWave(nil)
        }
        let head = outline.item(atRow: group.lowerBound) as? SidebarNode
        let workspaceTint = rendersWorkspaceRows && head?.kind == .workspace
            ? store.workspaces.first { $0.id == head?.id }?.tint : nil
        let edge = groupEdge(for: node)
        rowView.groupEdge = edge
        if let workspaceTint, let edge {
            rowView.band = (NSColor.tint(workspaceTint.color), edge)
        } else {
            rowView.band = nil
        }
        let session = node.kind == .session ? store.session(withID: node.id) : nil
        rowView.rowWash = session?.tint.map { NSColor.tint($0.color).withAlphaComponent(0.09) }
        rowView.selectionTint = (workspaceTint ?? session?.tint).map { NSColor.tint($0.color) }
        let indicator = effectiveIndicator(forSession: node.id)
        guard let session, indicator.status == .active else { return rowView.setWave(nil) }
        // dynamic system colors resolve for the sidebar's theme-pinned appearance, not the app's
        var wave: SidebarWave?
        outline.effectiveAppearance.performAsCurrentDrawingAppearance {
            let app = GhosttyApp.shared
            let accent = app.terminalSelectionBackgroundColor ?? app.terminalForegroundColor ?? .white
            guard let activeHex = app.statusColor(for: .active, override: indicator.color).agtermHexString,
                  let accentHex = accent.agtermHexString else { return }
            wave = SidebarBand.wave(
                status: indicator.status,
                sessionTintHex: session.tint.flatMap { NSColor.tint($0.color).agtermHexString },
                workspaceTintHex: workspaceTint.flatMap { NSColor.tint($0.color).agtermHexString },
                activeHex: activeHex, accentHex: accentHex)
        }
        rowView.setWave(wave)
    }
}
