// Richtlinie: entscheidet vor jedem Werkzeugaufruf, ob er laufen darf.
// Zugriffsstufen werden hier erzwungen – nicht nur im Systemprompt erwähnt.
//   read     – nur lesen und suchen; Befehle nur aus einer Liste harmloser Befehle
//   project  – schreiben nur im Projektordner; heikle Befehle (push, deploy, löschen außerhalb …) brauchen dich
//   full     – alles, außer offensichtlich zerstörerischen Befehlen
// Freigaben: Ist SALENTA_APPROVE gesetzt (Programm), wird es für heikle Aktionen gefragt (Exit 0 = erlaubt).

import { resolve, relative, isAbsolute, sep, join } from 'node:path'
import { tmpdir } from 'node:os'
import { spawnSync } from 'node:child_process'
import { realpathSync, existsSync } from 'node:fs'

export const ACCESS = ['read', 'project', 'full']

const NEVER = [
  /\brm\s+-[a-z]*r[a-z]*f?\s+(\/|~|\$HOME)(\s|$)/i,     // rm -rf / oder ~
  /\bmkfs\b|\bdd\s+if=.*\bof=\/dev\//i,
  /:\(\)\s*\{\s*:\|:&\s*\};:/,                            // Fork-Bombe
]
const RISKY = [
  /\bgit\s+push\b/i, /\bgit\s+reset\s+--hard\b/i, /\bgit\s+clean\s+-[a-z]*f/i, /\bgit\s+branch\s+-D\b/i,
  /\bnpm\s+publish\b/i, /\bvercel\b.*--prod\b/i, /\bnetlify\s+deploy\b.*--prod/i, /\bfly\s+deploy\b/i,
  /\bsudo\b/i, /\b(curl|wget)\b[^|]*\|\s*(sh|bash|zsh)\b/i, /\bkubectl\s+(delete|apply)\b/i,
  /\bdrop\s+(table|database)\b/i, /\bsupabase\s+db\s+(reset|push)\b/i, /\brm\s+-[a-z]*r/i,
  /\bgh\s+(pr\s+merge|release\s+create|repo\s+delete)\b/i, /\bchmod\s+-R\s+777\b/i,
]
const READ_SAFE = /^\s*(ls|cat|head|tail|wc|grep|rg|find|tree|pwd|echo|file|stat|du|which|node\s+--version|npm\s+(ls|view|--version)|git\s+(status|log|diff|show|branch|remote|rev-parse|ls-files|blame))\b/i

// Echter Pfad – auch für Dateien, die es noch nicht gibt: nächster vorhandener Ordner auflösen, Rest anhängen.
// (Auf macOS ist /var ein Verweis auf /private/var; ohne das gälte eine neue Datei im Projekt fälschlich als „außerhalb“.)
function realish(p) {
  let cur = resolve(p)
  const rest = []
  while (!existsSync(cur)) {
    const parent = resolve(cur, '..')
    if (parent === cur) return resolve(p)
    rest.unshift(cur.slice(parent.length + (parent.endsWith(sep) ? 0 : 1)))
    cur = parent
  }
  try { return join(realpathSync(cur), ...rest) } catch { return resolve(p) }
}

export function insideRoot(path, root) {
  const abs = realish(isAbsolute(path) ? path : resolve(root, path))
  const r = realish(root)
  const tmp = realish(tmpdir())
  const inside = (base) => { const rel = relative(base, abs); return rel === '' || (!rel.startsWith('..') && !isAbsolute(rel)) }
  return inside(r) || inside(tmp) || abs.startsWith(sep + 'tmp' + sep)
}

export function createPolicy({ access = 'project', root, approve = process.env.SALENTA_APPROVE } = {}) {
  if (!ACCESS.includes(access)) throw new Error(`Unbekannte Zugriffsstufe: ${access}`)

  function ask(kind, detail) {
    if (!approve) return false
    const r = spawnSync(approve, [kind, detail], { encoding: 'utf8', timeout: 15 * 60 * 1000 })
    return r.status === 0
  }

  return {
    access,
    root,
    /** Liefert null (erlaubt) oder einen Grund (verweigert). */
    check(tool, args = {}) {
      if (tool.name === 'bash') {
        const cmd = String(args.command || '')
        if (NEVER.some(rx => rx.test(cmd))) return 'Dieser Befehl ist immer gesperrt (zerstörerisch).'
        if (access === 'read') {
          const parts = cmd.split(/&&|\|\||;|\|/).map(s => s.trim()).filter(Boolean)
          const ok = !/>/.test(cmd) && !/`|\$\(/.test(cmd) && parts.length > 0
            && parts.every(p => READ_SAFE.test(p) || /^(head|tail|grep|wc|sort|uniq|cut|tr)\b/.test(p))
          return ok ? null : 'Nur-lesen-Modus: nur Befehle, die nichts verändern (ls, cat, grep, git status/log/diff …).'
        }
        if (access === 'project' && RISKY.some(rx => rx.test(cmd))) {
          return ask('bash', cmd) ? null
            : 'Heikler Befehl (z. B. push, deploy, löschen, sudo) – braucht die Freigabe des Besitzers. Nicht ausführen; im Abschlussbericht vorschlagen.'
        }
        return null
      }
      if (!tool.readOnly) {
        if (access === 'read') return 'Nur-lesen-Modus: Dateien dürfen nicht verändert werden.'
        const target = args.path || args.file_path
        if (target && access === 'project' && !insideRoot(String(target), root)) {
          return ask(tool.name, String(target)) ? null : `Schreiben nur im Projektordner erlaubt (${root}).`
        }
      }
      return null
    },
  }
}
