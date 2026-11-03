import agtermCore
import AppKit

extension FileTreeOutline.Coordinator: NSTextFieldDelegate {
    // MARK: - Context menu

    func menu(forRow row: Int) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let selected = selectedNodes()
        let hasSession = actions != nil && store.activeSession != nil
        if row >= 0, let node = outlineView?.item(atRow: row) as? FileTreeNode {
            menu.addItem(item("Open", #selector(openSelection)))
            menu.addItem(item("Open with Default App", #selector(openSelectionWithDefaultApp)))
            menu.addItem(.separator())
            let cwd = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
            menu.addItem(item("New Companion Here", #selector(newCompanionHere(_:)), enabled: hasSession, cwd: cwd))
            menu.addItem(.separator())
            menu.addItem(item("Cut", #selector(cutSelection)))
            menu.addItem(item("Copy", #selector(copySelection)))
            menu.addItem(item("Paste", #selector(paste), enabled: canPaste))
            menu.addItem(.separator())
            menu.addItem(item("Rename…", #selector(renameSelection), enabled: selected.count == 1))
            menu.addItem(item("Move to Trash", #selector(trashSelectionAction)))
        } else {
            menu.addItem(item("New Companion Here", #selector(newCompanionHere(_:)), enabled: hasSession && rootNode != nil,
                              cwd: rootNode?.url))
            menu.addItem(item("Paste", #selector(paste), enabled: canPaste && rootNode != nil))
        }
        return menu
    }

    private func item(_ title: String, _ action: Selector, enabled: Bool = true, cwd: URL? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        item.representedObject = cwd
        return item
    }

    @objc func openSelection() { selectedNodes().forEach(open) }

    @objc func openSelectionWithDefaultApp() { selectedNodes().forEach { NSWorkspace.shared.open($0.url) } }

    @objc func newCompanionHere(_ sender: NSMenuItem) {
        guard let cwd = sender.representedObject as? URL else { return }
        actions?.newCompanion(cwd: cwd.path, in: store)
    }

    @objc func renameSelection() {
        if let node = selectedNodes().first { beginRename(node) }
    }

    @objc func trashSelectionAction() { trashSelection() }

    // MARK: - Clipboard

    var canPaste: Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// The selection without nodes whose ancestor is also selected, so an operation never acts on an item twice.
    func topLevelSelection() -> [FileTreeNode] {
        let nodes = selectedNodes()
        let dirs = nodes.filter(\.isDirectory).map { $0.url.path + "/" }
        return nodes.filter { node in !dirs.contains { node.url.path.hasPrefix($0) } }
    }

    @objc func copySelection() {
        guard write(topLevelSelection()) else { return }
        setCut([])
    }

    @objc func cutSelection() {
        let nodes = topLevelSelection()
        guard write(nodes) else { return }
        cutChangeCount = pasteboard.changeCount
        setCut(Set(nodes.map(\.url.path)))
    }

    /// Writes file URLs, the form Finder reads and writes, so copy and paste work with it both ways.
    private func write(_ nodes: [FileTreeNode]) -> Bool {
        guard !nodes.isEmpty else { return false }
        pasteboard.clearContents()
        pasteboard.writeObjects(nodes.map { $0.url as NSURL })
        return true
    }

    private func setCut(_ paths: Set<String>) {
        if paths.isEmpty { cutChangeCount = nil }
        guard paths != cutPaths else { return }
        cutPaths = paths
        guard let outline = outlineView else { return }
        outline.reloadData(forRowIndexes: IndexSet(integersIn: 0 ..< outline.numberOfRows), columnIndexes: [0])
    }

    /// Moves the cut items, or copies when the pasteboard changed since the cut, into `FileTree.pasteTarget`.
    @objc func paste() {
        guard let rootNode else { return }
        let sources = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !sources.isEmpty else { return }
        let target = FileTree.pasteTarget(
            selection: selectedNodes().first.map { FileTreeEntry(url: $0.url, isDirectory: $0.isDirectory) }, root: rootNode.url)
        let moving = cutChangeCount == pasteboard.changeCount
        setCut([])
        // Finder empties the pasteboard after a move, so a second paste never names the moved-away sources.
        if moving { pasteboard.clearContents() }
        transfer(sources, into: target, moving: moving)
    }

    /// Why `source` cannot move or copy into `target`; nil when it can. Drops validate with it too.
    func transferRefusal(_ source: URL, into target: URL, moving: Bool) -> String? {
        let name = source.lastPathComponent
        let into = Self.canonical(target)
        if moving {
            guard FileTree.canMove(Self.canonical(source), into: into) else {
                return "\"\(name)\" cannot move into itself or the folder it is already in."
            }
            guard !FileManager.default.fileExists(atPath: target.appendingPathComponent(name).path) else {
                return "\"\(name)\" already exists in \"\(target.lastPathComponent)\"."
            }
        } else if into.pathComponents.starts(with: Self.canonical(source).pathComponents) {
            return "\"\(name)\" cannot be copied into itself."
        }
        return nil
    }

    /// Moves, or copies under `FileTree.copyDestination`, never over an existing item; one sheet lists what was skipped.
    func transfer(_ sources: [URL], into target: URL, moving: Bool) {
        let fm = FileManager.default
        var touched = [target], results: [URL] = [], errors: [String] = []
        for source in sources {
            if let refusal = transferRefusal(source, into: target, moving: moving) {
                errors.append(refusal)
                continue
            }
            do {
                if moving {
                    let dest = target.appendingPathComponent(source.lastPathComponent)
                    try fm.moveItem(at: source, to: dest)
                    touched.append(source.deletingLastPathComponent())
                    results.append(dest)
                } else {
                    let dest = FileTree.copyDestination(for: source, in: target) {
                        fm.fileExists(atPath: target.appendingPathComponent($0).path)
                    }
                    try fm.copyItem(at: source, to: dest)
                    results.append(dest)
                }
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        finish(reloading: touched, selecting: results, expanding: target, errors: errors)
    }

    // MARK: - Trash

    /// Moves the selection to the Trash and returns where each item landed.
    @discardableResult
    func trashSelection() -> [URL] {
        var parents: [URL] = [], trashed: [URL] = [], errors: [String] = []
        for node in topLevelSelection() {
            var result: NSURL?
            do {
                try FileManager.default.trashItem(at: node.url, resultingItemURL: &result)
                parents.append(node.url.deletingLastPathComponent())
                if let result { trashed.append(result as URL) }
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        finish(reloading: parents, selecting: [], errors: errors)
        return trashed
    }

    // MARK: - Rename

    /// Opens the row's name for editing with the name selected without its extension, like Finder.
    func beginRename(_ node: FileTreeNode) {
        guard renamingNode == nil, let outline = outlineView else { return }
        let row = outline.row(forItem: node)
        guard row >= 0, let field = (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField
        else { return }
        outline.scrollRowToVisible(row)
        renamingNode = node
        renameCancelled = false
        field.isEditable = true
        field.isBordered = true
        field.drawsBackground = true
        field.textColor = GhosttyApp.shared.terminalForegroundColor ?? .labelColor
        field.backgroundColor = GhosttyApp.shared.terminalBackgroundColor ?? .textBackgroundColor
        field.delegate = self
        field.window?.makeFirstResponder(field)
        let name = node.url.lastPathComponent
        let stem = node.isDirectory ? name : (name as NSString).deletingPathExtension
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
    }

    /// Ends an open rename without committing, before rows rebuild under its field.
    func cancelRename() {
        guard renamingNode != nil else { return }
        renameCancelled = true
        outlineView?.window?.makeFirstResponder(outlineView)
        renamingNode = nil
    }

    func control(_ control: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        renameCancelled = true
        control.window?.makeFirstResponder(outlineView)
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let node = renamingNode else { return }
        renamingNode = nil
        let newName = field.stringValue
        let commit = !renameCancelled
        field.isEditable = false
        field.isBordered = false
        field.drawsBackground = false
        field.delegate = nil
        field.stringValue = node.url.lastPathComponent
        // Let the field editor finish resigning before rows reload under it.
        DispatchQueue.main.async { [weak self] in
            guard let self, let outline = outlineView else { return }
            if !commit || !rename(node, to: newName) { outline.reloadItem(node) }
            outline.window?.makeFirstResponder(outline)
            let pending = pendingChanges
            pendingChanges = []
            if !pending.isEmpty { handleChanges(pending) }
        }
    }

    /// Renames on disk after `FileTree.renameError` passes; false, with an error shown, when nothing changed.
    @discardableResult
    func rename(_ node: FileTreeNode, to newName: String) -> Bool {
        let old = node.url.lastPathComponent
        guard newName != old else { return false }
        let parent = node.url.deletingLastPathComponent()
        let fm = FileManager.default
        // The item itself is no conflict: a case-only rename hits it on case-insensitive APFS.
        let conflict = FileTree.renameError(newName) {
            $0.caseInsensitiveCompare(old) != .orderedSame && fm.fileExists(atPath: parent.appendingPathComponent($0).path)
        }
        if let conflict {
            showErrors([conflict])
            return false
        }
        let dest = parent.appendingPathComponent(newName)
        do {
            try fm.moveItem(at: node.url, to: dest)
        } catch {
            showErrors([error.localizedDescription])
            return false
        }
        finish(reloading: [parent], selecting: [dest], errors: [])
        return true
    }

    // MARK: - Results

    private func finish(reloading dirs: [URL], selecting results: [URL], expanding target: URL? = nil, errors: [String]) {
        var seen = Set<String>()
        for dir in dirs {
            let path = Self.canonical(dir).path
            if seen.insert(path).inserted, let node = nodeCache[path] { reload(node) }
        }
        if !results.isEmpty, let target, let node = nodeCache[Self.canonical(target).path], node !== rootNode {
            outlineView?.expandItem(node)
        }
        let nodes = results.compactMap { nodeCache[Self.canonical($0).path] }
        if !nodes.isEmpty { select(nodes) }
        if !errors.isEmpty { showErrors(errors) }
    }

    /// One alert for a whole operation, never one per item.
    func showErrors(_ messages: [String]) {
        if let presentErrors { return presentErrors(messages) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = messages.count == 1 ? messages[0] : "Some items were skipped."
        if messages.count > 1 { alert.informativeText = messages.joined(separator: "\n") }
        if let window = outlineView?.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
