// hangar-pi-status-extension
//
// Pi lifecycle extension installed by hangar's Help ▸ Install Agent Status Hooks… command.
// It uses the installed hangar wrapper for session, pane, socket, and CLI resolution, so it is
// a harmless no-op outside hangar.

import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  const wrapper = join(homedir(), ".config", "hangar", "agent-status", "hangar-agent-status.sh");

  async function report(args: string[]): Promise<void> {
    if (!process.env.HANGAR_SESSION_ID) return;
    try {
      await pi.exec(wrapper, args, { timeout: 1_000 });
    } catch {
      // Status reporting is advisory and must never interrupt Pi's agent loop.
    }
  }

  pi.on("agent_start", async () => {
    await report(["active", "--blink"]);
  });

  // `agent_settled` waits for automatic retries, compaction retries, and queued continuations.
  pi.on("agent_settled", async () => {
    await report(["completed", "--auto-reset"]);
  });
}
