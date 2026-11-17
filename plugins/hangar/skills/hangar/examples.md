# Hangar control examples

Worked `hangarctl` examples. See `reference.md` for exact flags and return shapes. All assume
`hangarctl` is on PATH and you are inside a Hangar session (`HANGAR_ENABLED=1`).

Installable, human-facing workflows live in the repository's cookbook — see `cookbook.md` for how to
list, fetch and install one, or to read one as reference for a tricky case.

## Inspect the current state

```bash
hangarctl tree --json        # workspaces -> sessions, active/split/overlay/scratch/flagged flags, surface ids
hangarctl window list --json # windows, with open/active flags

# what is each pane RUNNING right now (foreground argv; absent at the shell prompt or for a setuid program like top/sudo)
# foregroundShell names the shell holding the foreground, so an existing pane with neither could not be read.
# it does NOT mean the pane is at a prompt: a builtin like `read` runs inside the shell and looks the same
hangarctl tree --json | jq -r '.result.tree.workspaces[].sessions[]
  | "\(.name): \(.foreground // .foregroundShell // "unknown")"'
```

## Capture or reset the restore-on-restart commands

The `rerun` restore mode saves each pane's foreground command at quit. Clear those saved commands in any
mode so a future rerun launch restores plain shells:

```bash
hangarctl restore clear
```

Or capture them now, so an exit that never reaches a clean quit (a force quit, a crash, a hard reset)
restores like one. It requires this launch to be in `rerun` mode and answers with the number of panes it captured:

```bash
hangarctl restore capture
```

Use a keybind or a scheduled job rather than typing it at a prompt: run by hand it records ITSELF, being
that pane's foreground process while it runs, and `restore clear` is app-global so it is no per-pane undo.

## See and clean up the daemons behind live sessions

In `live` mode each primary and split pane runs inside a zmx daemon that outlives the app. List them with
the pane that claims each one:

```bash
hangarctl zmx list
```

A `claimed` row with zero clients is a CLOSED window's pane, which is its resting state, not a leak. Only
`orphan` rows are eligible for cleanup, and prune refuses entirely if the pane inventory is incomplete:

```bash
hangarctl zmx prune
```

To destroy one pane's daemon and the process in it, name the session and the pane and confirm. All three
are required because this kills a backend process, reaching a pane no window is showing and every client
attached to it:

```bash
hangarctl zmx kill --target 3f2a --pane left --force
```

To move every live session created before the session host under it, so a tool's microphone permission
stops being asked per version, reset them. Hangar quits and reopens itself right after the reply, so run
this from outside the sessions it affects, or expect the calling shell to end:

```bash
hangarctl zmx reset --force
```

## Attach a session running on another Mac

List what the other machine offers across every open window, then open one here by its ID. The far side
has to be in `live` mode, reachable over ssh with key-based auth, and carry `hangarctl` from the cask or
the Help action — running Hangar alone leaves no CLI an ssh command can find. Run it with no host to ask
the same of this app, which is the form the remote call runs over there:

```bash
hangarctl zmx tree studio.local
hangarctl zmx attach studio.local 7c1e4a02-...
# Place it in a specific open local window.
hangarctl zmx attach studio.local 7c1e4a02-... --window "$window_id"
```

To let the user choose, pipe the listing through the picker:

```bash
s=$(hangarctl zmx tree studio.local --json |
  jq '[.result.remote.sessions[] | {id, label: .name,
        subtitle: (.windowName + "/" + .workspaceName + "  " + .cwd)}]' |
  hangarctl pick --prompt "Attach which session?" | jq -r '.id // empty')
[ -n "$s" ] && hangarctl zmx attach studio.local "$s"
```

The row is marked remote and carries `remoteHost` in the tree. Closing it ends only this side's connection,
and it does not come back after a relaunch.

Status, context, `notify` and HUD calls made by a program inside that session show on both Macs. Check the
mirroring stream, which needs `hangarctl` on the far side's ssh PATH:

```sh
hangarctl tree --json | jq '.. | objects | select(.remoteHost) | {name, presentation}'
```

## Read or change the local restore policy

This is about THIS instance, not a remote one: `zmx attach` requires nothing of the local restore mode.
A mode you set applies to the NEXT launch, because a pane is wrapped in a daemon or not at the moment it
is created:

```bash
hangarctl restore mode          # what settings hold, what this launch asked for, what it got
hangarctl restore mode live     # for the next launch
```

## Pin what a pane restores (per-session override)

`session restore` pins a shell line that a pane re-runs on the NEXT launch, overriding the captured
foreground. It is written now and consumed at the next launch (it never touches the running session), and
it is sticky — it fires again on every restart until cleared. Read it back on `tree` as the node's
`restoreCommand` / `splitRestoreCommand`.

In fresh-shell or live mode, a command or `--none` is saved for a future rerun launch and the response
names the active mode. `--clear` works in every mode. A pin never opts one session out of live mode.

```bash
hangarctl session restore "claude --resume abc123" --target "$HANGAR_SESSION_ID"  # pin a shell line
hangarctl session restore --none  --target "$HANGAR_SESSION_ID"   # pin nothing: restore a plain shell
hangarctl session restore --clear --target "$HANGAR_SESSION_ID"   # drop the override, back to auto-capture
hangarctl session restore "npm run dev" --target "$HANGAR_SESSION_ID" --pane-id "$HANGAR_PANE_ID"  # a split pane by its live slot
```

The pinned value is SHELL CODE: it persists in the window's state file (`windows/<id>.json`), is readable
via `tree`, and may enter shell history when it runs — so it must not carry secrets, and only
safely-interpolated values (a UUID-shaped session id) belong in it.

## Keep a forking agent session reattaching across restarts (a SessionStart hook)

`claude --resume <id> --fork-session` mints a NEW claude session on every Hangar restart, so restoring it
verbatim never reattaches the session you were in. Fix it by rewriting the override to the LIVE session id
on every start, from a Claude Code `SessionStart` hook — it runs inside the session's shell, where
`$HANGAR_SESSION_ID` and `$HANGAR_PANE_ID` are exported:

```bash
# in the SessionStart hook (the selector is --target; there is no --session).
# the hook's stdin JSON carries the live id as `session_id` — there is NO $CLAUDE_SESSION_ID variable.
sid=$(jq -r '.session_id // empty')
[ -n "$sid" ] || exit 0   # no id: leave the existing pin alone rather than pinning a broken line
hangarctl session restore "claude --resume $sid" \
    --target "$HANGAR_SESSION_ID" --pane-id "$HANGAR_PANE_ID"
```

Because the hook rewrites the override on every start, it always tracks the live child, so the next
restart reattaches instead of forking. Ownership flips to whoever sets it: write it once by hand and forget,
and it stays pinned to a STALE id — that is why this is a hook-driven override, not a set-once setting.

Read the id from the hook's stdin (`$CLAUDE_CODE_SESSION_ID` is exported in the session's environment as
well, but the stdin `session_id` is what the hook is handed). GUARD against an empty value before pinning:
a pin is sticky and persisted, so `claude --resume ` with an empty argument would be re-typed on every
launch until cleared. The id is UUID-shaped and safe to interpolate; never build the pinned line from
untrusted or secret values.

## Create a session and type into it

`session new` returns the new id and focuses the session. Capture the id, then type. The session is
realized eagerly, so no `--select` is needed.

```bash
sid=$(hangarctl session new --cwd "$HOME/project" --json | jq -r '.result.id')
hangarctl session type "git status" --target "$sid"
hangarctl session type $'\n' --target "$sid"     # send Return (or include it in the text)
hangarctl session split on --target "$sid"                    # open a split first
hangarctl session type $'ls\n' --target "$sid" --pane right   # then type into the split pane
```

Typing goes to the session's main (left) pane by default; `--pane right` targets the split pane and
errors with `session has no split pane` when there is none. In a custom keymap command, `$AGT_PANE`
holds the pane the shortcut fired from, so `session type --pane "$AGT_PANE"` types back into it.

Run a command AS the session's process (closes when it exits, no echoed command line):

```bash
hangarctl session new --command "ssh host -p 22"     # a default-PATH binary, no echoed command line; wrap a ; or && list in sh -c
hangarctl session new --command "zsh -lc 'htop'"     # Homebrew/non-default binary: --command has the app's GUI PATH, so wrap in a login shell (or use an absolute path); bare "htop" exits 127
hangarctl session new --command "zsh -lc 'make test'" --wait   # HOLD the row open after the command exits (press any key to close) so its final output stays readable; --wait needs --command
```

Create a session pre-named (label set at creation, no follow-up rename):

```bash
hangarctl session new --name "myhost" --command "ssh user@host"
```

Open a session in a named workspace, creating the workspace once and reusing it after (idempotent — no
duplicate "servers" workspace on repeated calls):

```bash
hangarctl session new --workspace-name servers --create-workspace --name "myhost" --command "ssh user@host"
```

Create a session in the background — do NOT switch to it. The current selection and keyboard focus stay
put; the new session appears in the sidebar but is not `active` in `tree` (the read-back). It is the
inverse of the overlay's `--follow`:

```bash
hangarctl session new --cwd "$HOME/project" --no-select
```

## Duplicate a session (a second shell in the same directory)

`session duplicate` creates a fresh session — a plain login shell — in the SAME workspace as the target,
directly AFTER it, rooted at the target's focused-pane cwd, then selects + focuses it and prints the new
id. ONLY the directory carries over: no custom name, `--command`, split, scratch, status, flag, font size,
or background. It is `session new --cwd <source cwd> --after <source>` in one atomic round-trip, except
that a remote source's cwd goes through the local rule first (an existing local directory is kept,
anything else becomes home), and the control half of the sidebar row's **Duplicate Session**
context-menu item.

```bash
hangarctl session duplicate                                    # a second shell beside the current session, same cwd
sid=$(hangarctl session duplicate --target 3f2a --json | jq -r '.result.id')
hangarctl session type $'npm run dev\n' --target "$sid"        # run something in the copy, source left alone
```

Read it back off `tree` — there is no new tree field: the duplicate's node appears directly after its
source, carrying the source's focused-pane cwd. That equals the source node's `tree.cwd` for a non-split
session (and a split focused on its primary pane); for a split focused off its primary the source node's
`tree.cwd` reports the primary while the duplicate carries the focused pane's directory, so compare against
the pane you duplicated from; for a remote source the duplicate carries that cwd after the local rule, so
it can read as home.

## Build a small layout

```bash
ws=$(hangarctl workspace new "build" --json | jq -r '.result.id')
a=$(hangarctl session new --workspace "$ws" --cwd "$HOME/proj" --json | jq -r '.result.id')
hangarctl session rename "server" --target "$a"
hangarctl session split on --axis horizontal --target "$a" # second shell below the primary
hangarctl session resize --split-ratio 0.7 --target "$a"   # top pane gets 70% (prints 0.700)
b=$(hangarctl session new --workspace "$ws" --json | jq -r '.result.id')
hangarctl session rename "logs" --target "$b"
```

## Place a session next to another instead of appending

`session new` appends at the end of the workspace by default. `--after`/`--before` place it directly
after/before an anchor session in one round-trip — no `move --to up` walk. The anchor is a session
address (id / unique prefix / `active`) and carries its own workspace, so it names the destination
itself (mutually exclusive with `--workspace`/`--workspace-name`).

```bash
# the headline case: create right after the current session
hangarctl session new --after active

# create right before a specific session (by unique prefix)
hangarctl session new --before 3f2a --name "notes"
```

`session move` gains the same placement mode. Relocate a session and slot it after/before an anchor —
wherever the anchor lives, even in another workspace — in one shot, with no visible row-by-row shuffle:

```bash
# move the current session to sit right after another (cross-workspace if the anchor is elsewhere)
hangarctl session move --after 3f2a --target active
hangarctl session move --before "$logs" --target "$server"

# move several sessions together as one ordered block
hangarctl session move "$ws" --target "$server" --target "$logs"
hangarctl session move --after "$anchor" --target "$server" --target "$logs"

# close several sessions with one grace-period undo
hangarctl session close --target "$server" --target "$logs"

# close one session with ⌘W's undo grace: undo inside it brings the running shell back
hangarctl session close --target "$server" --undoable
```

`--after`/`--before` are mutually exclusive with each other, with `--to`, and with a destination
workspace — the anchor already picks the workspace. Repeated `--target` is only for workspace and
after/before placement, not `--to up|down|top|bottom`.

## Resize the split divider from a keybinding

The divider is otherwise mouse-only — drag it, or double-click it for an even split. There is no built-in
resize action for any other fraction, so bind keys to the CLI
with `command "<name>" <chord> <shell…>` custom actions in `keymap.conf` (then `hangarctl keymap reload`):

```conf
# grow/shrink the left pane by 5% per press; cmd+ctrl+0 resets to an even split
command "grow left pane"  cmd+ctrl+l hangarctl session resize --grow-left 0.05
command "grow right pane" cmd+ctrl+h hangarctl session resize --grow-right 0.05
command "even split"      cmd+ctrl+0 hangarctl session resize --split-ratio 0.5
```

`--split-ratio` is absolute (0..1); `--grow-left`/`--grow-right` are relative nudges. All clamp to
0.05..0.95 and print the applied fraction.

## Run a program in a blocking overlay and read its status

`--block` waits for the program to exit and makes hangarctl exit with the program's status. The
program renders normally in the overlay; read its OUTPUT from the program's own output file.

Pass `--target "$HANGAR_SESSION_ID"` so the overlay attaches to YOUR (the calling) session. Without
`--target` it opens on whatever session is currently active — so if the user has moved to another
session or workspace, an agent (e.g. running revdiff) pops a blocking full-pane overlay on the WRONG
session. Always target your own session for these examples.

```bash
hangarctl session overlay open "revdiff HEAD~3 --output /tmp/notes.md" --target "$HANGAR_SESSION_ID" --block   # this session
echo "exit status: $?"
cat /tmp/notes.md
```

Floating panel variant (session stays visible behind it). Like a full overlay it opens in the background
without switching the user; add `--follow` when you want the user pulled to the overlay:

```bash
hangarctl session overlay open "zsh -lc 'htop'" --target "$HANGAR_SESSION_ID" --size-percent 70   # login shell so Homebrew's htop is on PATH; bare "htop" flashes open then vanishes (exit 127)
# tint the overlay pane so it stands out from the session behind it:
hangarctl session overlay open "revdiff HEAD~3" --target "$HANGAR_SESSION_ID" --size-percent 80 --background-color "#2a1a3a"
# switch the user to the target as it opens:
hangarctl session overlay open "revdiff HEAD~3" --target "$HANGAR_SESSION_ID" --size-percent 80 --follow
# resize the open overlay in place (the program keeps running): shrink to a floating panel, then back to full
hangarctl session overlay resize --size-percent 60 --target "$HANGAR_SESSION_ID"
# keep the 60% width but make the panel 240pt tall; read the laid-out size back as overlayWidth/overlayHeight
hangarctl session overlay resize --height 240 --target "$HANGAR_SESSION_ID"
hangarctl session overlay resize --full --target "$HANGAR_SESSION_ID"
# ... later
hangarctl session overlay close
```

Manual open + poll for status instead of `--block`:

```bash
hangarctl session overlay open "make test" --target "$HANGAR_SESSION_ID"   # this session
hangarctl session overlay result --json   # errors "still running" until it exits, then result.exitCode
```

## Ask for a choice with an HTML page, and switch sessions from one

A page is a richer `pick`: write the rows, open it with `--block`, and read the answer. The page needs no
JavaScript; Hangar handles the `data-hangar` tags.

```bash
page=$(mktemp /tmp/branchesXXXXXX)
{
  echo '<title>Pick a branch</title>'
  git for-each-ref --format='%(refname:short)' refs/heads | while read -r b; do
    esc=$(printf '%s' "$b" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/"/\&quot;/g')
    printf '<form data-hangar="session.overlay.submit"><input type="hidden" name="value" value="%s"><button>%s</button></form>\n' "$esc" "$esc"
  done
} > "$page"
if out=$(hangarctl session overlay open --html "$page" --block --target "$HANGAR_SESSION_ID" --follow); then
  branch=$(printf '%s' "$out" | jq -r .value)
fi
rm -f "$page"
```

Exit 2 means the user closed the page without choosing. For a switcher that stays current, open a page with
`--js` that builds its rows from `hangar.request('tree')` and switches with
`hangar.request('session.select', {target: id})`; rows written into a no-JS page are a snapshot.

## Read what the user highlighted inside an overlay

`session copy` and `session text` address the pane the overlay COVERS, so a selection the user made in
the overlay reads as `no selection` there and `session text --pane right` returns the shell underneath.
`session overlay copy`/`text` read the covering surface instead:

```bash
hangarctl session overlay copy --target "$HANGAR_SESSION_ID" --json   # result.text = the overlay's selection
hangarctl session overlay text --target "$HANGAR_SESSION_ID" --lines 40
```

Both take the overlay family's `--pane left|right` for a pane-scoped overlay; omit it for the
session-wide one.

A chord bound to a custom command gets this for free — `$AGT_SELECTION` already carries the selection of
the surface the chord fired in, the overlay included, while `$AGT_PANE` keeps naming the pane underneath
so the reply routes back with `session type --pane`:

```bash
# keymap.conf: command "note" ctrl+a>n ...
printf '%s' "$AGT_SELECTION" > /tmp/note.txt
hangarctl session type "see /tmp/note.txt" --target "$AGT_SESSION_ID" --pane "$AGT_PANE"
```

Reach for `session overlay copy` when the read is NOT chord-driven — an agent polling from outside, or a
script that needs the selection some time after the fact.

## Cover only your own pane, leaving the user's other pane usable

`--pane left|right` scopes the overlay to ONE split pane instead of the whole session. A newly spawned
shell can pass `$HANGAR_PANE` so the overlay appears over its pane while the user keeps working in the
sibling one:

```bash
hangarctl session overlay open "revdiff HEAD~3" --target "$HANGAR_SESSION_ID" --pane "$HANGAR_PANE"
```

This works on a fresh non-split session, which reports `HANGAR_PANE=left`, so there is no need to check the
split state first. Three cases still need care: `HANGAR_PANE` is a spawn role and may be stale after a pane
promotion or `session swap`; it is `scratch` in the scratch terminal, which `--pane` rejects as a usage
error; and a shell in the left pane of a session whose split is hidden with the right pane focused reports
`left` while only the right pane is on screen, so the open is refused with `pane not visible`. Fall back to
a session-wide overlay when the current role is uncertain or the pane-specific open fails.
Left and right are independent — both may be open at once, each with its
own `--background-color` — and a pane overlay is always full-pane, so `--size-percent` is rejected with
it. `--wait`, `--block`, `--cwd` and `--follow` behave exactly as they do for a session-wide overlay;
`close` and `result` take the same `--pane`:

```bash
hangarctl session overlay result --target "$HANGAR_SESSION_ID" --pane "$HANGAR_PANE" --json
hangarctl session overlay close --target "$HANGAR_SESSION_ID" --pane "$HANGAR_PANE"
```

Read the open panes back from `paneOverlays` in `tree --json`. Opening on a pane that is not on screen
errors `pane not visible` — a shown split renders both panes, a hidden one only the focused pane, so the
refused one is the pane without focus; hiding the split afterwards is fine, the program keeps running and
reappears when the split comes back.

## Show an image inline

To show the user an image (a generated favicon, a chart, a preview), run the bundled
`scripts/show-image.sh` with the image path. It opens an overlay (a real terminal) and renders the
image there via the kitty graphics protocol, which ghostty draws natively — no kitty binary and no
external image tool, just `base64` + `printf`. An optional second argument sets the panel size percent
(default 60):

Resolve the script against the directory this skill was loaded from — it sits beside `SKILL.md` in
every install layout (plugin cache or the app's `~/.claude/skills/hangar/` / `~/.codex/skills/hangar/`):

```bash
bash <this-skill-directory>/scripts/show-image.sh /abs/path/to/img.png 60
```

The image shows in a floating overlay over the active session; dismiss it with Enter in the panel or
`hangarctl session overlay close`. Do NOT emit graphics escapes to your own tool stdout (the harness
escapes the control bytes) and do NOT run an image viewer in your tool shell (no controlling
terminal) — the overlay's real terminal is what renders.

The script scales the image to the overlay and centers it, up or down, preserving aspect ratio, so
there is no need to resize a large screenshot first. Only when the terminal does not answer the
geometry query does it fall back to drawing at native pixel size in the top-left corner.

Tiny images (a favicon) upscale smoothly, which blurs the pixels. To keep them crisp, enlarge with
nearest-neighbor first:

```bash
magick favicon.png -filter point -resize 256x256 /tmp/big.png
```

Outside Hangar (`HANGAR_ENABLED` unset) there is no overlay — fall back to `open img.png` (Preview).

## Set a background watermark or color

A persistent backdrop behind the terminal grid (distinct from `show-image.sh`, which is a transient
overlay). An image or rasterized-text watermark (auto-fitting the window, re-fitting on resize), or a
solid terminal background color — per session, or per pane with `--pane`. The session default and left/right
pane labels survive a relaunch; a scratch label ends with its scratch terminal.

```bash
# rasterized text watermark on this session, faint
hangarctl session background text "STAGING" --color '#ff5500' --opacity 0.15 --target "$HANGAR_SESSION_ID"

# an image (PNG/JPEG), scaled to cover the window
hangarctl session background image /abs/logo.png --fit cover --opacity 0.2 --target "$HANGAR_SESSION_ID"

# a solid background color — e.g. mark a PROD session so it can't be mistaken for a scratch one
hangarctl session background color '#3a0d0d' --target "$HANGAR_SESSION_ID"

# remove it
hangarctl session background clear --target "$HANGAR_SESSION_ID"

# label each agent of a two-agent split; a pane override wins over the session default
hangarctl session background text "DRIVER" --opacity 0.12 --pane left --target "$HANGAR_SESSION_ID"
hangarctl session background text "PEER" --opacity 0.12 --pane right --target "$HANGAR_SESSION_ID"
hangarctl session background clear --pane right --target "$HANGAR_SESSION_ID"   # back to the default
```

`--opacity` is 0.0–1.0; `--fit` is `contain` (default) / `cover` / `stretch` / `none`; `--position` is
`center` (default) or an edge/corner anchor. An image/text watermark renders the pane opaque (overriding
window translucency), so it is always visible; a `color` takes no opacity and honors the Settings window
translucency (solid when off, blurred/translucent when on).

## Toggle the scratch terminal

A third per-session full-coverage shell. Hide keeps it alive; `exit` in it recreates on next show.

```bash
hangarctl session scratch on        # show; a --target that is not on screen stays unselected
hangarctl session scratch on --target "$HANGAR_SESSION_ID" --follow   # show and switch to it
hangarctl session scratch off       # hide, shell stays alive
hangarctl session scratch toggle
hangarctl session scratch on --command "zsh -lc 'lazygit'"   # run a program instead of a shell (run-once); login-shell wrap so Homebrew's PATH is found (bare "lazygit" exits 127)
```

## Drive the quick terminal

The quick terminal is the window's throwaway overlay (not in the session tree). Show it, type into it,
and read it back — the twins of `session type`/`session text`, but always the frontmost window's quick
terminal (no `--target`/`--pane`).

```bash
hangarctl quick show                                    # drop the overlay over whatever is active
hangarctl quick type 'ls -la'$'\n'                      # inject keystrokes (\n runs it)
echo "some payload" | hangarctl quick type --stdin      # pipe stdin in (e.g. a paste helper)
hangarctl quick text --all                              # read its screen + scrollback back
hangarctl tree --json | jq '.result.tree.quickVisible'  # is it open right now?
```

## Flag a working set and view just the flagged sessions

Flag a few sessions across workspaces, then flip the sidebar to the flagged view: one flat list with each
row labeled `session : workspace` (or by session name alone under the `plain` layout), or, under the tree
layout, the flagged sessions nested under their workspace rows. The flag is durable (persisted per session); `sidebar mode` is per-window; the layout is
app-wide.

```bash
hangarctl session flag on --target "$HANGAR_SESSION_ID"   # flag this session
hangarctl session flag on --target a1b2                   # flag another (any workspace)
hangarctl sidebar mode flagged                            # show only the flagged sessions
hangarctl sidebar flagged-layout tree                     # nest them under workspace rows, in every window
hangarctl sidebar flagged-layout plain                    # or one flat list of session names, no workspace suffix
hangarctl session go --to next                            # in flagged mode, nav steps the flagged set only
hangarctl session flag move --target c3d4 --before a1b2   # flat/plain order: put c3d4 right above a1b2
hangarctl sidebar mode tree                               # back to the full tree
hangarctl session flag clear                              # unflag everything in the window
```

## Acknowledge a driven session's notifications without stealing focus

An orchestrator relaying a session's output elsewhere (Telegram, another agent) fires `notify` to signal
"your turn", which raises the session's red unseen badge. Nothing normally clears that badge except
typing in the session (as Settings ▸ Notifications ▸ Badge reset allows) or visiting it, which pulls the selection to it. `session seen` clears it in place, so the badge
stays a real attention signal on the sessions a human tends while the driven ones stay clean.

```bash
hangarctl notify "your turn" --target "$SID"             # raises the unseen badge (body is positional)
hangarctl tree --json | jq '.result.tree.workspaces[].sessions[] | {id, unseen}'  # read the counts
hangarctl session seen --target "$SID"                   # clear it, selection/focus unchanged
```

## Focus a single workspace

Collapse the sidebar tree to one workspace's sessions (hiding the others), with the full tree one
command away. `on` replaces the marked set with this workspace and applies the filter; `off` unmarks it,
which switches the filter off as the set empties. Per-window and persisted; orthogonal to
`sidebar mode`. While the filter is applied, `session go` navigation is scoped to the marked workspaces'
sessions; suspending it restores stepping over all sessions.

Every mode acts on `--target`, which defaults to `active` — the CURRENT workspace: one that holds the
target because you created it in the foreground or ran `workspace select` on it while it was empty, else
the selected session's, else the last. That is not whatever the previous line addressed, so always name
the workspace you mean. Focusing another workspace hides a target-holding one and hands targeting back,
so `active` here and `active` a line later can differ.

**These commands MOVE the selection when they leave it invisible**, selecting the most recently used
session still visible instead: `workspace focus on`, a narrowing `toggle`, a `workspace focus off` whose
remaining members keep the filter applied, `workspace filter on`, both `sidebar mode` flips, and
`session flag off` on the selected session while the flagged view is up with other flagged sessions left.
Other commands do NOT: a plain `session new` or a `session select` of an unflagged session in FLAGGED
mode makes it active while the flagged list renders no row for it.

A view with NOTHING visible is the exception — nowhere to move to, so the selection stays. The same
commands repair it, so `session flag on` into an empty flagged view and `workspace focus add` of a
populated workspace while only empty ones are marked move the selection too. `session flag clear` never
does, and neither does `session new --no-select`.

Re-read `tree` after any command that changes what is visible, before using the default `active` target.

```bash
hangarctl workspace focus on --target "$HANGAR_WORKSPACE_ID"  # zoom to this workspace
hangarctl workspace focus toggle --target a1b2                # replace-toggle onto another workspace
hangarctl workspace focus off --target a1b2                   # unmark it; the tree comes back
```

## Build, read back, and restore a multi-workspace working set

`workspace focus add` MARKS a workspace without switching the filter on, so a set is built member by
member with the whole tree still on screen and applied ONCE with `workspace filter on`. `workspace
filter off` suspends it WITHOUT losing the set, so peeking at everything and coming back costs one call
each way. Membership reads back per workspace as `focused`, the flag as the tree-level
`workspaceFilter`, and a workspace row renders iff
`sidebarVisible && ((sidebarMode == "tree" && (!workspaceFilter || focused)) || (sidebarMode == "flagged" &&
sidebarFlaggedLayout == "tree" && one of its sessions is flagged))` — no workspace row renders at
all with the sidebar hidden or under the flat flagged list, and the flagged tree ignores the filter; in `tree`
mode with the filter off the whole tree is on screen regardless of membership, and only with the filter
on does visibility narrow to the members. `filter on` with nothing marked is refused, so an applied
filter always has a visible member and the pair can never disagree with what is on screen.

```bash
hangarctl workspace focus add --target a1b2      # mark; the tree stays fully visible
hangarctl workspace focus add --target c3d4      # mark a second one, still nothing hidden
hangarctl workspace filter on                    # now show only the two marked workspaces

# record the working set before changing it (one tree read for both fields)
tree=$(hangarctl tree --json)
marked=$(printf '%s' "$tree" | jq -r '.result.tree.workspaces[] | select(.focused) | .id')
was=$(printf '%s' "$tree" | jq -r '.result.tree.workspaceFilter')

hangarctl workspace filter off                   # peek at the whole tree; the set survives
hangarctl workspace filter on                    # back to the same two workspaces

# restore an earlier set exactly: clear, re-mark, then re-apply only if it was applied
hangarctl workspace filter off
for ws in $(hangarctl tree --json | jq -r '.result.tree.workspaces[] | select(.focused) | .id'); do
  hangarctl workspace focus off --target "$ws"
done
for ws in $marked; do hangarctl workspace focus add --target "$ws"; done
if [ "$was" = "true" ]; then hangarctl workspace filter on; fi
```

## Expand or collapse the sidebar tree

Open every workspace at once, or collapse all but the current one (the same resolution as
`--target active`, which stays expanded and scrolled into view) to cut clutter. Defaults to the frontmost window; pass
`--window` to target any open window. A no-op under the flat flagged list. In either tree layout both
apply to all workspaces, including those the view omits.

```bash
hangarctl sidebar expand                                 # expand every workspace (frontmost window)
hangarctl sidebar collapse                               # collapse all but the active workspace
hangarctl sidebar collapse --window "$HANGAR_WINDOW_ID"  # collapse a specific window's sidebar
```

## Build a collapsed workspace and fill it quietly

Collapse or expand ONE workspace by id (the per-workspace pair, unlike `sidebar expand`/`collapse` which
act on all of them). Create a workspace already collapsed with `workspace new --collapsed`, then add
sessions with `session new --no-select` so it never opens or steals the current selection — the example
for staging a batch of sessions out of the way. Read the open/closed state back from the tree workspace
node's `collapsed` flag (`true` when collapsed, omitted when expanded).

```bash
ws=$(hangarctl workspace new "batch" --collapsed --json | jq -r '.result.id')
for dir in ~/a ~/b ~/c; do
  hangarctl session new --cwd "$dir" --workspace "$ws" --no-select   # added, but the workspace stays shut
done
hangarctl workspace expand --target "$ws"    # open it when you want to see the staged sessions
hangarctl workspace collapse --target "$ws"  # fold it away again

# toggle: read the flag first, then flip
collapsed=$(hangarctl tree --json | jq -r --arg w "$ws" '.result.tree.workspaces[] | select(.id==$w) | .collapsed // false')
[ "$collapsed" = true ] && hangarctl workspace expand --target "$ws" || hangarctl workspace collapse --target "$ws"
```

## Copy a selection and reuse it

`session copy` returns the selection as text (it does not use the system clipboard). Pipe it onward.

```bash
sel=$(hangarctl session copy --json | jq -r '.result.text')
hangarctl session type "$sel" --target "$other"
```

`session select-all` selects the whole buffer, then `session copy` reads it back (or use `session text --all`):

```bash
hangarctl session select-all --target "$other"
buf=$(hangarctl session copy --target "$other" --json | jq -r '.result.text')
```

`session paste` pastes the system clipboard into a session — the socket analogue of ⌘V:

```bash
printf 'deploy staging' | pbcopy
hangarctl session paste --target "$other"   # lands at the prompt, not submitted
```

`--pane` picks which pane it lands in, so multi-line text can reach a split or the scratch terminal
without `session type` submitting it line by line:

```bash
pbcopy < notes.md
hangarctl session paste --pane right --target "$other"
hangarctl session text --pane right --target "$other" --json | jq -r '.result.text' | tail -3
```

## Read a session's buffer as text

`session text` returns the terminal buffer as plain text in `result.text` — the visible screen by
default, the whole scrollback with `--all`, or the last N lines with `--lines N`. Pipe it into
`grep`/`fzf` to extract URLs, paths, etc.

```bash
hangarctl session text                         # the visible screen of the focused pane
hangarctl session text --lines 50              # the last 50 lines of the buffer
hangarctl session text --pane right            # the split pane (errors if there is no split)
hangarctl session text --pane-id "$HANGAR_PANE_ID" # this shell's terminal, even after a swap
hangarctl session text --pane scratch --all    # the scratch terminal's full buffer, even while it's hidden
# drive the split pane's terminal by its stable id, wherever a swap moves it; an empty id counts as no id
# and reaches the default pane, so stop when the lookup finds none (no split, or the session is in another window)
id=$(hangarctl tree --json | jq -er --arg s "$HANGAR_SESSION_ID" \
  '.result.tree.workspaces[].sessions[] | select(.id == $s) | .surfaces[] | select(.kind == "right") | .paneID | select(. != null and . != "")') &&
  hangarctl session text --pane-id "$id" --target "$HANGAR_SESSION_ID" --lines 5 &&
  hangarctl surface cursor --pane-id "$id" --target "$HANGAR_SESSION_ID" &&
  hangarctl session type $'make test\n' --pane-id "$id" --target "$HANGAR_SESSION_ID"
# extract every URL from the full scrollback:
hangarctl session text --all --json | jq -r '.result.text' | grep -oE 'https?://[^ ]+'
```

`--pane scratch` reads (and `session type --pane scratch` writes) the session's scratch terminal whether
or not it is on screen, since its shell is kept alive when hidden. Handy for "I ran a deploy in the
scratch, read its output and tell me what broke" without leaving the scratch open:

```bash
hangarctl session scratch on                             # open the scratch once so it exists
hangarctl session type $'./deploy.sh\n' --pane scratch   # run it in the scratch (even after you hide it)
hangarctl session text --pane scratch --all              # read the result back
```

## Search the terminal scrollback

`session search` opens a search bar over the focused terminal and highlights matches in the live
output. It returns the "N of M" counter; step matches with `--next`/`--prev`, close with `--close`.

```bash
hangarctl session search "error"          # highlight matches, print the counter (e.g. "1 of 7")
hangarctl session search --next           # step to the next match
hangarctl session search --prev           # step back
n=$(hangarctl session search "warn" --json | jq -r '.result.count')   # how many matches
hangarctl session search --close          # close the search bar
```

## Notify the user in a specific session

```bash
hangarctl notify "build finished" --title "CI"                 # active session
hangarctl notify "tests failed" --target "$sid"               # a specific session
```

## Wait for a session status

From a project directory the agent already trusts, start a worker there and block until its agent
finishes or asks for input, giving up after ten minutes:

```bash
id=$(hangarctl session new --cwd "$PWD" --command "zsh -lc 'claude \"fix the failing tests\"'" --no-select --json | jq -r '.result.id')
status=$(hangarctl session wait --target "$id" --until completed --until blocked --timeout 600)
case $? in
  0) echo "worker $status" ;;
  2) echo "worker session closed" ;;
  124) echo "worker timed out" ;;
  *) echo "wait failed" ;;
esac
```

The wait returns at once when the status already matches, so a worker that finished before the call is
not missed. That also means a reused session still showing the previous run's `completed` matches
immediately: wait for `active` first when the session is not fresh.

## Relay accepted notifications

The notification event exists even when desktop banners are disabled. Forward each accepted event as
NDJSON to another process without parsing human output:

```bash
hangarctl events --json --kind notify |
  jq --unbuffered -c '{at: .ts, window, workspace, session, title: .payload.title, body: .payload.body}' |
  ./notification-relay
```

Foreground OSC notifications suppressed by Hangar do not appear in this stream.

## Clean up after sessions close

Lifecycle events follow visible tree membership. A soft close emits `session.closed` immediately, and
an undo later emits `session.created` for the same id. Delay irreversible cleanup if undo matters.

```bash
hangarctl events --json --kind session.closed |
  jq --unbuffered -r '.session' |
  while IFS= read -r sid; do
    ./release-session-resources "$sid"
  done
```

The stream does not say what closed a session: a closed row, another client's `session.close`, and the
exit of a `session.new --command` process are identical in it. Creating that session with `--wait`
removes the third, parking the row on the exit prompt rather than closing it, so a `session.closed`
under `--wait` is always a person or a client. App quit
emits no `session.closed` at all, since window teardown is skipped while terminating.

For resumable consumers, save the `run` and `next` fields from raw `events.read` batch responses and
restart with `hangarctl events --run "$run" --after "$next" --json`. The streaming JSON lines are bare
events and do not include the run id. If the command reports `event run changed`, `event cursor
expired`, or `event cursor is ahead of the current sequence`, stop loudly. Rebootstrap only after the
caller accepts that events may have been lost; never replace the cursor automatically.

## Agent status glyph

```bash
hangarctl session status active --blink --target "$HANGAR_SESSION_ID"   # working
hangarctl session status completed --auto-reset --target "$HANGAR_SESSION_ID"  # one-shot done flash
hangarctl session status blocked --sound default --target "$HANGAR_SESSION_ID" # needs input, with a beep
hangarctl session status completed --sound Glass --target "$HANGAR_SESSION_ID" # done, with a named sound
hangarctl session status blocked --color '#ff0000' --target "$HANGAR_SESSION_ID" # per-call red tint (reverts on next status)
hangarctl session status blocked --shape triangle --target "$HANGAR_SESSION_ID"  # per-call silhouette (reverts on next status)
hangarctl session status blocked --pane right --target "$HANGAR_SESSION_ID"     # a split-pane agent tags its pane (see below)
hangarctl session status idle --target "$HANGAR_SESSION_ID"             # clear
```

## Tag the blocking pane so navigation lands on it

An agent running in a split or scratch pane sets `--pane` so its block survives foreground typing in
another pane and the user's attention navigation lands on the RIGHT pane — the split, or a hidden scratch,
not the main pane. For `blocked` or `completed`, auto-follow and GUI selection through attention-nav
(⌃⌥↑/⌃⌥↓), plain session nav, the command palettes, a sidebar row, or a Dock-menu session row reveal and
focus the tagged pane. An `active` tag is informational and preserves the current pane. The socket
`session go --to next-attention` only steps the selection; it does not move focus into the pane.
Without `--pane` the status is treated as coming from the main (`left`) pane, so a block set from the split
can be wiped by typing in the main pane and the reveal lands on the wrong surface.

The tag also protects a block from the OTHER pane's agent: while the session is `blocked`, a status from a
different pane that is not itself `blocked` leaves the block shown, so an agent reporting `active` after every
tool call cannot erase its neighbour's request for input. It keeps the row active while either pane works,
too: one agent finishing leaves the row on the other's work, and `tree`'s `activePanes` says which panes are
still working. With an agent in each pane, tag both or the second one's ordinary work looks like it comes
from the first.

```bash
# an agent working in the split pane; $AGT_PANE is set in a custom keymap command, else name it
hangarctl session status active --pane right --target "$HANGAR_SESSION_ID"   # working, in the split
hangarctl session status blocked --pane right --target "$HANGAR_SESSION_ID"  # needs input; the user's attention nav focuses the split

# an agent working in the scratch terminal (even while it is hidden)
hangarctl session status blocked --pane scratch --target "$HANGAR_SESSION_ID" # the user's attention nav SHOWS + focuses the scratch

# read back which pane blocked
hangarctl tree --json | jq -r '.result.tree.workspaces[].sessions[] | select(.status) | "\(.name): \(.status) in \(.statusPane // "left")"'
```

`--pane left` (or omitting it) is the main pane. Feed a keymap command's `$AGT_PANE` straight through
(`session status blocked --pane "$AGT_PANE"`) to tag the exact pane a shortcut fired from.

The installed agent-status hook also forwards each surface's `$HANGAR_PANE_ID` as `session status --pane-id`,
a stable per-surface token that resolves to the pane's LIVE slot and overrides a stale `--pane` after a split
survivor is promoted into the main pane and then re-split; scripts driving `--pane` directly need not set it.

## Zoom a terminal surface by control id

```bash
# Fill the window with the active terminal surface; call again to leave zoom.
hangarctl surface zoom

# Zoom the active session's right split pane by id, even if the split is hidden.
sid=${HANGAR_SESSION_ID:?}
surface=$(hangarctl tree --json |
  jq -r --arg sid "$sid" '.result.tree.workspaces[].sessions[]
    | select(.id == $sid)
    | .surfaces[]
    | select(.kind == "right")
    | .id')
hangarctl surface zoom show --target "$surface"
hangarctl surface zoom hide --target "$surface"

# Look at the session under a running overlay and come back; the overlay keeps running meanwhile.
# The explicit id matters: with an overlay open, a bare `surface zoom` zooms the overlay itself.
hangarctl surface zoom toggle --target "surface:$sid:left"

# Read the current zoom back (the zoomed surface's control id; null when nothing is zoomed).
hangarctl tree --json | jq -r '.result.tree.zoomedSurface'
```

`surface zoom` is not `window zoom`: it does not move/resize the macOS window and must not change split
ratios, sidebar state, focus, or split/scratch visibility. Surface ids come from `tree --json`.

## Read a surface's cursor column

```bash
# The active surface's zero-based column, as a plain number.
col=$(hangarctl surface cursor)

# Any addressable surface, including a pane that is not on screen.
hangarctl surface cursor --target "surface:${HANGAR_SESSION_ID:?}:right"

# Under --json it is nested, so a future row would not move it.
hangarctl surface cursor --json | jq -r '.result.cursor.column'
```

Use it as a ONE-WAY signal about the line the caret is on. A column past the prompt proves the line is not
empty. A column AT the prompt proves nothing — the caret may have been moved back over text that is still
there — so never read it as "the input is empty". There is no row: the pinned libghostty exposes no cursor
accessor, and the vertical metrics it does export cannot recover a row that survives a custom
`adjust-font-baseline`. The command reports no field in `tree`, so poll it when you need it.

## Watch several sessions at once in a dashboard grid

The dashboard shows several sessions' live output in one view-only grid — for watching several agents or
builds at once. The cell unit is a session+pane: a non-split session is one cell, and a SPLIT session
shows as TWO cells (its left/primary and right/split panes) unless the id names one with a `:left`/`:right`
suffix, capped at 9 cells total. No cell takes input:
the keyboard navigates a highlight (arrows), Enter jumps into the highlighted session AND focuses that
exact pane then closes, Esc closes. Open it over the socket with explicit session ids, or with `--mru` to
pull the window's most-recently-used sessions automatically. The most-recently-used grid also has a built-in
opener: **⌘⇧G** (the `dashboard` action), **Navigate ▸ Dashboard**, or the command palette's **Dashboard**
toggle it auto-sized (the `dashboard --mru --auto-size` equivalent), so the recent-sessions view needs no
script for the common case.

```bash
# grid of three sessions, cells auto-sized to the grid (shrinking as it grows)
hangarctl dashboard "$a" "$b" "$c" --auto-size

# no ids: fill the grid from the window's most-recently-used sessions (up to 9, fewer if fewer)
hangarctl dashboard --mru --auto-size

# name ONE pane of a split session with a :left/:right suffix, so the pane you don't want costs no cell.
# a bare id still takes every pane, and the suffix works on any head (`active:left`, a unique prefix).
hangarctl dashboard "$a:left" "$b:right" --auto-size

# the payoff for an agent fleet: keep only the pane running the agent, whichever side it sits on.
# `foreground`/`splitForeground` are argv ARRAYS (and null when the pane is at a bare prompt), so join
# before matching — a bare `test` on them errors with "array cannot be matched".
hangarctl dashboard --auto-size $(hangarctl tree --json | jq -r '
  .result.tree.workspaces[].sessions[]
  | if ((.foreground // []) | join(" ") | test("claude|codex")) then "\(.id):left"
    elif ((.splitForeground // []) | join(" ") | test("claude|codex")) then "\(.id):right"
    else empty end')

# an absolute cell font in points instead of --auto-size (the two are mutually exclusive)
hangarctl dashboard "$a" "$b" --font-size 12

# open in a specific window (default is the frontmost)
hangarctl dashboard "$a" "$b" --window "$HANGAR_WINDOW_ID"

# read back what the open dashboard is showing (all null when none is open); members are pane refs
# (`<id>:left`/`<id>:right`), so a split session shows both its :left and :right cells
hangarctl tree --json | jq '.result.tree | {dashboardMembers, dashboardHighlighted, dashboardFontSize, dashboardFontMode}'

# close it (or press Enter/Esc in the grid)
hangarctl dashboard --close
```

The MRU grid is already on **⌘⇧G** (the built-in `dashboard` action). Rebind that chord in `keymap.conf`
with `map <chord> dashboard`. To dashboard a FIXED set of explicit ids instead, bind a `keymap.conf` custom
action (then `hangarctl keymap reload`):

```conf
command "Dashboard build hosts" ctrl+a>d /usr/local/bin/hangarctl dashboard "$WEB" "$API" --auto-size
```

`--mru` is mutually exclusive with explicit ids and `--close`, and errors with `no recent sessions` when
the window has none. The 9-cell cap counts PANES (a split session is two cells), so a set whose panes
exceed 9 keeps the first 9 panes and the response reports the dropped-pane count; ids are deduped. The
dashboard and terminal zoom are mutually exclusive (opening one closes the other). Opening/closing resizes
each pane's pty to/from its cell, so a running program may redraw — view-only means no input, not no
process effect.

## Ask the user to choose from a generated list

Pipe nonblank labels into `pick`. The call blocks until the user chooses or cancels, then prints a bare
JSON result:

```bash
choice=$(
  printf '%s\n' staging production |
    hangarctl pick --prompt "Deploy where?"
)

case $(jq -r '.result' <<<"$choice") in
  picked) jq -r '.id' <<<"$choice" ;;
  custom) jq -r '.query' <<<"$choice" ;;
esac
```

Use a JSON array when ids differ from labels or rows need subtitles. `--allow-custom` adds the current
nonmatching query as a choice:

```bash
jq -n '[
  {id: "stg", label: "Staging", subtitle: "staging.example.com"},
  {id: "prod", label: "Production", subtitle: "production.example.com"}
]' | hangarctl pick --prompt "Deploy target" --allow-custom
```

Typing matches labels only, so consequence text in a subtitle cannot filter one row out and leave its riskier
neighbour alone and preselected. An empty query keeps the order the items were supplied in, so the intended
default can be listed first.

With `--allow-custom` the item list may be empty, which is a rename prompt: `--query` seeds the current
value and the answer comes back as a custom result. `pick` reads stdin unconditionally, so redirect it or
the call blocks:

```bash
hangarctl pick --allow-custom --prompt "Rename to" --query "$current" < /dev/null |
  jq -r 'select(.result == "custom") | .query'
```

The seeded value is offered as the custom row on open; without `--query` nothing is listed until the user
types, since that row needs a nonblank query. Esc cancels.

Open without blocking when another process owns the lifecycle. The picker id reads back from the target
window's tree as `pickPending`; poll the same window, or cancel by exact id:

```bash
pick_id=$(
  printf '%s\n' alpha beta gamma |
    hangarctl pick --no-block --window "$HANGAR_WINDOW_ID" |
    jq -r '.id'
)

hangarctl tree --json --window "$HANGAR_WINDOW_ID" |
  jq -r '.result.tree.pickPending // empty'
hangarctl pick result "$pick_id" --window "$HANGAR_WINDOW_ID"
hangarctl pick cancel "$pick_id" --window "$HANGAR_WINDOW_ID"
```

Add `--follow` to raise a background target window when the picker opens. Without it, the picker waits in
that window without stealing focus.

## Require a yes/no answer in a cleanup hook

A shell cleanup hook can require approval before removing `./build`. This example runs inside
Hangar and requires `jq`. Only an `answered` result with id `yes` reaches the removal:

```bash
#!/usr/bin/env bash
answer=$(hangarctl ask "Remove ./build?" \
  --message "Delete $PWD/build." \
  --button yes=Delete --button no=Keep --default no --destructive yes \
  --window "${HANGAR_WINDOW_ID:?run this hook inside hangar}" --follow \
  --socket "${HANGAR_SOCKET:?run this hook inside hangar}") || exit 1

printf '%s\n' "$answer" |
  jq -e '.result == "answered" and .id == "yes"' >/dev/null || exit 1
rm -rf -- ./build
```

Choosing Keep returns an answer with exit 0, so the id check is required. Esc and Command-W return
`escaped` with exit 3; cancellation returns `cancelled` with exit 2. Both stop the hook.
`ask` leaves the hook's stdin untouched. Omit `--target` to keep the question centered over its window's terminal area
even when the hook's session is not selected. The default `--style terminal` uses the terminal theme;
add `--style gui` for the picker's material appearance and native buttons. The hook's behavior is the same.

## Say what you are doing while the user waits

`session hud` posts a passive panel over a session. The session keeps focus and stays typable under it, so
it is safe to leave up while you compute something. Cover the gap before a picker, then take it down:

```bash
me="$HANGAR_SESSION_ID"

hangarctl session hud "gathering options…" --spinner --detail "scanning branches" --target "$me"

branches=$(git for-each-ref --format='%(refname:short)' refs/heads)

hangarctl session hud update "ready" --detail "pick a branch" --target "$me"
choice=$(printf '%s\n' "$branches" | hangarctl pick --prompt "Check out which branch?")

hangarctl session hud close --target "$me"
```

In a split, keep the panel inside the calling agent's pane and follow that shell if pane roles change:

```bash
hangarctl session hud "gathering options…" --spinner --position bottom-right \
  --pane "$HANGAR_PANE" --pane-id "$HANGAR_PANE_ID" --target "$HANGAR_SESSION_ID"
```

The stable pane ID wins when it resolves. `--pane` is the fallback for older or unknown IDs. The selected
pane supplies the size, 80% cap, anchor, and 10% edge margin; `--sticky` drops the margin and, off center,
lifts the WIDTH cap to 100. A hidden pane keeps its HUD and shows it again
when restored; closing the pane closes its HUD.

`session hud update` repaints in place, no re-spawn and no blink, and it replaces the whole spec: `--detail`,
the spinner, `--text-color`, `--pane`, and `--pane-id` are dropped unless repeated. `--spinner-style bar|braille|circle|blocks|dot` picks the look and
turns the spinner on by itself (`dot` blinks instead of animating, for a panel up for minutes), and an
update may switch style mid-flight; `--spinner-style none` stops it, which is also what a read-back's
`none` echoes back to. `--position` anchors the panel to any of the nine
`top-left|top-center|top-right|center-left|center|center-right|bottom-left|bottom-center|bottom-right`
(default `center`), the same anchors `session background` takes, each off-center one keeping a fixed margin
off that pane edge on its own — a corner is what keeps the panel clear of the text being read, and the bare
`top`/`bottom` still work for the middle column. `--text-color #rrggbb` colors the text (an update can
change it, unlike `--background-color`), and `--size-percent N` overrides the panel's WIDTH; its height
always follows the message.

Read it back from the session node, and note the panel does NOT set `overlay` — one slot, and whichever
occupant holds it is the one that reports:

```bash
hangarctl tree --json | jq -r --arg s "$me" '
  .result.tree.workspaces[].sessions[] | select(.id == $s) | .hud.message // "no hud"'
```

Nothing announces a HUD as an event, so poll `tree` when another process owns the lifecycle. The slot is
shared with `session overlay open`, which means a second `session hud` replaces the first, a
`session overlay open` replaces a HUD, and `session overlay result` over one errors
`no overlay result: the slot holds a hud`. A HUD over
a RUNNING program is refused instead: a message is replaceable, a program is not.

### Keep a status board in a HUD

A controller agent driving worker sessions can keep a short status board in a corner of its own session
instead of printing it into its chat. Write the board to a file and post it with `--markdown`; `--font-size`
keeps it small, and a later `update` replaces it in place:

```bash
cat > /tmp/status.md <<'EOF'
## Workers
- **api** refactor: tests green
- **web** login page: waiting on review
- **infra** migration: *blocked*, needs a token
EOF

hangarctl session hud --file /tmp/status.md --markdown --font-size 11 --position top-right \
  --target "$HANGAR_SESSION_ID"

# after rewriting the file
hangarctl session hud update --file /tmp/status.md --markdown --position top-right \
  --target "$HANGAR_SESSION_ID"
```

An update replaces the whole spec, so repeat `--markdown` and `--position`; the font stays what the panel
opened with. A single newline inside a paragraph is a space, so keep entries as list items or end a line with
two spaces. A board taller than the panel is clipped, its excess rows giving way to a dim `… N more`. The
file is read once per command; nothing watches it, so push each change with an `update`.

## Navigate and manage windows

```bash
hangarctl session go --to next            # step selection to the next session
hangarctl session go --to next-attention  # jump to the next blocked/completed session (plus active when enabled)
hangarctl session go --to 3               # select the third session in sidebar order
hangarctl workspace go --to next          # step a whole workspace, landing on its first session
hangarctl workspace go --to prev          # wraps at both ends; no --target, it is relative
w=$(hangarctl window new "scratch" --json | jq -r '.result.id')
# or park one in the Dock right after creating it (it appears briefly on its way there):
# p=$(hangarctl window new "proj-b" --minimized --json | jq -r '.result.id')
hangarctl window resize "$w" --width 1200 --height 800
hangarctl window move "$w" --x 100 --y 100 --display 0
hangarctl window zoom "$w"                 # maximize-to-screen toggle (call again to restore)
hangarctl window fullscreen "$w"           # native macOS full screen toggle (⌃⌘F / green button)
hangarctl window minimize "$w" on          # park it in the Dock (off restores, toggle flips)
hangarctl window select "$w"               # raise it, un-minimizing if it was parked
hangarctl window go --to next              # raise the next OPEN window, wrapping (next|prev)
```

`window new` returns only once the window is really on screen, so the `window resize` above works on the
first try — no polling needed between them.

## Show one project at a time in a single spot

One window per project, all on the SAME frame, with everything but the current one parked in the Dock.
Switching then looks like switching a tab rather than managing five windows.

```bash
# align every window to the active one's frame, so raising one covers the others exactly
set -- $(hangarctl window list --json | jq -r '.result.windows[] | select(.active) | .geometry
  | "\(.x) \(.y) \(.width) \(.height) \(.display)"')
# select(.open): a closed window has no NSWindow, so resize/move would error on it
hangarctl window list --json | jq -r '.result.windows[] | select(.open) | .id' | while read -r id; do
  hangarctl window resize "$id" --width "$3" --height "$4"
  hangarctl window move "$id" --x "$1" --y "$2" --display "$5"
done

# building the set from scratch: create every project window already parked, then show one
for p in "Project A" "Project B" "Project C"; do
  hangarctl window new "$p" --minimized >/dev/null
done

# show exactly one project: raise it, park the rest
# show exactly one project: raise it, park the rest. `select` opens a closed window, so it needs no
# filter; `park` does — minimize errors on a window that has no NSWindow.
show() {
  hangarctl window list --json | jq -r --arg n "$1" '.result.windows[]
    | select(.name == $n or .open)
    | "\(if .name == $n then "select" else "park" end) \(.id)"' |
  while read -r act id; do
    if [ "$act" = select ]; then
      hangarctl window select "$id"
    else
      hangarctl window minimize "$id" on
    fi
  done
}
```

A minimized window still reports its `geometry`, and `window move`/`window resize` apply to it — a parked
window comes back at whatever frame was written while it sat in the Dock, so re-running the align step
covers parked windows too. The minimized state is live-only — re-run `show` after restarting Hangar.

## Reload the keymap after editing it

```bash
$EDITOR ~/.config/hangar/keymap.conf
hangarctl keymap reload          # prints the parse-diagnostic count (0 = clean)
```

## Change a ghostty setting Hangar does not expose

```bash
$EDITOR ~/.config/hangar/ghostty.conf   # e.g. add: macos-option-as-alt = true
hangarctl config reload                 # apply it; prints the diagnostic count (0 = clean)
```

`ghostty.conf` is scoped to Hangar and overrides the bundled defaults and your global
`~/.config/ghostty/config`; the values Hangar emits from Settings load last and win over matching values
there. Current list: https://naiksoftware.github.io/hangar/docs#ghostty. Full key reference: https://ghostty.org/docs/config

## Set the terminal theme

The app default is the bundled `hangar` theme; the "default ghostty" option (no theme) is ghostty's
own built-in colors.

```bash
hangarctl theme list                         # bundled themes, the current one marked *
hangarctl theme list --json | jq -r '.result.themes[]'   # just the names
hangarctl theme set "Dracula"                # set + persist it app-wide (unknown name errors)
hangarctl theme set "hangar"                 # back to the app default theme
hangarctl theme set                          # ghostty's built-in default (no theme)

# follow the macOS Light/Dark appearance automatically — setting a dark theme starts tracking:
hangarctl theme set --dark "hangar"          # light side seeds from the current theme
hangarctl theme set "Builtin Light"          # while tracking, a name replaces the LIGHT side (pair kept)
hangarctl theme list --json | jq '.result | {sync, light, dark}'   # inspect the sync state
hangarctl theme set --dark none              # stop tracking; the light theme stays as the single theme
```

## Targeting another window's tree

```bash
hangarctl tree --json --window work          # the "work" window's tree (prefix match)
hangarctl session new --window work --cwd "$HOME"
```

## Checking a keybinding actually took effect

`keymap.conf` says one thing; the menu bar dispatches another. After a rebind, verify both.

```bash
hangarctl keymap reload                      # apply the edited file (prints the diagnostic count)
hangarctl keymap list                        # the resolved chords AND the live menu equivalents
```

Confirm one action's chord, then confirm the menu is really carrying it:

```bash
hangarctl keymap list --json \
  | jq -r '.result.keymap.actions[] | select(.action == "close_session") | .chord'
hangarctl keymap list --json \
  | jq -r '.result.keymap.menu[] | select(.chord == "cmd+w") | "\(.menu) > \(.title)  [\(.selector)]"'
```

If those disagree, the keymap is fine and the menu is stale or the chord was taken: SwiftUI rebuilds the
menu lazily (on activation or a key press), so switch away and back before concluding anything, and relaunch if
it persists.

A menu entry with `"enabled": false` holds the chord but is inert — AppKit consumes the key and fires
nothing, including any same-chord sibling. Most File/View/Navigate items disable themselves while a modal
is up, so check this before blaming the binding:

```bash
hangarctl keymap list --json \
  | jq -r '.result.keymap.menu[] | select(.enabled == false) | "\(.chord)  \(.menu) > \(.title)"'
```

Find every chord already in use before picking one for a new binding. All FOUR sources matter: a custom
command's shortcut and a built-in's `alternates` are delivered by the key monitor rather than a menu item,
so they can never show up under `menu`. Miss one and a new `map` line on the same chord makes the next
reload drop that binding. A shortcut holding alternatives is one `|`-joined string, so split it.

```bash
hangarctl keymap list --json | jq -r '
  [ .result.keymap.actions[].chord,
    (.result.keymap.actions[].alternates // [] | .[]),
    (.result.keymap.commands[].shortcut // "" | split("|") | .[]),
    .result.keymap.menu[].chord ] | map(select(. != null and . != "")) | unique | .[]'
```

Read the parse problems in full rather than just their count:

```bash
hangarctl keymap list --json | jq -r '.result.keymap.diagnostics[] | "line \(.line): \(.message)"'
```
