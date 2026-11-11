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

const MOCK_MCP = join(dirname(fileURLToPath(import.meta.url)), 'mock-mcp.mjs')
function mcpConfig(dir, withApp = true) {
  const f = join(dir, 'mcp.json')
  const servers = { browser: { command: process.execPath, args: [MOCK_MCP, 'browser'] } }
  if (withApp) servers['salenta-os'] = { command: process.execPath, args: [MOCK_MCP, 'salenta-os'] }
  writeFileSync(f, JSON.stringify({ mcpServers: servers }))
  return f
}

test('Werkzeug-Server: Browser-Werkzeuge laufen über die Freigabe von Salenta Code', () => {
  const cfgDir = mkdtempSync(join(tmpdir(), 'sah-mcp-'))
  const log = join(cfgDir, 'log.txt')
  const { code, events } = run([
    { toolCalls: [{ name: 'mcp__browser__browser_snapshot', args: {} }, { name: 'mcp__browser__browser_click', args: { element: 'OK' } }] },
    { toolCalls: [{ name: 'mcp__browser__browser_click', args: { element: 'Jetzt kaufen' } }] },
    { text: 'Geklickt; der Kauf braucht dich.' },
  ], 'x', ['--mcp-config', mcpConfig(cfgDir)], {}, { MOCK_LOG: log })
  assert.equal(code, 0)
  const text = readFileSync(log, 'utf8')
  assert.match(text, /klick OK/)
  assert.ok(!/klick Jetzt kaufen/.test(text), 'abgelehnter Klick darf nicht ausgeführt werden')
  assert.match(text, /freigabe mcp__browser__browser_click/)
  const errs = events.filter(e => e.type === 'tool_result')
  assert.equal(errs.length, 1)
  assert.match(errs[0].output, /Verweigert: Kaufen braucht dich/)
})

test('Werkzeug-Server ohne Salenta Code: Browser-Steuerung braucht jemanden, der freigibt', () => {
  const cfgDir = mkdtempSync(join(tmpdir(), 'sah-mcp-'))
  const log = join(cfgDir, 'log.txt')
  const { events } = run([
    { toolCalls: [{ name: 'mcp__browser__browser_click', args: { element: 'OK' } }] },
    { text: 'x' },
  ], 'x', ['--mcp-config', mcpConfig(cfgDir, false)], {}, { MOCK_LOG: log, SALENTA_APPROVE: '' })
  assert.ok(!existsSync(log))
  assert.match(events.find(e => e.type === 'tool_result').output, /brauchen eine Freigabe/)
})

test('Mit Freigabe arbeiten: Befehle, die etwas verändern, werden vorgelegt – Lesen bleibt frei', async () => {
  const asked = []
  const approver = { available: true, kind: () => 'program', ask: async (t, i) => { asked.push(t); return { allow: true } } }
  const p = createPolicy({ access: 'project', root: '/tmp', approval: 'ask', approver })
  const bash = { name: 'bash' }
  assert.equal(p.check(bash, { command: 'git status && cat a.txt' }), null)
  assert.equal(p.check(bash, { command: 'npm run build' }).ask.tool, 'Bash')
  assert.equal(p.check({ name: 'write' }, { path: 'a.txt' }), null)
  assert.match(createPolicy({ access: 'project', root: '/tmp', approval: 'ask' }).check(bash, { command: 'npm run build' }), /niemand da/)
  assert.equal(createPolicy({ access: 'project', root: '/tmp', approval: 'auto', approver }).check(bash, { command: 'npm run build' }), null)
  assert.equal(createPolicy({ access: 'project', root: '/tmp', approver }).check(bash, { command: 'git push' }).ask.tool, 'Bash')
})

test('Websuche: Treffer werden aus der Ergebnisseite gelesen', async () => {
  const { parseSearch } = await import('../tools/extra.mjs')
  const html = '<a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.org%2Fdocs&amp;rut=1">Beispiel <b>Doku</b></a><a class="result__snippet" href="x">Kurzer <b>Text</b></a>'
    + '<a rel="nofollow" class="result__a" href="https://example.com/b">Zwei</a>'
  const hits = parseSearch(html)
  assert.equal(hits.length, 2)
  assert.deepEqual(hits[0], { title: 'Beispiel Doku', url: 'https://example.org/docs', snippet: 'Kurzer Text' })
  assert.equal(hits[1].url, 'https://example.com/b')
})

test('Computer-Steuerung: nur mit Freigabe; Kaufen wird abgelehnt; ohne Freigeber gar nicht', async () => {
  const cfgDir = mkdtempSync(join(tmpdir(), 'sah-mcp-'))
  const log = join(cfgDir, 'log.txt')
  const script = [
    { toolCalls: [{ name: 'computer_apps', args: {} }, { name: 'computer_click', args: { app: 'Notizen', name: 'Neue Notiz' } }] },
    { toolCalls: [{ name: 'computer_click', args: { app: 'Shop', name: 'Jetzt kaufen' } }] },
    { text: 'fertig' },
  ]
  const a = run(script, 'x', ['--computer', '--mcp-config', mcpConfig(cfgDir)], {}, { MOCK_LOG: log, SALENTA_HARNESS_COMPUTER_MOCK: '1' })
  assert.equal(a.code, 0)
  assert.match(readFileSync(log, 'utf8'), /freigabe mcp__computer__click/)
  const errs = a.events.filter(e => e.type === 'tool_result')
  assert.equal(errs.length, 1)
  assert.match(errs[0].output, /Kaufen braucht dich/)
  const b = run(script.slice(0, 1).concat([{ text: 'x' }]), 'x', ['--computer'], {}, { SALENTA_HARNESS_COMPUTER_MOCK: '1', SALENTA_APPROVE: '' })
  assert.equal(b.events.filter(e => e.type === 'tool_result' && /niemand da/.test(e.output)).length, 2)
  const c = run([{ toolCalls: [{ name: 'computer_apps', args: {} }] }, { text: 'x' }], 'x', [], {}, { SALENTA_HARNESS_COMPUTER_MOCK: '1' })
  assert.match(c.events.find(e => e.type === 'tool_result').output, /Unbekanntes oder nicht erlaubtes Werkzeug/)
})

test('Computer-Steuerung: Tastenkürzel werden sicher übersetzt', async () => {
  const { keyScript } = await import('../tools/computer.mjs')
  assert.match(keyScript('cmd+shift+s'), /keystroke "s" using \{command down, shift down\}/)
  assert.match(keyScript('return'), /key code 36$/)
  assert.throws(() => keyScript('cmd+" & do shell script "x'), /Unbekannte Taste/)
  assert.throws(() => keyScript('hyper+a'), /Unbekannte Zusatztaste/)
})

test('Entscheidungsfrage: eine Antwort ohne Werkzeuge, im Format der Hilfsmodelle; bei Fehler bleibt die Ausgabe leer', () => {
  const dir = mkdtempSync(join(tmpdir(), 'sah-'))
  const s = join(dir, '.mock.json'); writeFileSync(s, JSON.stringify([{ text: '{"agent":"codex","effort":"low"}' }]))
  const env = { ...process.env, SALENTA_HARNESS_MOCK: s, SALENTA_HARNESS_HOME: join(dir, '.home') }
  const ok = spawnSync('node', [CLI, '--provider', 'mock', 'ask'], { encoding: 'utf8', env, input: 'Welcher Agent? Antworte als JSON.' })
  assert.equal(ok.status, 0)
  const j = JSON.parse(ok.stdout.trim())
  assert.equal(j.type, 'result'); assert.equal(j.is_error, false); assert.equal(j.via, 'harness')
  assert.equal(JSON.parse(j.result).agent, 'codex')
  writeFileSync(s, JSON.stringify([{ text: '' }]))
  const bad = spawnSync('node', [CLI, '--provider', 'mock', 'ask'], { encoding: 'utf8', env, input: 'Frage' })
  assert.equal(bad.status, 1)
  assert.equal(bad.stdout.trim(), '')
  const none = spawnSync('node', [CLI, '--provider', 'mock', 'ask'], { encoding: 'utf8', env, input: '' })
  assert.equal(none.status, 2)
})
