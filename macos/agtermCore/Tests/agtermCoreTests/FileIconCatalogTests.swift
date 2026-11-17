import Foundation
import Testing
@testable import agtermCore

struct FileIconCatalogTests {
    @Test func exactNameBeatsExtension() {
        let npm = FileIconCatalog.icon(forName: "package.json", isDirectory: false)
        #expect(npm == FileIcon(font: .fileIcons, glyph: 0xE91C, color: .red))
        #expect(npm != FileIconCatalog.icon(forName: "a.json", isDirectory: false))
    }

    @Test func extensionIsCaseInsensitive() {
        #expect(FileIconCatalog.icon(forName: "A.SWIFT", isDirectory: false)
            == FileIconCatalog.icon(forName: "a.swift", isDirectory: false))
        #expect(FileIconCatalog.icon(forName: "a.swift", isDirectory: false).font == .devopicons)
        #expect(FileIconCatalog.icon(forName: ".swiftlint.yml", isDirectory: false)
            == FileIconCatalog.icon(forName: "a.yml", isDirectory: false))
    }

    @Test func prefixAndSuffixNamesMatch() {
        #expect(FileIconCatalog.icon(forName: "README.md", isDirectory: false).glyph == 0xF02D)
        #expect(FileIconCatalog.icon(forName: "LICENSE-MIT", isDirectory: false).glyph == 0xF02D)
        #expect(FileIconCatalog.icon(forName: ".env.local", isDirectory: false).glyph == 0xF07C)
        #expect(FileIconCatalog.icon(forName: ".envrc", isDirectory: false).glyph == 0xF016)
        #expect(FileIconCatalog.icon(forName: "Cargo.lock", isDirectory: false).glyph == 0xF023)
        #expect(FileIconCatalog.icon(forName: "x-lock.json", isDirectory: false).glyph == 0xF023)
    }

    @Test func directoryUsesFolder() {
        #expect(FileIconCatalog.icon(forName: "a.swift", isDirectory: true)
            == FileIcon(font: .fontAwesome, glyph: 0xF07B, color: .grey))
    }

    @Test func unknownUsesGenericFile() {
        let generic = FileIcon(font: .fontAwesome, glyph: 0xF016, color: .grey)
        #expect(FileIconCatalog.icon(forName: "x.qqq", isDirectory: false) == generic)
        #expect(FileIconCatalog.icon(forName: ".bashrc", isDirectory: false) == generic)
    }

    @Test func everyColorHasBothHexes() throws {
        let hex = try Regex("^#[0-9a-f]{6}$")
        for color in FileIconColor.allCases {
            #expect(color.hex(dark: true).wholeMatch(of: hex) != nil)
            #expect(color.hex(dark: false).wholeMatch(of: hex) != nil)
            #expect(color.hex(dark: true) != color.hex(dark: false))
        }
    }
}
