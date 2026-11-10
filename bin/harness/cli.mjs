#!/usr/bin/env node
// Salenta Harness – Kommandozeile
//
//   salenta-harness "Baue X und teste es"                 Auftrag im aktuellen Ordner
//   salenta-harness --cwd ~/Code/app --access read "…"     nur lesen
//   salenta-harness --provider deepseek --model deepseek-chat "…"
//   salenta-harness --json "…"                            Ereignisstrom (für Salenta Code)
//   salenta-harness --resume <sitzung> "weiter: …"        Sitzung fortsetzen
//   salenta-harness --plugin ./mein-werkzeug.mjs "…"      Erweiterung laden
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
import { planTool, webTool } from './tools/extra.mjs'

const VERSION = '0.1.0'

function parse(argv) {
  const o = { plugins: [], prompt: [] }
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
  if (preset !== 'minimal') rt.use(planTool).use(webTool).use(agentTools)
  return rt
}

async function main() {
  const o = parse(process.argv.slice(2))
  if (o.version) { console.log(VERSION); return 0 }
  if (o.help) {
    console.log(`Salenta Harness ${VERSION}\n\nsalenta-harness [--cwd DIR] [--access read|project|full] [--provider ${Object.keys(PROVIDERS).filter(p => p !== 'mock').join('|')}] [--model M]\n                [--preset standard|minimal] [--max-steps N] [--max-minutes N] [--json] [--resume ID] [--plugin FILE] "Auftrag"\nsalenta-harness sessions     letzte Sitzungen\nsalenta-harness doctor       Anbieter und Schlüssel prüfen`)
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

  const prompt = (o.prompt.join(' ') || await readStdin()).trim()
  if (!prompt) { console.error('Kein Auftrag. salenta-harness --help'); return 2 }

  const root = resolve(o.cwd || process.cwd())
  const access = o.access || cfg.access || 'project'
  const p = pickProvider(o.provider, cfg)
  const model = o.model || process.env.SALENTA_HARNESS_MODEL || (p.name === (cfg.provider || p.name) ? cfg.model : undefined) || p.model
  const rt = buildRuntime(o.preset || 'standard', cfg)
  for (const f of [...(cfg.plugins || []), ...o.plugins]) rt.use((await import(pathToFileURL(resolve(f)).href)).default)
  rt.provide('provider', createProvider({ ...p, model }))
  // Ersatzanbieter für den Fall, dass der gewählte ins Limit läuft (nur ohne ausdrücklich festgelegten Anbieter)
  const chain = (o.provider || process.env.SALENTA_HARNESS_PROVIDER) && !process.env.SALENTA_HARNESS_MOCK_FALLBACK ? [] : fallbackChain(p.name, cfg)
  rt.provide('fallback', () => { const n = chain.shift(); return n ? createProvider(n) : null })
  rt.provide('policy', createPolicy({ access, root }))
  const out = createOutput({ json: o.json })
  rt.provide('output', out)

  const session = o.resume ? Session.open(o.resume) : new Session()
  session.append('meta', { root, access, provider: p.name, model, version: VERSION })
  out.init({ sessionId: session.id, provider: p.name, model, root, access })

  const ac = new AbortController()
  process.on('SIGINT', () => ac.abort()); process.on('SIGTERM', () => ac.abort())
  const r = await runAgent({
    rt, prompt, session, root, access, model, signal: ac.signal,
    maxSteps: o.maxSteps || cfg.maxSteps || 80, maxMinutes: o.maxMinutes || cfg.maxMinutes || 120,
  })
  out.done(r)
  if (!o.json && r.text) { console.log(''); console.log(r.text.trim()) }
  return r.ok ? 0 : r.reason === 'limit' ? 3 : 1
}

main().then(code => process.exit(code), e => { console.error(`✗ ${e.stack || e.message}`); process.exit(1) })
