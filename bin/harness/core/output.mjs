// Ausgabe: lesbar fürs Terminal oder als JSON-Ereignisstrom (eine Zeile je Ereignis) für Salenta Code.
// Werkzeugnamen werden in die vertrauten Namen übersetzt (Read, Edit, Bash …), damit die Live-Ansicht sie erkennt.

const LABEL_ARGS = (args) => {
  const a = { ...args }
  if (a.path && !a.file_path) a.file_path = a.path
  if (a.items && !a.todos) a.todos = a.items
  return a
}

export function createOutput({ json = false, stream = process.stdout } = {}) {
  const t0 = Date.now()
  const w = (s) => stream.write(s + '\n')
  const ev = (o) => w(JSON.stringify(o))
  const stamp = () => { const s = Math.floor((Date.now() - t0) / 1000); return `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}` }
  const ind = (d) => '  '.repeat(d)
  let steps = 0
  const usage = { input: 0, output: 0, cached: 0 }

  if (json) {
    return {
      init(info) { ev({ type: 'init', session_id: info.sessionId, model: `${info.provider}/${info.model}`, cwd: info.root, access: info.access, agent: 'salenta-harness' }) },
      text(t, d) { ev({ type: 'message', role: 'assistant', content: d ? `↳ ${t}` : t }) },
      tool(name, args, d) { steps++; ev({ type: 'tool_use', tool_name: name, parameters: LABEL_ARGS(args), depth: d }) },
      toolError(msg, d) { ev({ type: 'tool_result', status: 'error', output: msg, depth: d }) },
      info(msg, d) { ev({ type: 'reasoning', text: msg, depth: d }) },
      warn(msg, d) { ev({ type: 'reasoning', text: '⚠ ' + msg, depth: d }) },
      error(msg) { ev({ type: 'error', message: msg }) },
      usage(u) { usage.input += u.input || 0; usage.output += u.output || 0; usage.cached += u.cached || 0; ev({ type: 'usage', ...u, total: { ...usage } }) },
      done(r) { ev({ type: 'result', status: r.ok ? 'success' : 'error', result: r.text, stats: { steps: r.steps, changed: r.changed, usage: r.usage, reason: r.reason || null } }) },
    }
  }
  return {
    init(info) { w(`▶ Salenta Harness · ${info.provider}/${info.model} · ${info.access} · ${info.root}`); w('') },
    text(t, d) { w(''); for (const l of t.trim().split('\n')) w(ind(d) + '  ' + l); w('') },
    tool(name, args, d) { steps++; const a = LABEL_ARGS(args); w(`${stamp()} ${ind(d)}${name} ${a.file_path || a.command || a.pattern || a.url || a.description || ''}`.trimEnd()) },
    toolError(msg, d) { w(`${ind(d)}      ✗ ${msg.split('\n')[0].slice(0, 160)}`) },
    info(msg, d) { w(`${stamp()} ${ind(d)}· ${msg}`) },
    warn(msg, d) { w(`${stamp()} ${ind(d)}⚠ ${msg}`) },
    error(msg) { w(`✗ ${msg}`) },
    usage(u) { usage.input += u.input || 0; usage.output += u.output || 0; usage.cached += u.cached || 0 },
    done(r) {
      w('')
      w(`━━ ${r.ok ? 'Fertig' : 'Abgebrochen'} · ${r.steps} Schritte · ${usage.input + usage.output} Tokens${usage.cached ? ` (${Math.round(usage.cached / Math.max(1, usage.input) * 100)} % aus dem Cache)` : ''}`)
    },
  }
}
