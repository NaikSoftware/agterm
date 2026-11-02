import AppKit
import CoreText
import XCTest
@testable import agterm
@testable import agtermCore

@MainActor
final class FileIconRendererTests: XCTestCase {
    private let fonts: [FileIconFont] = [.fileIcons, .devopicons, .mfixx, .fontAwesome]

    func testEveryFontResolvesAfterRegistration() {
        _ = FileIconRenderer.image(for: FileIconCatalog.icon(forName: "a", isDirectory: true), pointSize: 16, dark: true)
        for font in fonts {
            XCTAssertEqual(NSFont(name: font.rawValue, size: 16)?.fontName, font.rawValue)
        }
    }

    func testEveryCatalogGlyphExistsInItsFont() throws {
        _ = FileIconRenderer.image(for: FileIconCatalog.icon(forName: "a", isDirectory: true), pointSize: 16, dark: true)
        for icon in FileIconCatalog.allIcons {
            let font = try XCTUnwrap(NSFont(name: icon.font.rawValue, size: 16))
            let units = try Array(String(XCTUnwrap(Unicode.Scalar(icon.glyph))).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            XCTAssertTrue(CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count),
                          "\(icon.font) U+\(String(icon.glyph, radix: 16, uppercase: true))")
        }
    }

    func testImageIsNonEmptyAndCached() throws {
        let icon = FileIconCatalog.icon(forName: "main.swift", isDirectory: false)
        let image = FileIconRenderer.image(for: icon, pointSize: 16, dark: false)
        XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let rep = NSBitmapImageRep(cgImage: cg)
        let painted = (0..<rep.pixelsHigh).contains { y in
            (0..<rep.pixelsWide).contains { x in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 }
        }
        XCTAssertTrue(painted)
        XCTAssertTrue(FileIconRenderer.image(for: icon, pointSize: 16, dark: false) === image)
    }

    func testSameGlyphInAnotherColorIsNotShared() {
        let js = FileIconRenderer.image(for: FileIconCatalog.icon(forName: "a.js", isDirectory: false), pointSize: 16, dark: true)
        let mjs = FileIconRenderer.image(for: FileIconCatalog.icon(forName: "a.mjs", isDirectory: false), pointSize: 16, dark: true)
        XCTAssertFalse(js === mjs)
    }
}
