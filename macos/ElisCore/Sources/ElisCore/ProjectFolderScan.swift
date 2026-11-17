import Foundation

/// One subfolder of a scanned root, offered as a workspace to create or link.
public struct ProjectCandidate: Equatable, Sendable {
    public enum Existing: Equatable, Sendable {
        case none
        case pinned(UUID)
        case named(UUID, String)
    }

    public var name: String
    public var path: String
    public var isGitRepository: Bool
    public var existing: Existing

    public init(name: String, path: String, isGitRepository: Bool, existing: Existing) {
        self.name = name
        self.path = path
        self.isGitRepository = isGitRepository
        self.existing = existing
    }

    public var preselected: Bool {
        guard isGitRepository else { return false }
        if case .pinned = existing { return false }
        return true
    }
}

@MainActor
public enum ProjectFolderScan {
    static let rootNames = ["Projects", "Developer", "IdeaProjects", "code", "src", "dev"]

    /// The visible immediate subdirectories of `root` (symlinks to directories included), in Finder order,
    /// minus any a pin would refuse (scanning `/Users` offers the home folder).
    public static func candidates(in root: String, workspaces: [Workspace], home: String = NSHomeDirectory(),
                                  fileManager: FileManager = .default) -> [ProjectCandidate] {
        guard let root = Workspace.normalizedFolder(root),
              let names = try? fileManager.contentsOfDirectory(atPath: root) else { return [] }
        return names
            .filter { !$0.hasPrefix(".") && isDirectory("\(root)/\($0)", fileManager) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .compactMap { name in
                guard case .success(let path) = Workspace.validatedProjectFolder("\(root)/\(name)", home: home) else { return nil }
                let existing: ProjectCandidate.Existing
                if let pinned = workspaces.first(where: { $0.projectFolder == path }) {
                    existing = .pinned(pinned.id)
                } else if let named = workspaces.first(where: { $0.name == name && $0.projectFolder == nil }) {
                    existing = .named(named.id, named.name)
                } else {
                    existing = .none
                }
                return ProjectCandidate(name: name, path: path,
                                        isGitRepository: fileManager.fileExists(atPath: "\(path)/.git"),
                                        existing: existing)
            }
    }

    /// The first conventional projects folder under `home` that exists. Nil otherwise: scanning home itself would
    /// stat inside Desktop, Documents and Downloads and raise privacy prompts.
    public static func defaultRoot(home: String, fileManager: FileManager = .default) -> String? {
        rootNames.map { "\(home)/\($0)" }.first { isDirectory($0, fileManager) }
    }

    private static func isDirectory(_ path: String, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
