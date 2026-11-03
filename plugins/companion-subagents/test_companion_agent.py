#!/usr/bin/env python3
import json
import os
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parent / "skills" / "companion-subagents" / "companion-agent.py"
FAKE = """#!{py}
import json, sys
from pathlib import Path
d = Path({d!r})
args = sys.argv[1:]
stdin = sys.stdin.read() if "--stdin" in args else None
with open(d / "calls.jsonl", "a") as fh:
    fh.write(json.dumps({{"args": args, "stdin": stdin}}) + "\\n")
if args[:2] == ["session", "new"]:
    print(json.dumps({{"result": {{"id": "CHILD1"}}}}))
elif args[:2] == ["msg", "read"]:
    q = d / "inbox.json"
    print(json.dumps({{"result": {{"messages": json.loads(q.read_text()) if q.exists() else []}}}}))
"""


class CompanionAgentTest(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        fake = self.d / "agtermctl"
        fake.write_text(FAKE.format(py=sys.executable, d=str(self.d)))
        fake.chmod(0o755)
        base = {k: v for k, v in os.environ.items() if not k.startswith("AGTERM")}
        self.env = {**base, "AGTERMCTL": str(fake)}

    def run_cmd(self, args, stdin="", **env):
        return subprocess.run([sys.executable, str(SCRIPT), *args], input=stdin, capture_output=True,
                              text=True, env={**self.env, **env}, check=False)

    def calls(self):
        return [json.loads(line) for line in (self.d / "calls.jsonl").read_text().splitlines()]

    def test_spawn_passes_task_through_quotes_and_resume(self):
        task = "don't break on 'quotes', \"doubles\", $HOME and `ticks`"
        rid = "0" * 8 + "-1111-2222-3333-" + "4" * 12
        who = "You are 'Rex', a \"strict\" reviewer."
        res = self.run_cmd(["spawn", "probe", "--cwd", "/tmp", "--resume", rid, "--agent", "Explore",
                            "--model", "sonnet", "--identity", who],
                           stdin=task, AGTERM_SESSION_ID="LEAD", AGTERM_PANE_ID="PANE")
        self.assertEqual((res.returncode, res.stdout.strip()), (0, "CHILD1"), res.stderr)
        args = self.calls()[0]["args"]
        self.assertEqual(args[:4], ["session", "new", "--parent", "LEAD"])
        argv = shlex.split(args[args.index("--command") + 1])
        self.assertEqual(argv[:2], ["zsh", "-lc"])
        fake_claude = self.d / "bin" / "claude"
        fake_claude.parent.mkdir()
        fake_claude.write_text('#!/bin/sh\nprintf "%s|" "$AGTERM_COMPANION_LEAD" "$AGTERM_COMPANION_FLAGS" "$@"\n')
        fake_claude.chmod(0o755)
        out = subprocess.run(["zsh", "-fc", argv[2]], capture_output=True, text=True, check=False,
                             env={"PATH": f"{fake_claude.parent}:/usr/bin:/bin"}).stdout
        self.assertEqual(out.split("|")[:-1], [
            "LEAD:PANE", "--agent Explore --model sonnet", "--resume", rid, "--agent", "Explore",
            "--model", "sonnet", "--append-system-prompt", who, "-n", "probe", task])

    def test_spawn_rejects_unsafe_identity_tokens(self):
        res = self.run_cmd(["spawn", "p", "--model", "opus[1m]"], stdin="t", AGTERM_SESSION_ID="L", AGTERM_PANE_ID="P")
        self.assertIn("--model", res.stderr)

    def test_spawn_rejects_bad_name_outside_agterm(self):
        self.assertNotEqual(self.run_cmd(["spawn", "x"], stdin="t").returncode, 0)
        bad = self.run_cmd(["spawn", "Bad Name"], stdin="t", AGTERM_SESSION_ID="L", AGTERM_PANE_ID="P")
        self.assertIn("kebab-case", bad.stderr)

    def test_stop_reports_and_wait_reads_acks_and_closes(self):
        self.run_cmd(["stop"], stdin=json.dumps({"session_id": "S1", "cwd": "/w d", "last_assistant_message": "done"}),
                     AGTERM_COMPANION_LEAD="LEAD:PANE", AGTERM_COMPANION_NAME="probe", AGTERM_SESSION_ID="CHILD1",
                     AGTERM_COMPANION_FLAGS="--agent Explore", AGTERM_COMPANION_CONVERSATION="S1")
        sent = self.calls()[-1]
        self.assertEqual(sent["args"], ["msg", "send", "--stdin", "--to", "LEAD:PANE"])
        self.assertEqual(self.run_cmd(["wait", "--timeout", "0"]).returncode, 2)
        (self.d / "inbox.json").write_text(json.dumps([
            {"id": "m0", "body": "unrelated"}, {"id": "m1", "body": sent["stdin"]}]))
        res = self.run_cmd(["wait", "--timeout", "0"])
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("## probe  (resume with: --resume S1 --cwd '/w d' --agent Explore)\ndone", res.stdout)
        tail = [c["args"] for c in self.calls()[-2:]]
        self.assertEqual(tail, [["msg", "ack", "m1"], ["session", "close", "--target", "CHILD1"]])

    def test_stop_is_silent_outside_a_companion_and_for_nested_runs(self):
        self.assertEqual(self.run_cmd(["stop"], stdin="{}").returncode, 0)
        nested = json.dumps({"session_id": "NESTED", "last_assistant_message": "Title: x"})
        self.run_cmd(["stop"], stdin=nested, AGTERM_COMPANION_LEAD="L:P", AGTERM_COMPANION_CONVERSATION="S1")
        self.assertFalse((self.d / "calls.jsonl").exists())

    def test_fresh_spawn_pins_its_conversation_id(self):
        self.run_cmd(["spawn", "p", "--model", "haiku"], stdin="t", AGTERM_SESSION_ID="L", AGTERM_PANE_ID="P")
        line = shlex.split(self.calls()[0]["args"][-2])[2]
        convo = line.split("AGTERM_COMPANION_CONVERSATION=")[1].split()[0]
        self.assertIn(f"claude --session-id {convo} ", line)

    def test_pre_agent_denies_only_in_a_lead(self):
        call = json.dumps({"tool_input": {"subagent_type": "Explore", "model": "haiku", "prompt": "x"}})
        out = json.loads(self.run_cmd(["pre-agent"], stdin=call, AGTERM_SESSION_ID="S").stdout)["hookSpecificOutput"]
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("--agent Explore --model haiku", out["permissionDecisionReason"])
        self.assertEqual(self.run_cmd(["pre-agent"]).stdout, "")
        self.assertEqual(self.run_cmd(["pre-agent"], AGTERM_SESSION_ID="S", AGTERM_COMPANION_LEAD="L:P").stdout, "")
        self.assertEqual(self.run_cmd(["pre-agent"], AGTERM_SESSION_ID="S", AGTERM_COMPANIONS="off").stdout, "")


if __name__ == "__main__":
    unittest.main()
