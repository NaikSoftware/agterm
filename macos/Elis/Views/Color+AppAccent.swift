import SwiftUI

extension Color {
    /// SwiftUI's `accentColor` and default tint stay system blue despite the `AccentColor` asset; AppKit's follows it.
    static let appAccent = Color(nsColor: .controlAccentColor)
}
