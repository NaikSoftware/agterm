import agtermCore
import AppKit

/// The row menu's Tint submenu: None and the fixed colors. A batch of sessions checks an entry only when every
/// target shares it. A tint always colors the row's icon and name.
extension WorkspaceSidebar.Coordinator {
    /// tintMenuItem builds the submenu for the menu's session targets.
    func tintMenuItem(forSessions ids: [UUID]) -> NSMenuItem {
        let tints = ids.map { store.session(withID: $0)?.tint }
        return tintMenuItem(current: tints, request: { TintMenuRequest(sessionIDs: ids, choice: $0) })
    }

    /// tintMenuItem builds the submenu for one workspace row's own tint.
    func tintMenuItem(forWorkspace id: UUID) -> NSMenuItem {
        let tint = store.workspaces.first { $0.id == id }?.tint
        return tintMenuItem(current: [tint], request: { TintMenuRequest(workspaceID: id, choice: $0) })
    }

    private func tintMenuItem(current: [SidebarTint?], request: (TintMenuRequest.Choice) -> TintMenuRequest) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let colors = Set(current.map { $0?.color })
        let none = NSMenuItem(title: "None", action: #selector(menuTint(_:)), keyEquivalent: "")
        none.state = colors == [nil] ? .on : .off
        none.target = self
        none.representedObject = request(.color(nil))
        submenu.addItem(none)
        for color in TintColor.allCases {
            let value = TintValue.named(color)
            submenu.addItem(colorItem(color.rawValue.capitalized, value, checked: colors == [value], request: request(.color(value))))
        }
        if colors.count == 1, case let .hex(hex)?? = colors.first {
            submenu.addItem(colorItem("Custom \(hex)", .hex(hex), checked: true, request: request(.color(.hex(hex)))))
        }
        let tint = NSMenuItem(title: "Tint", action: nil, keyEquivalent: "")
        tint.submenu = submenu
        return tint
    }

    /// colorItem is one swatched color row. macOS 27 can hide menu item images by default, so the swatch asks to stay.
    private func colorItem(_ title: String, _ value: TintValue, checked: Bool, request: TintMenuRequest) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(menuTint(_:)), keyEquivalent: "")
        item.image = Self.swatch(value)
        // preferredImageVisibility is macOS 27 SDK API the CI toolchain cannot name, so it is set by key; 1 is .visible
        if item.responds(to: NSSelectorFromString("setPreferredImageVisibility:")) {
            item.setValue(1, forKey: "preferredImageVisibility")
        }
        item.state = checked ? .on : .off
        item.target = self
        item.representedObject = request
        return item
    }

    @objc private func menuTint(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? TintMenuRequest else { return }
        let tint = request.choice.tint
        if let workspaceID = request.workspaceID {
            if actions.sendWorkspaceTint(tint, to: workspaceID, in: store) { return }
            store.setTint(tint, forWorkspace: workspaceID)
            return
        }
        if actions.sendTint(forSessions: request.sessionIDs, in: store, { _ in tint }) { return }
        switch request.choice {
        case .color(let value?): store.setTintColor(value, forSessions: request.sessionIDs, startingOn: Set(TintPart.allCases))
        case .color(nil): store.setTintColor(nil, forSessions: request.sessionIDs)
        }
    }

    /// swatch draws at display time, so the dynamic system color follows the menu's appearance.
    private static func swatch(_ color: TintValue) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor.tint(color).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    /// TintMenuRequest carries one menu choice and the rows it was built for, so it acts on exactly those.
    private final class TintMenuRequest {
        enum Choice {
            case color(TintValue?)

            var tint: SidebarTint? {
                switch self {
                case .color(let value): value.map { SidebarTint(color: $0, parts: Set(TintPart.allCases)) }
                }
            }
        }

        let sessionIDs: [UUID]
        let workspaceID: UUID?
        let choice: Choice

        init(sessionIDs: [UUID] = [], workspaceID: UUID? = nil, choice: Choice) {
            self.sessionIDs = sessionIDs
            self.workspaceID = workspaceID
            self.choice = choice
        }
    }
}
