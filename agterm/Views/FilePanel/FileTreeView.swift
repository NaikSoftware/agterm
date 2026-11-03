import agtermCore
import AppKit
import SwiftUI

enum FileTreeRoot: Equatable {
    case noSession, noLocalFolder, folder(URL)

    @MainActor init(session: Session?) {
        guard let session, !session.focusedCwd.isEmpty else { self = .noSession; return }
        let reported = session.focusedCwd
        let local = session.localWorkingDirectory(reported: reported, homeDirectory: NSHomeDirectory())
        self = session.remoteHost != nil && local != reported
            ? .noLocalFolder : .folder(URL(fileURLWithPath: local, isDirectory: true))
    }
}

/// One file or folder, kept per path so reloads preserve the outline's identity-keyed expansion and selection.
final class FileTreeNode {
    let url: URL
    let isDirectory: Bool
    /// nil until first listed.
    var children: [FileTreeNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }
}

struct FileTreeView: View {
    let store: AppStore
    @State private var chromeText = WindowContentView.resolvedChromeText()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if case .folder(let url) = FileTreeRoot(session: store.activeSession) {
                Text(url.lastPathComponent)
                    .font(.system(size: GhosttyApp.shared.sidebarFontSize, weight: .medium))
                    .foregroundStyle(chromeText.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(url.path)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            FileTreeOutline(store: store)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(NotificationCenter.default.publisher(for: .agtermAppearanceChanged)) { _ in
            chromeText = WindowContentView.resolvedChromeText()
        }
    }
}

struct FileTreeOutline: NSViewRepresentable {
    let store: AppStore

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> NSScrollView { Self.makeScrollView(coordinator: context.coordinator) }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.setRoot(FileTreeRoot(session: store.activeSession))
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) { coordinator.stop() }

    /// Configured like `WorkspaceSidebar.makeNSView`, except the outline takes first responder for Return and the clipboard keys.
    @MainActor static func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let outline = FileTreeOutlineView()
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.headerView = nil
        outline.rowSizeStyle = .custom
        outline.rowHeight = AppSettings.sidebarRowHeight(fontSize: GhosttyApp.shared.sidebarFontSize)
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 14
        outline.autosaveExpandedItems = false
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.selectionHighlightStyle = .none
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.target = coordinator
        outline.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        let scroll = SidebarScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        coordinator.install(outline: outline, in: scroll)
        return scroll
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        let store: AppStore
        weak var outlineView: FileTreeOutlineView?
        let emptyLabel = NSTextField(labelWithString: "")
        var rootState: FileTreeRoot?
        var rootNode: FileTreeNode?
        var rootReadable = true
        /// Keyed by the `canonical` path, the form FSEvents reports.
        var nodeCache: [String: FileTreeNode] = [:]
        /// Paths shown dimmed as cut.
        var cutPaths: Set<String> = []
        var watcher: FileTreeWatcher?

        init(store: AppStore) {
            self.store = store
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged),
                                                   name: .agtermAppearanceChanged, object: nil)
        }

        func install(outline: FileTreeOutlineView, in scroll: SidebarScrollView) {
            outlineView = outline
            emptyLabel.font = .preferredFont(forTextStyle: .body)
            emptyLabel.lineBreakMode = .byTruncatingTail
            emptyLabel.isHidden = true
            scroll.addSubview(emptyLabel)
            scroll.emptyState = emptyLabel
            applyTheme()
        }

        func stop() {
            watcher?.stop()
            watcher = nil
        }

        func setRoot(_ state: FileTreeRoot) {
            guard state != rootState else { return }
            rootState = state
            stop()
            nodeCache = [:]
            rootNode = nil
            rootReadable = true
            if case .folder(let url) = state {
                let resolved = Self.canonical(url)
                let node = FileTreeNode(url: resolved, isDirectory: true)
                rootNode = node
                nodeCache[resolved.path] = node
                watcher = FileTreeWatcher(root: resolved) { [weak self] in self?.handleChanges($0) }
            }
            outlineView?.reloadData()
            updateEmptyState()
        }

        func children(of node: FileTreeNode) -> [FileTreeNode] {
            if let children = node.children { return children }
            let loaded = list(node)
            node.children = loaded ?? []
            if node === rootNode { rootReadable = loaded != nil }
            return node.children ?? []
        }

        /// Lists `node` from disk, reusing cached nodes; nil when the folder cannot be read.
        func list(_ node: FileTreeNode) -> [FileTreeNode]? {
            guard let entries = try? FileTree.children(of: node.url) else { return nil }
            return entries.map { entry in
                if let cached = nodeCache[entry.url.path], cached.isDirectory == entry.isDirectory { return cached }
                let child = FileTreeNode(url: entry.url, isDirectory: entry.isDirectory)
                nodeCache[entry.url.path] = child
                return child
            }
        }

        /// Re-lists one loaded folder and reloads its rows; file operations call it on the parent they changed.
        func reload(_ node: FileTreeNode) {
            guard let old = node.children else { return }
            let fresh = list(node)
            let kept = Set((fresh ?? []).map(ObjectIdentifier.init))
            for gone in old where !kept.contains(ObjectIdentifier(gone)) { evict(gone) }
            node.children = fresh ?? []
            if node === rootNode {
                rootReadable = fresh != nil
                outlineView?.reloadData()
            } else {
                outlineView?.reloadItem(node, reloadChildren: true)
            }
            updateEmptyState()
        }

        func reload(parentOf url: URL) {
            if let parent = nodeCache[Self.canonical(url.deletingLastPathComponent()).path] { reload(parent) }
        }

        // `resolvingSymlinksInPath` strips `/private` from `/private/var`, the form FSEvents and directory listings use.
        static func canonical(_ url: URL) -> URL {
            guard let real = realpath(url.path, nil) else { return url.standardizedFileURL }
            defer { free(real) }
            return URL(fileURLWithPath: String(cString: real), isDirectory: true)
        }

        func evict(_ node: FileTreeNode) {
            nodeCache[node.url.path] = nil
            node.children?.forEach(evict)
        }

        func handleChanges(_ paths: [String]) {
            guard let rootNode else { return }
            guard FileManager.default.fileExists(atPath: rootNode.url.path) else { return reload(rootNode) }
            var parents: [FileTreeNode] = []
            for path in paths {
                let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
                if let node = nodeCache[parent], node.children != nil, !parents.contains(where: { $0 === node }) {
                    parents.append(node)
                }
            }
            parents.forEach(reload)
        }

        func updateEmptyState() {
            let message: String? = switch rootState {
            case .noLocalFolder: "No local folder"
            case .folder where !FileManager.default.fileExists(atPath: rootNode?.url.path ?? ""): "Folder not found"
            case .folder where !rootReadable: "Cannot read this folder"
            default: nil
            }
            emptyLabel.stringValue = message ?? ""
            emptyLabel.isHidden = message == nil
            emptyLabel.superview?.needsLayout = true
        }

        func applyTheme() {
            outlineView?.appearance = NSAppearance(named: GhosttyApp.shared.terminalThemeIsDark ? .darkAqua : .aqua)
            emptyLabel.textColor = (GhosttyApp.shared.terminalForegroundColor ?? .secondaryLabelColor).withAlphaComponent(0.6)
        }

        @objc func appearanceChanged() {
            applyTheme()
            guard let outline = outlineView else { return }
            outline.rowHeight = AppSettings.sidebarRowHeight(fontSize: GhosttyApp.shared.sidebarFontSize)
            outline.reloadData(forRowIndexes: IndexSet(integersIn: 0 ..< outline.numberOfRows), columnIndexes: [0])
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = (item as? FileTreeNode) ?? rootNode else { return 0 }
            return children(of: node).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = (item as? FileTreeNode) ?? rootNode else { return NSNull() }
            return children(of: node)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? FileTreeNode)?.isDirectory ?? false
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { SidebarRowView() }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FileTreeNode else { return nil }
            let cell = outlineView.makeView(withIdentifier: FileTreeCellView.reuseID, owner: nil) as? FileTreeCellView
                ?? FileTreeCellView()
            let name = node.url.lastPathComponent
            let app = GhosttyApp.shared
            cell.textField?.stringValue = name
            cell.textField?.font = .systemFont(ofSize: app.sidebarFontSize)
            cell.imageView?.image = FileIconRenderer.image(
                for: FileIconCatalog.icon(forName: name, isDirectory: node.isDirectory), pointSize: 16, dark: app.terminalThemeIsDark)
            cell.textAlpha = cutPaths.contains(node.url.path) ? 0.5 : name.hasPrefix(".") ? 0.6 : 1
            cell.setColors(selected: outlineView.isRowSelected(outlineView.row(forItem: node)))
            return cell
        }
    }
}

final class FileTreeOutlineView: NSOutlineView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizesOutlineColumn = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        SidebarOutlineView.trimmedCellFrame(super.frameOfCell(atColumn: column, row: row), in: self, column: column, row: row)
    }

    override func keyDown(with event: NSEvent) {
        guard [36, 76].contains(event.keyCode), let coordinator = delegate as? FileTreeOutline.Coordinator else {
            return super.keyDown(with: event)
        }
        selectedRowIndexes.compactMap { item(atRow: $0) as? FileTreeNode }.forEach(coordinator.open)
    }
}

/// A `SidebarCellView` so `SidebarRowView` retints it on selection like a sidebar row.
final class FileTreeCellView: SidebarCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("file-tree-cell")
    var textAlpha: CGFloat = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseID
        let icon = NSImageView()
        icon.imageScaling = .scaleNone
        let name = NSTextField(labelWithString: "")
        name.lineBreakMode = .byTruncatingTail
        for view in [icon, name] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        textField = name
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Self.iconWidth),
            icon.heightAnchor.constraint(equalToConstant: Self.iconWidth),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Self.iconGap),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func setColors(selected: Bool) {
        textField?.textColor = themeTextColor(selected: selected).withAlphaComponent(textAlpha)
    }
}
