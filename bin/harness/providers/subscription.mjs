// Abo-Anbieter: das Modell kommt aus der Kommandozeile von Claude oder Codex, die der Nutzer schon eingeloggt hat –
// kein API-Schlüssel, keine Abrechnung pro Nutzung. Die Kommandozeile bekommt nur das Gespräch und die Werkzeugliste und
// antwortet mit genau einem JSON-Objekt; die Werkzeuge führt der Harness selbst aus (mit seinen eigenen Regeln).

import { spawn, spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const BIN = {
  'claude-cli': { env: 'SALENTA_HARNESS_CLAUDE_BIN', name: 'claude' },
  'codex-cli': { env: 'SALENTA_HARNESS_CODEX_BIN', name: 'codex' },
}

export function findBinary(provider) {
  const b = BIN[provider]
  if (!b) return null
  if (process.env[b.env]) return process.env[b.env]
  const dirs = [...(process.env.PATH || '').split(':'), '/opt/homebrew/bin', '/usr/local/bin', `${process.env.HOME}/.local/bin`, `${process.env.HOME}/.claude/local`]
  for (const d of dirs) { const f = join(d, b.name); if (existsSync(f)) return f }
  return null
}

/** Das erste Abo, das auf diesem Rechner nutzbar ist (Claude zuerst, dann Codex). */
export function firstSubscription() {
  return ['claude-cli', 'codex-cli'].find(n => findBinary(n)) || null
}

const MAX_PROMPT = 400_000

/** Gespräch als Text für die Kommandozeile. Lange Werkzeugergebnisse werden gekürzt, damit der Prompt klein bleibt. */
export function buildPrompt({ system, messages, tools }) {
  const lines = []
  lines.push(system)
  lines.push('')
  lines.push('Du antwortest in diesem Gespräch NUR mit einem einzigen JSON-Objekt, ohne Text davor oder danach und ohne Codeblock:')
  lines.push('{"text":"kurze Nachricht an den Nutzer oder leer","toolCalls":[{"name":"<Werkzeug>","args":{...}}]}')
  lines.push('Mit toolCalls rufst du Werkzeuge auf (mehrere nur, wenn sie unabhängig sind). Du führst sie nicht selbst aus – das Ergebnis kommt in der nächsten Runde.')
  lines.push('Ist die Aufgabe erledigt, antworte mit "toolCalls":[] und dem Ergebnis in "text".')
  lines.push('')
  if (tools.length) {
    lines.push('Werkzeuge:')
    for (const t of tools) lines.push(`- ${t.name}: ${t.description} | Parameter: ${JSON.stringify(t.parameters)}`)
    lines.push('')
  }
  lines.push('Gespräch bisher:')
  for (const m of messages) {
    if (m.role === 'assistant') {
      lines.push(`[Assistent] ${JSON.stringify({ text: m.content || '', toolCalls: (m.toolCalls || []).map(c => ({ name: c.name, args: c.args ?? {} })) })}`)
    } else if (m.role === 'tool') {
      const out = String(m.content ?? '')
      lines.push(`[Ergebnis von ${m.name || 'Werkzeug'}] ${out.length > 12000 ? out.slice(0, 8000) + '\n…[gekürzt]…\n' + out.slice(-3000) : out}`)
    } else lines.push(`[Nutzer] ${m.content}`)
  }
  lines.push('')
  lines.push('Deine Antwort (nur das JSON-Objekt):')
  let p = lines.join('\n')
  if (p.length > MAX_PROMPT) p = p.slice(0, 20000) + '\n…[Anfang gekürzt]…\n' + p.slice(-(MAX_PROMPT - 20000))
  return p
}

/** Erstes vollständiges JSON-Objekt aus dem Text holen (die Kommandozeile schreibt manchmal Text oder einen Codeblock dazu). */
export function extractJSON(text) {
  const s = String(text || '')
  for (let i = s.indexOf('{'); i >= 0; i = s.indexOf('{', i + 1)) {
    let depth = 0, inStr = false, esc = false
    for (let j = i; j < s.length; j++) {
      const c = s[j]
      if (inStr) { if (esc) esc = false; else if (c === '\\') esc = true; else if (c === '"') inStr = false; continue }
      if (c === '"') inStr = true
      else if (c === '{') depth++
      else if (c === '}' && --depth === 0) {
        try { const o = JSON.parse(s.slice(i, j + 1)); if (o && typeof o === 'object' && ('text' in o || 'toolCalls' in o)) return o } catch {}
        break
      }
    }
  }
  return null
}

export function parseReply(raw, tools) {
  const o = extractJSON(raw)
  if (!o) return { text: String(raw || '').trim(), toolCalls: [] }   // kein JSON: als Endergebnis nehmen
  const known = new Set(tools.map(t => t.name))
  const calls = (Array.isArray(o.toolCalls) ? o.toolCalls : [])
    .filter(c => c && known.has(c.name))
    .map((c, i) => ({ id: `sub_${Date.now()}_${i}`, name: c.name, args: c.args && typeof c.args === 'object' ? c.args : {} }))
  return { text: typeof o.text === 'string' ? o.text : '', toolCalls: calls }
}

function run(bin, args, input, signal, timeoutMs) {
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, { stdio: ['pipe', 'pipe', 'pipe'], env: process.env })
    let out = '', err = ''
    const timer = setTimeout(() => { child.kill('SIGKILL'); reject(new Error(`${bin}: Zeitüberschreitung nach ${Math.round(timeoutMs / 1000)} s`)) }, timeoutMs)
    signal?.addEventListener('abort', () => { child.kill('SIGKILL'); reject(new Error('abgebrochen')) }, { once: true })
    child.stdout.on('data', d => { out += d })
    child.stderr.on('data', d => { err += d })
    child.on('error', e => { clearTimeout(timer); reject(e) })
    child.on('close', code => { clearTimeout(timer); resolve({ code, out, err }) })
    child.stdin.on('error', () => {})
    child.stdin.end(input)
  })
}

/** Kontingent leer oder nicht eingeloggt → Meldung, die Salenta Code erkennt (Agent wechseln). */
function limitText(s) { return /usage limit|rate limit|quota|limit reached|too many requests|overloaded|credit/i.test(s) }

export async function subscriptionChat(p, { system, messages, tools, model, signal }) {
  const bin = findBinary(p.name)
  if (!bin) throw new Error(`${p.name === 'codex-cli' ? 'Codex' : 'Claude'} ist nicht installiert oder nicht eingeloggt.`)
  const prompt = buildPrompt({ system, messages, tools })
  // Nur Modellnamen, die die jeweilige Kommandozeile kennt – ein DeepSeek-Name o. Ä. würde dort scheitern
  const okModel = p.name === 'claude-cli' ? /^(opus|sonnet|haiku|claude-)/ : /^(gpt-|o\d|codex)/
  const m = [model, p.model].find(x => x && okModel.test(x)) || ''
  const timeoutMs = Number(process.env.SALENTA_HARNESS_CLI_TIMEOUT_MS) || 600_000
  let res, tmp
  try {
    if (p.name === 'claude-cli') {
      // Werkzeuge der Kommandozeile bleiben aus: Der Harness führt sie selbst aus.
      const args = ['-p', '--output-format', 'text', '--tools', '', ...(m ? ['--model', m] : [])]
      res = await run(bin, args, prompt, signal, timeoutMs)
      if (res.code === 0) return { ...parseReply(res.out, tools), usage: { input: Math.ceil(prompt.length / 4), output: Math.ceil(res.out.length / 4), cached: 0 }, stop: 'stop' }
    } else {
      tmp = mkdtempSync(join(tmpdir(), 'harness-codex-'))
      const last = join(tmp, 'last.txt')
      const args = ['exec', '--skip-git-repo-check', '-s', 'read-only', '--output-last-message', last, ...(m ? ['-m', m] : []), '-']
      res = await run(bin, args, prompt, signal, timeoutMs)
      if (res.code === 0) {
        const raw = existsSync(last) ? readFileSync(last, 'utf8') : res.out
        return { ...parseReply(raw, tools), usage: { input: Math.ceil(prompt.length / 4), output: Math.ceil(raw.length / 4), cached: 0 }, stop: 'stop' }
      }
    }
  } finally { if (tmp) try { rmSync(tmp, { recursive: true, force: true }) } catch {} }
  const msg = `${res.err}\n${res.out}`.slice(-600)
  if (limitText(msg)) { const { LimitError } = await import('./index.mjs'); throw new LimitError(`quota exceeded (${p.name}): ${msg}`) }
  throw new Error(`${p.name} Fehler (Code ${res.code}): ${msg}`)
}
