import SwiftUI

/// ChromeButtonStyle is the 30x28 icon button of the sidebar footer and the title bar: a dim glyph, and for a
/// toggle that is on a faint fill and a full-strength glyph.
struct ChromeButtonStyle: ButtonStyle {
    let foreground: Color
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        ChromeButtonBody(label: configuration.label, foreground: foreground, isOn: isOn, isPressed: configuration.isPressed)
    }
}

/// The style's body as a view, the only place a style can read `isEnabled`: the explicit glyph color would
/// otherwise hide the system's disabled dimming.
private struct ChromeButtonBody: View {
    let label: ButtonStyleConfiguration.Label
    let foreground: Color
    let isOn: Bool
    let isPressed: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        label
            .labelStyle(.iconOnly)
            .foregroundStyle(foreground.opacity(isOn ? 1 : 0.58))
            .frame(width: 30, height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(foreground.opacity(isOn ? 0.12 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(isEnabled ? (isPressed ? 0.7 : 1) : 0.35)
    }
}
