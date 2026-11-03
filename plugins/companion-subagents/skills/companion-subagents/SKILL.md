---
name: companion-subagents
description: Run subagents as agterm companion sessions instead of the built-in Agent tool. Use when the Agent tool is denied with a pointer to companion sessions, or when the user asks to run a subagent, worker, helper or teammate in a companion, a visible session, or a sidebar row under this one.
---
<!-- agterm-companion-subagents -->

# Companion subagents

Each subagent is an interactive Claude Code session in an agterm companion under this pane.
The user can watch it and answer its permission prompts. It reports back over the agterm message bus.

`C=~/.claude/skills/companion-subagents/companion-agent.py`

## Spawn

The task goes on stdin. The companion starts with no context from this conversation: name the files,
the goal, what is already ruled out, and the report you want back.

```sh
$C spawn NAME [--cwd DIR] <<'EOF'
<task>
EOF
```

NAME is a short kebab-case label for the sidebar row. Spawn several before you wait to run them in parallel.

Give the companion an identity, the way the Agent tool takes `subagent_type` and `model`:

- `--agent A` runs it as a Claude Code agent definition: a built-in such as `Explore` or `Plan`, or a file
  in `~/.claude/agents/` or the project's `.claude/agents/`. A denied Agent call names the one it asked for.
- `--identity TEXT` appends who it is to its system prompt, for a one-off role with no agent file.
- `--model M` and `--effort E` pick the tier. Always pass `--model`, matched to the task's difficulty;
  a companion without it runs the user's default model, often the most expensive one.

| Task | `--model` |
|------|-----------|
| Hard reasoning: subtle root cause, architecture, adversarial review | `fable` |
| Standard implementation, refactors, writing tests, code review | `opus` |
| Mechanical, well-specified work: documented procedures, builds, focused searches | `sonnet` |
| Rote lookups, file listing, single greps, status checks | `haiku` |

## Wait

```sh
$C wait
```

It blocks until at least one companion ends its turn, prints each reply under `## NAME` with its resume
arguments, and closes those companions. Call it again for the rest. Exit 2 means nobody reported within
540 s: call it again. A companion waiting on a permission prompt has not ended its turn; tell the user
which row needs them.

## Follow up

To continue a finished companion with its context, spawn it again with the resume arguments `wait` printed:

```sh
$C spawn NAME --resume ID --cwd DIR <<'EOF'
<follow-up>
EOF
```

The printed arguments carry `--agent`, `--model` and `--effort`; pass `--identity` again yourself.
Resume only when its earlier context matters. For unrelated work, spawn a fresh companion.

## Rules

- A reply is the companion's own claim. Verify it before you act on it.
- A companion keeps the built-in Agent tool; it never spawns companions.
