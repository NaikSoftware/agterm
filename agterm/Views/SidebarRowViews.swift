import agtermCore
import AppKit

/// The workspace row's inline "+". NSButton fires its action on a Control-click, so that click goes up the
/// responder chain to `SidebarOutlineView.mouseDown`, which opens the row menu as right-click does.
final class AddSessionButton: NSButton {
    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control) else { return super.mouseDown(with: event) }
        nextResponder?.mouseDown(with: event)
    }
}

/// An `NSTableCellView` with a leading icon, the name field, and a trailing badge. The icon is the inherited
/// `cell.imageView` (overlapping squares for a workspace, outlined terminal for a session), so AppKit re-tints it white on
/// a selected row; the name is `cell.textField`, which the rename and selection wiring drives.
class SidebarCellView: NSTableCellView {
    /// Trailing unseen-notification count — a session's `unseenCount` or a collapsed workspace's roll-up; 0 hides.
    let badge = BadgeView()

    /// Agent-status glyph fed from the session's `agentIndicator`; hidden on `.idle` (workspace rows always idle).
    let statusIcon = StatusIconView()

    /// companionMarker shows on a folded parent whose hidden companions need attention, beside the parent's own
    /// status glyph rather than replacing it; session cells only.
    var companionMarker: NSImageView?
    var companionMarkerWidthConstraint: NSLayoutConstraint?

    /// titleCenter centers the name on the row; its constant carries the density's `titleLift`, reset on every
    /// configure since a reused cell keeps the density it was built with.
    var titleCenter: NSLayoutConstraint?

    /// flagMark is the flag after a flagged session's name in the tree, session cells only. While it shows, the
    /// name hugs its text (`nameStretch` drops below the name's hugging) so the flag follows it.
    var flagMark: NSImageView?
    var flagMarkWidthConstraint: NSLayoutConstraint?
    var flagMarkGapConstraint: NSLayoutConstraint?
    var nameStretch: NSLayoutConstraint?

    func setFlagMarkVisible(_ visible: Bool) {
        guard let flagMark else { return }
        flagMark.isHidden = !visible
        flagMarkWidthConstraint?.constant = visible ? 11 : 0
        flagMarkGapConstraint?.constant = visible ? 5 : 0
        nameStretch?.priority = visible ? .defaultLow - 1 : .defaultLow + 1
    }

    func setCompanionMarker(_ companions: [String]) {
        guard let companionMarker, let companionMarkerWidthConstraint else { return }
        companionMarker.isHidden = companions.isEmpty
        companionMarkerWidthConstraint.constant = companions.isEmpty ? 0 : 10
        let label = companions.isEmpty ? nil : "companions need attention: " + companions.joined(separator: ", ")
        companionMarker.setAccessibilityLabel(label)
        companionMarker.toolTip = label
    }

    /// Inline "+" button between the name and the status icon, workspace cells only (nil for session cells).
    /// Set by the cell builder; `handleSingleClick` reads it to avoid toggling expansion on a click on it.
    var addButton: NSButton?

    /// Width of `addButton`, toggled between 0 and the glyph width by `setAddButtonVisible` — the
    /// collapse-the-slot convention of `StatusIconView.widthConstraint`, so an idle row's name reclaims it.
    var addButtonWidthConstraint: NSLayoutConstraint?

    private static let addButtonWidth: CGFloat = 16
    /// quickStartSize is the side of the workspace row's square quick-start buttons.
    static let quickStartSize: CGFloat = 22

    /// Repeat button left of `addButton`: starts the last "+" choice and shows its icon. Shares the "+" hover
    /// reveal and Interface toggle. `repeatLauncher` is read on each reveal, since the last choice changes.
    var repeatButton: NSButton?
    var repeatButtonWidthConstraint: NSLayoutConstraint?
    var repeatButtonGapConstraint: NSLayoutConstraint?
    var repeatLauncher: (() -> SessionLauncher)?

    /// Hover-revealed close button at the trailing edge, session cells only (nil for workspace cells).
    var closeButton: NSButton?
    var closeButtonWidthConstraint: NSLayoutConstraint?

    var iconWidthConstraint: NSLayoutConstraint?
    var iconGapConstraint: NSLayoutConstraint?

    static let iconWidth: CGFloat = 18
    static let iconGap: CGFloat = 8

    /// notice is the remote presentation warning.
    var notice: String? {
        didSet { applyNotice() }
    }

    func setIconVisible(_ visible: Bool) {
        imageView?.isHidden = !visible
        iconWidthConstraint?.constant = visible ? Self.iconWidth : 0
        iconGapConstraint?.constant = visible ? Self.iconGap : 0
        applyNotice()
    }

    private func applyNotice() {
        imageView?.toolTip = imageView?.isHidden == false ? notice : nil
        updateNameTooltip()
    }

    /// The row's tint, applied by `setColors` so a selection change keeps it; nil restores the theme colors.
    var tint: SidebarTint? {
        didSet { imageView?.setAccessibilityValue(tint.map { "\($0.color.rawValue) tint" }) }
    }
    private var hoverTrackingArea: NSTrackingArea?

    /// Reveals or collapses the inline "+": the Finder/Xcode hover convention, so an idle row shows no button.
    /// The roll-up badge and status give way while it shows, so "+" always sits at the trailing edge.
    /// Driven by `mouseEntered`/`mouseExited`, reset hidden when a reused cell is reconfigured. No-op for session cells.
    func setAddButtonVisible(_ visible: Bool) {
        guard let addButton, let addButtonWidthConstraint else { return }
        badge.hoverHidden = visible
        statusIcon.hoverHidden = visible
        addButton.isHidden = !visible
        addButtonWidthConstraint.constant = visible ? Self.quickStartSize : 0
        guard let repeatButton, let repeatButtonWidthConstraint else { return }
        if visible, let launcher = repeatLauncher?() {
            repeatButton.image = launcher.image(pointSize: 13)
            repeatButton.toolTip = "New \(launcher.title) Session"
            repeatButton.setAccessibilityLabel(repeatButton.toolTip)
            repeatButton.setAccessibilityValue(launcher.rawValue)
        }
        repeatButton.isHidden = !visible
        repeatButtonWidthConstraint.constant = visible ? Self.quickStartSize : 0
        repeatButtonGapConstraint?.constant = visible ? 6 : 0
    }

    /// Reveals or collapses the session row's close button. It shows only while the row has no badge, status
    /// glyph or companion marker, so it never covers one; configure resets it hidden.
    func setCloseButtonVisible(_ visible: Bool) {
        guard let closeButton, let closeButtonWidthConstraint else { return }
        let show = visible && badge.count == 0 && !statusIcon.showsGlyph && companionMarker?.isHidden != false
        closeButton.isHidden = !show
        closeButtonWidthConstraint.constant = show ? Self.addButtonWidth : 0
    }

    override func layout() {
        super.layout()
        updateNameTooltip()
    }

    /// Reveals the full name on hover, but only while the row is too narrow to show it: the label truncates by
    /// tail and nothing else exposes what was cut. A tooltip repeating already-visible text would be noise, so
    /// the width decides. Runs from `layout`, so dragging the sidebar divider re-evaluates it. Skipped mid-rename
    /// — the field editor holds the text then, and `stringValue` is whatever has been typed so far.
    /// A hidden icon's `notice` also appears when the name fits.
    private func updateNameTooltip() {
        guard let field = textField, field.currentEditor() == nil else { return }
        let available = field.cell?.titleRect(forBounds: field.bounds).width ?? field.bounds.width
        let name = field.attributedStringValue.size().width > available ? field.stringValue : nil
        let hiddenNotice = imageView?.isHidden == true ? notice : nil
        let parts = [name, hiddenNotice].compactMap(\.self)
        field.toolTip = parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    // hover tracking for the workspace "+" and the session close button
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea); self.hoverTrackingArea = nil }
        guard addButton != nil || closeButton != nil else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        setCloseButtonVisible(true)
        // the "+" is a toggleable Interface element, gated at hover time only: a live Settings flip takes
        // effect on the next hover, and a "+" already on screen lingers until the next mouse exit/enter —
        // accepted for a hover-only affordance that clears on the next mouse move.
        guard !GhosttyApp.shared.hiddenInterfaceElements.contains(.workspaceAddSession) else { return }
        setAddButtonVisible(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setAddButtonVisible(false)
        setCloseButtonVisible(false)
    }

    /// setColors tints row text and icons from the theme for the row's selection state; a row `tint` colors both
    /// the icon and the name whatever its stored parts say. Never drive it from `backgroundStyle`, which AppKit
    /// flips only while the table is first responder.
    func setColors(selected: Bool) {
        let color = Self.themeTextColor(selected: selected)
        let tintColor = tint.map { NSColor.tint($0.color) }
        textField?.textColor = tintColor ?? color
        let iconAlpha: CGFloat = selected ? 0.85 : 0.58
        imageView?.contentTintColor = tintColor ?? color.withAlphaComponent(iconAlpha)
        for button in [addButton, repeatButton].compactMap(\.self) {
            button.contentTintColor = color
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.layer?.backgroundColor = color.withAlphaComponent(0.12).cgColor
        }
        closeButton?.contentTintColor = color.withAlphaComponent(iconAlpha)
        companionMarker?.contentTintColor = GhosttyApp.shared.statusColor(for: .blocked)
        flagMark?.contentTintColor = NSColor.tint(.indigo)
    }

    /// themeTextColor is the row text color the theme gives for a selection state, never a row tint.
    static func themeTextColor(selected: Bool) -> NSColor {
        let app = GhosttyApp.shared
        return selected
            ? (app.terminalSelectionForegroundColor ?? app.terminalForegroundColor ?? .white)
            : (app.terminalForegroundColor ?? .labelColor)
    }
}

/// A small filled accent capsule showing an unseen-notification count, custom-drawn (not an `NSTextField`) so
/// capsule and text center cleanly at row size. A single digit reads as a circle (min width = height). Exposed
/// to accessibility as a `notify-badge` static text.
final class BadgeView: NSView {
    /// The count to show, capped at `99+`. Drives `intrinsicContentSize` and redraw.
    var count = 0 {
        didSet {
            guard count != oldValue else { return }
            invalidateIntrinsicContentSize()
            isHidden = !showsCapsule
            needsDisplay = true
            setAccessibilityValue(label)
        }
    }

    /// hoverHidden collapses a nonzero badge while the workspace row's hover buttons take its slot.
    var hoverHidden = false {
        didSet {
            guard hoverHidden != oldValue else { return }
            invalidateIntrinsicContentSize()
            isHidden = !showsCapsule
        }
    }

    private var showsCapsule: Bool { count > 0 && !hoverHidden }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("notify-badge")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    private static let font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    // leading-edge gap so the capsule keeps air from the status glyph to its left; a count-0 badge collapses
    // fully and lets that glyph sit flush.
    private static let leadingGap: CGFloat = 4
    private var textAttributes: [NSAttributedString.Key: Any] { [.font: Self.font, .foregroundColor: NSColor.white] }
    private var label: String { count > 99 ? "99+" : String(count) }
    private static let fill = NSColor(srgbRed: 1, green: 0x45 / 255, blue: 0x3A / 255, alpha: 1)

    override var intrinsicContentSize: NSSize {
        let height: CGFloat = 16
        // `isHidden` alone does NOT collapse a view in Auto Layout, so a count-0 badge would reserve a trailing
        // slot and push the status glyph in from the right edge; zero width lets the name reclaim it.
        guard showsCapsule else { return NSSize(width: 0, height: height) }
        let capsule = max((label as NSString).size(withAttributes: textAttributes).width + 9, height)
        return NSSize(width: capsule + Self.leadingGap, height: height)
    }

    override func draw(_: NSRect) {
        let capsule = NSRect(x: Self.leadingGap, y: 0, width: bounds.width - Self.leadingGap, height: bounds.height)
        let radius = capsule.height / 2
        // the conventional unread red, fixed so it reads the same on every theme
        Self.fill.setFill()
        NSBezierPath(roundedRect: capsule, xRadius: radius, yRadius: radius).fill()
        let text = label as NSString
        let size = text.size(withAttributes: textAttributes)
        let origin = NSPoint(x: capsule.minX + (capsule.width - size.width) / 2, y: (capsule.height - size.height) / 2)
        text.draw(at: origin, withAttributes: textAttributes)
    }
}

/// A small SF-Symbol agent-status glyph left of the count badge: by default a `circle.fill` tinted
/// lavender-grey for `active`, amber for `blocked`, green for `completed`; a Settings shape or a per-call
/// `session.status --shape` swaps the silhouette, so shape carries the state alongside the tint. Hidden on
/// `.idle`. Accessibility: an `agent-status` static text whose value is the state name (XCUITest matches
/// `app.staticTexts["agent-status"]`; neither tint nor silhouette is observable there). Blink is a layer
/// `opacity` `CABasicAnimation` (autoreverse/repeat), added only while visible AND blinking; a non-blinking
/// `active` glyph gets a slower fade instead. Reduce Motion stops both.
final class StatusIconView: NSImageView {
    private static let blinkKey = "agent-status-blink"
    private static let fadeKey = "agent-status-fade"
    private static let glyphWidth: CGFloat = 16
    /// Symbol point size of the glyph: the default circle's ink measures 9pt across at 9. The view draws it
    /// unscaled, so the 16pt slot never enlarges it. The Settings shape picker previews options at the same size,
    /// so an option looks like the glyph it installs.
    static let glyphPointSize: CGFloat = 9

    /// The view's width, collapsed to 0 on `.idle` so a status-less row reclaims the slot (its label truncates
    /// full-width); `glyphWidth` when a glyph shows. Activated in init, toggled in `apply`.
    private lazy var widthConstraint = widthAnchor.constraint(equalToConstant: 0)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        imageScaling = .scaleNone
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("agent-status")
        widthConstraint.isActive = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    /// apply renders the indicator's tinted glyph and updates tooltip + accessibility value to the state name;
    /// `.idle` hides the view and stops the blink.
    func apply(_ indicator: AgentIndicator) {
        self.indicator = indicator
        toolTip = indicator.status.tooltipText
        showsGlyph = indicator.status != .idle
        applyPulses()
        guard showsGlyph else {
            image = nil
            setAccessibilityValue(AgentStatus.idle.rawValue)
            return
        }
        image = Self.icon(for: indicator.status, override: indicator.color, shape: indicator.shape)
        setAccessibilityValue(indicator.status.rawValue)
    }

    private var indicator = AgentIndicator()

    // Core Animation can drop a layer's animations while the view is out of a window, so re-add on return.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPulses()
    }

    private func applyPulses() {
        let motion = showsGlyph && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        pulse(Self.blinkKey, indicator.blink && motion, to: 0.2, duration: 0.5)
        pulse(Self.fadeKey, indicator.status == .active && !indicator.blink && motion, to: 0.25, duration: 1.4)
    }

    /// hoverHidden collapses a shown glyph while the workspace row's hover buttons take its slot.
    var hoverHidden = false {
        didSet { applyVisibility() }
    }

    private(set) var showsGlyph = false {
        didSet { applyVisibility() }
    }

    private func applyVisibility() {
        let visible = showsGlyph && !hoverHidden
        isHidden = !visible
        widthConstraint.constant = visible ? Self.glyphWidth : 0
    }

    /// pulse runs or stops an endless autoreversing opacity animation; a running one is left alone so a
    /// reconfigure never restarts it at full opacity.
    private func pulse(_ key: String, _ on: Bool, to opacity: Double, duration: CFTimeInterval) {
        guard on else {
            layer?.removeAnimation(forKey: key)
            return
        }
        guard layer?.animation(forKey: key) == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = opacity
        pulse.duration = duration
        pulse.autoreverses = true
        pulse.repeatCount = .greatestFiniteMagnitude
        if key == Self.fadeKey { pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut) }
        layer?.add(pulse, forKey: key)
    }

    private static func icon(for status: AgentStatus, override colorHex: String?, shape: StatusShape?) -> NSImage? {
        guard status != .idle else { return nil } // unreachable: `apply` returns early on `.idle` before drawing
        // symbol + color come from the shared resolvers, so this glyph and the SwiftUI StatusGlyph stay
        // identical, per-call `--shape`/`--color` overrides included.
        let weight = GhosttyApp.shared.statusSymbolWeight(for: status, override: shape)
        let config = NSImage.SymbolConfiguration(pointSize: Self.glyphPointSize, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [GhosttyApp.shared.statusColor(for: status, override: colorHex)]))
        let symbol = GhosttyApp.shared.statusSymbolName(for: status, override: shape)
        return NSImage(systemSymbolName: symbol, accessibilityDescription: status.rawValue)?
            .withSymbolConfiguration(config)
    }
}

/// Row view drawing its own selection pill in `drawBackground`: the row's group tint (`selectionTint`, else the
/// theme selection background) as a soft fill and hairline, so cells keep their normal colors when selected.
/// The table's `selectionHighlightStyle` is `.none` (`makeNSView`), or AppKit paints a gray unemphasized fill
/// whenever the sidebar isn't first responder. `isEmphasized` is overridden so the row redraws on a window
/// key-state change (dimmer for a background window).
class SidebarRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { window?.isKeyWindow ?? false }
        // isEmphasized is derived from the window's key state; the setter only triggers a redraw.
        // swiftlint:disable:next unused_setter_value
        set { needsDisplay = true }
    }

    override var isSelected: Bool {
        // AppKit won't redraw with selectionHighlightStyle == .none
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }

    // AppKit draws the triangle in the appearance's secondary label color; dimmed it reads near the spec's fg 36%
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if subview.identifier == NSOutlineView.disclosureButtonIdentifier { subview.alphaValue = 0.65 }
    }

    /// selectionTint is the tint of the row's group (workspace, else its own session tint); nil uses the theme.
    var selectionTint: NSColor? {
        didSet { if selectionTint != oldValue, isSelected { needsDisplay = true } }
    }

    var selectionColor: NSColor {
        let app = GhosttyApp.shared
        return selectionTint ?? app.terminalSelectionBackgroundColor ?? app.terminalForegroundColor ?? .white
    }

    /// band is the workspace group's opaque tint, drawn faint behind this row; the edge rounds, strokes and
    /// insets only the group's outer ends.
    var band: (color: NSColor, edge: SidebarBandEdge)? {
        didSet {
            guard band?.color != oldValue?.color || band?.edge != oldValue?.edge else { return }
            needsDisplay = true
            needsLayout = true
        }
    }

    /// groupEdge is the row's place in its workspace group, tinted or not; nil outside the tree.
    var groupEdge: SidebarBandEdge? {
        didSet {
            guard groupEdge != oldValue else { return }
            needsDisplay = true
            needsLayout = true
        }
    }

    /// rowWash is a tinted session's own wash, drawn over the band.
    var rowWash: NSColor? {
        didSet { if rowWash != oldValue { needsDisplay = true } }
    }

    /// isHovered draws the pointer's faint fill. It is cleared on reuse and when the row leaves its window, so
    /// a row scrolled or reloaded away from under the pointer never keeps it.
    var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    // a cell's own hover areas forward their events up the responder chain to this row; only its own count
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === hoverArea { isHovered = true }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === hoverArea { isHovered = false }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }

    /// waveLayer clips the drifting gradient to the row rect; nil while the row shows no wave.
    private(set) var waveLayer: CALayer?
    private var wave: SidebarWave?
    private var waveStill = false
    private var wavePeriod: CGFloat = 0
    static let waveKey = "sidebar-wave"
    static let bandRadius: CGFloat = 11

    /// setWave shows the active-row wave, or removes it for nil. It drifts one period per 4.8 s unless
    /// Reduce Motion is on, which leaves the gradient still.
    func setWave(_ wave: SidebarWave?) {
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard wave != self.wave || still != waveStill else { return }
        self.wave = wave
        waveStill = still
        guard let wave, let base = NSColor(agtermHex: wave.base), let second = NSColor(agtermHex: wave.second) else {
            waveLayer?.removeFromSuperlayer()
            waveLayer = nil
            return
        }
        wantsLayer = true
        let clip = waveLayer ?? CALayer()
        if waveLayer == nil {
            clip.masksToBounds = true
            clip.addSublayer(CAGradientLayer())
            layer?.insertSublayer(clip, at: 0)
            waveLayer = clip
        }
        let gradient = clip.sublayers?.first as? CAGradientLayer
        let period = [base.withAlphaComponent(0.04), base.withAlphaComponent(0.20), second.withAlphaComponent(0.16)]
        // two periods side by side, so a shift by one period lands on an identical frame
        gradient?.colors = (period + period + [base.withAlphaComponent(0.04)]).map(\.cgColor)
        gradient?.locations = [0, 0.125, 0.275, 0.5, 0.625, 0.775, 1]
        gradient?.startPoint = CGPoint(x: 0, y: 0.5)
        gradient?.endPoint = CGPoint(x: 1, y: 0.5)
        wavePeriod = 0
        layoutWave()
    }

    override func layout() {
        super.layout()
        alignToContent()
        layoutWave()
    }

    /// alignToContent keeps the cell and chevron in the content rect: AppKit places a cell by `frameOfCell` only
    /// when it adds it and afterwards just autoresizes it with the row, so a fold that moves the group's edge
    /// extras would otherwise stretch the cell across them.
    private func alignToContent() {
        let content = contentRect
        for subview in subviews {
            if subview is NSTableCellView {
                subview.frame = NSRect(x: subview.frame.minX, y: content.minY, width: subview.frame.width, height: content.height)
            } else if subview.identifier == NSOutlineView.disclosureButtonIdentifier {
                subview.setFrameOrigin(NSPoint(x: subview.frame.minX, y: content.midY - subview.frame.height / 2))
            }
        }
    }

    // re-adds the drift if Core Animation dropped it while the row was out of a window
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isHovered = false }
        needsLayout = true
    }

    private func layoutWave() {
        guard let clip = waveLayer, let gradient = clip.sublayers?.first else { return }
        let period = bounds.width * 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // square corners; the row rect sits inside the band's padding, so it never pokes past a rounded corner
        clip.frame = rowRect
        gradient.frame = CGRect(x: -clip.frame.minX, y: 0, width: period * 2, height: clip.bounds.height)
        CATransaction.commit()
        guard period != wavePeriod || (!waveStill && gradient.animation(forKey: Self.waveKey) == nil) else { return }
        wavePeriod = period
        gradient.removeAnimation(forKey: Self.waveKey)
        guard !waveStill, period > 0 else { return }
        let drift = CABasicAnimation(keyPath: "transform.translation.x")
        drift.fromValue = 0
        drift.toValue = -period
        drift.duration = 4.8
        drift.repeatCount = .greatestFiniteMagnitude
        gradient.add(drift, forKey: Self.waveKey)
    }

    /// Half the gap between workspace groups, and the group's padding around its rows.
    static let groupGap: CGFloat = 4
    static let groupPadding: CGFloat = 3

    /// bandRect is the group's frame in this row: `groupPadding` around the row rect, and `groupGap` short of
    /// the row's edge at the group's outer ends.
    func bandRect(_ edge: SidebarBandEdge) -> NSRect {
        let pill = selectionRect
        var rect = NSRect(x: pill.minX - Self.groupPadding, y: bounds.minY, width: pill.width + 2 * Self.groupPadding,
                          height: bounds.height)
        let top: CGFloat = edge == .first || edge == .single ? Self.groupGap : 0
        let bottom: CGFloat = edge == .last || edge == .single ? Self.groupGap : 0
        rect.origin.y += isFlipped ? top : bottom
        rect.size.height -= top + bottom
        return rect
    }

    /// edgeExtras is the space a row of a group adds outside its content: half the gap between groups plus the
    /// group's padding, above the first row and below the last. Row height, cell frame and drawing all read it.
    static func edgeExtras(_ edge: SidebarBandEdge?) -> (top: CGFloat, bottom: CGFloat) {
        let outer = groupGap + groupPadding
        return (edge == .first || edge == .single ? outer : 0, edge == .last || edge == .single ? outer : 0)
    }

    /// contentRect is the row less its edge extras, across the pill's width: where the cell lays out.
    var contentRect: NSRect {
        let pill = selectionRect, extras = Self.edgeExtras(groupEdge)
        return NSRect(x: pill.minX, y: bounds.minY + (isFlipped ? extras.top : extras.bottom), width: pill.width,
                      height: max(0, bounds.height - extras.top - extras.bottom))
    }

    /// rowRect is where selection, hover, wash and wave draw: the content rect, inset by the density's gap
    /// between rows.
    var rowRect: NSRect {
        contentRect.insetBy(dx: 0, dy: GhosttyApp.shared.sidebarDensity.selectionInset)
    }

    /// fillBand draws the group's rounded outline once across its rows: each row's piece overhangs the edges
    /// the group continues past and is clipped to the row, so only the outer edges round and stroke.
    private func fillBand(_ fill: NSColor, edge: SidebarBandEdge, stroke: NSColor? = nil) {
        let radius = Self.bandRadius
        var shape = bandRect(edge)
        let overhang = radius + 2
        let continuesUp = edge == .middle || edge == .last, continuesDown = edge == .middle || edge == .first
        if continuesUp { shape.size.height += overhang; if isFlipped { shape.origin.y -= overhang } }
        if continuesDown { shape.size.height += overhang; if !isFlipped { shape.origin.y -= overhang } }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        fill.setFill()
        NSBezierPath(roundedRect: shape, xRadius: radius, yRadius: radius).fill()
        if let stroke {
            let outline = NSBezierPath(roundedRect: shape.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
            outline.lineWidth = 1
            stroke.setStroke()
            outline.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if let band {
            fillBand(band.color.withAlphaComponent(0.10), edge: band.edge, stroke: band.color.withAlphaComponent(0.16))
        }
        let rect = rowRect, radius = Self.rowRadius
        if let rowWash {
            rowWash.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
        if isSelected {
            drawSelectionPill(in: rect)
        } else if isHovered {
            (GhosttyApp.shared.terminalForegroundColor ?? .labelColor).withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
    }

    /// rowRadius rounds selection, hover and wash.
    class var rowRadius: CGFloat { 8 }

    /// drawSelectionPill fills the row rect with the selection color and rings it with a hairline.
    func drawSelectionPill(in rect: NSRect) {
        let color = selectionColor, radius = Self.rowRadius
        color.withAlphaComponent(isEmphasized ? 0.20 : 0.12).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        let hairline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
        hairline.lineWidth = 1
        color.withAlphaComponent(isEmphasized ? 0.55 : 0.35).setStroke()
        hairline.stroke()
    }

    /// selectionRect is the pill's frame in the row.
    var selectionRect: NSRect {
        let outline = superview as? SidebarOutlineView
        let minX = outline?.selectionMinX ?? 8, maxInset = outline?.selectionMaxXInset ?? 8
        let inset = GhosttyApp.shared.sidebarDensity.selectionInset
        let pill = bounds.insetBy(dx: 0, dy: inset)
        return NSRect(x: pill.minX + minX, y: pill.minY, width: pill.width - minX - maxInset, height: pill.height)
    }
}

/// A stable reference-type node fed to `NSOutlineView`, which keys item identity and expansion state by object
/// identity (`===`) — nodes must be the SAME instances across reloads, never fresh structs. The coordinator
/// caches one per workspace/session id and rebuilds only the child lists.
final class SidebarNode {
    enum Kind {
        case workspace, session

        var iconElement: InterfaceElement { self == .workspace ? .workspaceIcons : .sessionIcons }
    }

    let kind: Kind
    let id: UUID
    /// Workspace child nodes, repopulated from the store on each rebuild. Empty for session nodes.
    var children: [SidebarNode] = []

    init(kind: Kind, id: UUID) {
        self.kind = kind
        self.id = id
    }
}
