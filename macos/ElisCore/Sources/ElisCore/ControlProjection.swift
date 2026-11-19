// The read-back PROJECTIONS: the immutable snapshots `tree` and `window.list` return, distinct from the
// request envelope in `ControlProtocol.swift` and the response envelope in `ControlResponse.swift`.
// Split out for the file size limit.

/// A terminal surface as projected into the `tree` response. `id` is the stable control address for
/// `surface.zoom`; `kind` the user-facing name (`left`, `right`, `scratch`, `overlay`). `active`/`visible`
/// derive from the session's own flags (overlay/scratch/splitFocused), NOT from terminal zoom, and `visible`
/// reads false for a pane behind a FLOATING overlay though it is visually on screen (any open overlay counts
/// as covering). Address by `id`/`kind`, not these flags; the zoom state is the top-level `zoomedSurface`.
public struct ControlSurfaceNode: Codable, Sendable, Equatable {
    public let id: String
    public let kind: String
    public let active: Bool
    public let visible: Bool
    /// Actual zmx backing for primary/split surfaces; nil for ephemeral surfaces or older servers.
    public let backedByZmx: Bool?
    /// Whether this pane's client leads its zmx daemon: `leader`, `follower` or `unowned`. A pane that
    /// does not lead is covered and its reads come from the daemon. Nil until the pane's zmx reports a
    /// role, which a zmx or an origin without explicit leadership never does.
    public let lead: ZmxLeadRole?
    /// reconnect is present while this pane's ssh lost its connection and the app waits to attach it
    /// again, omitted otherwise.
    public let reconnect: ControlReconnect?
    /// paneID is the token `--pane-id` resolves, omitted for a slot whose surface carries none.
    public let paneID: String?
    /// pendingMessages counts the pane's unacked bus messages, omitted at zero.
    public let pendingMessages: Int?
    /// phoneViewers counts the paired phone's open views of this pane, omitted at zero. elis-server's own tree
    /// always omits it (approved 2026-11-18): the relay runs only on a Mac, whose tree counts server rows too.
    public let phoneViewers: Int?
    /// phoneLead is true while the paired phone leads this pane, omitted otherwise; elis-server omits it as `phoneViewers`.
    public let phoneLead: Bool?
    /// remote is true when this pane's next ask, overlay or page goes to an attached Mac, omitted otherwise.
    public let remote: Bool?

    public init(id: String, kind: String, active: Bool, visible: Bool) {
        self.init(id: id, kind: kind, active: active, visible: visible, backedByZmx: nil)
    }

    public init(id: String, kind: String, active: Bool, visible: Bool, backedByZmx: Bool?,
                lead: ZmxLeadRole? = nil, reconnect: ControlReconnect? = nil, paneID: String? = nil,
                pendingMessages: Int? = nil, remote: Bool? = nil, phoneViewers: Int? = nil,
                phoneLead: Bool? = nil) {
        self.id = id
        self.kind = kind
        self.active = active
        self.visible = visible
        self.backedByZmx = backedByZmx
        self.lead = lead
        self.reconnect = reconnect
        self.paneID = paneID
        self.pendingMessages = pendingMessages
        self.remote = remote
        self.phoneViewers = phoneViewers
        self.phoneLead = phoneLead
    }
}

/// ControlReconnect is a remote pane's wait to be attached again. `failures` is the backoff streak: probes
/// of its host that failed in a row, plus one for a link that dropped again soon after attaching.
/// A key on the pane, a wake or a network change starts it over. `reason` is what ssh said on the last failed probe, omitted when it said nothing.
public struct ControlReconnect: Codable, Sendable, Equatable {
    public let failures: Int
    public let reason: String?

    public init(failures: Int, reason: String?) {
        self.failures = failures
        self.reason = reason
    }
}

/// The HUD panel occupying a session's overlay slot, as projected into the `tree` response. Present only
/// while a HUD is up, and the session node's `overlay` reads FALSE beside it, so a script polling "is a
/// program covering this session" can never mistake a message for a running program. The read side of
/// `session.hud.open`/`.update`; an open or close emits `tree.changed`, an update emits nothing.
public struct ControlHudNode: Codable, Sendable, Equatable {
    public let message: String
    /// The dim second line; nil/omitted when the caller set none.
    public let detail: String?
    /// The EFFECTIVE spinner style, a `HudSpinner` raw value or `HudSpinner.noneName`. Always present, the
    /// static case included, so a caller reads one field rather than inferring absence.
    public let spinner: String
    /// The panel's own `#rrggbb` background; nil/omitted when it keeps the session's terminal background. The
    /// color the open set, which survives every `session.hud.update` — the surface reads it once at creation,
    /// so this always names what the panel paints.
    public let backgroundColor: String?
    /// The panel's `#rrggbb` TEXT color; nil/omitted when it keeps the terminal foreground. Unlike
    /// `backgroundColor` this tracks the LATEST `session.hud.update`, the header the helper re-reads being
    /// what paints it.
    public let textColor: String?
    /// The EFFECTIVE share of the pane's WIDTH the panel occupies — the app's measurement, or the caller's
    /// `sizePercent` override, either way bounded by `HudLayout.clampSizePercent`, so a requested 100 reads
    /// back as the maximum that panel may take: 100 for a sticky one off center, 80 otherwise. Reported here because the node's `overlaySizePercent` stays
    /// omitted for a HUD. Optional because it projects the slot's optional percent, but no supported path
    /// leaves a live HUD sizeless: `openHud` always sets one and `overlay.resize --full` is refused.
    public let sizePercent: Int?
    /// The EFFECTIVE share of the pane's HEIGHT, always measured from the message (`HudLayout.heightPercent`)
    /// because no command sets it. Reported beside `sizePercent` so a caller polling the panel's geometry
    /// reads both axes rather than assuming one square.
    public let heightPercent: Int?
    /// The EFFECTIVE placement, a CANONICAL `HudPosition` raw value — one of the nine anchors, never one of
    /// the accepted `top`/`bottom` aliases, so a caller reads one spelling whichever he sent. Always present,
    /// including the `center` default, so a caller who omitted it never has to know what the default is.
    public let position: String
    /// The pane currently carrying the stable HUD target, nil/omitted for session-wide placement.
    public let pane: String?
    /// The panel's auto-hide in seconds, 0 for one that stays until something closes it. The CONFIGURED
    /// duration rather than the time left: each successful open or update restarts it, so a caller who wants
    /// a countdown holds its own clock from the call it made.
    public let hideAfter: Double
    /// markdown reports whether the message renders as markdown. Always present; an absent key decodes as
    /// false.
    public let markdown: Bool
    /// fontSize is the caller's requested point size, nil/omitted when the panel inherits the session's.
    public let fontSize: Double?
    /// sticky reports a panel flush against its edge or corner. Always present; an absent key decodes as
    /// false.
    public let sticky: Bool
    /// frame reports whether the panel draws its border, rounding and blank rows. Always present; an absent
    /// key decodes as true.
    public let frame: Bool

    public init(message: String, detail: String? = nil, spinner: String = HudSpinner.noneName,
                backgroundColor: String? = nil, textColor: String? = nil,
                sizePercent: Int? = nil, heightPercent: Int? = nil, position: String,
                pane: String? = nil, hideAfter: Double = 0, markdown: Bool = false, fontSize: Double? = nil,
                sticky: Bool = false, frame: Bool = true) {
        self.hideAfter = hideAfter
        self.markdown = markdown
        self.fontSize = fontSize
        self.sticky = sticky
        self.frame = frame
        self.message = message
        self.detail = detail
        self.spinner = spinner
        self.backgroundColor = backgroundColor
        self.textColor = textColor
        self.sizePercent = sizePercent
        self.heightPercent = heightPercent
        self.position = position
        self.pane = pane
    }

    enum CodingKeys: String, CodingKey {
        case message, detail, spinner, backgroundColor, textColor, sizePercent, heightPercent, position, pane
        case hideAfter, markdown, fontSize, sticky, frame
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        message = try c.decode(String.self, forKey: .message)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        spinner = try c.decode(String.self, forKey: .spinner)
        backgroundColor = try c.decodeIfPresent(String.self, forKey: .backgroundColor)
        textColor = try c.decodeIfPresent(String.self, forKey: .textColor)
        sizePercent = try c.decodeIfPresent(Int.self, forKey: .sizePercent)
        heightPercent = try c.decodeIfPresent(Int.self, forKey: .heightPercent)
        position = try c.decode(String.self, forKey: .position)
        pane = try c.decodeIfPresent(String.self, forKey: .pane)
        hideAfter = try c.decode(Double.self, forKey: .hideAfter)
        markdown = try c.decodeIfPresent(Bool.self, forKey: .markdown) ?? false
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize)
        sticky = try c.decodeIfPresent(Bool.self, forKey: .sticky) ?? false
        frame = try c.decodeIfPresent(Bool.self, forKey: .frame) ?? true
    }
}

/// The session's pending terminal ask and its current pane placement.
public struct ControlSessionAsk: Codable, Sendable, Equatable {
    /// Exact request id for result and cancellation lookup.
    public let id: String
    /// Current left/right placement, nil for the whole session.
    public let pane: String?
    /// True while a viewer presenting the session draws the ask; omitted when this Mac does.
    public let remote: Bool?
    /// True on a viewer for a replica of an ask its origin owns; the id is the origin's.
    public let replica: Bool?

    public init(id: String, pane: String? = nil, remote: Bool? = nil, replica: Bool? = nil) {
        self.id = id
        self.pane = pane
        self.remote = remote
        self.replica = replica
    }
}

/// The session-bound pick in flight for a session; a window's own pick is the tree's top-level `pickPending`.
public struct ControlSessionPick: Codable, Sendable, Equatable {
    public let id: String
    /// True while a viewer presenting the session draws the pick; omitted when this Mac does.
    public let remote: Bool?
    /// True on a viewer for a replica of a pick its origin owns; the id is the origin's.
    public let replica: Bool?

    public init(id: String, remote: Bool? = nil, replica: Bool? = nil) {
        self.id = id
        self.remote = remote
        self.replica = replica
    }
}

/// A session as projected into the `tree` response.
public struct ControlSessionNode: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let cwd: String
    /// The split pane's last reported or fallback directory, including hidden splits; omitted without one.
    public let splitCwd: String?
    /// The scratch shell's last reported or start directory, hidden scratch included; omitted without one.
    public let scratchCwd: String?
    /// The raw terminal title from the latest OSC 0/1/2 (a remote host over SSH, a shell `PROMPT_COMMAND`);
    /// nil/omitted when none reported. The unprocessed `Session.oscTitle`, distinct from `name` (the derived
    /// sidebar label, which uses it as one fallback); a remote session's local `cwd` goes stale, this does not.
    public let title: String?
    /// Whether this is the window's selected session. Selection within the window, not keyboard focus: it
    /// stays `true` while another window is frontmost.
    public let active: Bool
    /// Whether the split is SHOWN side by side, the read side of `session.split on|off`. A split hidden with
    /// ⌘D reports `false` while its pane stays alive, so a caller asking "is there a second pane" must read
    /// `hasSplit`, not this.
    public let split: Bool
    /// Whether the session HAS a split pane at all, shown or hidden; nil/omitted when it has none. Present
    /// exactly when `splitRatio`/`splitFocused` can be, which is what makes those two readable without
    /// second-guessing `split`. The sidebar icon, the dashboard's second cell and Focus Left/Right Pane all
    /// follow this, not `split`.
    public let hasSplit: Bool?
    /// True only when every existing primary/split pane is currently zmx-backed; nil on older servers.
    public let backedByZmx: Bool?
    /// Process attribution for each local Live pane; this does not describe permission grants.
    public let liveAttribution: String?
    public let splitLiveAttribution: String?
    /// liveHostStale is true when the pane's session host is from an earlier helper build or login session;
    /// omitted otherwise.
    public let liveHostStale: Bool?
    public let splitLiveHostStale: Bool?
    /// Divider direction for a live split (`vertical`=left/right, `horizontal`=top/bottom); nil without one.
    public let splitAxis: String?
    /// The primary-pane fraction (0.05...0.95) of the pane area below the titlebar band, for a session that
    /// HAS a split; nil with no split, or while the split has never been SHOWN, since the divider is seeded
    /// on its first layout. A shown split therefore always reports a value, 0.5 when nothing set one. The
    /// read side of `session.resize`, otherwise echoed only on that call.
    public let splitRatio: Double?
    /// For a session that HAS a split (shown or hidden), which pane holds keyboard focus: `true` = split
    /// (right), `false` = main (left); nil/omitted with no split. The read side of `session.focus`.
    public let splitFocused: Bool?
    /// Whether a caller's PROGRAM occupies the session-wide overlay slot. False while a HUD holds it — the
    /// HUD is a message, not a running program, and it reports itself in `hud` instead.
    public let overlay: Bool
    /// An OPEN overlay's size (`overlay == true`): nil/omitted = FULL-pane, else the floating panel's percent
    /// of the pane (1...100); absent with no overlay AND while a HUD holds the slot, whose size is `hud`'s.
    /// The read side of `session.overlay.resize`.
    public let overlaySizePercent: Int?
    /// overlayWidth and overlayHeight are a floating program or page's content size in points, after
    /// `--width`/`--height` and the cap, from the session's last layout; the page strip is not included. Omitted for a full overlay, a HUD, and a
    /// session not laid out yet. The read side of `session.overlay.open`/`.resize` `--width`/`--height`.
    public let overlayWidth: Double?
    public let overlayHeight: Double?
    /// The panes covered by their OWN overlay, ordered left then right (`["left"]`, `["right"]`,
    /// `["left","right"]`); nil/omitted when neither has one. Independent of `overlay`, the session-wide
    /// one — both kinds can be up at once. The read side of `session.overlay.open --pane`; those overlays
    /// are always full-pane, so there is no per-pane size to report.
    public let paneOverlays: [String]?
    /// The HUD panel occupying the session-wide overlay slot; nil/omitted when none is up. Mutually exclusive
    /// with `overlay` — one slot, and whichever holds it is the one that reports.
    public let hud: ControlHudNode?
    /// Pending terminal ask; GUI asks are exposed at the tree's top level.
    public let ask: ControlSessionAsk?
    public let pick: ControlSessionPick?
    public let scratch: Bool
    public let flagged: Bool
    /// True for a headless origin's session left with no live pane; omitted otherwise.
    public let ended: Bool?
    /// pending is a remote window row's operation state: `pending` while one is on its way to the server, `unknown`
    /// when one's outcome could not be learned; omitted otherwise.
    public let pending: String?
    /// scratchBacked is true while a remote window row's scratch is the server's daemon; omitted otherwise.
    public let scratchBacked: Bool?
    /// scratchPaneID and scratchPendingMessages are a server scratch's mail address and unacked count, which its absent
    /// zoom surface cannot carry; omitted for a local scratch and the count at none.
    public let scratchPaneID: String?
    public let scratchPendingMessages: Int?
    /// interactions are the asks, picks, pages and jobs the session holds for a presenter, omitted when there are none.
    public let interactions: [ControlInteraction]?
    /// What the session is FOR: `Session.effectiveContext`, so the local `session.context` value or, on an
    /// attached row without one, the origin's mirrored context. Nil/omitted when neither is set.
    public let context: String?
    /// For a `--command` session, whether it HOLDS its surface after the command exits (`session.new
    /// --command … --wait`) instead of closing; nil/omitted for a plain or non-holding session. The read
    /// side of `session.new --wait`; it persists across restart, unlike an overlay's live-only wait.
    public let commandWait: Bool?
    /// The split pane's hold-after-exit policy; nil/omitted without a holding split creation command.
    public let splitCommandWait: Bool?
    /// The LIVE foreground process command (full argv) in the main pane; nil/omitted when the foreground IS a
    /// recognized shell (`foregroundShell` names it) and whenever the process cannot be read — no foreground
    /// pid, a setuid leader like `top`/`sudo`, an unresolved zmx pane, a failed syscall. Shares the restore
    /// capture's extraction but not its rules: this read descends the process group, the capture does not.
    public let foreground: [String]?
    /// The coding agent running anywhere in the session's foreground process group (`claude`, `codex`,
    /// `opencode`, `antigravity`), the sidebar icon's source; nil/omitted for none. Unlike `foreground` it sees
    /// an agent a script started, and it updates on the app's 2 s sample, not per read.
    public let agent: String?
    /// Claude Code's conversation id for the session, also mirrored from an origin; nil/omitted when unknown.
    public let agentSessionId: String?
    /// The split (right) pane's live foreground command (full argv), the split analogue of `foreground`.
    public let splitForeground: [String]?
    /// The main pane's foreground process when it IS a recognized shell, as its basename (`zsh`, `fish`);
    /// nil/omitted whenever `foreground` is present. For a pane that exists, neither field means elis could
    /// not determine the foreground state at all — the two a bare nil `foreground` used to conflate.
    ///
    /// NOT proof of an interactive prompt, so it is never permission to type: a builtin such as `read` or
    /// `vared`, and a shell loop, run inside the shell process, leaving a pane blocked on input
    /// indistinguishable from one at a prompt. Recognized means elis knows the argv as a shell, by a
    /// built-in set widened with the user's `$SHELL`; a shell outside both reports in `foreground` like any
    /// other program.
    public let foregroundShell: String?
    /// The split (right) pane's foreground shell basename, the split analogue of `foregroundShell`. Read
    /// `hasSplit` before interpreting the split pair: with no split pane both are absent because there is no
    /// pane, not because anything could not be read.
    public let splitForegroundShell: String?
    /// The main pane's PERSISTED restore-command override, the read side of `session.restore`. Tri-state:
    /// omitted = no override (auto-capture), `""` = pinned to nothing (a plain shell), a command = that shell
    /// line runs on the next launch. Read from persisted state, so it still reports the pin after the
    /// override fired. Unrelated to `foreground`, the LIVE process.
    public let restoreCommand: String?
    /// The split (right) pane's persisted restore-command override, the split analogue of `restoreCommand`
    /// (the read side of `session.restore --pane right`).
    public let splitRestoreCommand: String?
    /// The session's agent status (`active`/`completed`/`blocked`) as the `AgentStatus` raw value;
    /// nil/omitted when idle. The read side of `session.status`.
    public let status: String?
    /// Which pane set the agent status (`"left"|"right"|"scratch"`, `left`=main, `right`=split); nil/omitted
    /// when idle or unspecified. The read side of `session.status --pane`.
    public let statusPane: String?
    /// Whether the agent-status glyph blinks (pulses for attention); nil/omitted when idle or not blinking.
    /// The read side of `session.status --blink`.
    public let statusBlink: Bool?
    /// The per-call `#rrggbb` glyph-tint override; nil/omitted when idle or using the Settings status color.
    /// The read side of `session.status --color`.
    public let statusColor: String?
    /// The per-call glyph-silhouette override (a `StatusShape` raw value); nil/omitted when idle or drawing
    /// the Settings shape / the status's default shape. The read side of `session.status --shape` — the
    /// PER-CALL override only, exactly like `statusColor`.
    public let statusShape: String?
    /// When the status was last set, idle and repeated values included, as epoch seconds on the
    /// `ControlEvent.ts` clock. Omitted before any set; never persisted.
    public let statusChangedAt: Double?
    /// activePanes lists the panes still reporting `active` (`"left"|"right"|"scratch"`), empty when none, whatever the row shows:
    /// a pane's turn end leaves the row on another pane's work, and this says which panes are working. Omitted
    /// only for a row mirroring an origin that does not send the list.
    public let activePanes: [String]?
    /// lastSelectedAt is `Session.lastSelectedAt` as epoch seconds; omitted when no selection timestamp has
    /// been recorded.
    public let lastSelectedAt: Double?
    /// The row's tint color (`session.tint`); nil/omitted when untinted.
    public let tint: String?
    /// Deprecated: always `icon,name`, since a tint colors both; present exactly when `tint` is.
    public let tintOn: [String]?
    /// The parent's id for a companion; omitted for a top-level session.
    public let parent: String?
    /// True for a parent whose companions are folded; omitted otherwise.
    public let collapsed: Bool?
    /// `page` for a page session, which has no terminal; omitted for a terminal session.
    public let content: String?
    /// info is the sidebar info line's source as set (`Session.effectiveInfo`, so an attached row without a local
    /// line shows its origin's). The three info fields are all present while a line is set, all omitted otherwise.
    public let info: String?
    /// infoMarkdown says whether `info` is read as markdown.
    public let infoMarkdown: Bool?
    /// infoHideAfter is the CONFIGURED expiry in seconds, 0 for none, never a countdown.
    public let infoHideAfter: Double?
    /// The session's background watermark spec; nil/omitted when none is set. The read side of
    /// `session.background`.
    public let background: BackgroundWatermark?
    /// paneBackgrounds is the read side of `session.background --pane`: overrides only, never effective values,
    /// so an absent pane inherits `background`; omitted when no pane has one.
    public let paneBackgrounds: PaneBackgrounds?
    /// paneGrids is the read side of `session.grid`, omitted while every pane follows its view.
    public let paneGrids: ControlPaneGrids?
    /// The session's unseen-notification badge count; nil/omitted when zero. `notify` (and terminal OSC
    /// 9/777) raise it, `session.seen` clears it. Ephemeral like `status` — never persisted, resets on restart.
    public let unseen: Int?
    /// The default/left pane's live font size in points via `addressableSurface`: the main pane, or the
    /// promoted split survivor once the primary exited (the pane `font --pane left`, and the default, writes);
    /// nil/omitted when unrealized. The live cmd +/- value, persisted for the main pane but live-only for a
    /// promoted survivor.
    public let fontSize: Double?
    /// The split (right) pane's live font size in points; nil/omitted with no realized split pane. The read
    /// side of `font --pane right`, otherwise unobservable — live-only, not persisted.
    public let splitFontSize: Double?
    /// The scratch terminal's live font size in points, or nil when no scratch surface is realized (omitted).
    /// The read side of `font --pane scratch` (also live-only).
    public let scratchFontSize: Double?
    /// Addressable terminal surfaces owned by this session; nil/omitted against a server predating
    /// `surface.zoom`. Hidden-but-alive surfaces are included, so a client can zoom them without unhiding.
    public let surfaces: [ControlSurfaceNode]?
    /// Whether the MAIN pane's terminal exists — the libghostty surface created and its program spawned —
    /// as opposed to the session merely being in the model. False means `session.type`/`session.text` will
    /// report `session not realized` and a `--command` has not run yet. nil/omitted only against a server
    /// predating the field; this one always reports it.
    ///
    /// `session.new` answers `ok` for a model insert, which is honest but says nothing about the terminal:
    /// libghostty refuses to create a surface while the display is asleep, so a session a scheduled job
    /// creates overnight sits unrealized until the displays wake (#416). This is the field that tells them
    /// apart. It reports the main pane because that is what `--command` spawns on and what the input/read
    /// commands address by default; per-pane liveness is `fontSize`/`splitFontSize`/`scratchFontSize`,
    /// each omitted when its pane is unrealized.
    public let realized: Bool?

    /// The host a teleported session is attached to; nil/omitted for a local one. Live-only — a remote
    /// session is never persisted, so this never survives a relaunch.
    public let remoteHost: String?
    /// The origin's id for the session an attached row shows, the id `zmx attach` takes; omitted for a local one.
    public let remoteSessionID: String?

    /// This Mac's presentation stream to the session's origin, on an attached session only. `state` is
    /// `connecting`, `connected`, `unsupported` for an origin that predates the stream, or `failed` with
    /// the reason in `error`. It says whether status, context, notifications and HUD are being mirrored, never
    /// whether the panes' own ssh connections are up.
    public let presentation: ControlPresentationNode?
    /// The presentation streams on this session: how many mirror it, a count of connections so two rows
    /// attached from one Mac are two, and whether one presents it. Omitted when there is none.
    public let presenters: ControlPresentersNode?
    /// Overlay slots a viewer presenting this session holds, on the origin; omitted when none is held. Such
    /// an overlay covers nothing here, so `overlay` and `paneOverlays` leave it out.
    public let remoteOverlays: [ControlRemoteOverlayNode]?
    /// htmlOverlays lists the pages in this session's overlay slots, session-wide first then left and right;
    /// omitted when none is open. A local page's slot is also reported covered by `overlay` and `paneOverlays`;
    /// a page shown on the presenting Mac (`remote`) covers nothing here.
    public let htmlOverlays: [ControlHtmlOverlayNode]?
    /// hiddenOverlays lists the hidden slots as `session`, `left`, `right`, omitted when none is hidden. A
    /// hidden local slot still counts in `overlay` and `paneOverlays`, which report occupancy; a remote page
    /// is listed when the presenting Mac reports it hidden.
    public let hiddenOverlays: [String]?

    public init(id: String, name: String, cwd: String, title: String? = nil, active: Bool, split: Bool,
                hasSplit: Bool? = nil, backedByZmx: Bool?, splitAxis: String? = nil,
                splitRatio: Double? = nil, splitFocused: Bool? = nil,
                overlay: Bool = false, overlaySizePercent: Int? = nil, overlayWidth: Double? = nil,
                overlayHeight: Double? = nil, paneOverlays: [String]? = nil,
                hud: ControlHudNode? = nil, ask: ControlSessionAsk? = nil, pick: ControlSessionPick? = nil,
                scratch: Bool = false, flagged: Bool = false, ended: Bool? = nil, pending: String? = nil, scratchBacked: Bool? = nil,
                scratchPaneID: String? = nil, scratchPendingMessages: Int? = nil, interactions: [ControlInteraction]? = nil,
                commandWait: Bool? = nil, splitCommandWait: Bool? = nil,
                agent: String? = nil, agentSessionId: String? = nil, foreground: [String]? = nil, splitForeground: [String]? = nil,
                foregroundShell: String? = nil, splitForegroundShell: String? = nil,
                restoreCommand: String? = nil, splitRestoreCommand: String? = nil, status: String? = nil,
                statusPane: String? = nil, statusBlink: Bool? = nil, statusColor: String? = nil,
                statusShape: String? = nil, statusChangedAt: Double? = nil, activePanes: [String]? = nil,
                background: BackgroundWatermark? = nil, paneBackgrounds: PaneBackgrounds? = nil, unseen: Int? = nil,
                fontSize: Double? = nil, splitFontSize: Double? = nil, scratchFontSize: Double? = nil,
                surfaces: [ControlSurfaceNode]? = nil, realized: Bool? = nil,
                context: String? = nil, remoteHost: String? = nil, splitCwd: String? = nil, scratchCwd: String? = nil,
                liveAttribution: String? = nil, splitLiveAttribution: String? = nil,
                liveHostStale: Bool? = nil, splitLiveHostStale: Bool? = nil,
                presentation: ControlPresentationNode? = nil, presenters: ControlPresentersNode? = nil,
                remoteOverlays: [ControlRemoteOverlayNode]? = nil, htmlOverlays: [ControlHtmlOverlayNode]? = nil,
                hiddenOverlays: [String]? = nil, lastSelectedAt: Double? = nil,
                tint: String? = nil, tintOn: [String]? = nil, parent: String? = nil, collapsed: Bool? = nil,
                content: String? = nil, info: SessionInfo? = nil, remoteSessionID: String? = nil,
                paneGrids: ControlPaneGrids? = nil) {
        self.paneGrids = paneGrids
        self.remoteSessionID = remoteSessionID
        self.content = content
        self.info = info?.source
        self.infoMarkdown = info?.markdown
        self.infoHideAfter = info?.hideAfter
        self.parent = parent
        self.collapsed = collapsed
        self.id = id
        self.name = name
        self.cwd = cwd
        self.title = title
        self.active = active
        self.split = split
        self.hasSplit = hasSplit
        self.backedByZmx = backedByZmx
        self.splitAxis = splitAxis
        self.splitRatio = splitRatio
        self.splitFocused = splitFocused
        self.overlay = overlay
        self.overlaySizePercent = overlaySizePercent
        self.overlayWidth = overlayWidth
        self.overlayHeight = overlayHeight
        self.paneOverlays = paneOverlays
        self.hud = hud
        self.ask = ask
        self.pick = pick
        self.scratch = scratch
        self.flagged = flagged
        self.ended = ended
        self.pending = pending
        self.scratchBacked = scratchBacked
        self.scratchPaneID = scratchPaneID
        self.scratchPendingMessages = scratchPendingMessages
        self.interactions = interactions
        self.context = context
        self.commandWait = commandWait
        self.splitCommandWait = splitCommandWait
        self.agent = agent
        self.agentSessionId = agentSessionId
        self.foreground = foreground
        self.splitForeground = splitForeground
        self.foregroundShell = foregroundShell
        self.splitForegroundShell = splitForegroundShell
        self.restoreCommand = restoreCommand
        self.splitRestoreCommand = splitRestoreCommand
        self.status = status
        self.statusPane = statusPane
        self.statusBlink = statusBlink
        self.statusColor = statusColor
        self.statusShape = statusShape
        self.statusChangedAt = statusChangedAt
        self.activePanes = activePanes
        self.lastSelectedAt = lastSelectedAt
        self.tint = tint
        self.tintOn = tintOn
        self.background = background
        self.paneBackgrounds = paneBackgrounds
        self.unseen = unseen
        self.fontSize = fontSize
        self.splitFontSize = splitFontSize
        self.scratchFontSize = scratchFontSize
        self.surfaces = surfaces
        self.realized = realized
        self.splitCwd = splitCwd
        self.scratchCwd = scratchCwd
        self.remoteHost = remoteHost
        self.liveAttribution = liveAttribution
        self.splitLiveAttribution = splitLiveAttribution
        self.liveHostStale = liveHostStale
        self.splitLiveHostStale = splitLiveHostStale
        self.presentation = presentation
        self.presenters = presenters
        self.remoteOverlays = remoteOverlays
        self.htmlOverlays = htmlOverlays
        self.hiddenOverlays = hiddenOverlays
    }
}

/// ControlHtmlOverlayNode is one HTML page in an overlay slot. `file` or `url` is what was opened and what
/// `session.overlay.reload` loads; `page` is where the user has navigated since, nil until the first load.
public struct ControlHtmlOverlayNode: Codable, Sendable, Equatable {
    /// pane is the pane role, omitted for the session-wide slot.
    public let pane: String?
    /// file, url, image, markdown, document and text name the source; exactly one is set.
    public let file: String?
    /// cwd is a file page's read grant, omitted when it has none.
    public let cwd: String?
    public let url: String?
    public let image: String?
    public let markdown: String?
    /// document is an HTML file a terminal click opened, shown with no file grant or bridge.
    public let document: String?
    public let text: ControlTextOverlayNode?
    /// state is `loading`, `loaded` or `failed`.
    public let state: String
    public let error: String?
    /// page, title and the history flags are omitted until the web view first reports them.
    public let page: String?
    public let title: String?
    public let canGoBack: Bool?
    public let canGoForward: Bool?
    /// navigation is true when the toolbar is shown, omitted otherwise.
    public let navigation: Bool?
    /// javascript says whether the page may run its own scripts.
    public let javascript: Bool
    /// chromeless says whether the page shows without its identity strip. Always present; an absent key
    /// decodes as false, since an older running server omits it.
    public let chromeless: Bool
    /// persistent says whether the page uses the saved browser store. Always present; an absent key decodes
    /// as false, since an older running server omits it.
    public let persistent: Bool
    /// browse says whether the page's main frame may leave its first origin. Always present; an absent key
    /// decodes as false, since an older running server omits it.
    public let browse: Bool
    /// zoom is the page zoom factor, 1 at actual size. One app-wide value, so every page reports the same.
    public let zoom: Double?
    /// id is the page's identity, the one `session.overlay.result --page` reads; an older server omits it.
    public let id: String?
    /// hidden is true while the page's slot is hidden, omitted otherwise.
    public let hidden: Bool?
    /// remote is true for a page this Mac opened that the presenting Mac shows, omitted otherwise.
    public let remote: Bool?
    /// replica is true for a page shown here for the Mac that opened it, omitted otherwise.
    public let replica: Bool?
    /// clicked is true for a page a terminal click opened, omitted otherwise. It names the origin only:
    /// `AppStore.releaseHiddenClickedPage` decides whether a click replaces the page, and `hidden` here also
    /// covers states it leaves alone.
    public let clicked: Bool?
    /// phone is true for a page the phone relay shows, omitted otherwise.
    public let phone: Bool?

    public init(pane: String?, file: String? = nil, cwd: String? = nil, url: String? = nil, image: String? = nil,
                markdown: String? = nil, document: String? = nil, text: ControlTextOverlayNode? = nil, state: String,
                error: String?, page: String? = nil, title: String? = nil, canGoBack: Bool? = nil,
                canGoForward: Bool? = nil, navigation: Bool? = nil, javascript: Bool = false, chromeless: Bool = false,
                zoom: Double? = nil, id: String? = nil, persistent: Bool = false, browse: Bool = false,
                hidden: Bool? = nil, remote: Bool? = nil, replica: Bool? = nil, clicked: Bool? = nil, phone: Bool? = nil) {
        self.id = id
        self.phone = phone
        self.clicked = clicked
        self.hidden = hidden
        self.remote = remote
        self.replica = replica
        self.pane = pane
        self.file = file
        self.cwd = cwd
        self.url = url
        self.image = image
        self.markdown = markdown
        self.document = document
        self.text = text
        self.state = state
        self.error = error
        self.page = page
        self.title = title
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.navigation = navigation
        self.javascript = javascript
        self.chromeless = chromeless
        self.persistent = persistent
        self.browse = browse
        self.zoom = zoom
    }

    enum CodingKeys: String, CodingKey {
        case pane, file, cwd, url, image, markdown, document, text, state, error, page, title, canGoBack, canGoForward, navigation, javascript
        case chromeless, persistent, browse, zoom, id, hidden, remote, replica, clicked, phone
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pane = try c.decodeIfPresent(String.self, forKey: .pane)
        file = try c.decodeIfPresent(String.self, forKey: .file)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        image = try c.decodeIfPresent(String.self, forKey: .image)
        markdown = try c.decodeIfPresent(String.self, forKey: .markdown)
        document = try c.decodeIfPresent(String.self, forKey: .document)
        text = try c.decodeIfPresent(ControlTextOverlayNode.self, forKey: .text)
        state = try c.decode(String.self, forKey: .state)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        page = try c.decodeIfPresent(String.self, forKey: .page)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        canGoBack = try c.decodeIfPresent(Bool.self, forKey: .canGoBack)
        canGoForward = try c.decodeIfPresent(Bool.self, forKey: .canGoForward)
        navigation = try c.decodeIfPresent(Bool.self, forKey: .navigation)
        javascript = try c.decode(Bool.self, forKey: .javascript)
        chromeless = try c.decodeIfPresent(Bool.self, forKey: .chromeless) ?? false
        persistent = try c.decodeIfPresent(Bool.self, forKey: .persistent) ?? false
        browse = try c.decodeIfPresent(Bool.self, forKey: .browse) ?? false
        zoom = try c.decodeIfPresent(Double.self, forKey: .zoom)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden)
        remote = try c.decodeIfPresent(Bool.self, forKey: .remote)
        replica = try c.decodeIfPresent(Bool.self, forKey: .replica)
        clicked = try c.decodeIfPresent(Bool.self, forKey: .clicked)
        phone = try c.decodeIfPresent(Bool.self, forKey: .phone)
    }
}

/// ControlRemoteOverlayNode is an overlay slot of an origin session held by the viewer presenting it, as
/// `tree` reports it.
public struct ControlRemoteOverlayNode: Codable, Sendable, Equatable {
    /// The pane role, omitted for the session-wide slot.
    public let pane: String?
    /// The size requested for a session-wide overlay; what the viewer applied is not reported.
    public let sizePercent: Int?
    /// pageID names the page the slot holds, the id `htmlOverlays` reports; omitted for a program overlay.
    public let pageID: String?

    public init(pane: String?, sizePercent: Int?, pageID: String? = nil) {
        self.pane = pane
        self.sizePercent = sizePercent
        self.pageID = pageID
    }
}

/// A viewer's presentation stream as `tree` reports it.
public struct ControlPresentationNode: Codable, Sendable, Equatable {
    public let state: String
    public let mode: String
    public let error: String?

    public init(state: String, mode: String, error: String? = nil) {
        self.state = state
        self.mode = mode
        self.error = error
    }
}

/// The viewers of an origin session as `tree` reports them. `mirrors` counts the viewers that are not the
/// presenter; `presenter` is omitted unless a viewer holds that role.
public struct ControlPresentersNode: Codable, Sendable, Equatable {
    public let mirrors: Int
    public let presenter: Bool?
    /// viewers counts every attached stream, the presenter included; absent from an app that predates it.
    public let viewers: Int?

    public init(mirrors: Int, presenter: Bool? = nil, viewers: Int? = nil) {
        self.mirrors = mirrors
        self.presenter = presenter
        self.viewers = viewers
    }

    /// viewedBy is the number of attached streams, derived from `mirrors` and `presenter` for an older app.
    public var viewedBy: Int { viewers ?? mirrors + (presenter == true ? 1 : 0) }
}

/// A workspace and its sessions as projected into the `tree` response.
public struct ControlWorkspaceNode: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let active: Bool
    /// Whether this workspace is a MEMBER of the sidebar's focus set; nil/omitted when not. Reported
    /// INDEPENDENTLY of whether the filter is applied (that flag is the tree top-level `workspaceFilter`), so
    /// a marked-but-not-filtering set reads back. Distinct from `active` (the CURRENT workspace — what
    /// `--target active` resolves to, which an empty or foreground-created destination makes current while
    /// the selected session stays behind in another one). The read
    /// side of the write-only `workspace.focus`/`workspace.filter`.
    ///
    /// A workspace ROW is VISIBLE iff `tree.sidebarVisible && ((tree.sidebarMode == "tree" &&
    /// (!tree.workspaceFilter || focused)) || (tree.sidebarMode == "flagged" &&
    /// tree.sidebarFlaggedLayout == "tree" && one of its sessions is `flagged`))`, every term on the same
    /// `tree` response — no second call needed. The parentheses matter: the focus filter restricts the
    /// ordinary tree only, and flagged mode ignores it. The shorter forms are wrong: `focused &&
    /// workspaceFilter` reports nothing visible while the filter is off, and a bare `!workspaceFilter ||
    /// focused` reports rows behind a hidden sidebar and under the FLAT flagged list, which has none. The
    /// filter-ON term is exact because enabled-with-an-empty-set is unrepresentable (enabling an empty set is
    /// refused; restore prunes stale ids then disables when it empties), so an applied filter always has at
    /// least one visible member.
    public let focused: Bool?
    /// Whether this workspace is COLLAPSED in the sidebar tree; nil when expanded (the default), so an
    /// all-expanded tree omits it, matching the persisted `WorkspaceSnapshot.collapsed`. The read side of
    /// `workspace.collapse`/`workspace.expand` and `workspace.new --collapsed`. Reports the persisted
    /// `!isExpanded`, independent of a transient focus force-reveal.
    public let collapsed: Bool?
    /// The workspace row's own tint color (`workspace.tint`); nil/omitted when untinted. Never inherited by
    /// the sessions inside.
    public let tint: String?
    /// Deprecated: always `icon,name`, since a tint colors both; present exactly when `tint` is.
    public let tintOn: [String]?
    /// The workspace's remembered folder (the last directory a local pane reported over OSC 7); nil/omitted
    /// when none. Read-only: the shell sets it with `cd`, there is no setter command.
    public let rememberedFolder: String?
    /// The workspace's pinned project folder; nil/omitted when none.
    public let projectFolder: String?
    public let sessions: [ControlSessionNode]

    public init(id: String, name: String, active: Bool, focused: Bool? = nil,
                collapsed: Bool? = nil, tint: String? = nil, tintOn: [String]? = nil,
                rememberedFolder: String? = nil, projectFolder: String? = nil, sessions: [ControlSessionNode]) {
        self.id = id
        self.name = name
        self.active = active
        self.focused = focused
        self.collapsed = collapsed
        self.tint = tint
        self.tintOn = tintOn
        self.rememberedFolder = rememberedFolder
        self.projectFolder = projectFolder
        self.sessions = sessions
    }
}
