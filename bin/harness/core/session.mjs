// Sitzung = Protokoll, das nur wächst (eine JSON-Zeile je Ereignis).
// Der Gesprächsverlauf für das Modell wird jedes Mal daraus neu aufgebaut – so lassen sich Läufe fortsetzen,
// nachvollziehen und zusammenfassen, ohne dass irgendwo ein zweiter, abweichender Stand entsteht.

import { mkdirSync, appendFileSync, readFileSync, existsSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'
import { randomUUID } from 'node:crypto'

export function harnessHome() {
  return process.env.SALENTA_HARNESS_HOME || join(homedir(), '.salenta-harness')
}

export class Session {
  constructor({ id, dir, parent = null } = {}) {
    this.id = id || randomUUID()
    this.dir = dir || join(harnessHome(), 'sessions')
    this.parent = parent
    mkdirSync(this.dir, { recursive: true })
    this.file = join(this.dir, `${this.id}.jsonl`)
    this.events = existsSync(this.file) ? Session.read(this.file) : []
  }

  static read(file) {
    return readFileSync(file, 'utf8').split('\n').filter(Boolean).flatMap(l => {
      try { return [JSON.parse(l)] } catch { return [] }
    })
  }

  static open(id, dir) {
    const d = dir || join(harnessHome(), 'sessions')
    if (!existsSync(join(d, `${id}.jsonl`))) throw new Error(`Sitzung nicht gefunden: ${id}`)
    return new Session({ id, dir: d })
  }

  static list(dir) {
    const d = dir || join(harnessHome(), 'sessions')
    if (!existsSync(d)) return []
    return readdirSync(d).filter(f => f.endsWith('.jsonl')).map(f => f.slice(0, -6))
  }

  append(type, data = {}) {
    const ev = { type, ts: Date.now(), ...data }
    this.events.push(ev)
    appendFileSync(this.file, JSON.stringify(ev) + '\n')
    return ev
  }

  /**
   * Gesprächsverlauf für das Modell. Nach einer Zusammenfassung zählt nur noch sie plus alles danach.
   * Neutrales Format: { role: 'user'|'assistant'|'tool', content, toolCalls?, toolCallId?, name? }
   */
  messages() {
    let start = 0
    let summary = null
    for (let i = this.events.length - 1; i >= 0; i--) {
      if (this.events[i].type === 'summary') { summary = this.events[i]; start = this.events[i].upto ?? i + 1; break }
    }
    const out = []
    if (summary) out.push({ role: 'user', content: `Zusammenfassung der bisherigen Arbeit (ältere Schritte wurden verdichtet):\n${summary.text}` })
    for (const ev of this.events.slice(start)) {
      if (ev.type === 'user') out.push({ role: 'user', content: ev.content })
      else if (ev.type === 'assistant') out.push({ role: 'assistant', content: ev.content || '', toolCalls: ev.toolCalls || [] })
      else if (ev.type === 'tool') out.push({ role: 'tool', toolCallId: ev.toolCallId, name: ev.name, content: ev.content })
    }
    // Ein Assistent mit Werkzeugaufrufen ohne passende Antworten (Abbruch mitten im Schritt) würde jeden Anbieter
    // stören – fehlende Antworten werden als „abgebrochen“ ergänzt.
    return repairToolPairs(out)
  }

  /** Anzahl der Ereignisse, die zum aktuellen Verlauf gehören (für die Zusammenfassung). */
  get length() { return this.events.length }

  get usage() {
    return this.events.filter(e => e.type === 'usage').reduce((a, e) => ({
      input: a.input + (e.input || 0), output: a.output + (e.output || 0), cached: a.cached + (e.cached || 0),
    }), { input: 0, output: 0, cached: 0 })
  }

  get todos() {
    const t = [...this.events].reverse().find(e => e.type === 'plan')
    return t ? t.items : []
  }
}

export function repairToolPairs(msgs) {
  const out = []
  for (let i = 0; i < msgs.length; i++) {
    const m = msgs[i]
    out.push(m)
    if (m.role === 'assistant' && m.toolCalls?.length) {
      const answered = new Set()
      let j = i + 1
      while (j < msgs.length && msgs[j].role === 'tool') { answered.add(msgs[j].toolCallId); j++ }
      // vorhandene Antworten übernehmen, fehlende ergänzen
      for (let k = i + 1; k < j; k++) out.push(msgs[k])
      for (const c of m.toolCalls) if (!answered.has(c.id)) out.push({ role: 'tool', toolCallId: c.id, name: c.name, content: 'Abgebrochen – kein Ergebnis.' })
      i = j - 1
    }
  }
  return out
}
