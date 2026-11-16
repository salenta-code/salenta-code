// Befehle im Projektordner ausführen – mit Zeitlimit und gekürzter Ausgabe (Anfang + Ende bleiben sichtbar).

import { spawn } from 'node:child_process'

function clip(s, max = 24_000) {
  if (s.length <= max) return s
  return s.slice(0, max * 0.4) + `\n… (${s.length - max} Zeichen ausgelassen) …\n` + s.slice(-max * 0.6)
}

export function runCommand(command, { cwd, timeoutSec = 120, env = process.env, signal } = {}) {
  return new Promise(resolvePromise => {
    const child = spawn('/bin/bash', ['-c', command], { cwd, env: { ...env, CI: '1', NO_COLOR: '1', FORCE_COLOR: '0' }, stdio: ['ignore', 'pipe', 'pipe'], detached: true })
    let out = ''
    const add = d => { out += d.toString(); if (out.length > 2_000_000) out = out.slice(-1_000_000) }
    child.stdout.on('data', add); child.stderr.on('data', add)
    let timedOut = false
    const kill = () => { try { process.kill(-child.pid, 'SIGTERM') } catch {} ; setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL') } catch {} }, 2000) }
    const timer = setTimeout(() => { timedOut = true; kill() }, timeoutSec * 1000)
    signal?.addEventListener?.('abort', kill)
    child.on('close', code => {
      clearTimeout(timer)
      resolvePromise({ code: timedOut ? 124 : code ?? 1, output: clip(out.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, '')), timedOut })
    })
    child.on('error', e => { clearTimeout(timer); resolvePromise({ code: 127, output: String(e.message), timedOut: false }) })
  })
}

export function shellTools(rt) {
  rt.tool({
    name: 'bash', label: 'Bash',
    description: 'Run a shell command in the project folder (bash). Use for tests, builds, git status/diff, package managers. Default timeout 120 s (max 900). Never start servers that keep running – use a timeout or run them in the background with &.',
    parameters: { type: 'object', properties: { command: { type: 'string' }, description: { type: 'string', description: 'What this does, in a few words' }, timeout: { type: 'integer', description: 'seconds' } }, required: ['command'] },
    async run({ command, timeout = 120 }, ctx) {
      const r = await runCommand(command, { cwd: ctx.root, timeoutSec: Math.min(900, Math.max(5, timeout)), signal: ctx.signal })
      if (/\b(test|vitest|jest|pytest|swift test|cargo test|go test|npm (run )?(test|lint|build|check)|pnpm|yarn)\b/.test(command)) ctx.state.checkedAt = ctx.state.step
      const head = r.timedOut ? `⏱ Abgebrochen nach ${timeout} s.\n` : ''
      return r.code === 0 ? { output: head + (r.output.trim() || '(keine Ausgabe)') } : { error: `${head}Exit ${r.code}\n${r.output.trim()}` }
    },
  })
}
