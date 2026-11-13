// Abo-Anbieter: Prompt, Antwort-Auslese und ein kompletter Lauf mit einer Ersatz-Kommandozeile (kein Netz, kein Abo nötig).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, writeFileSync, readFileSync, chmodSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { tmpdir } from 'node:os'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { extractJSON, parseReply, buildPrompt } from '../providers/subscription.mjs'

const CLI = join(dirname(fileURLToPath(import.meta.url)), '..', 'cli.mjs')
const tools = [{ name: 'read', description: 'Datei lesen', parameters: { type: 'object' } }, { name: 'edit', description: 'ändern', parameters: { type: 'object' } }]

test('extractJSON findet das Objekt auch mit Text und Codeblock drumherum', () => {
  assert.deepEqual(extractJSON('Klar!\n```json\n{"text":"hi","toolCalls":[]}\n```'), { text: 'hi', toolCalls: [] })
  assert.equal(extractJSON('{"a":1} dann {"text":"x"}').text, 'x')
  assert.equal(extractJSON('kein json'), null)
  assert.equal(extractJSON('{"text":"mit } in text","toolCalls":[]}').text, 'mit } in text')
})

test('parseReply: unbekannte Werkzeuge fliegen raus, Klartext wird Endergebnis', () => {
  const r = parseReply('{"text":"","toolCalls":[{"name":"read","args":{"path":"a"}},{"name":"gibtsnicht","args":{}}]}', tools)
  assert.equal(r.toolCalls.length, 1)
  assert.equal(r.toolCalls[0].name, 'read')
  assert.deepEqual(parseReply('Einfach Text', tools), { text: 'Einfach Text', toolCalls: [] })
})

test('buildPrompt enthält System, Werkzeuge und Gespräch und kürzt lange Ergebnisse', () => {
  const p = buildPrompt({ system: 'SYS', tools, messages: [{ role: 'user', content: 'Aufgabe' }, { role: 'tool', toolCallId: '1', content: 'x'.repeat(30000) }] })
  assert.ok(p.includes('SYS') && p.includes('- read:') && p.includes('[Nutzer] Aufgabe') && p.includes('gekürzt'))
  assert.ok(p.length < 20000)
})

test('kompletter Lauf über eine Ersatz-Kommandozeile (claude-cli): lesen, ändern, fertig – ohne Schlüssel', () => {
  const dir = mkdtempSync(join(tmpdir(), 'sub-'))
  writeFileSync(join(dir, 'a.txt'), 'Hallo Welt\n')
  const state = join(dir, 'n'); writeFileSync(state, '0')
  const fake = join(dir, 'fake-claude')
  writeFileSync(fake, `#!/usr/bin/env node
const fs = require('fs'); let n = +fs.readFileSync(${JSON.stringify(state)}, 'utf8'); fs.writeFileSync(${JSON.stringify(state)}, String(n + 1))
if (!process.argv.includes('--tools')) process.exit(3)
const replies = [
  'Ich lese zuerst.\\n{"text":"","toolCalls":[{"name":"read","args":{"path":"a.txt"}}]}',
  '{"text":"","toolCalls":[{"name":"edit","args":{"path":"a.txt","old_text":"Hallo","new_text":"Servus"}}]}',
  '{"text":"Geändert: a.txt","toolCalls":[]}']
process.stdin.resume(); process.stdin.on('data', () => {}); process.stdin.on('end', () => process.stdout.write(replies[n] || replies[2]))
`)
  chmodSync(fake, 0o755)
  const r = spawnSync('node', [CLI, '--provider', 'claude-cli', '--cwd', dir, '--json', 'ändere Hallo'], {
    encoding: 'utf8', env: { ...process.env, SALENTA_HARNESS_CLAUDE_BIN: fake, SALENTA_HARNESS_HOME: join(dir, '.home'), SALENTA_HARNESS_NO_FALLBACK: '1' },
  })
  const events = r.stdout.split('\n').filter(Boolean).map(l => JSON.parse(l))
  assert.equal(r.status, 0, r.stderr + r.stdout)
  assert.equal(readFileSync(join(dir, 'a.txt'), 'utf8'), 'Servus Welt\n')
  assert.equal(events.at(-1).status, 'success')
})

test('Limit der Kommandozeile wird als Limit gemeldet (Agentwechsel)', () => {
  const dir = mkdtempSync(join(tmpdir(), 'sub-'))
  const fake = join(dir, 'fake-claude')
  writeFileSync(fake, '#!/bin/sh\ncat >/dev/null\necho "5-hour usage limit reached" >&2\nexit 1\n'); chmodSync(fake, 0o755)
  const r = spawnSync('node', [CLI, '--provider', 'claude-cli', '--cwd', dir, '--json', 'tu was'], {
    encoding: 'utf8', env: { ...process.env, SALENTA_HARNESS_CLAUDE_BIN: fake, SALENTA_HARNESS_HOME: join(dir, '.home'), SALENTA_HARNESS_NO_FALLBACK: '1' },
  })
  assert.match(r.stdout + r.stderr, /quota exceeded/)
})
