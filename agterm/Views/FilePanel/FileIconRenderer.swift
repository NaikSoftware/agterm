import AppKit
import agtermCore

@MainActor
enum FileIconRenderer {
    private struct Key: Hashable {
        let font: String
        let glyph: UInt32
        let color: String
        let size: CGFloat
    }

    private static var cache: [Key: NSImage] = [:]

    private static let registered: Void = {
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "file-icons") ?? []
        for url in urls { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
    }()

    static func image(for icon: FileIcon, pointSize: CGFloat, dark: Bool) -> NSImage {
        _ = registered
        let hex = icon.color.hex(dark: dark)
        let key = Key(font: icon.font.rawValue, glyph: icon.glyph, color: hex, size: pointSize)
        if let image = cache[key] { return image }
        let font = CTFontCreateWithName(icon.font.rawValue as CFString, pointSize, nil)
        let units = Unicode.Scalar(icon.glyph).map { Array(String($0).utf16) } ?? []
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count)
        let glyph = glyphs.first ?? 0
        var ink = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .default, [glyph], &ink, 1)
        let color = (NSColor(agtermHex: hex) ?? .secondaryLabelColor).cgColor
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext, ink.width > 0, ink.height > 0 else { return true }
            // Icon fonts differ in glyph extent and baseline; centre the ink and shrink it into the square.
            let scale = min(1, rect.width / ink.width, rect.height / ink.height)
            context.translateBy(x: rect.midX, y: rect.midY)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -ink.midX, y: -ink.midY)
            context.setFillColor(color)
            CTFontDrawGlyphs(font, [glyph], [.zero], 1, context)
            return true
        }
        cache[key] = image
        return image
    }
}
