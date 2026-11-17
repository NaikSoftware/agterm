import agtermCore
import AppKit
import SwiftUI

/// Title-bar "jump to a session" buttons, split out of `WindowContentView` to keep that file under the
/// 1000-line limit (the `+Dashboard`/`+Zoom` extension pattern): the session switcher pill — the mouse
/// equivalent of the Ctrl-Tab switcher — and the attention bell. Both open a session picker over the
/// frontmost window and are referenced from `WindowContentView.titlebarRow`.
extension WindowContentView {
    /// The frontmost window's most-recently-used sessions, EXCLUDING the current one (not a jump target —
    /// you're already there), scoped to the visible/filtered set and capped like the Ctrl-Tab switcher. The
    /// live refresh rides the OBSERVED `activeSession`/`navigableSessions` reads — every `sessionRecency`
    /// mutation co-occurs with one (a push on select changes `activeSession`, a prune on close changes
    /// `navigableSessions`); `sessionRecency` itself is `@ObservationIgnored` and registers no observation.
    private var recentSessions: [UUID] {
        store.navigableRecentSessions(limit: SessionSwitcher.maxCandidates)
    }

    /// Recent minus the sessions Needs you already lists, still capped like the Ctrl-Tab switcher.
    private func recentWithoutAttention(_ attention: [AttentionEntry]) -> [UUID] {
        let listed = Set(attention.map(\.session.id))
        return Array(store.navigableRecentSessions(limit: SessionSwitcher.maxCandidates + listed.count)
            .filter { !listed.contains($0) }
            .prefix(SessionSwitcher.maxCandidates))
    }

    /// The newest closed sessions the switcher offers to reopen, below the open ones.
    private var recentClosedSessions: [RecentClosedItem] {
        Array(library.recentClosedItems.lazy.filter { $0.kind == .session }.prefix(15))
    }

    /// The title-bar session switcher: a one-line pill naming the active session that opens the switcher overlay
    /// under it. The label stays non-hittable on top and the button sits behind it, so a disabled button never
    /// dims the title. Opening the switcher is interactive-only, so it is control-API keep-in-sync exempt.
    var switcherPill: some View {
        HStack(spacing: 9) {
            SwitcherPillLabel(store: store, library: library, windowID: windowID, chromeText: chromeText,
                              showsSessionName: shows(.sessionName),
                              showsWindowName: shows(.windowName), showsContext: shows(.sessionContext),
                              showsRemoteHost: shows(.remoteHost))
            if let hint = actions.shortcutGlyph(for: .sessionPalette) {
                Text(verbatim: hint)
                    .font(.system(size: 11))
                    .foregroundStyle(chromeText.opacity(pick.modalPending ? 0.2 : 0.36))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: 472)
        .frame(height: toolbarMode == .normal ? 34 : 26)
        .allowsHitTesting(false)
        .background { recentSessionsButton }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { switcherPillFrame = $0 }
        .onDisappear { switcherPillFrame = nil }
    }

    /// The theme background moved 7% toward white on a dark theme, toward black on a light one.
    var popoverBackground: Color {
        let base = GhosttyApp.shared.terminalBackgroundColor ?? NSColor(srgbRed: 0.157, green: 0.173, blue: 0.204, alpha: 1)
        let toward: NSColor = GhosttyApp.shared.terminalThemeIsDark ? .white : .black
        return Color(nsColor: base.blended(withFraction: 0.07, of: toward) ?? base)
    }

    private var recentSessionsButton: some View {
        Button {
            actions.toggleSessionPalette()
        } label: {
            SwitcherPillChrome(chromeText: chromeText, openFill: popoverBackground,
                               open: isFrontmost && palette.mode == .switcher)
        }
        .buttonStyle(.plain)
        .toolTip(helpHint("Session switcher", .sessionPalette), isShown: titlebarTipsShown)
        .disabled(pick.modalPending)
        // a disabled pill hands its clicks to the drag/zoom layer, like the rest of the title.
        .allowsHitTesting(!pick.modalPending)
        .accessibilityLabel("Session switcher")
        .accessibilityIdentifier("recent-sessions-button")
    }

    /// Answers `PaletteController.requestSwitcher` (the pill, ⌃P, Navigate ▸ Go to Session, `keymap.run
    /// session_palette`) in the frontmost window. Every opener shows the one `.switcher` overlay: a system popover
    /// opened from a key equivalent hands the keyboard back to the terminal within half a second (AppKit, no agterm
    /// caller), and it cannot draw the design's radius, outline and shadow without an arrow.
    func toggleSwitcher() {
        guard isFrontmost, !pick.modalPending else { return }
        palette.toggle(.switcher)
    }

    /// The session switcher: hung 6pt under the title pill and centred on it, or, with no pill, centred over the
    /// terminal area near the top of the window. A click on the scrim, Esc or a commit closes it; the palette
    /// bracket restores focus and auto-follow.
    var switcherOverlay: some View {
        GeometryReader { geo in
            let width = GhosttyApp.shared.interfaceMetrics.scaled(472)
            let origin = geo.frame(in: .global).origin
            let anchor = switcherPillFrame.map { CGPoint(x: $0.midX - origin.x, y: $0.maxY + 6 - origin.y) }
            let x = anchor.map { min(max($0.x - width / 2, 8), geo.size.width - width - 8) }
                ?? (geo.size.width - width) / 2 + terminalAreaInset / 2
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.2)
                    .contentShape(Rectangle())
                    .onTapGesture { palette.close() }
                    .accessibilityElement()
                    .accessibilityIdentifier("switcher-scrim")
                switcherPanel
                    .background(popoverBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder((GhosttyApp.shared.terminalThemeIsDark ? Color.white : Color.black).opacity(0.10)))
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 18)
                    .offset(x: x, y: anchor.map { max($0.y, 0) } ?? geo.size.height * 0.12)
            }
        }
    }

    private func closeSwitcher() {
        if palette.mode == .switcher { palette.close() }
    }

    /// The switcher body both hosts share: a search field that holds the keyboard from the moment it opens, over
    /// "Needs you" (the bell's rows), "Recent" (MRU other sessions) and "Recently closed", empty sections hidden.
    /// A query swaps the sections for one "Sessions" list.
    private var switcherPanel: some View {
        let highlight = Color(nsColor: GhosttyApp.shared.activeStatusColor).opacity(0.2)
        let attention = library.attentionAcrossWindows
        // no `.accessibilityIdentifier` on this container: a SwiftUI identifier on a parent propagates to and
        // OVERRIDES its descendants', clobbering the per-row ids the tests read.
        return SwitcherPopover(
            foreground: chromeText, highlight: highlight,
            metrics: GhosttyApp.shared.interfaceMetrics,
            sections: [
                SwitcherSection(title: "Needs you",
                                hits: attention.map { .attention(window: $0.window.id, session: $0.session.id) }),
                SwitcherSection(title: "Recent", hits: recentWithoutAttention(attention).map { .session($0) }),
                SwitcherSection(title: "Recently closed", hits: recentClosedSessions.map { .closed($0.id) })
            ],
            candidates: switcherCandidates,
            onCommit: { hit in
                switch hit {
                case .session(let id): selectRecent(id)
                case .closed(let id): reopenRecentClosed(id)
                case let .attention(window, session):
                    if let entry = attention.first(where: { $0.window.id == window && $0.session.id == session }) {
                        selectAttention(entry)
                    }
                }
            },
            onClose: { closeSwitcher() },
            row: { hit, highlighted in switcherRow(hit, highlight: highlight, highlighted: highlighted) }
        )
    }

    /// What a query searches: every navigable session of this window in sidebar order, then the recently closed
    /// ones, keyed by name, then "workspace · detail".
    private var switcherCandidates: [SwitcherCandidate] {
        let open = store.listOrdered(store.navigableSessions).map { session in
            SwitcherCandidate(hit: .session(session.id), title: store.listLabel(for: session),
                              subtitle: "\(store.workspace(forSession: session.id)?.name ?? "") · \(session.subtitleDetail)")
        }
        let closed = recentClosedSessions.map { SwitcherCandidate(hit: .closed($0.id), title: $0.title, subtitle: $0.subtitle) }
        return open + closed
    }

    /// The window (once several are open) and workspace an attention row lives in, for the right-hand column.
    private func attentionWorkspace(_ entry: AttentionEntry) -> String {
        let workspace = library.store(for: entry.window.id)?.workspace(forSession: entry.session.id)?.name ?? ""
        return library.openIDs().count > 1 ? "\(entry.window.name) · \(workspace)" : workspace
    }

    /// The switcher closes first and the reopen runs on the next turn, since it may raise another window.
    private func reopenRecentClosed(_ id: RecentClosedItem.ID) {
        guard !pick.modalPending else { return }
        closeSwitcher()
        DispatchQueue.main.async { actions.openRecentClosed(id) }
    }

    /// One switcher row: an open session selects, a closed one reopens. `highlighted` is the keyboard highlight.
    @ViewBuilder private func switcherRow(_ hit: SwitcherHit, highlight: Color, highlighted: Bool) -> some View {
        let iconSize = GhosttyApp.shared.interfaceMetrics.scaled(14)
        switch hit {
        case let .attention(window, sessionID):
            if let entry = library.attentionAcrossWindows.first(where: { $0.window.id == window && $0.session.id == sessionID }) {
                SessionPopoverRow(
                    title: library.attentionLabel(entry),
                    subtitle: entry.session.switcherDetail,
                    remote: entry.session.remoteHost != nil,
                    status: entry.session.agentIndicator.status,
                    statusColorHex: entry.session.agentIndicator.color,
                    statusShape: entry.session.agentIndicator.shape,
                    foreground: chromeText,
                    hoverColor: highlight,
                    accessibilityID: "attention-session-row",
                    icon: (entry.session.runningAgent ?? .terminal).image(pointSize: iconSize),
                    isEnabled: actions.canSelectAttention(windowID: window, sessionID: sessionID),
                    singleLine: true,
                    workspace: attentionWorkspace(entry),
                    highlighted: highlighted
                ) { selectAttention(entry) }
            }
        case .session(let id):
            if let session = store.session(withID: id) {
                SessionPopoverRow(
                    title: store.listLabel(for: session),
                    subtitle: session.switcherDetail,
                    remote: session.remoteHost != nil,
                    status: session.agentIndicator.status,
                    statusColorHex: session.agentIndicator.color,
                    statusShape: session.agentIndicator.shape,
                    foreground: chromeText,
                    hoverColor: highlight,
                    accessibilityID: "recent-session-row",
                    icon: (session.runningAgent ?? .terminal).image(pointSize: iconSize),
                    singleLine: true,
                    workspace: store.workspace(forSession: id)?.name,
                    highlighted: highlighted
                ) { selectRecent(id) }
            }
        case .closed(let id):
            if let item = recentClosedSessions.first(where: { $0.id == id }) {
                SessionPopoverRow(
                    title: item.title,
                    subtitle: item.subtitle ?? "",
                    remote: false,
                    status: nil,
                    statusColorHex: nil,
                    statusShape: nil,
                    foreground: chromeText,
                    hoverColor: highlight,
                    accessibilityID: "recent-closed-row",
                    // a resume line reopens into claude even when claude had exited before the close
                    icon: (item.session?.agent.flatMap(SessionLauncher.init(rawValue:))
                           ?? (item.session?.resumeLine == nil ? .terminal : .claude))
                        .image(pointSize: iconSize),
                    singleLine: true,
                    highlighted: highlighted
                ) { reopenRecentClosed(id) }
            }
        }
    }

    /// The hover-highlight color for a title-bar popover row: the terminal theme's selection background (the
    /// color the selected sidebar row uses), or a subtle wash of the foreground when the theme sets no
    /// selection color. Shared with the custom-commands popover.
    var popoverHoverColor: Color {
        if let sel = GhosttyApp.shared.terminalSelectionBackgroundColor {
            return Color(nsColor: sel).opacity(0.5)
        }
        return chromeText.opacity(0.2)
    }

    /// Commit a switcher row: note activity (so auto-follow can't pull the selection back), select the
    /// session, focus it, and close the switcher — the twin of the Ctrl-Tab release commit.
    private func selectRecent(_ id: UUID) {
        guard !pick.modalPending else { return }
        store.noteUserActivity()
        let indicator = store.selectSession(id)
        closeSwitcher()
        actions.focusActiveSession()
        // reveal the picked session's blocked pane once the closing host's focus restore has run
        DispatchQueue.main.async { actions.revealActiveBlockedPane(captured: indicator) }
    }

    /// Title-bar bell reflecting the attention state across every open window (opt-in, gated by the
    /// `attentionButtonEnabled` mirror): dimmed and disabled when empty, plain when nothing is blocked, filled
    /// in the blocked-status color otherwise. No count, no pulse. Click opens the attention popover (the
    /// mouse form; ⌃⇧I / the Navigate menu keep the searchable `.attention` palette). Reading the library
    /// list in the body registers the per-session `agentIndicator` observation and the open-set version, so
    /// the glyph re-renders live; `.accessibilityValue` (none|attention|blocked) exposes the
    /// otherwise-unobservable bell↔bell.fill state to XCUITest, mirroring `StatusIconView`.
    var attentionButton: some View {
        let entries = library.attentionAcrossWindows
        let blocked = entries.contains { $0.session.agentIndicator.status == .blocked }
        let empty = entries.isEmpty
        let enabled = !empty && !pick.modalPending
        return Button {
            guard !pick.modalPending else { return }
            attentionPopoverShown.toggle()
        } label: {
            Label("Attention", systemImage: blocked ? "bell.fill" : "bell")
        }
        .buttonStyle(ChromeButtonStyle(foreground: blocked ? Color(nsColor: GhosttyApp.shared.blockedStatusColor) : chromeText,
                                       isOn: attentionPopoverShown))
        .overlay(alignment: .topTrailing) {
            if !empty {
                Text(verbatim: "\(entries.count)")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 14, minHeight: 14)
                    .background(Capsule().fill(Color(red: 1, green: 0x45 / 255, blue: 0x3a / 255)))
                    // a 2pt ring in the title band's own color cuts the badge out of the glyph
                    .background(Capsule().fill(terminalColor).padding(-2))
                    .offset(x: 2, y: -2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
        .toolTip(helpHint(empty ? "No sessions need attention" : "Show sessions that need attention", .showAttention),
                 isShown: titlebarTipsShown)
        .accessibilityIdentifier("attention-button")
        .accessibilityValue(empty ? "none" : (blocked ? "blocked" : "attention"))
        .popover(isPresented: $attentionPopoverShown, arrowEdge: .bottom) {
            attentionPopover
        }
        .onChange(of: attentionPopoverShown) { _, shown in
            // suppress auto-follow while open (counted, so it stays balanced).
            if shown { store.suppressAutoFollow() } else { store.resumeAutoFollow() }
        }
        .onChange(of: empty) { _, isEmpty in
            // the last attention session going idle fires no outside-click dismiss; close the popover so no
            // empty sliver lingers under the now-disabled bell.
            if isEmpty { attentionPopoverShown = false }
        }
    }

    /// The attention popover body: every open window's sessions needing attention as full-row
    /// `SessionPopoverRow`s with a trailing status glyph — the mouse form of the ⌃⇧I attention palette. A row
    /// whose window sits under a cover renders disabled, as the palette's does, rather than dismissing into
    /// a no-op. The rows are measured so short lists stay compact and long lists scroll at
    /// `attentionRowsCap`, for the reason `measuredPanelHeight` gives.
    private var attentionPopover: some View {
        let metrics = GhosttyApp.shared.interfaceMetrics
        return ScrollView {
            VStack(spacing: 2) {
                attentionRows(library.attentionAcrossWindows)
            }
            .background(
                GeometryReader { rows in
                    Color.clear.preference(key: RowsHeightKey.self, value: rows.size.height)
                }
            )
        }
        .frame(height: metrics.measuredPanelHeight(rowsHeight: attentionRowsHeight,
                                                   maxRowsHeight: metrics.scaled(Self.attentionRowsCap)).map { CGFloat($0) })
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(RowsHeightKey.self) { height in
            attentionRowsHeight = height
        }
        .padding(6)
        .frame(width: metrics.scaled(320))
        .background(popoverBackground)
        .presentationBackground(popoverBackground)
    }

    /// The bell popover's rows.
    private func attentionRows(_ entries: [AttentionEntry]) -> some View {
        ForEach(entries) { entry in
            SessionPopoverRow(
                title: library.attentionLabel(entry),
                subtitle: library.attentionSubtitle(entry),
                remote: entry.session.remoteHost != nil,
                status: entry.session.agentIndicator.status,
                statusColorHex: entry.session.agentIndicator.color,
                statusShape: entry.session.agentIndicator.shape,
                foreground: chromeText,
                hoverColor: popoverHoverColor,
                accessibilityID: "attention-session-row",
                isEnabled: actions.canSelectAttention(windowID: entry.window.id, sessionID: entry.session.id)
            ) { selectAttention(entry) }
        }
    }

    /// The attention popover's row-stack cap at the default interface size, about ten rows.
    static let attentionRowsCap: Double = 440

    /// Commit an attention popover row click. The popover closes first and the select runs on the next turn,
    /// so a raise of another window never competes with this popover's dismissal; the action rechecks the
    /// target then.
    private func selectAttention(_ entry: AttentionEntry) {
        let windowID = entry.window.id
        let sessionID = entry.session.id
        guard !pick.modalPending, actions.canSelectAttention(windowID: windowID, sessionID: sessionID) else { return }
        attentionPopoverShown = false
        closeSwitcher()
        DispatchQueue.main.async { actions.selectAttention(windowID: windowID, sessionID: sessionID) }
    }
}

/// One clickable session row for the title-bar popovers (recent-sessions and attention) — the shared two-line
/// `SessionSwitcherRow` tinted with the terminal theme (`foreground`), with an optional trailing status glyph
/// (`status` plus its per-call `statusColorHex`/`statusShape` overrides, matching the sidebar glyph), a
/// pointer-hover highlight (`hoverColor`) and a full-row hit area (`.contentShape`), so the WHOLE row selects on click, not just the text. Kept a `Button` so it reads as an
/// actionable control to VoiceOver; `accessibilityID` distinguishes the two popovers' rows for the tests.
/// `isEnabled` false renders the row dimmed and inert, for an attention row whose window is under a cover.
/// `singleLine` draws the switcher popover's 30pt row: name, reason, then `workspace` right-aligned.
private struct SessionPopoverRow: View {
    let title: String
    let subtitle: String
    let remote: Bool
    let status: AgentStatus?
    let statusColorHex: String?
    let statusShape: StatusShape?
    let foreground: Color
    let hoverColor: Color
    let accessibilityID: String
    var icon: NSImage?
    var isEnabled = true
    var singleLine = false
    var workspace: String?
    var highlighted = false
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            row
                .background((hovering || highlighted) && isEnabled ? hoverColor : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: singleLine ? 7 : 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .accessibilityIdentifier(accessibilityID)
    }

    @ViewBuilder private var row: some View {
        if singleLine {
            let metrics = GhosttyApp.shared.interfaceMetrics
            HStack(spacing: metrics.scaled(10)) {
                Group {
                    if let icon {
                        Image(nsImage: icon).renderingMode(.template).foregroundStyle(foreground.opacity(0.58))
                    }
                }
                .frame(width: metrics.scaled(18))
                if remote { Image(systemName: "cloud").accessibilityLabel("Remote") }
                Text(title)
                    .font(.system(size: metrics.base))
                    .layoutPriority(2)
                Text(subtitle)
                    .font(.system(size: metrics.scaled(12)))
                    .foregroundStyle(foreground.opacity(0.58))
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let workspace, !workspace.isEmpty {
                    Text(workspace)
                        .font(.system(size: metrics.scaled(12)))
                        .foregroundStyle(foreground.opacity(0.36))
                        .layoutPriority(1)
                }
                if let status, status != .idle {
                    StatusGlyph(status: status, colorHex: statusColorHex, shape: statusShape)
                }
            }
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, metrics.scaled(10))
            .frame(maxWidth: .infinity, minHeight: metrics.scaled(30), maxHeight: metrics.scaled(30), alignment: .leading)
        } else {
            SessionSwitcherRow(title: title, subtitle: subtitle, foreground: foreground,
                               status: status, statusColorHex: statusColorHex, statusShape: statusShape, remote: remote,
                               icon: icon)
        }
    }
}

/// A switcher row's target: an open session, a recently closed one to reopen, or a session needing attention in
/// any window.
enum SwitcherHit: Hashable {
    case session(UUID)
    case closed(RecentClosedItem.ID)
    case attention(window: UUID, session: UUID)
}

/// One searchable switcher row with the ⌃P session palette's search keys.
struct SwitcherCandidate {
    let hit: SwitcherHit
    let title: String
    let subtitle: String?
}

/// A titled run of switcher rows; an empty one is not drawn.
struct SwitcherSection {
    let title: String
    let hits: [SwitcherHit]
}

/// The switcher popover's body: a search field that takes the keyboard as the popover opens, over `sections` while
/// the query is empty and one ranked "Sessions" list otherwise. One keyboard rule covers both: ↑/↓ move the
/// highlight across every visible row (the first by default), Return commits it the way a click does, Esc closes.
/// Owns its query, highlight and measured height so typing re-renders only the popover.
private struct SwitcherPopover<Row: View>: View {
    let foreground: Color
    let highlight: Color
    let metrics: InterfaceMetrics
    let sections: [SwitcherSection]
    let candidates: [SwitcherCandidate]
    let onCommit: (SwitcherHit) -> Void
    let onClose: () -> Void
    let row: (SwitcherHit, Bool) -> Row
    @State private var query = ""
    @State private var highlighted = 0
    @State private var rowsHeight: Double = 0
    @FocusState private var fieldFocused: Bool

    /// The sections for an empty query, else one "Sessions" list ranked with the palette's own matcher and keys.
    private var visible: [SwitcherSection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sections.filter { !$0.hits.isEmpty } }
        let hits = fuzzyRank(query: trimmed, items: candidates) {
            paletteSearchKeys(title: $0.title, subtitle: $0.subtitle, callerSupplied: false)
        }.map(\.hit)
        return hits.isEmpty ? [] : [SwitcherSection(title: "Sessions", hits: hits)]
    }

    var body: some View {
        let visible = visible
        let hits = visible.flatMap(\.hits)
        VStack(spacing: 0) {
            field(hits: hits)
                .padding(.bottom, metrics.scaled(4))
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(visible.enumerated()), id: \.element.title) { index, section in
                            let offset = visible[..<index].reduce(0) { $0 + $1.hits.count }
                            header(section.title)
                            ForEach(Array(section.hits.enumerated()), id: \.element) { rowIndex, hit in
                                row(hit, offset + rowIndex == highlighted).id(hit)
                            }
                        }
                    }
                    .background(GeometryReader { rows in
                        Color.clear.preference(key: RowsHeightKey.self, value: rows.size.height)
                    })
                }
                .frame(height: metrics.measuredPanelHeight(rowsHeight: rowsHeight,
                                                           maxRowsHeight: metrics.scaled(WindowContentView.attentionRowsCap))
                    .map { CGFloat($0) })
                .scrollBounceBehavior(.basedOnSize)
                .onPreferenceChange(RowsHeightKey.self) { rowsHeight = $0 }
                .onChange(of: highlighted) { _, index in
                    if hits.indices.contains(index) { proxy.scrollTo(hits[index]) }
                }
            }
        }
        .padding(6)
        .frame(width: metrics.scaled(472))
        .onAppear {
            fieldFocused = true
            // the pill's click still holds first responder as the popover mounts; re-assert once it settles
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: metrics.scaled(11.5), weight: .semibold))
            .foregroundStyle(foreground.opacity(0.58))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, metrics.scaled(10))
            .padding(.top, metrics.scaled(8))
            .padding(.bottom, metrics.scaled(4))
    }

    private func field(hits: [SwitcherHit]) -> some View {
        HStack(spacing: metrics.scaled(10)) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: metrics.scaled(15)))
                .foregroundStyle(foreground.opacity(0.36))
                .frame(width: metrics.scaled(18))
            TextField("", text: $query, prompt: Text("Jump to a session").foregroundStyle(foreground.opacity(0.36)))
                .textFieldStyle(.plain)
                .font(.system(size: metrics.base))
                .foregroundStyle(foreground)
                .focused($fieldFocused)
                .onChange(of: query) { highlighted = 0 }
                .onSubmit { if hits.indices.contains(highlighted) { onCommit(hits[highlighted]) } }
                .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(hits.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                .onKeyPress(.escape) { onClose(); return .handled }
                .accessibilityIdentifier("switcher-search-field")
        }
        .padding(.horizontal, metrics.scaled(10))
        .frame(maxWidth: .infinity, minHeight: metrics.scaled(36), maxHeight: metrics.scaled(36))
        .overlay(alignment: .bottom) {
            Rectangle().fill(foreground.opacity(0.10)).frame(height: 1)
        }
    }
}

/// The switcher pill's rounded fill and inset hairline: stronger on hover, and while its popover is open the
/// popover's own background with a ring in the active status color.
private struct SwitcherPillChrome: View {
    let chromeText: Color
    let openFill: Color
    let open: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9)
        shape
            .fill(open ? openFill : chromeText.opacity(hovering && isEnabled ? 0.12 : 0.07))
            .overlay(shape.strokeBorder(chromeText.opacity(0.10), lineWidth: 1))
            .overlay {
                if open {
                    shape.stroke(Color(nsColor: GhosttyApp.shared.activeStatusColor).opacity(0.5), lineWidth: 2)
                        .padding(-1)
                }
            }
            .contentShape(shape)
            .onHover { hovering = $0 }
    }
}

/// The pill's one line: session icon, workspace, session (semibold), window and host, then the context, which
/// truncates first. Its own view so an OSC title tick never invalidates `WindowContentView` (#516). The workspace
/// breadcrumb is always shown; `InterfaceElement.workspaceName` governs only the plain title.
struct SwitcherPillLabel: View {
    let store: AppStore
    let library: WindowLibrary
    let windowID: WindowInfo.ID
    let chromeText: Color
    let showsSessionName: Bool
    let showsWindowName: Bool
    let showsContext: Bool
    let showsRemoteHost: Bool

    var body: some View {
        let session = store.activeSession
        let workspace = session.flatMap { store.workspace(forSession: $0.id) }?.name.trimmingCharacters(in: .whitespaces)
        let host = showsRemoteHost ? session?.remoteHost : nil
        // a remote window is named after its host, which the host part already shows
        let windowName = showsWindowName ? library.customWindowName(for: windowID).flatMap { $0 == host ? nil : $0 } : nil
        let context = showsContext ? session?.effectiveContext : nil
        let name = showsSessionName ? session?.displayName ?? "Agterm" : nil
        HStack(spacing: 9) {
            if let icon = (session?.runningAgent ?? .terminal).image(pointSize: 14) {
                Image(nsImage: icon).renderingMode(.template).foregroundStyle(chromeText.opacity(0.7))
            }
            // a narrow bar drops the identity's side parts whole, rather than squeezing each to an ellipsis
            ViewThatFits(in: .horizontal) {
                identity(workspace: workspace, name: name, windowName: windowName, host: host)
                identity(workspace: workspace, name: name, windowName: nil, host: host.map { _ in "" })
                identity(workspace: nil, name: name, windowName: nil, host: host.map { _ in "" })
            }
            .layoutPriority(1)
            if let context, !context.isEmpty {
                Text(context).font(.system(size: 12)).foregroundStyle(chromeText.opacity(0.58))
            }
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .truncationMode(.tail)
    }

    /// An empty `host` draws the cloud alone.
    private func identity(workspace: String?, name: String?, windowName: String?, host: String?) -> some View {
        HStack(spacing: 9) {
            if let workspace, !workspace.isEmpty {
                Text("\(workspace) ›").foregroundStyle(chromeText.opacity(0.58))
            }
            if let name {
                Text(name).font(.system(size: 13, weight: .semibold)).layoutPriority(1)
            }
            if let windowName {
                Text("— \(windowName)").foregroundStyle(chromeText.opacity(0.58))
            }
            if let host {
                HStack(spacing: 4) {
                    Image(systemName: InterfaceElement.remoteHost.symbolName!).fixedSize().accessibilityHidden(true)
                    if !host.isEmpty {
                        RemoteHostTextLayout { Text(verbatim: host).truncationMode(.middle) }
                    }
                }
                .foregroundStyle(chromeText.opacity(0.58))
            }
        }
    }
}
