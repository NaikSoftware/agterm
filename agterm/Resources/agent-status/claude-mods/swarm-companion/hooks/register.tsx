import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

const companionId = atom({ plugin: 'swarm-companion', key: 'companionId' } as const, null)
const ENDED = new Set(['completed', 'failed', 'killed'])

// Claude names the socket claude-swarm-<its pid>; walk up from this shell to find this session's one.
const OPEN = `
dir="\${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
p=$$
while [ -n "$p" ] && [ "$p" -gt 1 ]; do
  if [ -S "$dir/claude-swarm-$p" ]; then
    exec agtermctl session new --json --no-select --parent "$AGTERM_SESSION_ID" --name subagents --command "tmux -L claude-swarm-$p a"
  fi
  p=$(ps -o ppid= -p "$p" | tr -d ' ')
done
echo "no claude-swarm tmux socket for this session" >&2
exit 1
`

// one open attempt per teammate run: in-process teammates have no tmux socket, and a companion the
// person closed by hand must not come back until the run ends
let hasTried = false

async function syncCompanion($: EngineInterface) {
  const agents = await $.agent.list()
  const isRunning = agents.some(a => a.teammateId && !ENDED.has(a.status))
  const id = await read($, companionId)

  if (isRunning && id === null && !hasTried) {
    hasTried = true
    const ran = await $.process.run(['sh', '-c', OPEN])
    const opened = ran.exitCode === 0 ? (JSON.parse(ran.stdout) as { result?: { id?: string } }).result?.id : undefined
    if (opened) await update($, companionId, () => opened)
    else $.ui.log(`swarm-companion: ${ran.stderr.trim()}`, { to: 'debug' })
  } else if (!isRunning) {
    hasTried = false
    if (id !== null) {
      await update($, companionId, () => null)
      await $.process.run(['agtermctl', 'session', 'close', '--target', id]) // an error just means it is already closed
    }
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    // agtermctl and AGTERM_SESSION_ID exist only inside an agterm pane
    if ((await $.process.run(['sh', '-c', 'test -n "$AGTERM_SESSION_ID"'])).exitCode === 0) {
      $.clock.every(2000, () => void syncCompanion($).catch(() => {}))
    }
    return next(e)
  })
}
