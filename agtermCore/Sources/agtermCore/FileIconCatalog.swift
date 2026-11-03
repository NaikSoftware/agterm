/// Raw values are the fonts' PostScript names; the app bundles them under `Resources/file-icons`.
public enum FileIconFont: String, Sendable {
    case fileIcons = "file-icons"
    case devopicons = "DevOpicons"
    case mfixx = "MFixx"
    case fontAwesome = "FontAwesome"
}

public enum FileIconColor: CaseIterable, Sendable {
    case red, orange, yellow, green, cyan, blue, purple, pink, grey

    /// Atom file-icons `medium-*` on dark backgrounds, `dark-*` (LESS `darken(_, 15%)`) on light ones.
    public func hex(dark: Bool) -> String {
        switch self {
        case .red: dark ? "#ac4142" : "#742c2d"
        case .orange: dark ? "#d28445" : "#a35f27"
        case .yellow: dark ? "#f4bf75" : "#ee9e2e"
        case .green: dark ? "#90a959" : "#66783e"
        case .cyan: dark ? "#75b5aa" : "#4d9085"
        case .blue: dark ? "#6a9fb5" : "#46788d"
        case .purple: dark ? "#aa759f" : "#825078"
        case .pink: dark ? "#ff00cc" : "#b2008f"
        case .grey: dark ? "#7f7f7f" : "#595959"
        }
    }
}

public struct FileIcon: Equatable, Sendable {
    public let font: FileIconFont
    public let glyph: UInt32
    public let color: FileIconColor

    public init(font: FileIconFont, glyph: UInt32, color: FileIconColor) {
        self.font = font
        self.glyph = glyph
        self.color = color
    }
}

/// A subset of Atom's file-icons `config.cson`; rules that use Atom's Octicons take a Font Awesome glyph instead.
public enum FileIconCatalog {
    public static func icon(forName name: String, isDirectory: Bool) -> FileIcon {
        if isDirectory { return folder }
        let name = name.lowercased()
        if let icon = names[name] { return icon }
        if let icon = prefixes.first(where: { name.hasPrefix($0.0) })?.1 { return icon }
        if name.hasSuffix(".lock") || name.hasSuffix("-lock.json") { return lock }
        let parts = name.drop { $0 == "." }.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count > 1, let ext = parts.last else { return file }
        return extensions[String(ext)] ?? file
    }

    static let folder = FileIcon(font: .fontAwesome, glyph: 0xF07B, color: .grey)
    static let file = FileIcon(font: .fontAwesome, glyph: 0xF016, color: .grey)
    static let lock = FileIcon(font: .fontAwesome, glyph: 0xF023, color: .grey)

    private static let npm = FileIcon(font: .fileIcons, glyph: 0xE91C, color: .red)
    private static let git = FileIcon(font: .devopicons, glyph: 0xE602, color: .red)
    private static let swift = FileIcon(font: .devopicons, glyph: 0xE655, color: .orange)
    // Atom's dotenv glyph U+EBB8 is missing from the shipped font; config is the nearest.
    private static let dotenv = FileIcon(font: .fileIcons, glyph: 0xF07C, color: .yellow)

    static let names: [String: FileIcon] = [
        "dockerfile": FileIcon(font: .fileIcons, glyph: 0xF106, color: .blue),
        "makefile": FileIcon(font: .fontAwesome, glyph: 0xF0AE, color: .yellow),
        "package.json": npm,
        "package-lock.json": npm,
        "package.swift": swift,
        "yarn.lock": FileIcon(font: .fileIcons, glyph: 0xEA1A, color: .blue),
        ".gitignore": git,
        ".gitattributes": git,
        ".gitmodules": git,
        ".env": dotenv,
    ]

    static let prefixes: [(String, FileIcon)] = [
        ("readme", FileIcon(font: .fontAwesome, glyph: 0xF02D, color: .blue)),
        ("license", FileIcon(font: .fontAwesome, glyph: 0xF02D, color: .blue)),
        ("licence", FileIcon(font: .fontAwesome, glyph: 0xF02D, color: .blue)),
        (".env.", dotenv),
    ]

    static let extensions: [String: FileIcon] = {
        func icon(_ font: FileIconFont, _ glyph: UInt32, _ color: FileIconColor) -> FileIcon {
            FileIcon(font: font, glyph: glyph, color: color)
        }
        let yaml = icon(.fileIcons, 0x79, .red)
        let shell = icon(.fileIcons, 0xF0C8, .purple)
        let markdown = icon(.devopicons, 0xE63E, .blue)
        return [
            "swift": swift,
            "js": icon(.mfixx, 0xF129, .yellow), "mjs": icon(.mfixx, 0xF129, .blue), "cjs": icon(.mfixx, 0xF129, .green),
            "ts": icon(.fileIcons, 0x2A6, .blue), "tsx": icon(.fileIcons, 0xE9E7, .blue), "jsx": icon(.fileIcons, 0xE9E6, .blue),
            "json": icon(.fileIcons, 0xEABE, .cyan), "yaml": yaml, "yml": yaml, "toml": icon(.fileIcons, 0x1F143, .green),
            "md": markdown, "markdown": markdown, "txt": icon(.fontAwesome, 0xF0F6, .blue),
            "sh": shell, "bash": shell, "zsh": icon(.fileIcons, 0xF0C8, .blue),
            "py": icon(.mfixx, 0xF14C, .blue), "go": icon(.fileIcons, 0xEAAE, .blue),
            // Atom colours Rust maroon, which this palette folds into orange.
            "rs": icon(.devopicons, 0xE6A8, .orange), "rb": icon(.mfixx, 0xF150, .red),
            "java": icon(.mfixx, 0xF126, .purple), "kt": icon(.fileIcons, 0xE989, .blue),
            "c": icon(.mfixx, 0xF106, .blue), "h": icon(.mfixx, 0xF106, .purple),
            "cpp": icon(.mfixx, 0xF10B, .blue), "hpp": icon(.mfixx, 0xF10B, .purple), "cs": icon(.mfixx, 0xF10C, .blue),
            "php": icon(.fileIcons, 0xF147, .blue), "html": icon(.fontAwesome, 0xF13B, .orange),
            "css": icon(.fontAwesome, 0xF13C, .blue), "scss": icon(.devopicons, 0xE64B, .pink),
            "sql": icon(.mfixx, 0xF10E, .orange), "xml": icon(.fontAwesome, 0xF121, .blue), "svg": icon(.mfixx, 0xF15C, .yellow),
            "png": icon(.fontAwesome, 0xF1C5, .orange), "jpg": icon(.fontAwesome, 0xF1C5, .green),
            "jpeg": icon(.fontAwesome, 0xF1C5, .green), "gif": icon(.fontAwesome, 0xF1C5, .yellow),
            "webp": icon(.fontAwesome, 0xF1C5, .blue), "pdf": icon(.fontAwesome, 0xF1C1, .red),
            "zip": icon(.fontAwesome, 0xF1C6, .grey), "gz": icon(.fontAwesome, 0xF1C6, .blue),
            "dart": icon(.devopicons, 0xE698, .cyan), "lua": icon(.fileIcons, 0xE91B, .blue),
            "vue": icon(.fileIcons, 0xE906, .green), "svelte": icon(.fileIcons, 0x33DC, .orange),
        ]
    }()

    static var allIcons: [FileIcon] {
        [folder, file, lock] + Array(names.values) + prefixes.map(\.1) + Array(extensions.values)
    }
}
