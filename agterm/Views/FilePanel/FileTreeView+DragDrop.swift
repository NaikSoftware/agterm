import AppKit

extension FileTreeOutline.Coordinator {
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? FileTreeNode, renamingNode == nil else { return nil }
        // A selected item inside a selected folder travels with the folder, as in `topLevelSelection`.
        if outlineView.isRowSelected(outlineView.row(forItem: node)), !topLevelSelection().contains(where: { $0 === node }) {
            return nil
        }
        return node.url as NSURL
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex _: Int) -> NSDragOperation {
        guard let target = dropTarget(item) else { return [] }
        let sources = droppedURLs(info), moving = dropMoves(info)
        // Refused only when nothing can land; `transfer` reports the skipped items in one sheet, as paste does.
        guard sources.contains(where: { transferRefusal($0, into: target.url, moving: moving) == nil }) else { return [] }
        outlineView.setDropItem(target === rootNode ? nil : target, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return moving ? .move : .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex _: Int) -> Bool {
        guard let target = dropTarget(item) else { return false }
        let sources = droppedURLs(info)
        guard !sources.isEmpty else { return false }
        transfer(sources, into: target.url, moving: dropMoves(info))
        return true
    }

    /// The folder a drop lands in: a folder row itself, a file row's folder, or the root for empty space.
    private func dropTarget(_ item: Any?) -> FileTreeNode? {
        guard let node = (item as? FileTreeNode) ?? rootNode else { return nil }
        return node.isDirectory ? node : nodeCache[Self.canonical(node.url.deletingLastPathComponent()).path]
    }

    private func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    // ⌥ narrows the source mask to `.copy`; a drag from outside this outline always copies.
    private func dropMoves(_ info: NSDraggingInfo) -> Bool {
        (info.draggingSource as? NSOutlineView) === outlineView && info.draggingSourceOperationMask.contains(.move)
    }
}

/// Highlights the drop target folder with the selection pill at low alpha instead of AppKit's accent fill.
final class FileTreeRowView: SidebarRowView {
    override func drawDraggingDestinationFeedback(in _: NSRect) {
        (GhosttyApp.shared.terminalSelectionBackgroundColor ?? GhosttyApp.shared.terminalForegroundColor ?? .white).withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: selectionRect, xRadius: 7, yRadius: 7).fill()
    }
}
