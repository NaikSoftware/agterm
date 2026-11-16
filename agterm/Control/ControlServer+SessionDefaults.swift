import agtermCore
import Foundation

extension ControlServer {
    /// A new session's cwd without `--cwd`: the workspace's project folder, else its remembered folder, both only
    /// in the `currentSession` new-session mode, else $HOME.
    func defaultSessionCwd(in store: AppStore, workspaceID: UUID) -> String {
        settingsModel.settings.usableRememberedFolder(store.workspaces.first { $0.id == workspaceID }?.projectFolder)
            ?? settingsModel.settings.usableRememberedFolder(store.rememberedFolder(ofWorkspace: workspaceID))
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// The first workspace whose remembered folder is exactly `cwd`, only in the `currentSession` new-session mode.
    func remembering(_ cwd: String?, in store: AppStore) -> UUID? {
        guard settingsModel.settings.usesRememberedFolder, let cwd else { return nil }
        return store.workspaceID(rememberingFolder: cwd)
    }

    /// `value` trimmed of surrounding whitespace, or nil if absent or blank after trimming.
    func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
