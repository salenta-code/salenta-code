// MCP-Client: verbindet externe Werkzeug-Server (Browser, Computer-Steuerung, Salenta Code, eigene Anbindungen)
// und meldet ihre Werkzeuge als „mcp__<server>__<werkzeug>“ an.
// Unterstützt lokale Server (stdio, eine JSON-Nachricht je Zeile) und entfernte Server (HTTP, Antwort als JSON oder Ereignisstrom).
// Konfiguration im üblichen Format: { "mcpServers": { "name": { "command", "args", "env" } | { "url", "headers" } } }

import { spawn } from 'node:child_process'
import { readFileSync } from 'node:fs'

const PROTOCOL = '2025-06-18'
const CLIENT = { name: 'salenta-harness', version: '0.2.0' }

class StdioClient {
  constructor(name, spec) { this.name = name; this.spec = spec; this.next = 1; this.waiting = new Map(); this.buf = ''; this.stderr = '' }
  start() {
    const { command, args = [], env = {} } = this.spec
    this.child = spawn(command, args, { env: { ...process.env, ...env }, stdio: ['pipe', 'pipe', 'pipe'] })
    this.child.stdout.on('data', d => { this.buf += d.toString(); this.drain() })
    this.child.stderr.on('data', d => { this.stderr = (this.stderr + d.toString()).slice(-2000) })
    const dead = why => { for (const w of this.waiting.values()) w.reject(new Error(why)); this.waiting.clear(); this.closed = true }
    this.child.on('error', e => dead(`Start fehlgeschlagen: ${e.message}`))
    this.child.on('close', code => dead(`Server beendet (Code ${code})${this.stderr ? ': ' + this.stderr.trim().split('\n').pop() : ''}`))
  }
  drain() {
    let i
    while ((i = this.buf.indexOf('\n')) >= 0) {
      const line = this.buf.slice(0, i).trim(); this.buf = this.buf.slice(i + 1)
      if (!line) continue
      let m; try { m = JSON.parse(line) } catch { continue }
      if (m.id !== undefined && this.waiting.has(m.id)) {
        const w = this.waiting.get(m.id); this.waiting.delete(m.id); clearTimeout(w.timer)
        m.error ? w.reject(new Error(m.error.message || 'MCP-Fehler')) : w.resolve(m.result)
      } else if (m.id !== undefined && m.method) {
        // Anfragen des Servers (z. B. roots/list) beantworten wir knapp, damit er nicht hängt
        this.send({ jsonrpc: '2.0', id: m.id, ...(m.method === 'ping' ? { result: {} } : m.method === 'roots/list' ? { result: { roots: [] } } : { error: { code: -32601, message: 'nicht unterstützt' } }) })
      }
    }
  }
  send(msg) { if (!this.closed) try { this.child.stdin.write(JSON.stringify(msg) + '\n') } catch {} }
  request(method, params, timeoutMs = 60_000) {
    if (this.closed) return Promise.reject(new Error('Server läuft nicht mehr'))
    const id = this.next++
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.waiting.delete(id); reject(new Error(`Keine Antwort nach ${Math.round(timeoutMs / 1000)} s`)) }, timeoutMs)
      this.waiting.set(id, { resolve, reject, timer })
      this.send({ jsonrpc: '2.0', id, method, params })
    })
  }
  notify(method, params) { this.send({ jsonrpc: '2.0', method, params }) }
  close() { this.closed = true; try { this.child.stdin.end() } catch {}; setTimeout(() => { try { this.child.kill('SIGTERM') } catch {} }, 300).unref?.() }
}

class HttpClient {
  constructor(name, spec) { this.name = name; this.spec = spec; this.next = 1 }
  start() {}
  async post(body, timeoutMs) {
    const res = await fetch(this.spec.url, {
      method: 'POST', signal: AbortSignal.timeout(timeoutMs),
      headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream', 'mcp-protocol-version': PROTOCOL,
                 ...(this.session ? { 'mcp-session-id': this.session } : {}), ...(this.spec.headers || {}) },
      body: JSON.stringify(body),
    })
    const sid = res.headers.get('mcp-session-id'); if (sid) this.session = sid
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    return res
  }
  async request(method, params, timeoutMs = 60_000) {
    const id = this.next++
    const res = await this.post({ jsonrpc: '2.0', id, method, params }, timeoutMs)
    const text = await res.text()
    let msg
    if ((res.headers.get('content-type') || '').includes('event-stream')) {
      for (const block of text.split(/\r?\n\r?\n/)) {
        const data = block.split(/\r?\n/).filter(l => l.startsWith('data:')).map(l => l.slice(5).trim()).join('\n')
        if (!data) continue
        try { const m = JSON.parse(data); if (m.id === id) { msg = m; break } } catch {}
      }
    } else { try { msg = JSON.parse(text) } catch {} }
    if (!msg) throw new Error('Unlesbare Antwort')
    if (msg.error) throw new Error(msg.error.message || 'MCP-Fehler')
    return msg.result
  }
  notify(method, params) { this.post({ jsonrpc: '2.0', method, params }, 15_000).catch(() => {}) }
  close() {}
}

export function loadMcpConfig(files = [], inline = {}) {
  const servers = { ...(inline || {}) }
  for (const f of files) {
    try { Object.assign(servers, JSON.parse(readFileSync(f, 'utf8')).mcpServers || {}) } catch (e) { throw new Error(`MCP-Konfiguration unlesbar (${f}): ${e.message}`) }
  }
  return servers
}

const safe = s => String(s).replace(/[^A-Za-z0-9_-]/g, '-')

function resultText(r) {
  const parts = []
  for (const c of r?.content || []) {
    if (c.type === 'text') parts.push(c.text)
    else if (c.type === 'image') parts.push(`[Bild ${c.mimeType || ''}, ${Math.round((c.data || '').length * 0.75 / 1024)} kB – als Text nicht darstellbar; nutze eine Textansicht der Seite (Snapshot), wenn es eine gibt]`)
    else if (c.type === 'resource') parts.push(c.resource?.text || `[Ressource ${c.resource?.uri || ''}]`)
  }
  if (!parts.length && r?.structuredContent) parts.push(JSON.stringify(r.structuredContent))
  let text = parts.join('\n').trim() || '(keine Ausgabe)'
  if (text.length > 30_000) text = text.slice(0, 12_000) + `\n… (${text.length - 30_000} Zeichen ausgelassen) …\n` + text.slice(-18_000)
  return text
}

/** Verbindet alle Server parallel und meldet ihre Werkzeuge an. Ein Server, der nicht startet, bricht den Lauf nicht ab. */
export async function connectMcp(rt, servers, { out, timeoutMs = 45_000 } = {}) {
  const clients = []
  await Promise.all(Object.entries(servers || {}).map(async ([rawName, spec]) => {
    const name = safe(rawName)
    const c = spec?.url ? new HttpClient(name, spec) : spec?.command ? new StdioClient(name, spec) : null
    if (!c) return
    try {
      c.start()
      await c.request('initialize', { protocolVersion: PROTOCOL, capabilities: {}, clientInfo: CLIENT }, timeoutMs)
      c.notify('notifications/initialized', {})
      let cursor, tools = []
      do {
        const r = await c.request('tools/list', cursor ? { cursor } : {}, timeoutMs)
        tools = tools.concat(r?.tools || []); cursor = r?.nextCursor
      } while (cursor && tools.length < 400)
      for (const t of tools) {
        const full = `mcp__${name}__${safe(t.name)}`.slice(0, 64)
        rt.tool({
          name: full, label: full, mcp: { server: name, tool: t.name },
          description: String(t.description || t.name).slice(0, 1200),
          parameters: t.inputSchema && t.inputSchema.type === 'object' ? t.inputSchema : { type: 'object', properties: {} },
          readOnly: t.annotations?.readOnlyHint === true,
          async run(args, ctx) {
            // Freigaben können dauern (der Besitzer entscheidet) – dafür länger warten
            const wait = t.name === 'freigabe' ? 16 * 60_000 : 5 * 60_000
            try {
              const r = await c.request('tools/call', { name: t.name, arguments: args || {} }, wait)
              return r?.isError ? { error: resultText(r) } : { output: resultText(r) }
            } catch (e) { return { error: `${name}: ${e.message}` } }
          },
        })
      }
      clients.push(c)
      out?.info?.(`${name}: ${tools.length} Werkzeuge verbunden`, 0)
    } catch (e) {
      out?.warn?.(`${name} nicht verbunden: ${e.message}`, 0)
      try { c.close() } catch {}
    }
  }))
  return { clients, close() { for (const c of clients) try { c.close() } catch {} } }
}
