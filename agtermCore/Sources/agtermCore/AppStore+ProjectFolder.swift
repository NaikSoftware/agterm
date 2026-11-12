import Foundation

/// Why a path cannot be a workspace's project folder.
public enum ProjectFolderRejection: Error, Equatable, Sendable {
    case blank, rootOrHome

    public var message: String {
        switch self {
        case .blank: "project folder must not be blank"
        case .rootOrHome: "project folder must not be / or the home folder"
        }
    }
}

extension Workspace {
    /// `path` normalized, refused when blank, `/`, or `home`: those would own every session.
    public static func validatedProjectFolder(_ path: String,
                                              home: String = NSHomeDirectory()) -> Result<String, ProjectFolderRejection> {
        guard let folder = normalizedFolder(path) else { return .failure(.blank) }
        if folder == "/" || folder == normalizedFolder(home) { return .failure(.rootOrHome) }
        return .success(folder)
    }
}

extension AppStore {
    /// Pins `folder` (normalized; nil clears) on `id`. False when the workspace is gone.
    @discardableResult
    public func setProjectFolder(_ folder: String?, ofWorkspace id: UUID) -> Bool {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return false }
        let normalized = folder.flatMap(Workspace.normalizedFolder)
        guard workspaces[index].projectFolder != normalized else { return true }
        workspaces[index].projectFolder = normalized
        scheduleTreeChanged()
        save()
        return true
    }

    /// The workspace whose project folder is `cwd` or an ancestor of it; the longest pin wins, ties keep
    /// sidebar order.
    public func workspaceID(owningFolder cwd: String) -> UUID? {
        guard let folder = Workspace.normalizedFolder(cwd) else { return nil }
        var best: (id: UUID, length: Int)?
        for workspace in workspaces {
            guard let pin = workspace.projectFolder, folder == pin || folder.hasPrefix(pin + "/"),
                  pin.count > (best?.length ?? -1) else { continue }
            best = (workspace.id, pin.count)
        }
        return best?.id
    }

    /// Creates a workspace per unmatched candidate and pins a same-named one; pinned candidates are skipped.
    /// Returns how many workspaces were created or linked.
    @discardableResult
    public func importProjects(_ candidates: [ProjectCandidate]) -> Int {
        var count = 0
        for candidate in candidates {
            switch candidate.existing {
            case .pinned:
                continue
            case .named(let id, _):
                guard setProjectFolder(candidate.path, ofWorkspace: id) else { continue }
            case .none:
                _ = addWorkspace(name: candidate.name, revealNewWorkspace: false, projectFolder: candidate.path)
            }
            count += 1
        }
        return count
    }
}
