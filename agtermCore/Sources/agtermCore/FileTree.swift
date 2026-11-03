import Foundation

public struct FileTreeEntry: Equatable, Sendable {
    public let url: URL
    public let isDirectory: Bool

    public init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }
}

public enum FileTree {
    private static let hidden: Set<String> = [".DS_Store", ".git"]

    public static func children(of dir: URL) throws -> [FileTreeEntry] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey])
        return urls.compactMap { url -> FileTreeEntry? in
            guard !hidden.contains(url.lastPathComponent) else { return nil }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return FileTreeEntry(url: url, isDirectory: isDir)
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }

    public static func copyDestination(for source: URL, in dir: URL, exists: (String) -> Bool) -> URL {
        let name = source.lastPathComponent
        if !exists(name) { return dir.appendingPathComponent(name) }
        let isDir = source.hasDirectoryPath
            || ((try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
        let ext = isDir ? "" : source.pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var n = 1
        while true {
            let suffix = n == 1 ? " copy" : " copy \(n)"
            let candidate = stem + suffix + (ext.isEmpty ? "" : "." + ext)
            if !exists(candidate) { return dir.appendingPathComponent(candidate) }
            n += 1
        }
    }

    public static func canMove(_ source: URL, into dir: URL) -> Bool {
        let src = source.standardizedFileURL.pathComponents
        let dst = dir.standardizedFileURL.pathComponents
        if dst.starts(with: src) { return false }
        return dst != Array(src.dropLast())
    }

    public static func renameError(_ newName: String, sibling exists: (String) -> Bool) -> String? {
        if newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Name cannot be empty." }
        if newName.contains("/") || newName.contains(":") { return "Name cannot contain / or :." }
        if newName == "." || newName == ".." { return "Name is reserved." }
        if exists(newName) { return "\"\(newName)\" already exists." }
        return nil
    }

    public static func pasteTarget(selection: FileTreeEntry?, root: URL) -> URL {
        guard let selection else { return root }
        return selection.isDirectory
            ? selection.url
            : URL(fileURLWithPath: selection.url.deletingLastPathComponent().path)
    }
}
