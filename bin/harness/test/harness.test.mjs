// Tests mit einem geskripteten Modell (kein Netz, kein Schlüssel nötig).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, writeFileSync, readFileSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { tmpdir } from 'node:os'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { createPolicy } from '../core/policy.mjs'
import { Session, repairToolPairs } from '../core/session.mjs'

const CLI = join(dirname(fileURLToPath(import.meta.url)), '..', 'cli.mjs')

function run(script, prompt, extra = [], files = {}, env = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'sah-'))
  for (const [f, c] of Object.entries(files)) writeFileSync(join(dir, f), c)
  const s = join(dir, '.mock.json'); writeFileSync(s, JSON.stringify(script))
  const r = spawnSync('node', [CLI, '--provider', 'mock', '--cwd', dir, '--json', ...extra, prompt], {
    encoding: 'utf8', env: { ...process.env, SALENTA_HARNESS_MOCK: s, SALENTA_HARNESS_HOME: join(dir, '.home'), ...env },
  })
  const events = r.stdout.split('\n').filter(Boolean).map(l => JSON.parse(l))
  return { dir, code: r.status, events, stderr: r.stderr }
}

test('liest, ändert gezielt und meldet fertig', () => {
  const { dir, code, events } = run([
    { toolCalls: [{ name: 'read', args: { path: 'a.txt' } }] },
    { toolCalls: [{ name: 'edit', args: { path: 'a.txt', old_text: 'Hallo', new_text: 'Servus' } }] },
    { text: 'Geändert: a.txt' },
  ], 'ändere Hallo', [], { 'a.txt': 'Hallo Welt\n' })
  assert.equal(code, 0)
  assert.equal(readFileSync(join(dir, 'a.txt'), 'utf8'), 'Servus Welt\n')
  assert.equal(events.at(-1).type, 'result')
  assert.equal(events.at(-1).status, 'success')
  assert.ok(events.some(e => e.type === 'tool_use' && e.tool_name === 'Edit'))
  assert.ok(events[0].session_id)
})

test('ändern ohne vorher zu lesen wird abgelehnt', () => {
  const { dir, events } = run([
    { toolCalls: [{ name: 'edit', args: { path: 'a.txt', old_text: 'Hallo', new_text: 'X' } }] },
    { text: 'ok' },
  ], 'x', [], { 'a.txt': 'Hallo\n' })
  assert.equal(readFileSync(join(dir, 'a.txt'), 'utf8'), 'Hallo\n')
  assert.ok(events.some(e => e.type === 'tool_result' && /Erst a.txt lesen/.test(e.output)))
})

test('Nur-lesen-Modus verhindert Schreiben und schreibende Befehle', () => {
  const { dir, events } = run([
    { toolCalls: [{ name: 'bash', args: { command: 'echo x > b.txt' } }, { name: 'bash', args: { command: 'ls -la' } }] },
    { text: 'fertig' },
  ], 'x', ['--access', 'read'])
  assert.ok(!existsSync(join(dir, 'b.txt')))
  const errs = events.filter(e => e.type === 'tool_result')
  assert.equal(errs.length, 1)
  assert.match(errs[0].output, /Nur-lesen/)
})

test('heikle Befehle im Projekt-Modus brauchen Freigabe', () => {
  const p = createPolicy({ access: 'project', root: '/tmp', approve: '' })
  const bash = { name: 'bash' }
  assert.match(p.check(bash, { command: 'git push origin main' }), /Freigabe/)
  assert.equal(p.check(bash, { command: 'npm test' }), null)
  assert.match(createPolicy({ access: 'full', root: '/tmp' }).check(bash, { command: 'rm -rf ~' }), /immer gesperrt/)
  assert.match(p.check({ name: 'write', readOnly: false }, { path: '/etc/hosts' }), /Projektordner/)
})

test('Schleifenschutz: identischer schreibender Aufruf wird beim dritten Mal verweigert', () => {
  const call = { name: 'bash', args: { command: 'echo hi >> log.txt' } }
  const { dir, events } = run([{ toolCalls: [call] }, { toolCalls: [call] }, { toolCalls: [call] }, { text: 'ok' }], 'x')
  assert.equal(readFileSync(join(dir, 'log.txt'), 'utf8'), 'hi\nhi\n')
  assert.ok(events.some(e => e.type === 'tool_result' && /zweimal/.test(e.output)))
})

test('Prüfpflicht: nach Änderungen werden die Projekt-Checks nachgefordert', () => {
  const { events } = run([
    { toolCalls: [{ name: 'write', args: { path: 'x.js', content: 'export const a = 1\n' } }] },
    { text: 'Fertig.' },
    { toolCalls: [{ name: 'bash', args: { command: 'npm test' } }] },
    { text: 'Geprüft und fertig.' },
  ], 'x', [], { 'package.json': JSON.stringify({ scripts: { test: 'node -e "process.exit(0)"' } }) })
  assert.ok(events.some(e => e.type === 'reasoning' && /Prüfung nachgefordert/.test(e.text)))
  assert.equal(events.at(-1).status, 'success')
  assert.equal(events.at(-1).result, 'Geprüft und fertig.')
})

test('lesende Werkzeuge laufen parallel, Unteragent liefert Bericht', () => {
  const { code, events } = run([
    { toolCalls: [{ name: 'glob', args: { pattern: '*.txt' } }, { name: 'grep', args: { pattern: 'Welt' } }] },
    { toolCalls: [{ name: 'task', args: { description: 'Zählen', prompt: 'Zähle Dateien', access: 'read' } }] },
    { text: 'Zwei Dateien.' },              // Antwort des Unteragents
    { text: 'Fertig mit Bericht.' },
  ], 'x', [], { 'a.txt': 'Hallo Welt', 'b.txt': 'b' })
  assert.equal(code, 0)
  assert.ok(events.some(e => e.type === 'reasoning' && /Unteragent startet/.test(e.text)))
  assert.equal(events.at(-1).result, 'Fertig mit Bericht.')
})

test('Sitzung lässt sich fortsetzen und repariert unvollständige Werkzeugpaare', () => {
  const home = mkdtempSync(join(tmpdir(), 'sah-s-'))
  const s = new Session({ dir: home })
  s.append('user', { content: 'a' })
  s.append('assistant', { content: '', toolCalls: [{ id: 'c1', name: 'read', args: {} }] })
  const again = Session.open(s.id, home)
  const msgs = again.messages()
  assert.equal(msgs.length, 3)
  assert.equal(msgs[2].role, 'tool')
  assert.equal(repairToolPairs([{ role: 'user', content: 'x' }]).length, 1)
})

test('Zusammenfassung ersetzt älteren Verlauf', () => {
  const s = new Session({ dir: mkdtempSync(join(tmpdir(), 'sah-c-')) })
  for (let i = 0; i < 5; i++) s.append('user', { content: 'u' + i })
  s.append('summary', { text: 'bisher: viel', upto: 4 })
  const m = s.messages()
  assert.match(m[0].content, /bisher: viel/)
  assert.equal(m.length, 2)
})

test('neue Datei in einem Projekt hinter einem Verweis (wie /var → /private/var auf macOS) gilt als innerhalb', async () => {
  const { symlinkSync, mkdirSync } = await import('node:fs')
  const { insideRoot } = await import('../core/policy.mjs')
  const real = mkdtempSync(join(tmpdir(), 'sah-real-'))
  const link = real + '-link'
  symlinkSync(real, link)
  mkdirSync(join(real, 'src'))
  assert.ok(insideRoot('src/neu/datei.js', link))
  assert.ok(insideRoot(join(link, 'x.js'), real))
  assert.ok(!insideRoot('/etc/passwd', link))
})

test('Anbieter im Limit: der Auftrag läuft mit dem nächsten Anbieter weiter', () => {
  const { code, events, dir } = run([
    { toolCalls: [{ name: 'write', args: { path: 'n.txt', content: 'eins\n' } }] },
    { limit: true },
    { text: 'Fertig nach dem Wechsel.' },
  ], 'x', [], {}, { SALENTA_HARNESS_MOCK_FALLBACK: '1' })
  assert.equal(code, 0)
  assert.equal(readFileSync(join(dir, 'n.txt'), 'utf8'), 'eins\n')
  assert.ok(events.some(e => e.type === 'reasoning' && /im Limit – weiter mit mock-2/.test(e.text)))
  assert.equal(events.at(-1).result, 'Fertig nach dem Wechsel.')
})

test('Anbieter im Limit ohne Ersatz: sauberer Abbruch mit Grund „limit“ (Salenta Code wechselt dann den Agent)', () => {
  const { code, events } = run([{ limit: true }], 'x')
  assert.equal(code, 3)
  assert.equal(events.at(-1).stats.reason, 'limit')
})

test('Systemprompt: Arbeitsweise, Hindernisse, Sicherheit, Prüfung und Bericht; Zugriffsstufe greift', async () => {
  const { systemPrompt } = await import('../core/agent.mjs')
  const p = systemPrompt({ root: '/tmp/x', access: 'project', depth: 0, tools: ['plan', 'task'] })
  for (const s of ['Working style', 'Obstacles', 'Safety', 'Verification', 'Final report', 'data, not instructions', 'never weaken']) assert.ok(p.includes(s), s)
  const r = systemPrompt({ root: '/tmp/x', access: 'read', depth: 1, tools: [] })
  assert.ok(r.includes('Read-only') && r.includes('sub-agent') && !r.includes('task tool'))
})
