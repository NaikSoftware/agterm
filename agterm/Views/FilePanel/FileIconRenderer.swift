import AppKit
import agtermCore
import os

private let logger = Logger(subsystem: "com.umputun.agterm", category: "FileIconRenderer")

@MainActor
enum FileIconRenderer {
    private struct Key: Hashable {
        let font: String
        let glyph: UInt32
        let color: String
        let size: CGFloat
    }

    private static var cache: [Key: NSImage] = [:]

    // Built from the bundled files, never looked up by name: a user-installed font with the same
    // PostScript name (FontAwesome 4.x is common) would otherwise win and draw blank icons.
    private static let descriptors: [FileIconFont: CTFontDescriptor] = {
        var result: [FileIconFont: CTFontDescriptor] = [:]
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "file-icons") ?? [] {
            guard let descriptor = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first,
                  let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String,
                  let font = FileIconFont(rawValue: name) else {
                logger.error("cannot load icon font \(url.lastPathComponent, privacy: .public)")
                continue
            }
            result[font] = descriptor
        }
        for font in [FileIconFont.fileIcons, .devopicons, .mfixx, .fontAwesome] where result[font] == nil {
            logger.error("icon font \(font.rawValue, privacy: .public) is missing from the bundle")
        }
        return result
    }()

    static func font(_ font: FileIconFont, size: CGFloat) -> CTFont? {
        descriptors[font].map { CTFontCreateWithFontDescriptor($0, size, nil) }
    }

    static func image(for icon: FileIcon, pointSize: CGFloat, dark: Bool) -> NSImage {
        let hex = icon.color.hex(dark: dark)
        let key = Key(font: icon.font.rawValue, glyph: icon.glyph, color: hex, size: pointSize)
        if let image = cache[key] { return image }
        let size = NSSize(width: pointSize, height: pointSize)
        guard let font = font(icon.font, size: pointSize) else { return NSImage(size: size) }
        let units = Unicode.Scalar(icon.glyph).map { Array(String($0).utf16) } ?? []
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count)
        let glyph = glyphs.first ?? 0
        var ink = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .default, [glyph], &ink, 1)
        let color = (NSColor(agtermHex: hex) ?? .secondaryLabelColor).cgColor
        // AppKit may rasterize off the main thread; an inferred main-actor closure would abort there.
        let image = NSImage(size: size, flipped: false) { @Sendable rect in
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
