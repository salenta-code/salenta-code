// Datei-Werkzeuge: lesen, schreiben, gezielt ersetzen, Dateien finden, Inhalte suchen.

import { readFileSync, writeFileSync, mkdirSync, existsSync, statSync, readdirSync } from 'node:fs'
import { resolve, dirname, relative, join, isAbsolute } from 'node:path'
import { spawnSync } from 'node:child_process'

const SKIP = new Set(['node_modules', '.git', '.next', 'dist', 'build', '.venv', '__pycache__', '.turbo', '.cache', 'coverage', '.playwright-mcp'])
const MAX_READ = 60_000

const abs = (ctx, p) => (isAbsolute(p) ? p : resolve(ctx.root, p))
const rel = (ctx, p) => relative(ctx.root, p) || '.'

function globToRegex(glob) {
  let rx = ''
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i]
    if (c === '*') {
      if (glob[i + 1] === '*') { rx += '.*'; i++; if (glob[i + 1] === '/') i++ } else rx += '[^/]*'
    } else if (c === '?') rx += '[^/]'
    else if (c === '{') { const end = glob.indexOf('}', i); rx += '(' + glob.slice(i + 1, end).split(',').map(s => s.replace(/[.+^$()|[\]\\]/g, '\\$&')).join('|') + ')'; i = end }
    else rx += c.replace(/[.+^$()|[\]\\]/g, '\\$&')
  }
  return new RegExp('^' + rx + '$')
}

function walk(dir, root, out, limit) {
  let entries = []
  try { entries = readdirSync(dir, { withFileTypes: true }) } catch { return }
  for (const e of entries) {
    if (out.length >= limit) return
    if (SKIP.has(e.name) || (e.name.startsWith('.') && e.name !== '.github')) continue
    const p = join(dir, e.name)
    if (e.isDirectory()) walk(p, root, out, limit)
    else out.push(relative(root, p))
  }
}

export function fileTools(rt) {
  rt.tool({
    name: 'read', label: 'Read', readOnly: true, parallelSafe: true,
    description: 'Read a text file. Use offset/limit (line numbers, 1-based) for large files. Always read a file before editing it.',
    parameters: { type: 'object', properties: { path: { type: 'string' }, offset: { type: 'integer' }, limit: { type: 'integer' } }, required: ['path'] },
    run({ path, offset = 1, limit = 2000 }, ctx) {
      const p = abs(ctx, path)
      if (!existsSync(p)) return { error: `Datei fehlt: ${path}` }
      if (statSync(p).isDirectory()) return { error: `${path} ist ein Ordner – nutze glob.` }
      ctx.state.read.add(p)
      const lines = readFileSync(p, 'utf8').split('\n')
      const from = Math.max(1, offset), to = Math.min(lines.length, from + limit - 1)
      let text = lines.slice(from - 1, to).map((l, i) => `${String(from + i).padStart(5)}\t${l}`).join('\n')
      if (text.length > MAX_READ) text = text.slice(0, MAX_READ) + '\n… (gekürzt – mit offset/limit weiterlesen)'
      return { output: text + (to < lines.length ? `\n… ${lines.length - to} weitere Zeilen` : '') }
    },
  })

  rt.tool({
    name: 'write', label: 'Write',
    description: 'Create or overwrite a file with the full content. Prefer edit for changes to existing files.',
    parameters: { type: 'object', properties: { path: { type: 'string' }, content: { type: 'string' } }, required: ['path', 'content'] },
    run({ path, content }, ctx) {
      const p = abs(ctx, path)
      if (existsSync(p) && !ctx.state.read.has(p)) return { error: `${path} existiert schon – erst lesen, dann gezielt mit edit ändern.` }
      mkdirSync(dirname(p), { recursive: true })
      writeFileSync(p, content)
      ctx.state.read.add(p); ctx.state.changed.add(rel(ctx, p))
      return { output: `Geschrieben: ${rel(ctx, p)} (${content.split('\n').length} Zeilen)` }
    },
  })

  rt.tool({
    name: 'edit', label: 'Edit',
    description: 'Replace an exact text snippet in a file. old_text must match exactly once (include surrounding lines to make it unique). Set replace_all to change every occurrence.',
    parameters: { type: 'object', properties: { path: { type: 'string' }, old_text: { type: 'string' }, new_text: { type: 'string' }, replace_all: { type: 'boolean' } }, required: ['path', 'old_text', 'new_text'] },
    run({ path, old_text, new_text, replace_all = false }, ctx) {
      const p = abs(ctx, path)
      if (!existsSync(p)) return { error: `Datei fehlt: ${path}` }
      if (!ctx.state.read.has(p)) return { error: `Erst ${path} lesen, dann ändern.` }
      const src = readFileSync(p, 'utf8')
      const count = old_text ? src.split(old_text).length - 1 : 0
      if (count === 0) return { error: 'old_text nicht gefunden – Datei neu lesen und den genauen Text (mit Einrückung) verwenden.' }
      if (count > 1 && !replace_all) return { error: `old_text kommt ${count}× vor – mehr Umgebung angeben oder replace_all setzen.` }
      const next = replace_all ? src.split(old_text).join(new_text) : src.replace(old_text, () => new_text)
      writeFileSync(p, next)
      ctx.state.changed.add(rel(ctx, p))
      return { output: `Geändert: ${rel(ctx, p)} (${replace_all ? count : 1} Stelle${count > 1 && replace_all ? 'n' : ''})` }
    },
  })

  rt.tool({
    name: 'glob', label: 'Glob', readOnly: true, parallelSafe: true,
    description: 'Find files by pattern, e.g. "src/**/*.ts" or "**/package.json". Skips node_modules, .git and build folders.',
    parameters: { type: 'object', properties: { pattern: { type: 'string' } }, required: ['pattern'] },
    run({ pattern }, ctx) {
      const all = []; walk(ctx.root, ctx.root, all, 20_000)
      const rx = globToRegex(pattern.replace(/^\.\//, ''))
      const hits = all.filter(f => rx.test(f) || (!pattern.includes('/') && rx.test(f.split('/').pop())))
      return { output: hits.length ? hits.slice(0, 300).join('\n') + (hits.length > 300 ? `\n… ${hits.length - 300} weitere` : '') : 'Keine Treffer.' }
    },
  })

  rt.tool({
    name: 'grep', label: 'Grep', readOnly: true, parallelSafe: true,
    description: 'Search file contents with a regular expression. Optional glob filter (e.g. "*.swift"). Returns file:line:text.',
    parameters: { type: 'object', properties: { pattern: { type: 'string' }, glob: { type: 'string' }, ignore_case: { type: 'boolean' } }, required: ['pattern'] },
    run({ pattern, glob, ignore_case = false }, ctx) {
      const rg = spawnSync('rg', ['-n', '--no-heading', '--max-count', '50', '--max-columns', '300', ...(ignore_case ? ['-i'] : []), ...(glob ? ['-g', glob] : []), '-e', pattern, '.'], { cwd: ctx.root, encoding: 'utf8', timeout: 30_000 })
      let out
      if (rg.error) {
        // ohne ripgrep: eigene Suche
        const files = []; walk(ctx.root, ctx.root, files, 5000)
        const frx = glob ? globToRegex(glob.includes('/') ? glob : '**/' + glob) : null
        const rx = new RegExp(pattern, ignore_case ? 'i' : '')
        const hits = []
        for (const f of files) {
          if (frx && !frx.test(f) && !frx.test(f.split('/').pop())) continue
          let text; try { text = readFileSync(join(ctx.root, f), 'utf8') } catch { continue }
          if (text.length > 2_000_000) continue
          text.split('\n').forEach((l, i) => { if (hits.length < 400 && rx.test(l)) hits.push(`${f}:${i + 1}:${l.slice(0, 300)}`) })
        }
        out = hits.join('\n')
      } else out = rg.stdout
      out = (out || '').trim()
      return { output: out ? (out.length > 30_000 ? out.slice(0, 30_000) + '\n… (gekürzt)' : out) : 'Keine Treffer.' }
    },
  })
}
