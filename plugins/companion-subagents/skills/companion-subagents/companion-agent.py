#!/usr/bin/env python3
"""Run Claude Code subagents as agterm companion sessions that report over the agterm message bus.

spawn NAME [--cwd DIR] [--resume ID] [--agent A] [--model M] [--effort E] [--identity TEXT]
                                       start `claude` in a companion of this pane; the task is read from stdin
wait [--timeout S] [--keep]            block until companions report; print each reply, then close them
pre-agent                              PreToolUse hook: deny the built-in Agent tool inside agterm
stop                                   Stop hook: a companion sends its final reply to its lead
"""
from __future__ import annotations  # /usr/bin/python3 is 3.9

import argparse
import base64
import json
import os
import re
import shlex
import subprocess
import sys
import time
import uuid

LEAD_ENV = "AGTERM_COMPANION_LEAD"
NAME_ENV = "AGTERM_COMPANION_NAME"
FLAGS_ENV = "AGTERM_COMPANION_FLAGS"
CONVO_ENV = "AGTERM_COMPANION_CONVERSATION"
MARK = "agterm-companion "


def agt(*args: str, stdin: str | None = None) -> subprocess.CompletedProcess:
    return subprocess.run([os.environ.get("AGTERMCTL", "agtermctl"), *args], input=stdin,
                          capture_output=True, text=True, check=False)


def decoded(text: str) -> str:
    # base64 keeps quotes in free text away from libghostty's argv split and the login shell alike
    return f"\"$(print -rn -- {base64.b64encode(text.encode()).decode()} | base64 -D)\""


def spawn(name: str, task: str, cwd: str, args: argparse.Namespace) -> str:
    sid, pane = os.environ.get("AGTERM_SESSION_ID"), os.environ.get("AGTERM_PANE_ID")
    if not sid or not pane:
        sys.exit("not inside an agterm pane: AGTERM_SESSION_ID or AGTERM_PANE_ID is unset")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,39}", name):
        sys.exit("NAME must be kebab-case: lowercase letters, digits and dashes")
    if args.resume and not re.fullmatch(r"[0-9a-f-]{36}", args.resume):
        sys.exit("--resume takes the session id that `wait` printed")
    for flag, pattern in (("agent", r"[A-Za-z0-9][A-Za-z0-9:_.-]*"), ("model", r"[A-Za-z0-9][A-Za-z0-9._-]*")):
        value = getattr(args, flag)
        if value and not re.fullmatch(pattern, value):
            sys.exit(f"--{flag} {value!r}: letters, digits and . _ - only")
    if not task.strip():
        sys.exit("empty task: pipe the task text on stdin")
    # identity flags are plain tokens, carried in the env so the report can hand them back for --resume
    ident = " ".join(f"--{f} {getattr(args, f)}" for f in ("agent", "model", "effort") if getattr(args, f))
    # pin the conversation id: hooks inside the companion start nested `claude -p` runs that inherit this env,
    # and only the companion's own conversation may report
    convo = args.resume or str(uuid.uuid4())
    claude = "claude" + (f" --resume {convo}" if args.resume else f" --session-id {convo}") + (f" {ident}" if ident else "")
    if args.identity:
        claude += f" --append-system-prompt {decoded(args.identity)}"
    line = (f"{LEAD_ENV}={sid}:{pane} {NAME_ENV}={name} {FLAGS_ENV}=\"{ident}\" {CONVO_ENV}={convo} "
            f"{claude} -n {name} {decoded(task)}")
    res = agt("session", "new", "--parent", sid, "--cwd", cwd, "--name", name, "--no-select",
              "--command", f"zsh -lc {shlex.quote(line)}", "--json")
    if res.returncode != 0:
        sys.exit(f"agtermctl session new failed: {res.stderr.strip() or res.stdout.strip()}")
    return json.loads(res.stdout)["result"]["id"]


def wait(timeout: float, keep: bool) -> int:
    deadline = time.monotonic() + timeout
    while True:
        res = agt("msg", "read", "--json")
        if res.returncode != 0:
            sys.exit(f"agtermctl msg read failed: {res.stderr.strip() or res.stdout.strip()}")
        msgs = json.loads(res.stdout)["result"].get("messages", [])
        mine = [m for m in msgs if m.get("body", "").startswith(MARK)]
        if mine:
            break
        if time.monotonic() >= deadline:
            print("no companion has reported yet; call `wait` again", file=sys.stderr)
            return 2
        time.sleep(1)
    # ack only companion reports, so other mail for this pane stays queued
    agt("msg", "ack", *[m["id"] for m in mine])
    for m in mine:
        head, _, reply = m["body"].partition("\n")
        meta = json.loads(head[len(MARK):])
        again = f"--resume {meta['resume']} --cwd {shlex.quote(meta['cwd'])} {meta.get('flags', '')}".rstrip()
        print(f"## {meta['name']}  (resume with: {again})\n{reply}\n")
        if not keep and meta.get("session"):
            agt("session", "close", "--target", meta["session"])
    return 0


def stop(event: dict) -> None:
    lead = os.environ.get(LEAD_ENV)
    if not lead or event.get("session_id") != os.environ.get(CONVO_ENV):
        return
    meta = {"name": os.environ.get(NAME_ENV, "companion"), "resume": event.get("session_id", ""),
            "cwd": event.get("cwd") or os.getcwd(), "session": os.environ.get("AGTERM_SESSION_ID", ""),
            "flags": os.environ.get(FLAGS_ENV, "")}
    body = MARK + json.dumps(meta) + "\n" + (event.get("last_assistant_message") or "")
    res = agt("msg", "send", "--stdin", "--to", lead, stdin=body)
    if res.returncode != 0:
        print(f"companion report not delivered: {res.stderr.strip()}", file=sys.stderr)


def pre_agent(event: dict) -> None:
    # a companion keeps the built-in tool, so companions never nest
    if not os.environ.get("AGTERM_SESSION_ID") or os.environ.get(LEAD_ENV) or os.environ.get("AGTERM_COMPANIONS") == "off":
        return
    call = event.get("tool_input") or {}
    hint = " ".join(f"--{f} {call[k]}" for f, k in (("agent", "subagent_type"), ("model", "model"))
                    if call.get(k) and call[k] != "general-purpose")
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": (
            "Subagents run as agterm companion sessions here: use the companion-subagents skill"
            + (f", spawning with {hint}" if hint else "") + ". Set AGTERM_COMPANIONS=off to opt out."
        ),
    }}))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sp = sub.add_parser("spawn")
    sp.add_argument("name")
    sp.add_argument("--cwd", default=os.getcwd())
    sp.add_argument("--resume")
    sp.add_argument("--agent", help="a Claude Code agent definition, e.g. Explore or one in ~/.claude/agents")
    sp.add_argument("--model")
    sp.add_argument("--effort", choices=["low", "medium", "high", "xhigh", "max"])
    sp.add_argument("--identity", help="who the companion is; appended to its system prompt")
    wp = sub.add_parser("wait")
    wp.add_argument("--timeout", type=float, default=540)  # under the Bash tool's 600 s ceiling
    wp.add_argument("--keep", action="store_true")
    sub.add_parser("pre-agent")
    sub.add_parser("stop")
    args = ap.parse_args()
    if args.cmd == "spawn":
        print(spawn(args.name, sys.stdin.read(), args.cwd, args))
    elif args.cmd == "wait":
        return wait(args.timeout, args.keep)
    elif args.cmd == "pre-agent":
        pre_agent(json.loads(sys.stdin.read() or "{}"))
    else:
        stop(json.load(sys.stdin))
    return 0


if __name__ == "__main__":
    sys.exit(main())
