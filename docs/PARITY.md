# Parity with agterm master

The target is agterm `master` (NaikSoftware fork), not a redesign.
Sources: `site/docs.html`, the site screenshots, the Swift code, and the fork-only commits.
macOS keys map to Linux as ⌘ → Ctrl+Shift (Konsole's convention); ⌘⇧ and ⌘⌃ → Ctrl+Alt+Shift; ⌃ → Ctrl; ⌥ → Alt.

Legend: [x] done · [ ] todo · (fork) = fork-only feature, not in upstream docs.

## Phase 1: sidebar, chrome, sessions

- [x] Title bar strip: sidebar toggle, session name
- [x] Title bar: file panel toggle (fork, left of the sidebar toggle); split button
- [x] Sidebar rows: workspace = chevron + grid icon + name; session = terminal icon + name + status dot at the right
- [x] Session icon = logo of the agent in its foreground process group (claude, codex, opencode, agy), sampled every 2 s (fork)
- [x] Workspace "+" on hover: menu of Terminal + agents found on the login shell PATH, with logos; repeat button for the last choice (fork)
- [x] Remembered folder per workspace (last cwd its panes reported); new sessions open there (fork)
- [x] Settings: new session directory (home / workspace folder / custom), placement (end / after current)
- [x] Session name: pinned rename, else the title a running program (agent) set, else "New session" (owner's default; shell prompt titles ignored); inline rename on double-click
- [x] Sidebar footer: new session, new workspace, flagged view (flat list)
- [x] Sidebar footer: workspace filter
- [x] Session context menu: Clear Status, Rename, Copy Name, Duplicate Session, Move to ▸, Flag, Close Session (batch over a multi-selection)
- [x] Session context menu: New Companion
- [x] Workspace context menu: New Session, Rename, Copy Name, Flag All Sessions, Delete Workspace
- [x] Workspace context menu: Focus/Unfocus, Add to/Remove from Focus, Tint
- [x] Session context menu: Tint (None, seven colours, Show On icon/name; batch), palette Tint Session items, `session|workspace tint`, `--tint` on new
- [x] Drag to reorder sessions and workspaces; drag a session to another workspace; multi-select
- [x] Drop folders from the file manager onto the tree to open sessions there
- [x] Strip agent spinner glyphs (✳ ◑ braille) from terminal titles (fork)
- [x] Close-session reselection by MRU within the workspace
- [x] Shortcuts: new session ⌘N, new workspace ⌘⇧N, open directory ⌘O, close ⌘W, prev/next session ⌥⌘↑↓, attention ⌃⌥↑↓, toggle sidebar ⌘⌃S, flag ⌘⇧F
- [x] Shortcuts: reopen ⌘⇧T, font ⌘+ ⌘− ⌘0 (`font inc|dec|reset`, sizes persisted; driven through Konsole's Ctrl+wheel zoom)

## Phase 2: terminals

- [x] Split ⌘D / ⌘⇧D (one session, two shells; transposes; hides; divider memory, double-click resets; swap panes; focus left/right; close split)
- Scratch: dropped at the owner's request (2026-11-04)
- Quick terminal: dropped at the owner's request (2026-11-04)
- [x] Search: Konsole's own search bar (Ctrl+Shift+F)
- [x] Terminal zoom ⌘⇧↩ (⌘W leaves zoom)
- [x] Fullscreen (F11: ⌘⌃F maps onto the flag chord)
- [x] Companions (pinned under parent, folding with attention marker, moves with parent, closes with parent, respawn on exit, `session new --parent`)
- [x] Duplicate as Companion (copies the split layout and each pane's program; `session duplicate --companion`)

## Phase 3: navigation and windows

- [x] Session palette ⌃P, action palette ⌃⇧P (fuzzy, Ctrl-J/K, disabled actions greyed)
- [ ] Custom-commands palette ⌃⇧O (with keymap, phase 5)
- [x] Ctrl-Tab MRU switcher (hold Ctrl, Tab walks, release switches; one tap flips back)
- [x] Recent-sessions title-bar button (a menu under the clock, not a popover)
- [ ] Flagged view workspace-tree layout, Edit Flagged Sessions… / Edit Focused Workspaces… editors
- [x] Workspace filter / focus (`workspace focus on|off|toggle|add`, `workspace filter`; suspends on an outside select; navigation stays inside)
- [x] Reopen closed session ⌘⇧T, `recent open`
- [x] Undo close ⌘Z within the 3 s grace (sessions, batches with companions, workspaces; Settings switch; `session close --undoable`)
- [ ] Multiple windows (library, restore frames)
- [x] Notifications: `notify`, unseen-count badge, banner click focuses the session, `session seen`
- [ ] Notifications from OSC 9 / 777 inside the terminal; settings (banner, badge, sound)
- [ ] Agent status: dot colours/shapes, blink, status reset (first key / Enter / off), auto-follow, blocked sound

## Phase 4: file panel (fork)

- [x] Column right of the sidebar with the active session's folder tree, live refresh
- [x] Atom file-icons
- [x] Open: Markdown, text and images in the built-in viewer; others with the default app
- [x] Context menu: Open, Open with Default App, New Companion Here, Cut, Copy, Paste, Rename…, Move to Trash
- [x] Drag inside to move (Ctrl to copy), drop from the file manager to copy in, drop on a terminal to paste the path
- [x] `filepanel [show|hide|toggle]`, `filepanel width`

## Phase 5: settings, keymap, extension

- [ ] Settings dialog: General, Appearance, Interface, Notifications, Agent Status, Key Mapping
- [ ] Theme picker with live preview
- [ ] keymap.conf: built-in rebinding, `command "Name" chord shell…`, AGT_* context, reload/edit
- [ ] Hooks (`hooks.conf`), page bridge
- [ ] Overlays (program, HTML/URL page, HUD), dashboard
- [ ] Restore modes (fresh / re-run commands / live sessions)
- [ ] Control API breadth: every command in `site/commands.html`
- [ ] Agent skill + hook installers for Claude/Codex/OpenCode/Pi
