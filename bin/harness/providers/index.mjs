// Modell-Anbieter. Alle liefern dieselbe Antwortform:
//   { text, toolCalls: [{ id, name, args }], usage: { input, output, cached }, stop }
// OpenAI-kompatibel: DeepSeek, OpenRouter, OpenAI, Ollama (lokal) und jeder Server mit /chat/completions.
// Anthropic: eigene Messages-Schnittstelle.

import { readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { harnessHome } from '../core/session.mjs'
import { subscriptionChat, firstSubscription } from './subscription.mjs'

export class LimitError extends Error {}

export const PROVIDERS = {
  deepseek:   { kind: 'openai', base: 'https://api.deepseek.com/v1', keyEnv: 'DEEPSEEK_API_KEY', model: 'deepseek-chat' },
  openrouter: { kind: 'openai', base: 'https://openrouter.ai/api/v1', keyEnv: 'OPENROUTER_API_KEY', model: 'deepseek/deepseek-chat' },
  openai:     { kind: 'openai', base: 'https://api.openai.com/v1', keyEnv: 'OPENAI_API_KEY', model: 'gpt-4.1' },
  ollama:     { kind: 'openai', base: (process.env.OLLAMA_HOST ? process.env.OLLAMA_HOST.replace(/\/$/, '') : 'http://localhost:11434') + '/v1', keyEnv: null, model: 'qwen3:8b' },
  anthropic:  { kind: 'anthropic', base: 'https://api.anthropic.com/v1', keyEnv: 'ANTHROPIC_API_KEY', model: 'claude-sonnet-5-5' },
  // Abos: kein Schlüssel, die eingeloggte Kommandozeile liefert das Modell (Modell leer = deren Standard)
  'claude-cli': { kind: 'subscription', keyEnv: null, model: '' },
  'codex-cli':  { kind: 'subscription', keyEnv: null, model: '' },
  mock:       { kind: 'mock' },
}

export function loadConfig() {
  const f = join(harnessHome(), 'config.json')
  if (!existsSync(f)) return {}
  try { return JSON.parse(readFileSync(f, 'utf8')) } catch { return {} }
}

/** Anbieter wählen: ausdrücklich, aus der Konfiguration, sonst der erste mit Schlüssel – zuletzt lokal. */
export function pickProvider(name, cfg = loadConfig()) {
  const want = name || process.env.SALENTA_HARNESS_PROVIDER || cfg.provider
  if (want) {
    const p = PROVIDERS[want] || (cfg.providers || {})[want]
    if (!p) throw new Error(`Unbekannter Anbieter: ${want}`)
    return { name: want, ...p, ...((cfg.providers || {})[want] || {}) }
  }
  for (const n of ['deepseek', 'anthropic', 'openai', 'openrouter']) if (process.env[PROVIDERS[n].keyEnv]) return { name: n, ...PROVIDERS[n] }
  const sub = firstSubscription()   // ohne Schlüssel: das Abo, das schon da ist, vor dem lokalen Modell
  if (sub) return { name: sub, ...PROVIDERS[sub] }
  return { name: 'ollama', ...PROVIDERS.ollama }
}

/** Reihenfolge der Ersatzanbieter: alle mit Schlüssel (ohne den aktuellen); lokal nur, wenn es sonst nichts gibt. */
export function fallbackChain(current, cfg = loadConfig()) {
  if (process.env.SALENTA_HARNESS_NO_FALLBACK || cfg.fallback === false) return []
  if (process.env.SALENTA_HARNESS_MOCK_FALLBACK) return [{ name: 'mock-2', kind: 'mock', model: 'mock' }]   // nur für Tests
  const out = []
  for (const n of ['deepseek', 'anthropic', 'openai', 'openrouter']) {
    if (n !== current && process.env[PROVIDERS[n].keyEnv]) out.push({ name: n, ...PROVIDERS[n], ...((cfg.providers || {})[n] || {}) })
  }
  return out
}

const sleep = ms => new Promise(r => setTimeout(r, ms))

async function post(url, body, headers, { retries = 3, signal } = {}) {
  let last
  for (let attempt = 0; attempt <= retries; attempt++) {
    let res
    try {
      res = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: JSON.stringify(body), signal: signal || AbortSignal.timeout(600_000) })
    } catch (e) {
      last = new Error(`Verbindung fehlgeschlagen (fetch failed): ${e.message}`)
      await sleep(1500 * (attempt + 1)); continue
    }
    const text = await res.text()
    if (res.ok) { try { return JSON.parse(text) } catch { throw new Error(`Antwort ist kein JSON: ${text.slice(0, 300)}`) } }
    // Kontingent leer → als Limit melden (Salenta Code erkennt „quota exceeded“ / „rate limit“ und wechselt den Agent)
    if (res.status === 402 || /insufficient|quota|balance|credit/i.test(text)) throw new LimitError(`quota exceeded (HTTP ${res.status}): ${text.slice(0, 300)}`)
    if (res.status === 429 || res.status >= 500) {
      last = new Error(`HTTP ${res.status}: ${text.slice(0, 300)}`)
      if (attempt === retries && res.status === 429) throw new LimitError(`rate limit (HTTP 429): ${text.slice(0, 300)}`)
      const ra = Number(res.headers.get('retry-after'))
      await sleep(ra > 0 && ra < 120 ? ra * 1000 : 2000 * 2 ** attempt); continue
    }
    throw new Error(`HTTP ${res.status}: ${text.slice(0, 600)}`)
  }
  throw last
}

// ---------- OpenAI-kompatibel ----------

function toOpenAI(system, messages) {
  const out = [{ role: 'system', content: system }]
  for (const m of messages) {
    if (m.role === 'assistant') {
      const msg = { role: 'assistant', content: m.content || '' }
      if (m.toolCalls?.length) msg.tool_calls = m.toolCalls.map(c => ({ id: c.id, type: 'function', function: { name: c.name, arguments: JSON.stringify(c.args ?? {}) } }))
      out.push(msg)
    } else if (m.role === 'tool') out.push({ role: 'tool', tool_call_id: m.toolCallId, content: String(m.content ?? '') })
    else out.push({ role: 'user', content: m.content })
  }
  return out
}

async function openaiChat(p, { system, messages, tools, model, signal, maxTokens }) {
  const key = p.keyEnv ? process.env[p.keyEnv] : null
  if (p.keyEnv && !key) throw new Error(`Kein Schlüssel: ${p.keyEnv} setzen (oder anderen Anbieter wählen).`)
  const body = {
    model: model || p.model,
    messages: toOpenAI(system, messages),
    ...(tools.length ? { tools: tools.map(t => ({ type: 'function', function: { name: t.name, description: t.description, parameters: t.parameters } })), tool_choice: 'auto' } : {}),
    ...(maxTokens ? { max_tokens: maxTokens } : {}),
  }
  const j = await post(`${p.base}/chat/completions`, body, key ? { authorization: `Bearer ${key}` } : {}, { signal })
  const choice = j.choices?.[0] || {}
  const msg = choice.message || {}
  const toolCalls = (msg.tool_calls || []).map((c, i) => {
    let args = {}
    try { args = typeof c.function?.arguments === 'string' ? JSON.parse(c.function.arguments || '{}') : (c.function?.arguments || {}) } catch { args = { _raw: c.function?.arguments } }
    return { id: c.id || `call_${Date.now()}_${i}`, name: c.function?.name, args }
  })
  const u = j.usage || {}
  return {
    text: msg.content || '', reasoning: msg.reasoning_content || '', toolCalls, stop: choice.finish_reason,
    usage: { input: u.prompt_tokens || 0, output: u.completion_tokens || 0, cached: u.prompt_cache_hit_tokens || u.prompt_tokens_details?.cached_tokens || 0 },
  }
}

// ---------- Anthropic ----------

function toAnthropic(messages) {
  const out = []
  const push = (role, block) => {
    const last = out[out.length - 1]
    if (last && last.role === role) last.content.push(block)
    else out.push({ role, content: [block] })
  }
  for (const m of messages) {
    if (m.role === 'assistant') {
      if (m.content) push('assistant', { type: 'text', text: m.content })
      for (const c of m.toolCalls || []) push('assistant', { type: 'tool_use', id: c.id, name: c.name, input: c.args ?? {} })
      if (!m.content && !(m.toolCalls || []).length) push('assistant', { type: 'text', text: '…' })
    } else if (m.role === 'tool') push('user', { type: 'tool_result', tool_use_id: m.toolCallId, content: String(m.content ?? '') })
    else push('user', { type: 'text', text: m.content })
  }
  return out
}

async function anthropicChat(p, { system, messages, tools, model, signal, maxTokens = 8192 }) {
  const key = process.env[p.keyEnv]
  if (!key) throw new Error(`Kein Schlüssel: ${p.keyEnv} setzen.`)
  const body = {
    model: model || p.model, max_tokens: maxTokens,
    system: [{ type: 'text', text: system, cache_control: { type: 'ephemeral' } }],
    messages: toAnthropic(messages),
    ...(tools.length ? { tools: tools.map(t => ({ name: t.name, description: t.description, input_schema: t.parameters })) } : {}),
  }
  const j = await post(`${p.base}/messages`, body, { 'x-api-key': key, 'anthropic-version': '2023-06-01' }, { signal })
  const text = (j.content || []).filter(b => b.type === 'text').map(b => b.text).join('\n')
  const toolCalls = (j.content || []).filter(b => b.type === 'tool_use').map(b => ({ id: b.id, name: b.name, args: b.input || {} }))
  const u = j.usage || {}
  return { text, toolCalls, stop: j.stop_reason, usage: { input: (u.input_tokens || 0) + (u.cache_read_input_tokens || 0), output: u.output_tokens || 0, cached: u.cache_read_input_tokens || 0 } }
}

// ---------- Mock (Tests) ----------
// SALENTA_HARNESS_MOCK = Pfad zu einer JSON-Datei mit einer Liste von Antworten { text, toolCalls }

function mockChat() {
  const f = process.env.SALENTA_HARNESS_MOCK
  const script = JSON.parse(readFileSync(f, 'utf8'))
  mockChat.i = (mockChat.i || 0)
  const r = script[mockChat.i++] || { text: 'Fertig.' }
  if (r.limit) return Promise.reject(new LimitError('quota exceeded (HTTP 402): test'))
  return Promise.resolve({ text: r.text || '', toolCalls: (r.toolCalls || []).map((c, i) => ({ id: c.id || `m${mockChat.i}_${i}`, ...c })), usage: { input: 100, output: 20, cached: 0 } })
}

export function createProvider(p) {
  return {
    name: p.name,
    model: p.model,
    chat: (req) => p.kind === 'anthropic' ? anthropicChat(p, req) : p.kind === 'subscription' ? subscriptionChat(p, req) : p.kind === 'mock' ? mockChat(req) : openaiChat(p, req),
  }
}
