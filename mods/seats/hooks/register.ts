import type { Register } from 'claude-code'

// Runs the rotator scripts directly, so checking seats never costs a model turn. CLAUDE_ROTATOR_DIR names the rotator folder
// (the one holding claude-cli-account.ps1); there is no default, every install puts it somewhere else.
const DIR = (process.env.CLAUDE_ROTATOR_DIR || '').replace(/[\\/]+$/, '')
const SCRIPTS: Record<string, string> = DIR ? { claude: DIR + '/claude-cli-account.ps1' } : {}

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
    if (!DIR) return { text: 'seats: set CLAUDE_ROTATOR_DIR to your rotator folder (the one holding claude-cli-account.ps1).' }
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
