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
/// `cell.imageView` (stack for a workspace, outlined terminal for a session), so AppKit re-tints it white on
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

    func setCompanionMarker(_ companions: [String]) {
        guard let companionMarker, let companionMarkerWidthConstraint else { return }
        companionMarker.isHidden = companions.isEmpty
        companionMarkerWidthConstraint.constant = companions.isEmpty ? 0 : 14
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

    static let iconWidth: CGFloat = 16
    static let iconGap: CGFloat = 6

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
        addButtonWidthConstraint.constant = visible ? Self.addButtonWidth : 0
        guard let repeatButton, let repeatButtonWidthConstraint else { return }
        if visible, let launcher = repeatLauncher?() {
            repeatButton.image = launcher.image(pointSize: 13)
            repeatButton.toolTip = "New \(launcher.title) Session"
            repeatButton.setAccessibilityLabel(repeatButton.toolTip)
            repeatButton.setAccessibilityValue(launcher.rawValue)
        }
        repeatButton.isHidden = !visible
        // sized to the logo, which can be wider than the "+" slot, so the gap stays visible
        repeatButtonWidthConstraint.constant = visible ? max(Self.addButtonWidth, ceil(repeatButton.image?.size.width ?? 0)) : 0
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

    /// setColors tints row text and icons from the theme for the row's real selection state, except the parts
    /// a row `tint` colors, which keep it selected or not. Never drive it from `backgroundStyle`, which AppKit
    /// flips only while the table is first responder.
    func setColors(selected: Bool) {
        let color = Self.themeTextColor(selected: selected)
        let tintColor = tint.map { NSColor.tint($0.color) }
        textField?.textColor = tint?.shows(.name) == true ? tintColor : color
        let iconAlpha: CGFloat = selected ? 0.85 : 0.6
        imageView?.contentTintColor = tint?.shows(.icon) == true ? tintColor : color.withAlphaComponent(iconAlpha)
        addButton?.contentTintColor = color.withAlphaComponent(iconAlpha)
        repeatButton?.contentTintColor = color.withAlphaComponent(iconAlpha)
        closeButton?.contentTintColor = color.withAlphaComponent(iconAlpha)
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

    private static let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold)
    // leading-edge gap so the capsule keeps air from the status glyph to its left; a count-0 badge collapses
    // fully and lets that glyph sit flush.
    private static let leadingGap: CGFloat = 4
    private var textAttributes: [NSAttributedString.Key: Any] { [.font: Self.font, .foregroundColor: NSColor.white] }
    private var label: String { count > 99 ? "99+" : String(count) }

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
        // systemRed (the conventional unread color) reads on dark rows and on the accent-colored selected row,
        // where an accent capsule would blend in.
        NSColor.systemRed.setFill()
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
    /// Symbol point size of the glyph; the Settings shape picker previews options at the same size, so an
    /// option looks like the glyph it installs.
    static let glyphPointSize: CGFloat = 13

    /// The view's width, collapsed to 0 on `.idle` so a status-less row reclaims the slot (its label truncates
    /// full-width); `glyphWidth` when a glyph shows. Activated in init, toggled in `apply`.
    private lazy var widthConstraint = widthAnchor.constraint(equalToConstant: 0)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        imageScaling = .scaleProportionallyUpOrDown
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
        toolTip = indicator.status.tooltipText
        showsGlyph = indicator.status != .idle
        guard showsGlyph else {
            image = nil
            setAccessibilityValue(AgentStatus.idle.rawValue)
            pulse(Self.blinkKey, false, to: 0.2, duration: 0.5)
            pulse(Self.fadeKey, false, to: 0.25, duration: 1.4)
            return
        }
        image = Self.icon(for: indicator.status, override: indicator.color, shape: indicator.shape)
        setAccessibilityValue(indicator.status.rawValue)
        let motion = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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

/// Row view drawing its own selection pill in `drawBackground`, so the selection is the terminal's
/// `selection-background` color in every state. The table's `selectionHighlightStyle` is `.none` (`makeNSView`),
/// or AppKit paints a gray unemphasized fill whenever the sidebar isn't first responder (the normal case, since
/// focus lives in the terminal), overriding a custom `drawSelection`. `isEmphasized` is overridden so the row
/// redraws on a window key-state change (dimmer for a background window).
///
/// It is also the single source of truth for the cell's selection tint: `isSelected` (the state the pill draws
/// from) re-tints the hosted `SidebarCellView` whenever AppKit updates it, and `didAddSubview` tints a cell the
/// moment it attaches. Otherwise pill and text color desync — and on the many themes where
/// `foreground == selection-background` (the inverted-selection idiom), a stale tint renders the text invisible.
class SidebarRowView: NSTableRowView {
    private static let keyAlpha: CGFloat = 0.13
    private static let inactiveAlpha: CGFloat = 0.07

    override var isEmphasized: Bool {
        get { window?.isKeyWindow ?? false }
        // isEmphasized is derived from the window's key state; the setter only triggers a redraw.
        // swiftlint:disable:next unused_setter_value
        set { needsDisplay = true }
    }

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            // AppKit won't redraw with selectionHighlightStyle == .none; re-tint the cell from the pill's state.
            needsDisplay = true
            retintCellViews()
            applyDisclosureAppearance()
        }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        // a cell materialized into an already-selected row (reload/expand row-map flux can make the cell
        // builder's own selection lookup miss) picks up the row's live state on attach.
        (subview as? SidebarCellView)?.setColors(selected: isSelected)
        if subview.identifier == NSOutlineView.disclosureButtonIdentifier { applyDisclosureAppearance() }
    }

    private func retintCellViews() {
        for case let cell as SidebarCellView in subviews { cell.setColors(selected: isSelected) }
    }

    /// applyDisclosureAppearance gives a selected row's triangle the appearance that matches the selected row
    /// text, since AppKit colors it from appearance alone and the outline's pin reads the sidebar background,
    /// not the pill. An unselected triangle inherits that pin.
    func applyDisclosureAppearance() {
        let appearance = isSelected ? Self.selectedTriangleAppearance() : nil
        for subview in subviews where subview.identifier == NSOutlineView.disclosureButtonIdentifier {
            subview.appearance = appearance
        }
    }

    private static func selectedTriangleAppearance() -> NSAppearance? {
        guard let text = SidebarCellView.themeTextColor(selected: true).usingColorSpace(.sRGB) else { return nil }
        let textIsDark = ThemeBrightness.isDark(red: Double(text.redComponent), green: Double(text.greenComponent),
                                                blue: Double(text.blueComponent))
        return NSAppearance(named: textIsDark ? .aqua : .darkAqua)
    }

    /// band is the workspace group's tint behind this row; the edge rounds and insets only the group's outer ends.
    var band: (color: NSColor, edge: SidebarBandEdge)? {
        didSet {
            guard band?.color != oldValue?.color || band?.edge != oldValue?.edge else { return }
            needsDisplay = true
            needsLayout = true
        }
    }

    /// rowWash is a tinted session's own wash, drawn over the band.
    var rowWash: NSColor? {
        didSet { if rowWash != oldValue { needsDisplay = true } }
    }

    /// waveLayer clips the drifting gradient to the band rect; nil while the row shows no wave.
    private(set) var waveLayer: CALayer?
    private var wave: SidebarWave?
    private var waveStill = false
    private var wavePeriod: CGFloat = 0
    static let waveKey = "sidebar-wave"

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
        layoutWave()
    }

    private func layoutWave() {
        guard let clip = waveLayer, let gradient = clip.sublayers?.first else { return }
        let period = bounds.width * 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = bandRect(band?.edge ?? .middle)
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

    /// bandRect is the band's frame for an edge: inset 3pt from the row sides, and 2pt at the group's outer ends
    /// so adjacent groups never touch.
    func bandRect(_ edge: SidebarBandEdge) -> NSRect {
        let outerTop = edge == .first || edge == .single
        let outerBottom = edge == .last || edge == .single
        var rect = bounds.insetBy(dx: 3, dy: 0)
        let topInset: CGFloat = outerTop ? 2 : 0, bottomInset: CGFloat = outerBottom ? 2 : 0
        rect.origin.y += isFlipped ? topInset : bottomInset
        rect.size.height -= topInset + bottomInset
        return rect
    }

    /// fillBand rounds only the group's outer corners: the rounded rect overhangs the inner sides and is clipped.
    private func fillBand(_ color: NSColor, edge: SidebarBandEdge) {
        let rect = bandRect(edge)
        let radius: CGFloat = 9
        var shape = rect
        if edge == .middle || edge == .last { shape.size.height += radius; if isFlipped { shape.origin.y -= radius } }
        if edge == .middle || edge == .first { shape.size.height += radius; if !isFlipped { shape.origin.y -= radius } }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        color.setFill()
        NSBezierPath(roundedRect: shape, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if let band { fillBand(band.color, edge: band.edge) }
        if let rowWash { fillBand(rowWash, edge: band?.edge ?? .middle) }
        guard isSelected else { return }
        if let selection = GhosttyApp.shared.terminalSelectionBackgroundColor {
            selection.withAlphaComponent(isEmphasized ? 1 : 0.55).setFill()
        } else {
            (GhosttyApp.shared.terminalForegroundColor ?? .white)
                .withAlphaComponent(isEmphasized ? Self.keyAlpha : Self.inactiveAlpha).setFill()
        }
        NSBezierPath(roundedRect: selectionRect, xRadius: 7, yRadius: 7).fill()
    }

    /// selectionRect is the pill's frame in the row.
    var selectionRect: NSRect {
        let minX = (superview as? SidebarOutlineView)?.selectionMinX ?? 8
        let inset = GhosttyApp.shared.sidebarDensity.selectionInset
        let pill = bounds.insetBy(dx: 0, dy: inset)
        return NSRect(x: pill.minX + minX, y: pill.minY, width: pill.width - minX - 8, height: pill.height)
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
