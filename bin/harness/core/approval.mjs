// Freigaben: wer entscheidet, wenn ein Schritt die Zustimmung des Besitzers braucht?
// Reihenfolge: 1. Salenta Code (Werkzeug „freigabe“ – dieselbe Freigabe-Leiste, Regeln, Auto-Modus und Zeitlimits wie bei allen Agents)
//              2. ein eigenes Programm (SALENTA_APPROVE; Exit 0 = erlaubt)   3. Rückfrage im Terminal   4. niemand → abgelehnt

import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'

const APP_TOOL = 'mcp__salenta-os__freigabe'

export function createApprover({ rt, program = process.env.SALENTA_APPROVE, tty = process.stdin.isTTY && process.stdout.isTTY, out } = {}) {
  const viaApp = () => rt.toolByName(APP_TOOL)
  const kind = () => viaApp() ? 'app' : program ? 'program' : tty ? 'terminal' : 'none'

  async function ask(tool, input) {
    const app = viaApp()
    if (app) {
      const r = await app.run({ tool_name: tool, input }, {})
      if (r.error) return { allow: false, message: r.error }
      try {
        const j = JSON.parse(r.output)
        return { allow: j.behavior === 'allow', message: j.message || '' }
      } catch { return { allow: false, message: 'Freigabe-Antwort unlesbar' } }
    }
    const detail = typeof input === 'string' ? input : input?.command || input?.path || JSON.stringify(input || {}).slice(0, 400)
    if (program) {
      return await new Promise(resolve => {
        const child = spawn(program, [tool, detail], { stdio: 'ignore' })
        const timer = setTimeout(() => { try { child.kill() } catch {}; resolve({ allow: false, message: 'Keine Antwort innerhalb von 15 Minuten.' }) }, 15 * 60_000)
        child.on('close', code => { clearTimeout(timer); resolve({ allow: code === 0, message: code === 0 ? '' : 'Abgelehnt.' }) })
        child.on('error', () => { clearTimeout(timer); resolve({ allow: false, message: 'Freigabe-Programm nicht startbar.' }) })
      })
    }
    if (tty) {
      const rl = createInterface({ input: process.stdin, output: process.stdout })
      const a = await new Promise(res => rl.question(`\n? Freigabe für ${tool}: ${detail}\n  Erlauben? [j/N] `, res))
      rl.close()
      return { allow: /^(j|ja|y|yes)$/i.test(a.trim()), message: 'Abgelehnt.' }
    }
    return { allow: false, message: 'Niemand da, der freigeben kann.' }
  }

  return { kind, ask, get available() { return kind() !== 'none' } }
}
