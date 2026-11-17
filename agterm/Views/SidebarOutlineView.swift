import AppKit

/// `NSOutlineView` subclass routing the per-row context menu and double-click rename to the coordinator.
final class SidebarOutlineView: NSOutlineView {
    // never become first responder: focus lives in the terminal, and a mouse click still selects the row
    // (selection is independent of first responder). Otherwise the responder bounce (terminal → outline →
    // terminal, via mouseDown's focusActiveTerminal) makes AppKit re-set `isEmphasized` on the rows — an
    // extra repaint that flicks the selection pill on every click. Programmatic selection never bounces.
    override var acceptsFirstResponder: Bool { false }

    // expansion would widen the column per nesting level and push every row's trailing glyph and badge past the
    // sidebar edge; the column's autoresizing mask already fits it to the sidebar.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizesOutlineColumn = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Where a row's content belongs: the level-0 disclosure triangle ends at 14pt, and the cell's own 2pt
    /// icon inset supplies the gap after it.
    private static let contentX: CGFloat = 14

    /// reservesDisclosureColumn is false when no level-0 row draws a triangle: workspace chevrons hidden, or a
    /// flat flagged list.
    var reservesDisclosureColumn = true

    /// listsSessionsFlat is true for the flat and plain flagged lists.
    var listsSessionsFlat = false

    /// selectionMinX is where a row's selection pill starts; a flat list has no strip to leave room for it.
    var selectionMinX: CGFloat { listsSessionsFlat ? 0 : usesSpecGeometry ? 3 : 8 }

    /// selectionMaxXInset is the pill's gap to the row's trailing edge.
    var selectionMaxXInset: CGFloat { usesSpecGeometry ? 11 : 8 }

    /// usesSpecGeometry lays out the tree on macOS 27 by the design's own measures: the pill 3pt into the row,
    /// the chevron 8pt into the pill, icons after it and trailing items 8pt short of the pill's end. Earlier
    /// releases keep AppKit's native frames (`testBelowTheGateFramesMatchAPlainOutline`).
    var usesSpecGeometry: Bool {
        guard #available(macOS 27.0, *) else { return false }
        return reservesDisclosureColumn
    }

    private static let specChevronX: CGFloat = 11
    private static let specChevronWidth: CGFloat = 12
    /// A level-0 (workspace) cell; its icon sits 2pt in, after the chevron and an 8pt gap.
    private static let specWorkspaceCellX: CGFloat = 29
    /// A level-1 (session) cell, its icon 26pt into the pill.
    private static let specSessionCellX: CGFloat = 27

    /// specCellX is a cell's leading edge; each level past the session adds the density's indent scaled to the
    /// design's 20pt step.
    private func specCellX(level: Int) -> CGFloat {
        guard level > 0 else { return Self.specWorkspaceCellX }
        return Self.specSessionCellX + CGFloat(level - 1) * indentationPerLevel * 10 / 7
    }

    // with the cell's 2pt icon inset, puts the icon 8pt inside a pill starting at 0, as in the tree
    private static let flatContentX: CGFloat = 6

    /// macOS 27 reserves a wider leading strip than the triangle occupies, so the tree there takes the spec
    /// geometry (`usesSpecGeometry`); the earlier layout is already tight and cannot be tested here. Without the
    /// reserved strip the trim runs on every version, toward `contentMinX`.
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        guard !frame.isEmpty, tableColumns.indices.contains(column), tableColumns[column] === outlineTableColumn else {
            return frame
        }
        if usesSpecGeometry {
            let level = level(forRow: row)
            guard level >= 0 else { return frame }
            // the cell's trailing items sit 2pt in, so this leaves them 8pt short of the pill's end
            let maxX = min(frame.maxX, bounds.width - selectionMaxXInset - 6)
            frame.origin.x = specCellX(level: level)
            frame.size.width = max(0, maxX - frame.minX)
            return frame
        }
        guard let target = contentMinX(atRow: row) else { return frame }
        let trim = max(0, frame.minX - target)
        frame.origin.x -= trim
        frame.size.width += trim
        return frame
    }

    /// frameOfOutlineCell hides level-0 triangles with an empty frame. `shouldShowOutlineCellForItem`
    /// would hide them too, but AppKit then refuses to collapse the item.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        if usesSpecGeometry, !frame.isEmpty {
            let level = level(forRow: row)
            // a nested parent's chevron keeps the same 8pt gap before its own icon
            frame.origin.x = level > 0 ? specCellX(level: level) + 2 - 8 - Self.specChevronWidth : Self.specChevronX
            frame.size.width = Self.specChevronWidth
            return frame
        }
        guard !reservesDisclosureColumn, !frame.isEmpty, let target = contentMinX(atRow: row) else { return frame }
        guard level(forRow: row) > 0 else { return .zero }
        frame.origin.x = target - frame.width
        return frame
    }

    /// trimmedCellFrame applies the macOS 27 strip trim to another outline (the file panel's tree).
    static func trimmedCellFrame(_ frame: NSRect, in outline: NSOutlineView, column: Int, row: Int) -> NSRect {
        var frame = frame
        guard #available(macOS 27.0, *), !frame.isEmpty, outline.tableColumns.indices.contains(column),
              outline.tableColumns[column] === outline.outlineTableColumn else { return frame }
        let level = outline.level(forRow: row)
        guard level >= 0 else { return frame }
        let trim = max(0, frame.minX - (contentX + CGFloat(level) * outline.indentationPerLevel))
        frame.origin.x -= trim
        frame.size.width += trim
        return frame
    }

    /// contentMinX returns nil to keep the native frame. Without the strip the shift stops short of a nested
    /// triangle's width, so a companion parent's still fits at compact's 10pt indent.
    private func contentMinX(atRow row: Int) -> CGFloat? {
        let level = level(forRow: row)
        guard level >= 0 else { return nil }
        let indent = CGFloat(level) * indentationPerLevel
        if listsSessionsFlat { return Self.flatContentX + indent }
        guard reservesDisclosureColumn else { return max(0, Self.contentX - indentationPerLevel) + indent }
        return nil
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        (delegate as? WorkspaceSidebar.Coordinator)?.finishDraggingSequence()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        // standard Mac list behavior: keep a multi-selection when right-clicking one of its selected rows,
        // narrow to the clicked session when right-clicking outside it.
        if row >= 0, let node = item(atRow: row) as? SidebarNode, node.kind == .session,
           !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return (delegate as? WorkspaceSidebar.Coordinator)?.menu(forRow: row)
    }

    override func mouseDown(with event: NSEvent) {
        // NSTableView treats Control-click as a plain click and ignores a left-button event handed to
        // rightMouseDown, so the secondary-click convention has to open the menu here.
        if event.modifierFlags.contains(.control) {
            if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
        } else {
            super.mouseDown(with: event)
        }
        // after the click is handled, hand keyboard focus back to the terminal; row selection persists
        // (model state), only first responder moves. Skipped mid-rename by the coordinator.
        (delegate as? WorkspaceSidebar.Coordinator)?.focusActiveTerminal()
    }
}
