#!/usr/bin/env node
// Salenta Harness – Kommandozeile
//
//   salenta-harness "Baue X und teste es"                 Auftrag im aktuellen Ordner
//   salenta-harness --cwd ~/Code/app --access read "…"     nur lesen
//   salenta-harness --provider deepseek --model deepseek-chat "…"
//   salenta-harness --json "…"                            Ereignisstrom (für Salenta Code)
//   salenta-harness --resume <sitzung> "weiter: …"        Sitzung fortsetzen
//   salenta-harness --plugin ./mein-werkzeug.mjs "…"      Erweiterung laden
//   salenta-harness --mcp-config server.json "…"          Werkzeug-Server verbinden (Browser, Computer, eigene Anbindungen)
//   salenta-harness --approval ask "…"                    mit Freigabe arbeiten (Standard: auto = selbstständig)
//   salenta-harness --computer "…"                        Mac bedienen (Apps, Fenster, Klicken, Tippen – nur mit Freigabe)
//   salenta-harness ask < frage.txt                       eine kurze Entscheidungsfrage beantworten (ohne Werkzeuge) – für Salenta Code
//   salenta-harness sessions | doctor | --help
//
// Anbieter: deepseek (DEEPSEEK_API_KEY), anthropic (ANTHROPIC_API_KEY), openai (OPENAI_API_KEY),
// openrouter (OPENROUTER_API_KEY), ollama (lokal, ohne Schlüssel). Ohne Angabe: der erste mit Schlüssel, sonst lokal.
// Konfiguration (optional): ~/.salenta-harness/config.json  { "provider": "deepseek", "model": "…", "providers": { … } }

import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { createRuntime } from './core/runtime.mjs'
import { Session } from './core/session.mjs'
import { createPolicy } from './core/policy.mjs'
import { createOutput } from './core/output.mjs'
import { runAgent, agentTools } from './core/agent.mjs'
import { pickProvider, createProvider, loadConfig, fallbackChain, PROVIDERS } from './providers/index.mjs'
import { fileTools } from './tools/files.mjs'
import { shellTools } from './tools/shell.mjs'
import { planTool, webTool, searchTool } from './tools/extra.mjs'
import { computerTools, computerCheck, computerLive } from './tools/computer.mjs'
import { connectMcp, loadMcpConfig } from './core/mcp.mjs'
import { createApprover } from './core/approval.mjs'

const VERSION = '0.2.0'

function parse(argv) {
  const o = { plugins: [], mcp: [], prompt: [] }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    const next = () => argv[++i]
    if (a === '--cwd' || a === '-C') o.cwd = next()
    else if (a === '--access') o.access = next()
    else if (a === '--provider') o.provider = next()
    else if (a === '--model' || a === '-m') o.model = next()
    else if (a === '--max-steps') o.maxSteps = Number(next())
    else if (a === '--max-minutes') o.maxMinutes = Number(next())
    else if (a === '--preset') o.preset = next()
    else if (a === '--resume') o.resume = next()
    else if (a === '--plugin') o.plugins.push(next())
    else if (a === '--mcp-config') o.mcp.push(next())
    else if (a === '--approval') o.approval = next()
    else if (a === '--computer') o.computer = true
    else if (a === '--live') o.live = true
    else if (a === '--json') o.json = true
    else if (a === '--help' || a === '-h') o.help = true
    else if (a === '--version' || a === '-v') o.version = true
    else o.prompt.push(a)
  }
  return o
}

async function readStdin() {
  if (process.stdin.isTTY) return ''
  let s = ''
  for await (const c of process.stdin) s += c
  return s.trim()
}

/** Voreinstellungen: welche Werkzeuge ein Lauf bekommt. */
function buildRuntime(preset, cfg) {
  const rt = createRuntime({ systemExtra: cfg.systemExtra || '' })
  rt.use(fileTools).use(shellTools)
  if (preset !== 'minimal') rt.use(planTool).use(webTool).use(searchTool).use(agentTools)
  return rt
}

async function main() {
  const o = parse(process.argv.slice(2))
  if (o.version) { console.log(VERSION); return 0 }
  if (o.help) {
    console.log(`Salenta Harness ${VERSION}\n\nsalenta-harness [--cwd DIR] [--access read|project|full] [--provider ${Object.keys(PROVIDERS).filter(p => p !== 'mock').join('|')}] [--model M]\n                [--approval auto|ask] [--mcp-config FILE] [--computer] [--preset standard|minimal] [--max-steps N] [--max-minutes N]\n                [--json] [--resume ID] [--plugin FILE] "Auftrag"\nsalenta-harness sessions     letzte Sitzungen\nsalenta-harness doctor       Anbieter und Schlüssel prüfen\nsalenta-harness tools        Werkzeuge auflisten (mit --mcp-config / --computer)\nsalenta-harness computer-check   Computer-Steuerung prüfen (verändert nichts)`)
    return 0
  }
  const cfg = loadConfig()
  if (o.prompt[0] === 'sessions') { console.log(Session.list().slice(-20).join('\n') || '(keine)'); return 0 }
  if (o.prompt[0] === 'doctor') {
    for (const [n, p] of Object.entries(PROVIDERS)) if (n !== 'mock') console.log(`${n.padEnd(11)} ${p.keyEnv ? (process.env[p.keyEnv] ? '✓ Schlüssel da' : `– ${p.keyEnv} fehlt`) : 'lokal'}  Standardmodell: ${p.model}`)
    const p = pickProvider(o.provider, cfg)
    console.log(`\nGewählt: ${p.name} (${o.model || cfg.model || p.model})`)
    return 0
  }

  if (o.prompt[0] === 'ask') {
    // Entscheidungsmodell von Salenta Code: eine Frage, eine Antwort, keine Werkzeuge. Die Ausgabe hat dasselbe Format wie
    // die anderen Hilfsmodelle ({"type":"result","result":…}). Bei einem Fehler bleibt die Ausgabe leer (Fehler auf stderr),
    // damit der Aufrufer sauber auf sein Ersatzmodell wechseln kann.
    const question = (o.prompt.slice(1).join(' ') || await readStdin()).trim()
    if (!question) { console.error('ask: keine Frage'); return 2 }
    const first = pickProvider(o.provider, cfg)
    const firstModel = o.model || process.env.SALENTA_HARNESS_MODEL || (first.name === (cfg.provider || first.name) ? cfg.model : undefined) || first.model
    const chain = [{ ...first, model: firstModel }, ...(o.provider || process.env.SALENTA_HARNESS_PROVIDER ? [] : fallbackChain(first.name, cfg))]
    const seconds = Math.max(3, Number(process.env.SALENTA_HARNESS_ASK_SECONDS) || 12)
    const ac = new AbortController()
    const timer = setTimeout(() => ac.abort(), seconds * 1000)
    try {
      for (const p of chain) {
        try {
          const provider = createProvider(p)
          const r = await provider.chat({
            system: 'You are the decision model of a coding workbench. Answer exactly in the format the question asks for – nothing before or after it.',
            messages: [{ role: 'user', content: question }], tools: [], model: p.model, signal: ac.signal,
          })
          if (!(r.text || '').trim()) throw new Error('leere Antwort')
          console.log(JSON.stringify({ type: 'result', subtype: 'success', is_error: false, result: r.text.trim(), via: 'harness', provider: p.name, model: p.model }))
          return 0
        } catch (e) {
          if (ac.signal.aborted) { console.error(`ask: keine Antwort in ${seconds} s`); return 1 }
          console.error(`ask: ${p.name} – ${String(e?.message || e).slice(0, 200)}`)
        }
      }
      return 1
    } finally { clearTimeout(timer) }
  }

  if (o.prompt[0] === 'computer-check') {
    const r = o.live ? await computerLive() : await computerCheck()
    console.log(r.lines.join('\n'))
    return r.ok ? 0 : 1
  }
  if (o.prompt[0] === 'tools') {
    // Alle Werkzeuge dieses Laufs auflisten (inkl. verbundener Server) – ohne ein Modell zu fragen. * = verändert etwas
    const rt = buildRuntime(o.preset || 'standard', cfg)
    if ((o.computer || cfg.computer) && process.platform === 'darwin') rt.use(r => computerTools(r))
    const mcp = await connectMcp(rt, loadMcpConfig(o.mcp, cfg.mcpServers), { out: createOutput({ json: false }) })
    for (const t of rt.tools()) console.log(`${t.name}${t.readOnly ? '' : ' *'}`)
    mcp.close()
    return 0
  }

  const prompt = (o.prompt.join(' ') || await readStdin()).trim()
  if (!prompt) { console.error('Kein Auftrag. salenta-harness --help'); return 2 }

  const root = resolve(o.cwd || process.cwd())
  const access = o.access || cfg.access || 'project'
  const p = pickProvider(o.provider, cfg)
  const model = o.model || process.env.SALENTA_HARNESS_MODEL || (p.name === (cfg.provider || p.name) ? cfg.model : undefined) || p.model
  const rt = buildRuntime(o.preset || 'standard', cfg)
  // Computer-Steuerung: nur auf dem Mac und nur, wenn sie eingeschaltet wurde
  if ((o.computer || cfg.computer || process.env.SALENTA_HARNESS_COMPUTER) && (process.platform === 'darwin' || process.env.SALENTA_HARNESS_COMPUTER_MOCK)) {
    rt.use(r => computerTools(r, process.env.SALENTA_HARNESS_COMPUTER_MOCK ? { run: async (script, args = []) => ({ output: `MOCK ${args.join('|')}` }), opener: async a => ({ output: `MOCK open ${a.join(' ')}` }) } : {}))
  }
  for (const f of [...(cfg.plugins || []), ...o.plugins]) rt.use((await import(pathToFileURL(resolve(f)).href)).default)
  rt.provide('provider', createProvider({ ...p, model }))
  // Ersatzanbieter für den Fall, dass der gewählte ins Limit läuft (nur ohne ausdrücklich festgelegten Anbieter)
  const chain = (o.provider || process.env.SALENTA_HARNESS_PROVIDER) && !process.env.SALENTA_HARNESS_MOCK_FALLBACK ? [] : fallbackChain(p.name, cfg)
  rt.provide('fallback', () => { const n = chain.shift(); return n ? createProvider(n) : null })
  const out = createOutput({ json: o.json })
  rt.provide('output', out)
  const approval = o.approval || process.env.SALENTA_HARNESS_APPROVAL || cfg.approval || 'auto'
  const approver = createApprover({ rt, tty: !o.json && process.stdin.isTTY && process.stdout.isTTY, out })
  rt.provide('approver', approver)
  rt.provide('policy', createPolicy({ access, root, approval, approver }))

  const session = o.resume ? Session.open(o.resume) : new Session()
  session.append('meta', { root, access, provider: p.name, model, version: VERSION })
  out.init({ sessionId: session.id, provider: p.name, model, root, access })
  // Werkzeug-Server (Browser, Computer-Steuerung, Salenta Code, eigene Anbindungen)
  const mcp = await connectMcp(rt, loadMcpConfig(o.mcp, cfg.mcpServers), { out })

  const ac = new AbortController()
  process.on('SIGINT', () => ac.abort()); process.on('SIGTERM', () => ac.abort())
  const r = await runAgent({
    rt, prompt, session, root, access, model, signal: ac.signal,
    maxSteps: o.maxSteps || cfg.maxSteps || 80, maxMinutes: o.maxMinutes || cfg.maxMinutes || 120,
  })
  mcp.close()
  out.done(r)
  if (!o.json && r.text) { console.log(''); console.log(r.text.trim()) }
  return r.ok ? 0 : r.reason === 'limit' ? 3 : 1
}

main().then(code => process.exit(code), e => { console.error(`✗ ${e.stack || e.message}`); process.exit(1) })
