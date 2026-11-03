import agtermCore
import AppKit

extension FileTreeOutline.Coordinator {
    // A single click only selects: opening on it would break drag and multi-select.
    @objc func handleDoubleClick(_ sender: NSOutlineView) {
        guard let node = sender.item(atRow: sender.clickedRow) as? FileTreeNode else { return }
        open(node)
    }

    /// Toggles a folder; shows a file over the active session the way a terminal link click does, else hands it to its app.
    func open(_ node: FileTreeNode) {
        if node.isDirectory {
            guard let outline = outlineView else { return }
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
            return
        }
        let url = node.url
        guard let active = store.activeSession else {
            NSWorkspace.shared.open(url)
            return
        }
        let session = active.id
        let fallback: @MainActor (Bool) -> Void = { shown in if !shown { NSWorkspace.shared.open(url) } }
        let ext = url.pathExtension.lowercased()
        let markdown = LinkPolicy.markdownExtensions.contains(ext), image = LinkPolicy.imageExtensions.contains(ext)
        let text = !markdown && !image && TextPage.isPanelCandidate(file: url.path)
        // the session-wide slot holds one page, so a viewer still showing the previous file would refuse this one
        if (markdown || image || text) && active.fileViewerActive { store.closeOverlay(session) }
        if markdown {
            LinkOpener.shared.markdown(url, session, nil, fallback)
        } else if image {
            LinkOpener.shared.image(url, session, fallback)
        } else if text {
            LinkOpener.shared.text(LinkPolicy.TextLink(url: url, line: nil, session: session, sizePercent: nil), fallback)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
