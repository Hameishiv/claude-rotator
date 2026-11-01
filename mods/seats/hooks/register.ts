import type { Register } from 'claude-code'

// Runs the rotator scripts directly, so checking seats never costs a model turn.
const SCRIPTS: Record<string, string> = {
  claude: 'C:/Dev/Rotators/claude-cli-account.ps1',
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'seats',
      description: 'Claude rotator seat status, live',
    })
    return next(e)
  })

  on('command.run', { command: 'seats' }, async ($, e) => {
    const which = e.args.trim().toLowerCase() || 'claude'
    const script = SCRIPTS[which]
    if (!script) return { text: 'Usage: /seats' }
    try {
      const r = await $.process.run(['pwsh', '-NoProfile', '-File', script, '--status'], { timeoutMs: 180_000 })
      const out = (r.stdout + (r.stderr ? '\n' + r.stderr : '')).trim()
      return { text: '```\n' + (out || `(no output, exit ${r.exitCode})`) + '\n```' }
    } catch (err) {
      return { text: `seats: ${which} status failed: ${String(err)}` }
    }
  })
}
