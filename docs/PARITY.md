# Parity with agterm master

The target is agterm `master` (NaikSoftware fork), not a redesign.
Sources: `site/docs.html`, the site screenshots, the Swift code, and the fork-only commits.
macOS keys map to Linux as ⌘ → Ctrl+Shift (Konsole's convention); ⌘⇧ and ⌘⌃ → Ctrl+Alt+Shift; ⌃ → Ctrl; ⌥ → Alt.

Legend: [x] done · [ ] todo · (fork) = fork-only feature, not in upstream docs.

## Phase 1: sidebar, chrome, sessions

- [x] Title bar strip: sidebar toggle, session name
- [ ] Title bar: file panel toggle (fork, phase 4); split, split-vertical, scratch, quick terminal buttons (phase 2)
- [x] Sidebar rows: workspace = chevron + grid icon + name; session = terminal icon + name + status dot at the right
- [x] Session icon = logo of the agent in its foreground process group (claude, codex, opencode, agy), sampled every 2 s (fork)
- [x] Workspace "+" on hover: menu of Terminal + agents found on the login shell PATH, with logos; repeat button for the last choice (fork)
- [x] Remembered folder per workspace (last cwd its panes reported); new sessions open there (fork)
- [x] Settings: new session directory (home / workspace folder / custom), placement (end / after current)
- [x] Default session name = cwd basename; rename pins a name, clearing reverts; inline rename on double-click
- [x] Sidebar footer: new session, new workspace, flagged view (flat list)
- [ ] Sidebar footer: workspace filter (phase 3)
- [x] Session context menu: Clear Status, Rename, Copy Name, Duplicate Session, Move to ▸, Flag, Close Session (batch over a multi-selection)
- [ ] Session context menu: New Companion (phase 2)
- [x] Workspace context menu: New Session, Rename, Copy Name, Flag All Sessions, Delete Workspace
- [ ] Workspace context menu: Focus (phase 3)
- [x] Drag to reorder sessions and workspaces; drag a session to another workspace; multi-select
- [x] Drop folders from the file manager onto the tree to open sessions there
- [x] Strip agent spinner glyphs (✳ ◑ braille) from terminal titles (fork)
- [x] Close-session reselection by MRU within the workspace
- [x] Shortcuts: new session ⌘N, new workspace ⌘⇧N, open directory ⌘O, close ⌘W, prev/next session ⌥⌘↑↓, attention ⌃⌥↑↓, toggle sidebar ⌘⌃S, flag ⌘⇧F
- [ ] Shortcuts: reopen ⌘⇧T (phase 3), font ±0

## Phase 2: terminals

- [x] Split ⌘D / ⌘⇧D (one session, two shells; transposes; hides; divider memory, double-click resets; swap panes; focus left/right; close split)
- [x] Scratch ⌘J per session
- [x] Quick terminal ⌃` (floating, 90% of screen, click-away dismiss; `quick on` stays put)
- [ ] Quick terminal global hotkey (keymap `global-hotkey`, phase 5)
- [x] Search: Konsole's own search bar (Ctrl+Shift+F)
- [x] Terminal zoom ⌘⇧↩ (⌘W leaves zoom)
- [x] Fullscreen (F11: ⌘⌃F maps onto the flag chord)
- [ ] Companions (pinned under parent, folding, respawn on exit)

## Phase 3: navigation and windows

- [x] Session palette ⌃P, action palette ⌃⇧P (fuzzy, Ctrl-J/K, disabled actions greyed)
- [ ] Custom-commands palette ⌃⇧O (with keymap, phase 5)
- [x] Ctrl-Tab MRU switcher (hold Ctrl, Tab walks, release switches; one tap flips back)
- [ ] Recent-sessions title-bar button
- [ ] Flagged view (flat / workspace tree), workspace filter / focus
- [x] Reopen closed session ⌘⇧T, `recent open`
- [ ] Undo close ⌘Z within the grace period
- [ ] Multiple windows (library, restore frames)
- [ ] Notifications: OSC 9/777 and `notify`, unseen badges, banner click focuses the pane
- [ ] Agent status: dot colours/shapes, blink, status reset (first key / Enter / off), auto-follow, blocked sound

## Phase 4: file panel (fork)

- [ ] Column right of the sidebar with the active session's folder tree, live refresh
- [ ] Atom file-icons
- [ ] Open: Markdown, text and images in the built-in viewer; others with the default app
- [ ] Context menu: Open, Open with Default App, New Companion Here, Cut, Copy, Paste, Rename…, Move to Trash
- [ ] Drag inside to move (Ctrl to copy), drop from the file manager to copy in, drop on a terminal to paste the path
- [ ] `filepanel [show|hide|toggle]`, `filepanel width`

## Phase 5: settings, keymap, extension

- [ ] Settings dialog: General, Appearance, Interface, Notifications, Agent Status, Key Mapping
- [ ] Theme picker with live preview
- [ ] keymap.conf: built-in rebinding, `command "Name" chord shell…`, AGT_* context, reload/edit
- [ ] Hooks (`hooks.conf`), page bridge
- [ ] Overlays (program, HTML/URL page, HUD), dashboard
- [ ] Restore modes (fresh / re-run commands / live sessions)
- [ ] Control API breadth: every command in `site/commands.html`
- [ ] Agent skill + hook installers for Claude/Codex/OpenCode/Pi
