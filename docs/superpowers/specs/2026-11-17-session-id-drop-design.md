# Drop a session or workspace on a terminal to insert its ids

## Intent

A user drags a sidebar row onto another session's terminal to type that session's id at the cursor,
so they can hand it to an agent or a command without copying it by hand.

## Behavior

- A session row drop inserts the session's id.
- A multi-row session drag (the existing Cmd/Shift selection) inserts each selected session's id in
  visual order, joined by `,`.
- A workspace row drop inserts the ids of all its sessions, companions included, in tree order, joined by `,`.
  An empty workspace inserts nothing.
- A session's id is its Claude Code conversation id while one is known, else its agterm session id.
- A local row's agterm id is `Session.id`; a remote row's is its origin's `remoteSessionID`, the id
  `agtermctl` on that origin addresses.
- The text goes in as a bracketed paste, like every other drop on a terminal.

## Approaches

- **A (chosen): the drag writes the text.** The sidebar's pasteboard item gets a plain-string
  representation beside its private session/workspace type. The terminal already accepts strings,
  so the surface view does not change. Drags outside the app stay refused (`setDraggingSourceOperationMask([], forLocal: false)`), so the ids reach only agterm's own views.
- **B (rejected): the terminal resolves at drop time.** The surface accepts the private types and looks the
  sessions up across windows. More code in the surface view for no gain the user asked for.
- Workspace-row multi-select with Cmd+click was considered and dropped: the user chose to keep session
  multi-select as it is.

## Parts

- `agtermCore`: a host-free formatter from sessions to the inserted string (agent id, else agterm id, `,` join),
  table-tested.
- `Session` gains `agentSessionID: String?`. `SessionAgentMonitor` sets it from `~/.claude/sessions/<pid>.json`
  where it sets `resumeLine` today, sharing the same id validation. Like `resumeLine`, only a new id replaces it while claude runs, and the id stays after claude exits;
  another agent running clears it.
- `ControlSessionNode` gains `agentSessionId`, the read-back of that field (tree, `agtermctl`, skill
  reference, `site/commands.html`).
- Remote rows take `agentSessionId` from the origin's tree through the path that already mirrors origin
  state onto them. An agterm-server host reports none, so its rows fall back to `remoteSessionID`.
- `WorkspaceSidebar+DragDrop` adds the string to the pasteboard item. The flagged views drag session rows only,
  and a workspace drag stays tree-only, as today.

## Non-goals

- Agent ids for Codex, OpenCode and Antigravity: there is no source for them yet. They fall back to the agterm id.
- No new control command: a drop is a GUI gesture; the new read-back field covers scripting.

## Left to the builder

- Where the remote mirror path lives and how it carries the new field.
- The existing surface comment that says a session-row drag is ignored must change.
