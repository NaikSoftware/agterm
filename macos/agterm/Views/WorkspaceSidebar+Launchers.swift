import agtermCore
import AppKit

/// LauncherChoice is a "+" menu item's payload: the row it was opened from and what to start there.
private final class LauncherChoice: NSObject {
    let workspaceID: UUID
    let launcher: SessionLauncher

    init(workspaceID: UUID, launcher: SessionLauncher) {
        self.workspaceID = workspaceID
        self.launcher = launcher
    }
}

/// The workspace row's "+" menu and the repeat button beside it.
extension WorkspaceSidebar.Coordinator {
    var lastLauncher: SessionLauncher {
        actions.settingsModel?.lastSessionLauncher ?? .terminal
    }

    /// "+" opens the launcher menu. The button carries no workspace id, so it is derived from the outline row at
    /// click time — reused cells target the right one.
    @objc func addSessionButtonClicked(_ sender: NSButton) {
        guard let workspaceID = clickedWorkspace(sender) else { return }
        SessionLaunchers.refresh()
        let menu = NSMenu()
        for launcher in SessionLaunchers.available {
            let item = NSMenuItem(title: launcher.title, action: #selector(menuLaunch(_:)), keyEquivalent: "")
            item.target = self
            item.image = launcher.image(pointSize: 16)
            item.representedObject = LauncherChoice(workspaceID: workspaceID, launcher: launcher)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc func repeatLauncherClicked(_ sender: NSButton) {
        guard let workspaceID = clickedWorkspace(sender) else { return }
        launch(lastLauncher, toWorkspace: workspaceID)
    }

    @objc private func menuLaunch(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? LauncherChoice else { return }
        launch(choice.launcher, toWorkspace: choice.workspaceID)
    }

    private func launch(_ launcher: SessionLauncher, toWorkspace workspaceID: UUID) {
        actions.settingsModel?.setLastSessionLauncher(launcher)
        guard let session = addNewSession(toWorkspace: workspaceID), let command = launcher.command else { return }
        let store = store
        Task { [weak typer = actions.sessionTyper] in
            _ = await typer?.typeLine(command, into: session.id, store: store)
        }
    }

    private func clickedWorkspace(_ sender: NSButton) -> UUID? {
        // a click on a row button must not also flip the row's expansion
        pendingRowToggle?.cancel()
        pendingRowToggle = nil
        guard let outline = outlineView else { return nil }
        let row = outline.row(for: sender)
        guard row >= 0, let node = outline.item(atRow: row) as? SidebarNode, node.kind == .workspace else { return nil }
        return node.id
    }
}
