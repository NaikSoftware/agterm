/// The whole workspace tree, the payload of a `tree` response.
public struct ControlTree: Codable, Sendable, Equatable {
    public let workspaces: [ControlWorkspaceNode]
    /// Milliseconds since the last user input in the projected window; nil/omitted before any activity. A
    /// LIVE, continuously-growing delta — `tree`-only, since the tree is built fresh per request on the main
    /// actor while cache-served `window.list` would freeze it between commands. The auto-follow idle metric.
    public let idleMs: Int?
    /// The window's auto-follow-blocked timeout in milliseconds, or nil when the feature is disabled
    /// (omitted from the JSON). The read side of the GUI-only Auto-follow setting.
    public let autoFollowMs: Int?
    /// Whether the projected window's attention navigation also stops on `active` sessions. Always populated
    /// by the app, optional for version skew. The read side of a GUI-only setting with no control setter.
    public let attentionIncludesActive: Bool?
    /// Whether the projected window's GUI attention navigation walks every open window. `session.go`
    /// stays window-scoped either way. Always populated by the app, optional for version skew.
    public let attentionNavigationAcrossWindows: Bool?
    /// Whether the projected window's sidebar is visible. LIVE, built fresh from the window's store per
    /// request — the read side of the write-only `sidebar` command. Always present on a `tree` response (the
    /// producer passes a non-optional `Bool`), unlike `idleMs`/`autoFollowMs`; the `window.list` copy omits
    /// it for a closed window.
    public let sidebarVisible: Bool?
    /// The projected window's sidebar VIEW mode — `SidebarMode.rawValue` (`tree` = the workspace tree,
    /// `flagged` = the flagged working-set view). LIVE and always populated on an app-produced `tree`;
    /// optional at the protocol level (like the other `tree` fields) for version skew. The read side of the
    /// write-only `sidebar.mode`. `tree`-only, as every field below is: a GUI toggle bypasses the command
    /// path, so a cached `window.list` copy would go stale.
    public let sidebarMode: String?
    /// How the flagged view arranges its sessions — `FlaggedViewLayout.rawValue` (`flat` | `plain` | `tree`). APP-WIDE,
    /// so every window's `tree` reports the same value, and reported under the ordinary tree too, where it
    /// is dormant. The read side of `sidebar.flagged-layout` and a term of the workspace-row visibility
    /// predicate on `ControlWorkspaceNode.focused`.
    public let sidebarFlaggedLayout: String?
    /// sidebarDensity is the app-wide row spacing, `SidebarDensity.rawValue` (`default` | `compact`), the same on
    /// every window's `tree`. The read side of `sidebar.density`.
    public let sidebarDensity: String?
    /// flaggedOrder is the window's saved flagged order as session ids, the flat and plain rows' order and the
    /// read side of `session.flag move`; omitted when nothing is flagged.
    public let flaggedOrder: [String]?
    /// Where a clicked web link from terminal output opens: `LinkOpenMode.rawValue` (`browser` | `overlay` |
    /// `overlay95` | `overlay75` | `overlay50`), the effective value, so the default reads `browser`. APP-WIDE, the read side of `browser.links`; nil
    /// in a host-produced tree and from an older server.
    public let linkOpenMode: String?
    /// The projected window's sidebar divider position in points - the read side of `sidebar.width`, and the
    /// only place it is reported. LIVE and `tree`-only, like every field below and like `sidebarMode`: the
    /// tree is the live per-window read surface, and nothing needs width discovery ACROSS windows, which is
    /// the only thing the cached `window.list` copy would add.
    public let sidebarWidth: Double?
    /// The projected window's file panel visibility and width in points - the read side of `filepanel` and
    /// `filepanel.width`, `tree`-only like `sidebarWidth`.
    public let filePanelVisible: Bool?
    public let filePanelWidth: Double?
    /// Whether the projected window's workspace focus FILTER is applied — the flag half of the focus set,
    /// whose member half is each workspace node's `focused`. Only ONE term of the row-visibility predicate;
    /// see `focused`. LIVE and `tree`-only (the bottom-bar toggle and the row menu flip it outside the
    /// command path). The read side of the write-only `workspace.filter`. nil in a host-produced tree that
    /// projects no window.
    public let workspaceFilter: Bool?
    /// Whether the projected window's quick terminal is visible. LIVE, resolved app-side per request from the
    /// window's `QuickTerminalController`, so the `quick` toggle can be made idempotent. The read side of the
    /// write-only `quick` command; `tree`-only (the GUI ⌃` toggle). nil in a host-produced tree with no app
    /// closure.
    public let quickVisible: Bool?
    /// The control id of the surface terminal zoom fills the projected window with —
    /// `surface:<session-id>:<kind>`, or `quick` for the quick terminal — nil/omitted when nothing is zoomed.
    /// LIVE, resolved app-side per request from the window's `TerminalZoomController`: the read side of the
    /// write-only `surface.zoom`; `tree`-only.
    public let zoomedSurface: String?
    /// The open dashboard's cells as pane refs in grid order (`<session-uuid>:left` primary,
    /// `<session-uuid>:right` split), so a split session appears as TWO refs; nil/omitted with no dashboard.
    /// LIVE, resolved app-side per request from the projected window's `DashboardController` — the read side
    /// of the write-only `dashboard` command; `tree`-only. nil in a host-produced tree with no app closure.
    public let dashboardMembers: [String]?
    /// The pane ref (`<session-uuid>:left`/`:right`) of the dashboard's highlighted cell — the one Enter jumps
    /// into, focusing that exact pane; nil/omitted with no dashboard. LIVE from the window's
    /// `DashboardController`, the read side of the keyboard highlight nav.
    public let dashboardHighlighted: String?
    /// The absolute font size in points applied to the dashboard cells; nil/omitted with no dashboard OR an
    /// untouched font (the members keep their own size). LIVE from the window's `DashboardController`, the
    /// read side of `dashboard --font-size`/`--auto-size`.
    public let dashboardFontSize: Double?
    /// The dashboard's font mode — `auto` (`--auto-size`), `fixed` (`--font-size`), `untouched`; nil/omitted
    /// with no dashboard. LIVE from the window's `DashboardController`, the read side of the font flags.
    public let dashboardFontMode: String?
    /// The id of the picker currently awaiting a choice, or nil when no picker is open.
    public let pickPending: String?
    /// The pending GUI ask; terminal asks are exposed on their session nodes.
    public let askPending: String?
    /// The app serving this socket. Constant rather than live like every field above it, and present so an
    /// agent already reading the tree gets its version floor without a second round-trip; `version` answers
    /// the same question for a caller that has no tree, no window, and no JSON parser.
    public let app: AppIdentity?
    /// remote is the server a remote window mirrors and its connection; nil/omitted for a local window.
    public var remote: ControlRemoteWindow?
    /// phone is the app's phone relay as `ControlPhoneStatus.readback`: never the link, which holds the token.
    public var phone: ControlPhoneStatus?
    /// The Live sessions reset state: app-global like `app`, omitted when nothing is pending and no launch
    /// has consumed a marker. The read side of `zmx.reset`.
    public let liveReset: ControlLiveResetReadback?
    /// indexUnsaved is true while the last `windows.json` write failed, omitted otherwise. App-global like
    /// `app`.
    public let indexUnsaved: Bool?
    /// snapshotUnsaved is true after this window's AppStore save fails until its next successful save,
    /// omitted otherwise. Per window, unlike `indexUnsaved`.
    public let snapshotUnsaved: Bool?

    public init(workspaces: [ControlWorkspaceNode], idleMs: Int? = nil, autoFollowMs: Int? = nil,
                attentionIncludesActive: Bool? = nil, attentionNavigationAcrossWindows: Bool? = nil,
                sidebarVisible: Bool? = nil, sidebarMode: String? = nil, sidebarFlaggedLayout: String? = nil,
                flaggedOrder: [String]? = nil, sidebarWidth: Double? = nil,
                filePanelVisible: Bool? = nil, filePanelWidth: Double? = nil, workspaceFilter: Bool? = nil,
                quickVisible: Bool? = nil,
                zoomedSurface: String? = nil, dashboardMembers: [String]? = nil,
                dashboardHighlighted: String? = nil, dashboardFontSize: Double? = nil,
                dashboardFontMode: String? = nil, pickPending: String? = nil, askPending: String? = nil,
                app: AppIdentity? = nil, liveReset: ControlLiveResetReadback? = nil,
                indexUnsaved: Bool? = nil, snapshotUnsaved: Bool? = nil, linkOpenMode: String? = nil,
                sidebarDensity: String? = nil) {
        self.workspaces = workspaces
        self.snapshotUnsaved = snapshotUnsaved
        self.sidebarDensity = sidebarDensity
        self.linkOpenMode = linkOpenMode
        self.liveReset = liveReset
        self.indexUnsaved = indexUnsaved
        self.idleMs = idleMs
        self.autoFollowMs = autoFollowMs
        self.attentionIncludesActive = attentionIncludesActive
        self.attentionNavigationAcrossWindows = attentionNavigationAcrossWindows
        self.sidebarVisible = sidebarVisible
        self.sidebarMode = sidebarMode
        self.sidebarFlaggedLayout = sidebarFlaggedLayout
        self.flaggedOrder = flaggedOrder
        self.sidebarWidth = sidebarWidth
        self.filePanelVisible = filePanelVisible
        self.filePanelWidth = filePanelWidth
        self.workspaceFilter = workspaceFilter
        self.quickVisible = quickVisible
        self.zoomedSurface = zoomedSurface
        self.dashboardMembers = dashboardMembers
        self.dashboardHighlighted = dashboardHighlighted
        self.dashboardFontSize = dashboardFontSize
        self.dashboardFontMode = dashboardFontMode
        self.pickPending = pickPending
        self.askPending = askPending
        self.app = app
    }
}

/// An open window's on-screen frame — the read side of write-only `window.move`/`window.resize`, in the
/// SAME coordinate system those accept so a read-then-restore round-trips: `x`/`y` the top-left relative to
/// `display`'s top-left (y down), `width`/`height` the frame size in points, `display` a screen-list index.
public struct ControlWindowFrame: Codable, Sendable, Equatable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public let display: Int

    public init(x: Int, y: Int, width: Int, height: Int, display: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.display = display
    }
}

/// A window as projected into the `window.list` response. `open` is whether its on-screen window is
/// up; `active` is whether it is the frontmost window.
public struct ControlWindowNode: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let open: Bool
    public let active: Bool
    /// The window's auto-follow-blocked timeout in milliseconds; nil/omitted when disabled. The live
    /// `idleMs` stays tree-only, since the cached `window.list` copy would go stale.
    public let autoFollowMs: Int?
    /// Whether this window's sidebar is visible; nil/omitted for a CLOSED window with no live store. Read
    /// from the open window's store, mirroring `autoFollowMs`. The read side of `sidebar`, per window.
    public let sidebarVisible: Bool?
    /// The window's on-screen frame (position + size + display); nil/omitted for a CLOSED window with no live
    /// NSWindow. The read side of `window.move`/`window.resize`. Read live app-side on the window cache,
    /// refreshed on move/resize/zoom/fullscreen (`ControlServer` observes the NSWindow notifications), so a
    /// hand-drag or GUI toggle shows up without another command.
    public let geometry: ControlWindowFrame?
    /// Whether the window is in native macOS full screen; nil/omitted for a CLOSED window. The read side of
    /// the write-only `window.fullscreen` toggle, so it can be made idempotent. Read live app-side; like
    /// `geometry` it rides the cache.
    public let fullscreen: Bool?
    /// Whether the window is zoomed (maximized-to-screen, NOT full screen), or nil for a CLOSED window
    /// (omitted from the JSON). The read side of the write-only `window.zoom` toggle. Read live app-side.
    public let zoomed: Bool?
    /// Whether the window is minimized to the Dock; nil/omitted for a CLOSED window. The read side of
    /// `window.minimize`. Live app-side on the cache, refreshed on the NSWindow miniaturize/deminiaturize
    /// notifications so ⌘M or a Dock click shows too. A minimized window still reports its `geometry` (where
    /// it comes back to).
    public let minimized: Bool?
    /// remote is the server a remote window mirrors; its `state` is omitted for a closed window, which has no stream.
    public var remote: ControlRemoteWindow?

    public init(id: String, name: String, open: Bool, active: Bool, autoFollowMs: Int? = nil,
                sidebarVisible: Bool? = nil, geometry: ControlWindowFrame? = nil,
                fullscreen: Bool? = nil, zoomed: Bool? = nil, minimized: Bool? = nil) {
        self.id = id
        self.name = name
        self.open = open
        self.active = active
        self.autoFollowMs = autoFollowMs
        self.sidebarVisible = sidebarVisible
        self.geometry = geometry
        self.fullscreen = fullscreen
        self.zoomed = zoomed
        self.minimized = minimized
    }
}
