# Phone terminal stream (relay mux + libghostty-vt) — design

Status: for approval. Both spikes reported GO-WITH-CAVEATS (throwaway spike dirs in the
session scratchpad). Marked **[call]** = a decision made by the author, not yet confirmed by the user.

## Intent

elis Mobile shows a session as polled plain text (`session.text` every 700 ms, `mobile/lib/screens/session.dart:69`).
It has no colours, no cursor and no real scrolling, and the relay cannot hold a stream open
(`PhoneSession.forward`: one line in, one line out). The phone must draw a real terminal that renders
Claude Code, codex and agy correctly, with native UI around it.

## Goals

- A real, coloured terminal on the phone for Live (zmx) panes: local, attached-from-Mac and elis-server rows.
- Native scrolling with fling through main-screen scrollback.
- One phone link that carries control requests, pushed events and terminal bytes, over TLS and Bluetooth L2CAP.
- Phones that do not ask for the new link keep today's JSON lines unchanged.

## Non-goals

- Native ask/pick sheets on the phone (needs a presenter routing rule; own design later).
- A terminal for non-Live panes: they keep the text view, improved in M1.
- iOS. The Linux (`linux/`) relay: phones paired with it keep the text view; a C++ port later reuses the golden vectors (user decision).

## Anti-goals

- A slow phone that stalls the Mac's pane, the program in it, or grows the zmx daemon's memory.
- A phone that can name a host, daemon or argv the app did not resolve.
- A second copy of the relay's auth, revoke and per-phone order code.

## Approaches

1. **Own mux on the existing relay, carrying zmx attach bytes; libghostty-vt on the phone (picked).**
2. Improve the text view only. Rejected as the end state (no colour, no TUI fidelity); kept as M1.
3. mosh / tmux -CC screen-diff sync. Rejected: duplicates zmx; mosh needs UDP and is GPLv3; neither fits BLE.
4. Agent protocols (ACP, Claude stream-json, codex app-server). Rejected: cannot read agents already in a pane.

## Modes: Watch and Take over (user decision: keep both)

**Watch** (default). The phone's attach never claims; the Mac keeps the lead.
- Fit to phone (`session.grid`, existing) resizes the Mac surface of a pane the Mac leads; the daemon follows the
  leader, so the watched stream arrives laid out for the phone. Unfitted, or on a pane another Mac leads, the
  phone renders the daemon's grid with pinch zoom and pan.
- Input: `session.type` (through `zmx type`, encoded against the program's live keyboard mode) and
  `session.scroll`, as today.

**Take over.** The relay adds a second attach with `ZMX_MANAGED_CLAIM` on a pty sized to the phone. The phone
leads; the Mac pane shows its existing lead cover.
- Input: all of it (keys, paste, mouse wheel, focus) goes as DATA on the vt channel into the claiming attach,
  encoded on the phone by libghostty-vt's encoders against the emulator's current modes. `session.scroll` is
  refused on a covered pane, so wheel events cannot use it here.
- Size: RESIZE frames become `TIOCSWINSZ` on the claiming pty.
- Output still comes from the follower attach; the relay drains the claiming attach's output and scans it only
  for the zmx role report (OSC 2). When the role is no longer leader (the Mac took the lead back), the relay
  sends LEAD `{role}` and the phone returns to Watch.
- The claiming attach is never detached for a resync: that leaves the daemon unowned and the Mac reattaches and
  takes the lead. Leaving Take over closes it on purpose, with that same effect.
- Entering Take over first resets the phone's Fit-to-phone grid (a covered pane refuses `session.grid` anyway).
- elis-server rows need the leadership patch in the server's zmx; M3 verifies it, and a server without it
  refuses Take over with a clear error.

## Protocol model ("link v2")

Upgrade on the existing line protocol: phone sends `{"auth":tok}`, waits for the hello answer, then sends
`{"mux":1}`; the relay answers `{"ok":true,"mux":1}`. **[call: phone waits]** After that both sides speak binary
frames on the same stream. On Bluetooth they ride inside the existing Noise + DEFLATE framing (`BleLink.swift`).

Frame: `u8 kind | u32 channel | u32 len | payload`, big endian, `len` <= 64 KiB.

| kind | dir | payload |
|---|---|---|
| OPEN | phone→relay | JSON `{type:"vt", target, pane?, claim?, cols?, rows?}` |
| OPENED | relay→phone | JSON `{cols, rows}` or `{error}` |
| DATA | both | control/events: JSON lines; vt: VT bytes relay→phone, encoded input phone→relay (Take over only) |
| RESIZE | phone→relay | u16 cols, u16 rows (Take over only) |
| LEAD | relay→phone | JSON `{role}` from the claiming attach's role report |
| CREDIT | both | u32: bytes the receiver accepts more on that channel |
| GRID | relay→phone | u16 cols, u16 rows |
| RESYNC | relay→phone | empty: reset the emulator; the next DATA is a full screen |
| CLOSE | both | JSON `{reason}` |

Channels: 0 = control (today's `{id,cmd,target,args}`; answers matched by `id`; requests may run concurrently),
1 = events (the relay forwards `events.read` rows as they arrive; the phone re-reads `tree` on a tree event) **[call]**,
n >= 2 = one per open vt pane. Scheduler priority control > events > vt. vt credit window 16 KiB on BLE, 256 KiB on TLS.

## Attach model (zmx spike)

zmx has no slow-client cap: a backlog sits in whichever process stops reading. A follower's pty size has no effect,
and the attach stream carries no cols/rows.
- The app resolves the attach: new protocol command `session.attach` **[call]** checks the target is a Live pane in
  the tree and returns the argv (local `zmx attach <daemon>`, or `RemoteSession.attachCommand` with the ssh pool's
  ControlPath for attached and elis-server rows). The relay never builds argv from phone input.
- The relay runs that argv on an openpty, managed and non-claiming (plus the claiming one in Take over), reads it at full speed into a bounded buffer
  (default 512 KiB), and feeds the phone by credit.
- Overflow: drop the buffer, start a fresh follower attach, close the old one, send RESYNC. No lead changes.
- First burst of each attach: the relay's attaches ask zmx for the visible screen only (~10 KB instead of up to
  2.2 MB of scrollback) through a new attach flag in a small patch in `scripts/zmx-patches/` (user decision).
  The phone gets older history by `session.text --lines` on demand, as in M1.
- Grid: the relay reads cols/rows from the `zmx screen` header on open and on RESYNC, from the `session.grid`
  answer when the phone fits, and polls the header once a second while a vt channel is open **[call]**.
- Watchdog: the relay kills an attach process that stops draining.
- A daemon that no leader ever attached to sends no snapshot (only clear + role); the phone shows it empty until output.

## Phone terminal engine (Android spike)

- libghostty-vt at `GHOSTTY_REV` builds unpatched for `aarch64-linux-android` and `x86_64-linux-android`
  (`zig build -Demit-lib-vt`); NDK clang links the static `.a` plus a small C shim into one `libvtshim.so`
  (2.2 MB stripped). Dart binds the shim through `dart:ffi`.
- Fidelity: Claude Code, vim and a shell stress recording match tmux row by row. Parse 289 MB/s, snapshot 32 us.
- Required: a per-row paint cache (the rebuild-every-frame painter missed 60 Hz); honour mode 2026 (RENDER_HOLD);
  colour emoji font first for VS16/ZWJ clusters.
- Terminal query replies the phone's emulator would generate are dropped in Watch (the Mac's surface answers).
  In Take over the phone is the leader's terminal, so it sends them as input.
- Not tested yet: codex, agy (not installed on this Mac). M2 records both and adds them to the fidelity set.

## Control API coverage

- `session.attach [--pane]` (protocol + dispatcher + CLI): the protocol form returns the argv; `elisctl session
  attach <target>` runs it on stdio for scripts and end-to-end tests.
- Read-back: the pane node gains `phoneViewers` (count). Events: `phone.attached`, `phone.detached`, with their
  arguments in `EventFormatter.human`.
- elis-server's own socket: `session.attach` is served there too (it owns the daemons); remote rows on a Mac
  resolve through the origin.

## Where the code goes

- `ElisCore/Sources/ElisCore/PhoneLink/` (new files): frame codec, channel table, credit, scheduler. Pure value
  types, host-free, Linux-safe.
- `elisctlKit/PhoneLink*.swift` (new files): relay side. `PhoneSession` hands the connection to
  `PhoneLinkSession` after `{"mux":1}`; existing files get only small hooks.
- Phone: `mobile/lib/link/` (codec) and `mobile/lib/terminal/` (ffi binding, painter, zoom).
- Golden vectors: one JSON file of frames and frame sequences, read by both the Swift and the Dart tests.

## Migration to the Elis restructure

The Elis branch (`worktree-elis-rename`) moves the app into `macos/`, imports elis as `linux/` and
`mobile/`, and renames elis to Elis by script (`tools/elis/`). A branch still open after its merge runs the
same scripts on itself, then merges master.
- Mac side: branch from `origin/master`. After Elis merges: `restructure.sh` (only phase 1 applies), commit,
  `rename.sh`, commit, `check-names.sh`, `git merge origin/master`. New code in new files keeps conflicts small.
- Phone side: elis `mobile/` has the same path in the monorepo. Work on an elis branch; after Elis
  merges, `git format-patch` it and `git am` it onto a monorepo branch, then `rename.sh`.
  Never merge it into elis `main` after the import: phase 2 does not re-import.
- New identifiers avoid the product name where they can (`PhoneLink`, `"mux"`).

## Milestones

- M1: text view fix on the phone (scrollback on demand, local scroll with fling). No protocol change.
- M2: protocol model: Swift codec + scheduler + golden vectors + tests; Dart codec + same vectors. Record codex/agy.
- M3: zmx visible-screen attach patch; `session.attach` + read-back + events + tests + docs + skill; verify the
  server zmx has the leadership patch.
- M4: relay mux, attach runner, buffer/resync/watchdog; phone terminal view in Watch, local and remote Live rows.
- M5: Take over (claiming attach, input encoders, RESIZE, LEAD), zoom/pan, Fit to phone on the terminal view,
  Bluetooth end-to-end on the emulator.
- M6: Text mode (reflow, live block, command cards) and the mode switcher with auto-pick.
- M7: Chat mode with the first adapters (Claude Code transcript, codex rollout).
- Later: native asks (own design).

## Session view: Chat, Text, Term (user decision 2026-11-18)

A session can be any program: an agent, a shell, any CLI or TUI. The phone draws every session through one
switcher with three modes; each is a layout of data the phone already has, never a guess about the program.
Mockups: the "Elis phone agent UI" design canvas (zsh, Claude Code, agy, vim).

| Mode | Built from | Fits |
|---|---|---|
| Term | the attach stream drawn by libghostty-vt: the exact grid, zoom and pan, key bar | every program; the only mode for full-screen apps |
| Text | the same emulator's main-screen lines, rewrapped to the phone width at a normal font size; rows the program still redraws stay in a pinned live block; one card per command (exit code, duration, folded output) when the shell sends OSC 133 marks, plain lines otherwise | shells, logs, agents that draw on the main screen |
| Chat | a per-program adapter only (Claude Code transcript JSONL, codex rollout) | programs with an adapter |

- Auto-pick, in order: alternate screen → Term; a program with an adapter → Chat; anything else → Text.
- A mode that does not fit is disabled, never hidden. A line under the switcher says why Elis picked the mode.
  A manual pick sticks for the session until Auto is chosen again.
- Chat never interprets the screen: a prompt the program draws (a permission menu, a picker) shows as the live
  rows of the screen with its keys, and the program answers it.
- Elis status, asks and notifications come from Elis, not from the screen, so they look the same in every mode.
- Input in Text and Chat goes through `session.type` (Watch) or the claiming attach (Take over), as in Term.
- Rejected: a separate Blocks mode (the owner could not tell it from Reader; command cards are part of Text) and
  an agent-only graphic UI (sessions are any program).

## Decided by the user (2026-11-18)

1. Linux elis relay: text fallback now, port later.
2. First-burst trim: a small zmx patch (attach flag), not a byte-pattern cut.
3. Scope: terminal-output streaming is approved; `control-api.md:23` changes with M3.
4. Take over stays, beside Fit to phone.
5. Session view: Chat, Text and Term with auto-pick (section above); Term is the fallback, not the goal.

## Notes for the M4 relay (from the M2 review)

M4a settled these. `.claude/rules/control-api.md` (relay mux) owns the relay's behavior and the wire contract
M4b builds on; this list keeps only what is not stated there.

- Caps: channel 0 at 4 MiB of answers waiting; the direct queue (OPENED, RESYNC, GRID, CLOSE) at 256 frames;
  past either, the link closes. Channel 1 is bounded at 256 KiB; the oldest rows are dropped and counted.
- Zmx role titles are filtered from the stream.
- The relay prints one `phone detached` line per open pane before `phone disconnected`, with the app's `attach.paneID`.

Still open for M4b:

- Take over input needs a receive window in the relay (OPEN with `claim` is refused for now).
- OPENED, GRID, LEAD, RESYNC and CLOSE bypass the scheduler, so GRID can overtake queued DATA laid out for the old grid.
- `phone.attached` carries no session id; resolve it at emit time if hooks need it.
- A pane never shown since launch answers `session not realized`; decide whether the phone may watch it.

## Left to the builder

Exact JSON fields of OPEN/OPENED/CLOSE, buffer and credit numbers within the stated ranges, Dart package layout,
poll interval tuning for remote rows.
