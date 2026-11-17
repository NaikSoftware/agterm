import agtermCore
import AppKit
import SwiftUI

/// The custom title-bar row and its label/buttons, split out of `WindowContentView` for the file size limit.
/// Owns the title text (workspace / session / window name, gated by the Interface toggles), the row layout, and the
/// per-session chrome buttons; recent-sessions / attention / dashboard buttons live in their own extensions.
extension WindowContentView {
    /// The window title at the terminal's leading edge, shared with the zoom titlebar. A child view, so its
    /// session-name reads register on its own body and an OSC title tick never invalidates this one (#516).
    var titleLabel: TitlebarLabel {
        TitlebarLabel(store: store, library: library, windowID: windowID, toolbarMode: toolbarMode,
                      chromeText: chromeText, showsWorkspaceName: shows(.workspaceName),
                      showsSessionName: shows(.sessionName), showsWindowName: shows(.windowName),
                      showsContext: shows(.sessionContext), showsRemoteHost: shows(.remoteHost))
    }

    /// Feeds the OS window title to `WindowAccessor` from its own body, for the same reason as `titleLabel`.
    var windowTitleSync: WindowTitleSync {
        WindowTitleSync(store: store, library: library, windowID: windowID, captureOnExit: captureOnExit)
    }

    /// The window chrome above the terminal: the full custom titlebar row, or in hidden mode an invisible ~3px
    /// top drag strip alone (no row; `WindowAppearance.sync` also drops the traffic lights), so the terminal
    /// runs full-bleed while staying movable + double-click-zoomable. Non-private, rendered above the overlays.
    @ViewBuilder var customTitlebar: some View {
        if toolbarMode == .hidden {
            // only the top ~3px loses click-through (the accepted cost), kept thin so it stays clear of the
            // terminal's first row (window-padding-y = 6) whose clicks it would swallow; `WindowControlArea`
            // still supplies the standard title-bar gestures.
            Color.clear
                .frame(height: 3)
                .frame(maxWidth: .infinity)
                // Color.clear is hit-testable in SwiftUI and would swallow the mouseDown before the
                // WindowControlArea behind it, so opt out and let drag/double-click-zoom reach the AppKit view.
                .allowsHitTesting(false)
                .background { WindowControlArea() }
        } else {
            titlebarRow
        }
    }

    /// Custom titlebar row replacing the system toolbar: the sidebar and file panel toggles pinned to the
    /// leading columns' trailing edge (by the divider), the title at the terminal's start (or the switcher pill
    /// centred over the terminal column), and the trailing cluster (attention popover, divider, scratch / split
    /// controls, divider, dashboard / quick terminal / custom commands). Positions track `leadingColumnsWidth`;
    /// the left inset clears the system traffic lights.
    private var titlebarRow: some View {
        Group {
            if shows(.recentSessions) {
                // the pill takes its own clicks; the rest of the row still falls through to the drag/zoom layer.
                HStack(spacing: 0) {
                    titlebarLeading
                    Spacer(minLength: 12)
                    titlebarTrailingActions
                }
                .overlay {
                    // centred over the terminal column; each spacer's floor keeps it off the buttons on its side, so a
                    // tight bar first shifts the pill, then truncates it. An overlay, not a custom `Layout`: a
                    // `Layout`-placed pill drew in place but never received its click.
                    HStack(spacing: 0) {
                        Spacer(minLength: max(12, titlebarLeadingWidth - leadingColumnsWidth + 12))
                        switcherPill
                        Spacer(minLength: titlebarTrailingWidth + 12)
                    }
                    .padding(.leading, leadingColumnsWidth)
                }
            } else {
                HStack(spacing: 0) {
                    titlebarLeading
                    // 1px divider + gap to the title
                    Color.clear.frame(width: leadingColumnsWidth > 0 ? 11 : 12).allowsHitTesting(false)
                    titleLabel
                        // the title text falls through to the drag/zoom layer behind it, so double-click zooms and
                        // drag moves the window; the rest of the row is non-hittable spacers plus the buttons.
                        .allowsHitTesting(false)
                    Spacer(minLength: 12)
                    titlebarTrailingActions
                }
            }
        }
        .buttonStyle(.plain)
        // tint the title text and the toolbar buttons with the terminal theme's foreground so the
        // chrome tracks the theme (the cwd subtitle dims itself to 0.6 over this).
        .foregroundStyle(chromeText)
        // the row isn't drawn in hidden mode; imageScale hits the SF Symbols, not the title text.
        .imageScale(toolbarMode == .normal ? .large : .medium)
        .frame(height: titlebarHeight)
        .frame(maxWidth: .infinity)
        // make the header behave like a standard title bar: single-click drag moves the window, double-click
        // runs the user's configured title-bar action (zoom/minimize/none) — a custom titlebar gets no native
        // double-click handling. the layer sits BEHIND the row, so the buttons keep their clicks while the
        // spacers + title text opt out of hit-testing (above) and fall through to it.
        .background { WindowControlArea() }
    }

    /// The traffic-light inset and the file panel / sidebar toggles, pinned to the leading columns' edge.
    private var titlebarLeading: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 78).allowsHitTesting(false) // system traffic lights
            if leadingColumnsWidth > 0 {
                HStack(spacing: 2) {
                    Spacer(minLength: 0)
                    // keep the columns-width frame even when the toggle is hidden, so the title still starts
                    // at the terminal's leading edge; the Spacer fills the freed space.
                    filePanelToggleButton
                    if shows(.sidebarToggle) {
                        sidebarToggleButton
                    }
                }
                .padding(.trailing, 12)
                // two 30pt buttons, their gap and the trailing padding
                .frame(width: max(74, leadingColumnsWidth - 1 - 78))
            } else {
                HStack(spacing: 2) {
                    filePanelToggleButton
                    if shows(.sidebarToggle) {
                        sidebarToggleButton
                    }
                }
            }
        }
    }

    /// `titlebarLeading`'s width, from the fixed 30pt `ChromeButtonStyle` geometry. Computed rather than measured so
    /// the pill's clearance holds on the very first layout pass.
    private var titlebarLeadingWidth: CGFloat {
        let toggles: CGFloat = shows(.sidebarToggle) ? 2 : 1
        return 78 + (leadingColumnsWidth > 0 ? max(74, leadingColumnsWidth - 1 - 78) : toggles * 30 + (toggles - 1) * 2)
    }

    /// `titlebarTrailingActions`' width, computed for the same reason: 30pt buttons 3 apart, each divider 1pt plus its
    /// 6pt margins, and the 12pt trailing padding.
    private var titlebarTrailingWidth: CGFloat {
        let groups = titlebarGroupCounts
        let buttons = CGFloat(groups.a + groups.b + groups.c)
        let dividers = InterfaceElement.titlebarGroupDividers(countA: groups.a, countB: groups.b, countC: groups.c)
        let dividerCount = CGFloat((dividers.afterA ? 1 : 0) + (dividers.afterB ? 1 : 0))
        let items = buttons + dividerCount
        return buttons * 30 + dividerCount * 13 + max(0, items - 1) * 3 + 12
    }

    private var titlebarGroupCounts: (a: Int, b: Int, c: Int) {
        let flags = [attentionButtonEnabled, shows(.scratch), shows(.split), shows(.overlayToggle),
                     shows(.dashboard), shows(.quickTerminal), shows(.customCommands)].map { $0 ? 1 : 0 }
        return (flags[0], flags[1] + flags[2] + flags[3], flags[4] + flags[5] + flags[6])
    }

    /// The title bar's trailing action cluster, each button gated by its Interface toggle: the attention
    /// popover, per-session scratch / split controls, window-overlay dashboard / quick terminal
    /// and the custom-commands popover. A separator sits ONLY where two groups that each still show 2+
    /// buttons meet, so a group reduced to one button flows in unbracketed and an empty group lets its
    /// neighbors meet directly.
    private var titlebarTrailingActions: some View {
        let showAttention = attentionButtonEnabled // the bell keeps its own separate Notifications setting
        let showScratch = shows(.scratch)
        let showSplit = shows(.split)
        let showOverlayToggle = shows(.overlayToggle)
        let showDashboard = shows(.dashboard)
        let showQuick = shows(.quickTerminal)
        let showCustom = shows(.customCommands)
        let groups = titlebarGroupCounts
        // a separator only between two 2+-button groups (the host-free rule, unit-tested in agtermCore).
        let dividers = InterfaceElement.titlebarGroupDividers(countA: groups.a, countB: groups.b, countC: groups.c)
        return HStack(spacing: 3) {
            if showAttention { attentionButton }
            if dividers.afterA { titlebarDivider }
            if showScratch { scratchButton }
            if showSplit { splitButton }
            if showOverlayToggle { overlayToggleButton }
            if dividers.afterB { titlebarDivider }
            if showDashboard { dashboardButton.buttonStyle(ChromeButtonStyle(foreground: chromeText, isOn: dashboard.isOpen)) }
            if showQuick { quickTerminalButton }
            if showCustom { customCommandsButton.buttonStyle(ChromeButtonStyle(foreground: chromeText, isOn: customCommandsShown)) }
        }
        .padding(.trailing, 12)
    }

    /// Whether title-bar tooltips may show: an ask's click catcher covers the whole window, title bar included.
    var titlebarTipsShown: Bool { pick.pendingAsk == nil }

    /// The 1px themed separator between two title-bar button groups.
    private var titlebarDivider: some View {
        Rectangle().fill(chromeText.opacity(0.10)).frame(width: 1, height: 18).padding(.horizontal, 6)
    }

    /// Our own sidebar show/hide toggle (the custom split has no system one). Animated collapse.
    private var sidebarToggleButton: some View {
        Button {
            actions.toggleSidebar()
        } label: {
            Label("Toggle Sidebar", systemImage: InterfaceElement.sidebarToggle.symbolName!)
        }
        .buttonStyle(ChromeButtonStyle(foreground: chromeText, isOn: store.sidebarVisible))
        .toolTip(helpHint("Toggle Sidebar", .toggleSidebar), isShown: titlebarTipsShown)
        .accessibilityIdentifier("sidebar-toggle-button")
    }

    private var filePanelToggleButton: some View {
        Button {
            actions.toggleFilePanel()
        } label: {
            Label("Toggle File Panel", systemImage: "folder")
        }
        .buttonStyle(ChromeButtonStyle(foreground: chromeText, isOn: store.filePanelVisible))
        .toolTip(helpHint("Toggle File Panel", .toggleFilePanel), isShown: titlebarTipsShown)
        .accessibilityIdentifier("file-panel-toggle-button")
    }

    private var splitButton: some View {
        let isSplit = store.activeSession?.isSplit ?? false
        let hasSplit = store.activeSession?.hasSplit ?? false
        let splitFocused = store.activeSession?.splitFocused ?? false
        let axis = store.activeSession?.splitAxis ?? .leftRight
        let shortcutAction: BuiltinAction = axis == .topBottom ? .toggleHorizontalSplit : .toggleSplit
        // filled = pane visible, outline = hidden: no split is an empty two-pane outline, a shown split fills
        // both, and a collapsed one fills the visible leading or trailing half on the current axis.
        // `splitFocused` identifies that visible pane. `a11y` mirrors all seven states for XCUITest, which
        // cannot read the symbol name: none, both, both-horizontal, left, right, top, and bottom.
        let symbol: String
        let a11y: String
        if !hasSplit {
            symbol = InterfaceElement.split.symbolName!; a11y = "none"
        } else if isSplit {
            symbol = axis == .topBottom ? "rectangle.split.1x2.fill" : "rectangle.split.2x1.fill"
            a11y = axis == .topBottom ? "both-horizontal" : "both"
        } else if splitFocused {
            symbol = axis == .topBottom ? "rectangle.bottomhalf.filled" : "rectangle.righthalf.filled"
            a11y = axis == .topBottom ? "bottom" : "right"
        } else {
            symbol = axis == .topBottom ? "rectangle.tophalf.filled" : "rectangle.lefthalf.filled"
            a11y = axis == .topBottom ? "top" : "left"
        }
        return Button {
            actions.toggleCurrentSplit()
        } label: {
            Label("Split", systemImage: symbol)
        }
        .buttonStyle(ChromeButtonStyle(foreground: chromeText, isOn: isSplit))
        .toolTip(helpHint(isSplit ? "Hide split" : (hasSplit ? "Show split" : "Split right"), shortcutAction),
                 isShown: titlebarTipsShown)
        .disabled(store.activeSession == nil)
        .accessibilityValue(a11y)
        .accessibilityIdentifier("split-toggle")
    }

    /// Toggles the active session's scratch terminal — a third, full-overlay login shell kept alive when
    /// hidden. 2-state glyph (filled while shown): no "hidden but exists" state, since its `exit` clears it.
    private var scratchButton: some View {
        let active = store.activeSession?.scratchActive ?? false
        return Button {
            actions.toggleScratch()
        } label: {
            Label("Scratch", systemImage: active ? "rectangle.inset.filled" : InterfaceElement.scratch.symbolName!)
        }
        .buttonStyle(ChromeButtonStyle(foreground: chromeText, isOn: active))
        .toolTip(helpHint(active ? "Hide scratch terminal" : "Show scratch terminal", .toggleScratch),
                 isShown: titlebarTipsShown)
        .disabled(store.activeSession == nil)
        .accessibilityIdentifier("scratch-toggle")
    }

    /// Hides the active session's overlays or shows them again. Always present once enabled in Settings,
    /// disabled with nothing to hide, and slashed while anything is hidden, so a hidden overlay is never out
    /// of sight entirely.
    private var overlayToggleButton: some View {
        let session = store.activeSession
        let slots = session?.hideableOverlaySlots(nil) ?? []
        let anyShown = session?.anyOverlayShown(nil) ?? false
        let anyHidden = !(session?.hiddenOverlayNames.isEmpty ?? true)
        return Button {
            actions.toggleOverlays()
        } label: {
            Label("Overlays", systemImage: anyHidden ? "rectangle.on.rectangle.slash" : InterfaceElement.overlayToggle.symbolName!)
        }
        .buttonStyle(ChromeButtonStyle(foreground: chromeText, isOn: anyHidden))
        .toolTip(helpHint(anyShown ? "Hide Overlays" : "Show Overlays", .toggleOverlay), isShown: titlebarTipsShown)
        // this window's own covers, the set `PaletteContext.modalActive` holds for the frontmost window
        .disabled(slots.isEmpty || pick.modalPending || terminalZoom.target != nil || dashboard.isOpen)
        .accessibilityLabel(anyShown ? "Hide Overlays" : "Show Overlays")
        .accessibilityValue(anyHidden ? "hidden" : (slots.isEmpty ? "none" : "shown"))
        .accessibilityIdentifier("overlay-toggle")
    }

    /// Toggles the quick terminal: one scratch terminal overlaid at 90% of the window, above the sidebar and
    /// terminal. Clicking it again or the surrounding margin hides it; the shell stays alive until quit.
    private var quickTerminalButton: some View {
        Button {
            actions.toggleQuickTerminal()
        } label: {
            Label("Quick Terminal", systemImage: InterfaceElement.quickTerminal.symbolName!)
        }
        .buttonStyle(ChromeButtonStyle(foreground: chromeText))
        .toolTip(helpHint("Quick Terminal", .quickTerminal), isShown: titlebarTipsShown)
        .disabled(pick.modalPending)
        .accessibilityIdentifier("quick-terminal-toggle")
    }
}

/// The OS window title: the active session's display name, suffixed as "session — window" for a custom
/// (user-set) window name; auto "window N" names are omitted, and "Agterm" when nothing is selected. Always
/// the real name, regardless of the Interface toggles that gate only the on-screen `TitlebarLabel`, so
/// Mission Control and the Window menu stay labelled.
struct WindowTitleSync: View {
    let store: AppStore
    let library: WindowLibrary
    let windowID: WindowInfo.ID
    let captureOnExit: AppDelegate.ExitCapture?

    var body: some View {
        WindowAccessor(titleToken: title, windowID: windowID, library: library, store: store,
                       captureOnExit: captureOnExit)
    }

    private var title: String {
        let session = store.activeSession?.displayName ?? "Agterm"
        guard let name = library.customWindowName(for: windowID) else { return session }
        return "\(session) — \(name)"
    }
}

/// Both title-bar lines: the workspace / session / window name, and in normal mode the session's `context` when one is
/// set and shown, else the focused pane's `subtitleDetail`. The Interface toggles are resolved into `Parts`
/// here, so `TitlebarComposition` never sees the settings.
struct TitlebarLabel: View {
    let store: AppStore
    let library: WindowLibrary
    let windowID: WindowInfo.ID
    let toolbarMode: ToolbarMode
    let chromeText: Color
    let showsWorkspaceName: Bool
    let showsSessionName: Bool
    let showsWindowName: Bool
    let showsContext: Bool
    let showsRemoteHost: Bool
    var body: some View {
        let composition = composition
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 0) {
                if !composition.title.isEmpty {
                    Text(composition.title).fontWeight(.semibold)
                        .layoutPriority(1)
                }
                if let host = composition.host {
                    HStack(spacing: 4) {
                        Image(systemName: InterfaceElement.remoteHost.symbolName!)
                            .fixedSize()
                            .accessibilityHidden(true)
                        RemoteHostTextLayout {
                            Text(verbatim: host)
                                .truncationMode(.middle)
                        }
                    }
                    .foregroundStyle(chromeText.opacity(0.6))
                    .padding(.leading, composition.title.isEmpty ? 0 : 6)
                    .layoutPriority(1)
                }
                if !composition.tail.isEmpty {
                    Text(composition.tail).fontWeight(.semibold)
                }
            }
            if !composition.subtitle.isEmpty {
                Text(composition.subtitle)
                    .font(.caption)
                    .foregroundStyle(chromeText.opacity(0.6))
            }
        }
        // a caller-set context can run to 256 bytes, far past the row; tail truncation drops its end rather
        // than letting the label push the trailing button cluster off the bar. the host truncates in the
        // MIDDLE under its own ceiling instead, so an ssh target retains both of its ends.
        .lineLimit(1)
        .truncationMode(.tail)
        // fixed-width slot, so the label's width stays put while an animated title ticks (#516)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composition: TitlebarComposition {
        // the workspace is looked up from the ACTIVE SESSION, not `currentWorkspaceID`: selecting an
        // empty workspace makes it current while the previous session stays selected, and the title
        // names the session's home.
        let workspace = showsWorkspaceName ? store.activeSession.flatMap { store.workspace(forSession: $0.id) } : nil
        return TitlebarComposition.compose(
            TitlebarComposition.Parts(
                workspaceName: workspace?.name,
                sessionName: showsSessionName ? (store.activeSession?.displayName ?? "Agterm") : nil,
                windowName: showsWindowName ? library.customWindowName(for: windowID) : nil,
                context: showsContext ? store.activeSession?.effectiveContext : nil,
                detail: store.activeSession?.subtitleDetail ?? "",
                remoteHost: showsRemoteHost ? store.activeSession?.remoteHost : nil
            ),
            mode: toolbarMode
        )
    }
}

/// Caps the host without expanding short names or preventing compression beside the sidebar.
struct RemoteHostTextLayout: Layout {
    static let ceiling: CGFloat = 240

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(proposal.width ?? Self.ceiling, Self.ceiling)
        return subviews[0].sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
