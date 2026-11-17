# Loop Status Active Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a Claude `Stop` with a pending session cron keeps the agterm row `active --blink`.

**Architecture:** one more condition in the Claude status adapter's `Stop` rewrite, read from the payload's `session_crons` array.

**Tech Stack:** bash 3.2 hook script, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-17-loop-status-active-design.md`

## Global Constraints

- The script stays bash 3.2 compatible and reads JSON only through its existing `field` helper.
- `make lint`, `cd agtermCore && swift test` must pass.

## Review Focus

- `session_crons` absent (older Claude Code): `Stop` completes as before.
- `session_crons` is `[]`: `Stop` completes with the caller's flags.
- Cron pending: the rewrite drops `--auto-reset`, as the running-agent rewrite does.

---

### Task 1: Pending cron keeps the row active

**Files:**
- Modify: `agterm/Resources/agent-status/agterm-claude-status.sh` (the `Stop` branch near `running_agent`)
- Test: `agtermCore/Tests/agtermCoreTests/ClaudeStatusHookTests.swift`

- [ ] **Step 1: Write the failing tests**

Add a `crons: String? = nil` parameter to `payload(_:agentID:tasks:)`; it appends `"session_crons":<crons>`.

```swift
@Test func stopWithAPendingCronStaysActive() throws {
    let crons = #"[{"id":"c1","schedule":"*/5 * * * *","recurring":true,"prompt":"p"}]"#
    let result = try run(chain: ["login", "claude"], args: ["completed", "--auto-reset"],
                         input: .pipe(Self.payload("Stop", tasks: "[]", crons: crons)))
    #expect(result.calls == ["active --blink"])
}

@Test func stopWithNoCronCompletes() throws {
    let result = try run(chain: ["login", "claude"], args: ["completed", "--auto-reset"],
                         input: .pipe(Self.payload("Stop", tasks: "[]", crons: "[]")))
    #expect(result.calls == ["completed --auto-reset"])
}
```

- [ ] **Step 2: Run them; the first fails**

Run: `cd agtermCore && swift test --filter ClaudeStatusHookTests`
Expected: `stopWithAPendingCronStaysActive` fails with `["completed --auto-reset"]`.

- [ ] **Step 3: Implement**

`pending_cron()` returns 0 when `field session_crons` is a number greater than 0.
The `Stop` branch becomes `if running_agent || pending_cron; then set -- active --blink`.

- [ ] **Step 4: Run tests; all pass**

Run: `cd agtermCore && swift test --filter ClaudeStatusHookTests`

- [ ] **Step 5: Commit**
