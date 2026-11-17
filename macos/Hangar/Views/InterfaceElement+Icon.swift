import HangarCore
import AppKit
import SwiftUI

extension InterfaceElement {
    /// icon is the element's glyph for SwiftUI: its bundled image sized like a symbol at `size`, else its symbol.
    func icon(size: CGFloat = 15) -> some View {
        Group {
            if let assetName {
                Image(assetName).resizable().scaledToFit().frame(width: size, height: size)
            } else if let symbolName {
                Image(systemName: symbolName)
            }
        }
    }
}

extension NSImage {
    /// bundledIcon is a copy of a template asset scaled to `size` points, for the sidebar's own icons.
    static func bundledIcon(_ name: String, size: CGFloat) -> NSImage? {
        let image = NSImage(named: name)?.copy() as? NSImage
        image?.size = NSSize(width: size, height: size)
        image?.isTemplate = true
        return image
    }
}
