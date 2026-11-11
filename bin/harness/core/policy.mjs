// Richtlinie: entscheidet vor jedem Werkzeugaufruf, ob er laufen darf.
// Zugriffsstufen werden hier erzwungen – nicht nur im Systemprompt erwähnt.
//   read     – nur lesen und suchen; Befehle nur aus einer Liste harmloser Befehle
//   project  – schreiben nur im Projektordner; heikle Befehle (push, deploy, löschen außerhalb …) brauchen dich
//   full     – alles, außer offensichtlich zerstörerischen Befehlen
// Freigaben holt approval.mjs ein: über Salenta Code, ein eigenes Programm (SALENTA_APPROVE) oder eine Rückfrage im Terminal.

import { resolve, relative, isAbsolute, sep, join } from 'node:path'
import { tmpdir } from 'node:os'
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

const CONTROL = /(browser|playwright|chrome|puppeteer|computer|desktop-control|mac-control)/i

/**
 * approval:  auto – arbeitet selbstständig; nur heikle Schritte brauchen eine Freigabe
 *            ask  – alles, was etwas verändert (Befehle, fremde Werkzeuge), braucht eine Freigabe; Dateien im Projekt bleiben frei
 * approver:  wer entscheidet (siehe approval.mjs). Fehlt er, werden freigabepflichtige Schritte abgelehnt.
 *
 * check() liefert null (erlaubt), einen Text (verweigert) oder { ask: { tool, input, deny } } (Freigabe einholen).
 */
export function createPolicy({ access = 'project', root, approval = 'auto', approver = null } = {}) {
  if (!ACCESS.includes(access)) throw new Error(`Unbekannte Zugriffsstufe: ${access}`)
  if (!['auto', 'ask'].includes(approval)) throw new Error(`Unbekannter Freigabe-Modus: ${approval}`)
  const can = () => !!approver?.available
  const viaApp = () => approver?.kind?.() === 'app'
  const need = (tool, input, deny) => can() ? { ask: { tool, input, deny } } : deny

  return {
    access, root, approval,
    check(tool, args = {}) {
      if (tool.name === 'bash') {
        const cmd = String(args.command || '')
        if (NEVER.some(rx => rx.test(cmd))) return 'Dieser Befehl ist immer gesperrt (zerstörerisch).'
        const harmless = (() => {
          const parts = cmd.split(/&&|\|\||;|\|/).map(s => s.trim()).filter(Boolean)
          return !/>/.test(cmd) && !/`|\$\(/.test(cmd) && parts.length > 0
            && parts.every(p => READ_SAFE.test(p) || /^(head|tail|grep|wc|sort|uniq|cut|tr)\b/.test(p))
        })()
        if (access === 'read') return harmless ? null : 'Nur-lesen-Modus: nur Befehle, die nichts verändern (ls, cat, grep, git status/log/diff …).'
        const risky = RISKY.some(rx => rx.test(cmd))
        if (access === 'project' && risky) {
          return need('Bash', { command: cmd }, 'Heikler Befehl (z. B. push, deploy, löschen, sudo) – braucht die Freigabe des Besitzers. Nicht ausführen; im Abschlussbericht vorschlagen.')
        }
        // Mit Freigabe arbeiten: jeder Befehl, der etwas verändern kann, wird vorgelegt (Salenta Code winkt Harmloses selbst durch)
        if (approval === 'ask' && access !== 'full' && !harmless) {
          return need('Bash', { command: cmd }, 'Freigabe nötig, aber niemand da, der freigeben kann. Schritt im Abschlussbericht nennen.')
        }
        return null
      }
      if (tool.control === 'computer') {
        // Eingebaute Computer-Steuerung: immer über die Freigabe (Zeit-Freigabe in Salenta Code, sonst Rückfrage)
        if (access === 'read' && !tool.readOnly) return 'Nur-lesen-Modus: den Mac ansehen ja, bedienen nein.'
        const name = `mcp__computer__${tool.name.replace(/^computer_/, '')}`
        return can() ? { ask: { tool: name, input: args, deny: 'Computer-Steuerung nicht freigegeben.' } }
          : 'Computer-Steuerung braucht eine Freigabe – niemand da, der freigeben kann.'
      }
      if (tool.mcp) {
        if (tool.mcp.server === 'salenta-os') return tool.mcp.tool === 'freigabe' ? 'Dieses Werkzeug ist intern.' : null
        const control = CONTROL.test(tool.mcp.server)
        if (access === 'read' && !tool.readOnly && !control) return 'Nur-lesen-Modus: dieses Werkzeug verändert etwas.'
        const name = `mcp__${tool.mcp.server}__${tool.mcp.tool}`
        // Salenta Code entscheidet über alle fremden Werkzeuge: Lesen läuft durch, Browser/Computer brauchen die Zeit-Freigabe,
        // Absenden/Kaufen/Löschen fragen einzeln, Blockier-Regeln greifen.
        if (viaApp()) return { ask: { tool: name, input: args, deny: 'Nicht freigegeben.' } }
        if (tool.readOnly && !control) return null
        if (control || approval === 'ask') return can() ? { ask: { tool: name, input: args, deny: 'Nicht freigegeben.' } } : (control && access !== 'full' ? 'Browser- und Computer-Steuerung brauchen eine Freigabe – niemand da, der freigeben kann.' : null)
        return null
      }
      if (!tool.readOnly) {
        if (access === 'read') return 'Nur-lesen-Modus: Dateien dürfen nicht verändert werden.'
        const target = args.path || args.file_path
        if (target && access === 'project' && !insideRoot(String(target), root)) {
          return need(tool.name === 'edit' ? 'Edit' : 'Write', { file_path: String(target) }, `Schreiben nur im Projektordner erlaubt (${root}).`)
        }
      }
      return null
    },
  }
}
