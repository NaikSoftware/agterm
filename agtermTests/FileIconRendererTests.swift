import AppKit
import CoreText
import XCTest
@testable import agterm
@testable import agtermCore

@MainActor
final class FileIconRendererTests: XCTestCase {
    private let fonts: [FileIconFont] = [.fileIcons, .devopicons, .mfixx, .fontAwesome]

    func testEveryFontLoadsFromTheBundledFile() throws {
        for font in fonts {
            let loaded = try XCTUnwrap(FileIconRenderer.font(font, size: 16), "\(font)")
            XCTAssertEqual(CTFontCopyPostScriptName(loaded) as String, font.rawValue)
            let url = try XCTUnwrap(CTFontCopyAttribute(loaded, kCTFontURLAttribute) as? URL, "\(font)")
            XCTAssertTrue(url.path.hasPrefix(Bundle.main.bundlePath), url.path)
        }
    }

    func testEveryCatalogGlyphExistsInItsFont() throws {
        for icon in FileIconCatalog.allIcons {
            let font = try XCTUnwrap(FileIconRenderer.font(icon.font, size: 16))
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
        XCTAssertTrue(Self.painted(image))
        XCTAssertTrue(FileIconRenderer.image(for: icon, pointSize: 16, dark: false) === image)
    }

    func testImageRasterizesOffTheMainThread() async {
        nonisolated(unsafe) let image = FileIconRenderer.image(
            for: FileIconCatalog.icon(forName: "off-main.rs", isDirectory: false), pointSize: 18, dark: true)
        let painted = await Task.detached { Self.painted(image) }.value
        XCTAssertTrue(painted)
    }

    func testSameGlyphInAnotherColorIsNotShared() {
        let js = FileIconRenderer.image(for: FileIconCatalog.icon(forName: "a.js", isDirectory: false), pointSize: 16, dark: true)
        let mjs = FileIconRenderer.image(for: FileIconCatalog.icon(forName: "a.mjs", isDirectory: false), pointSize: 16, dark: true)
        XCTAssertFalse(js === mjs)
    }

    private nonisolated static func painted(_ image: NSImage) -> Bool {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let rep = NSBitmapImageRep(cgImage: cg)
        return (0..<rep.pixelsHigh).contains { y in
            (0..<rep.pixelsWide).contains { x in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 }
        }
    }
}
