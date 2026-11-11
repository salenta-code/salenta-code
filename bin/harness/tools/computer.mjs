// Computer-Steuerung (macOS): Apps öffnen, Fenster und Bedienelemente als Text lesen, klicken, tippen, Menüs bedienen.
// Arbeitet über die Bedienungshilfen von macOS (System Events) – dadurch auch für Modelle ohne Bildverständnis nutzbar:
// der Agent „sieht“ ein Fenster als Liste seiner Bedienelemente.
// Jede Aktion läuft über die Richtlinie: Die Steuerung muss freigegeben sein, Absenden/Kaufen/Löschen fragen einzeln.
// Voraussetzung: Der startende Prozess (Salenta Code oder das Terminal) darf in den Systemeinstellungen unter
// „Datenschutz & Sicherheit › Bedienungshilfen“ den Mac steuern.

import { spawn } from 'node:child_process'

export const SCRIPTS = {
  apps: `on run argv
  set out to ""
  tell application "System Events"
    repeat with p in (application processes whose background only is false)
      set entryText to (name of p) as text
      if frontmost of p then set entryText to entryText & " (vorn)"
      set entryText to entryText & ": "
      try
        repeat with w in windows of p
          set entryText to entryText & "[" & (name of w) & "] "
        end repeat
      end try
      set out to out & entryText & linefeed
    end repeat
  end tell
  return out
end run`,
  ui: `on run argv
  set appName to item 1 of argv
  set maxItems to (item 2 of argv) as integer
  set out to ""
  with timeout of 40 seconds
    tell application "System Events"
      tell application process appName
        set out to "Fenster: " & (name of front window) & linefeed
        set els to entire contents of front window
        set n to 0
        repeat with e in els
          if n >= maxItems then
            set out to out & "… (weitere Elemente ausgelassen)" & linefeed
            exit repeat
          end if
          try
            set r to (role description of e) as text
            set t to ""
            try
              if name of e is not missing value then set t to (name of e) as text
            end try
            if t is "" then
              try
                set d to (description of e) as text
                if d is not r and d is not "missing value" then set t to d
              end try
            end if
            set ident to ""
            try
              set ident to (value of attribute "AXIdentifier" of e) as text
              if ident is "missing value" then set ident to ""
            end try
            if t is "" then
              try
                set h to (help of e) as text
                if h is not "missing value" then set t to h
              end try
            end if
            set v to ""
            try
              if value of e is not missing value then set v to (value of e) as text
            end try
            if t is not "" or v is not "" or (ident is not "" and r is not "Gruppe" and r is not "group") then
              if (length of v) > 120 then set v to (text 1 thru 120 of v) & "…"
              set entryText to r & " \\"" & t & "\\""
              if ident is not "" and ident is not t then set entryText to entryText & " [id: " & ident & "]"
              if v is not "" and v is not t then set entryText to entryText & " = " & v
              set out to out & entryText & linefeed
              set n to n + 1
            end if
          end try
        end repeat
      end tell
    end tell
  end timeout
  return out
end run`,
  click: `on run argv
  set appName to item 1 of argv
  set wanted to item 2 of argv
  set wantedRole to item 3 of argv
  with timeout of 40 seconds
    tell application "System Events"
      tell application process appName
        set els to entire contents of front window
        repeat with e in els
          set hit to false
          try
            if ((name of e) as text) is wanted then set hit to true
          end try
          if not hit then
            try
              if ((description of e) as text) is wanted then set hit to true
            end try
          end if
          if not hit then
            try
              if ((value of attribute "AXIdentifier" of e) as text) is wanted then set hit to true
            end try
          end if
          if not hit then
            try
              if ((help of e) as text) is wanted then set hit to true
            end try
          end if
          if hit then
            set r to ""
            try
              set r to (role description of e) as text
            end try
            if wantedRole is "" or r contains wantedRole then
              click e
              return "Geklickt: " & r & " \\"" & wanted & "\\""
            end if
          end if
        end repeat
      end tell
    end tell
  end timeout
  error "Kein Bedienelement mit diesem Namen oder dieser id im vorderen Fenster gefunden. Lies das Fenster zuerst mit computer_ui."
end run`,
  clickAt: `on run argv
  set px to (item 1 of argv) as integer
  set py to (item 2 of argv) as integer
  tell application "System Events"
    click at {px, py}
  end tell
  return "Geklickt bei " & px & "," & py
end run`,
  type: `on run argv
  set t to item 1 of argv
  tell application "System Events"
    keystroke t
  end tell
  return "Getippt."
end run`,
  menu: `on run argv
  set appName to item 1 of argv
  tell application "System Events"
    tell application process appName
      set frontmost to true
      if (count of argv) is 3 then
        click menu item (item 3 of argv) of menu (item 2 of argv) of menu bar 1
      else
        click menu item (item 4 of argv) of menu 1 of menu item (item 3 of argv) of menu (item 2 of argv) of menu bar 1
      end if
    end tell
  end tell
  return "Menü gewählt."
end run`,
}

const DIAG = `on run argv
  set appName to item 1 of argv
  set out to ""
  tell application "System Events"
    tell application process appName
      set out to out & "Fenster: " & (count of windows) & linefeed
      set els to entire contents of front window
      set out to out & "Elemente: " & (count of els) & linefeed
      set n to 0
      repeat with e in els
        if n >= 45 then exit repeat
        set entryText to ""
        try
          set entryText to entryText & (class of e as text)
        end try
        try
          set entryText to entryText & " | role=" & (role of e as text)
        end try
        try
          set entryText to entryText & " | rdesc=" & (role description of e as text)
        end try
        try
          set entryText to entryText & " | name=" & (name of e as text)
        end try
        try
          set entryText to entryText & " | desc=" & (description of e as text)
        end try
        try
          set entryText to entryText & " | title=" & (title of e as text)
        end try
        try
          set entryText to entryText & " | val=" & (value of e as text)
        end try
        try
          set entryText to entryText & " | id=" & (value of attribute "AXIdentifier" of e as text)
        end try
        try
          set entryText to entryText & " | help=" & (help of e as text)
        end try
        set out to out & entryText & linefeed
        set n to n + 1
      end repeat
    end tell
  end tell
  return out
end run`

const KEYS = { return: 36, enter: 36, tab: 48, space: 49, delete: 51, backspace: 51, escape: 53, esc: 53, left: 123, right: 124, down: 125, up: 126,
               home: 115, end: 119, pageup: 116, pagedown: 121, forwarddelete: 117, f1: 122, f2: 120, f3: 99, f4: 118, f5: 96 }
const MODS = { cmd: 'command down', command: 'command down', shift: 'shift down', alt: 'option down', option: 'option down', ctrl: 'control down', control: 'control down' }

/** „cmd+shift+s“ → AppleScript-Zeile. Wirft bei unbekannten Tasten. */
export function keyScript(combo) {
  const parts = String(combo).toLowerCase().split('+').map(s => s.trim()).filter(Boolean)
  const key = parts.pop()
  const mods = parts.map(m => { if (!MODS[m]) throw new Error(`Unbekannte Zusatztaste: ${m}`); return MODS[m] })
  const using = mods.length ? ` using {${[...new Set(mods)].join(', ')}}` : ''
  if (key in KEYS) return `tell application "System Events" to key code ${KEYS[key]}${using}`
  if ([...key].length === 1) return `tell application "System Events" to keystroke ${JSON.stringify(key)}${using}`
  throw new Error(`Unbekannte Taste: ${key}`)
}

function explain(err) {
  const e = String(err)
  if (/assistive|-25211|Hilfszugriff|Bedienungshilfen/i.test(e)) return 'macOS erlaubt die Steuerung noch nicht: In den Systemeinstellungen unter „Datenschutz & Sicherheit › Bedienungshilfen“ Salenta Code (oder das Terminal) einschalten. Das kann nur der Besitzer.'
  if (/-1743|not authorized to send apple events/i.test(e)) return 'macOS erlaubt die Automation noch nicht: In den Systemeinstellungen unter „Datenschutz & Sicherheit › Automation“ den Zugriff auf „System Events“ einschalten. Das kann nur der Besitzer.'
  if (/-1719|Can.t get window|Fenster .* nicht|Ungültiger Index/i.test(e)) return 'Diese App hat gerade kein Fenster, oder das Element gibt es nicht (mehr). Fenster erst öffnen bzw. mit computer_ui neu lesen.'
  if (/-1728|Can.t get application process|process .* doesn.t exist/i.test(e)) return 'Diese App läuft nicht oder heißt anders. Mit computer_apps die laufenden Apps ansehen oder sie mit computer_open öffnen.'
  return e.trim().split('\n').pop().slice(0, 400)
}

function osascript(script, args = [], { timeoutSec = 40 } = {}) {
  return new Promise(resolve => {
    const child = spawn('/usr/bin/osascript', ['-e', script, ...args.map(String)], { stdio: ['ignore', 'pipe', 'pipe'] })
    let out = '', err = ''
    child.stdout.on('data', d => { out += d }); child.stderr.on('data', d => { err += d })
    const timer = setTimeout(() => { try { child.kill('SIGKILL') } catch {} }, timeoutSec * 1000)
    child.on('close', code => {
      clearTimeout(timer)
      if (code === null) return resolve({ error: 'macOS hat nicht geantwortet. Meist wartet auf dem Bildschirm die Abfrage, ob Salenta Code „System Events“ steuern darf, oder die Freigabe unter „Datenschutz & Sicherheit › Bedienungshilfen“ fehlt. Das kann nur der Besitzer erlauben.' })
      resolve(code === 0 ? { output: out.trim() || '(keine Ausgabe)' } : { error: explain(err || `Exit ${code}`), raw: (err || '').trim().split('\n').pop() })
    })
    child.on('error', e => { clearTimeout(timer); resolve({ error: `osascript nicht startbar: ${e.message}` }) })
  })
}

function open(args) {
  return new Promise(resolve => {
    const child = spawn('/usr/bin/open', args, { stdio: ['ignore', 'pipe', 'pipe'] })
    let err = ''
    child.stderr.on('data', d => { err += d })
    child.on('close', code => resolve(code === 0 ? { output: 'Geöffnet.' } : { error: err.trim() || `Exit ${code}` }))
    child.on('error', e => resolve({ error: e.message }))
  })
}

/** run: (script, args) => {output}|{error} – austauschbar für Tests. */
export function computerTools(rt, { run = osascript, opener = open } = {}) {
  const def = (name, description, properties, required, fn, readOnly = false) => rt.tool({
    name: `computer_${name}`, label: `Computer:${name}`, control: 'computer', readOnly, description,
    parameters: { type: 'object', properties, required }, run: fn,
  })
  const app = { type: 'string', description: 'App name exactly as shown by computer_apps, e.g. "Finder"' }

  def('apps', 'List the running apps and their windows on this Mac. Start here before you operate the desktop.', {}, [], () => run(SCRIPTS.apps), true)
  def('ui', 'Read the front window of an app as text: every control with its kind, name, id and value. Use this to see what you can click or where to type. Controls without a name are clicked by their id.',
      { app, max: { type: 'integer', description: 'max. number of controls (default 200)' } }, ['app'],
      ({ app: a, max = 200 }) => run(SCRIPTS.ui, [a, Math.min(600, Math.max(20, max))]), true)
  def('open', 'Open an app (by name), a file or folder (by path) or a web address in the default browser.',
      { target: { type: 'string', description: 'App name, path or https:// address' } }, ['target'],
      ({ target }) => /^(https?:\/\/|\/|~)/.test(target) ? opener([target.replace(/^~/, process.env.HOME || '~')]) : opener(['-a', target]))
  def('click', 'Click a control in the front window of an app by its exact name or its id (both from computer_ui). Give "role" (e.g. "button", "Taste") if several controls share the name. Alternatively click at screen coordinates x,y.',
      { app, name: { type: 'string' }, role: { type: 'string' }, x: { type: 'integer' }, y: { type: 'integer' } }, [],
      ({ app: a, name, role = '', x, y }) => {
        if (Number.isInteger(x) && Number.isInteger(y)) return run(SCRIPTS.clickAt, [x, y])
        if (!a || !name) return { error: 'Entweder app + name oder x + y angeben.' }
        return run(SCRIPTS.click, [a, name, role])
      })
  def('type', 'Type text into the control that currently has the keyboard focus (click a text field first).', { text: { type: 'string' } }, ['text'],
      ({ text }) => run(SCRIPTS.type, [text]))
  def('key', 'Press a key or shortcut, e.g. "return", "tab", "escape", "cmd+s", "cmd+shift+z", "down".', { keys: { type: 'string' } }, ['keys'],
      ({ keys }) => { try { return run(keyScript(keys)) } catch (e) { return { error: e.message } } })
  def('menu', 'Choose a menu item of an app by its titles, e.g. menu "Ablage", item "Sichern …" (optional submenu item).',
      { app, menu: { type: 'string' }, item: { type: 'string' }, subitem: { type: 'string' } }, ['app', 'menu', 'item'],
      ({ app: a, menu, item, subitem }) => run(SCRIPTS.menu, subitem ? [a, menu, item, subitem] : [a, menu, item]))
}

/** Selbsttest auf dem Mac: Skripte übersetzen (ohne sie auszuführen) und einmal die laufenden Apps lesen (verändert nichts). */
export async function computerCheck() {
  const lines = []
  if (process.platform !== 'darwin') return { ok: false, lines: ['Computer-Steuerung gibt es nur auf dem Mac.'] }
  const { tmpdir } = await import('node:os')
  const { join } = await import('node:path')
  const { rmSync } = await import('node:fs')
  let ok = true
  const all = { ...SCRIPTS, key: keyScript('cmd+shift+s') }
  for (const [name, script] of Object.entries(all)) {
    const file = join(tmpdir(), `salenta-harness-${name}-${process.pid}.scpt`)
    const r = await new Promise(resolve => {
      const child = spawn('/usr/bin/osacompile', ['-o', file, '-e', script], { stdio: ['ignore', 'pipe', 'pipe'] })
      let err = ''
      child.stderr.on('data', d => { err += d })
      child.on('close', code => resolve({ code, err }))
      child.on('error', e => resolve({ code: 127, err: e.message }))
    })
    try { rmSync(file, { force: true }) } catch {}
    if (r.code !== 0) ok = false
    lines.push(`${r.code === 0 ? '✓' : '✗'} Skript ${name}${r.code === 0 ? '' : ': ' + r.err.trim().split('\n').pop()}`)
  }
  const apps = await osascript(SCRIPTS.apps)
  if (apps.error) { ok = false; lines.push(`✗ Apps lesen: ${apps.error}`) }
  else lines.push(`✓ Apps lesen: ${apps.output.split('\n').filter(Boolean).length} Apps sichtbar`)
  // Fenster lesen braucht die Bedienungshilfen-Freigabe – ohne sie kann der Agent nichts bedienen
  const ui = await osascript(SCRIPTS.ui, ['Finder', 5])
  if (ui.error && /assistive|-25211|Hilfszugriff|Bedienungshilfen/i.test(ui.raw || ui.error)) { ok = false; lines.push('✗ Fenster lesen und bedienen: ' + ui.error) }
  else lines.push('✓ Fenster lesen und bedienen ist erlaubt')
  return { ok, lines }
}

/** Echter Test am Mac (nur auf ausdrücklichen Wunsch): öffnet den Rechner, liest sein Fenster, klickt 7 + 8 = und prüft die Anzeige.
 *  Tippt nichts über die Tastatur (damit nichts in ein anderes Fenster geraten kann) und beendet den Rechner danach wieder. */
export async function computerLive() {
  const lines = []
  let ok = true
  const step = (good, text) => { lines.push(`${good ? '✓' : '✗'} ${text}`); if (!good) ok = false }
  if (process.platform !== 'darwin') return { ok: false, lines: ['Computer-Steuerung gibt es nur auf dem Mac.'] }
  const o = await open(['-g', '-a', 'Calculator'])
  step(!o.error, 'Rechner öffnen' + (o.error ? ': ' + o.error : ''))
  if (o.error) return { ok, lines }
  await new Promise(r => setTimeout(r, 3000))
  try {
    const apps = await osascript(SCRIPTS.apps)
    const name = (apps.output || '').split('\n').map(l => l.split(':')[0].replace(' (vorn)', '').trim()).find(n => /^(Calculator|Rechner)$/i.test(n))
    step(!!name, name ? `Rechner läuft als „${name}“` : 'Rechner nicht unter den laufenden Apps' + (apps.error ? ': ' + apps.error : ''))
    if (!name) return { ok, lines }
    const before = await osascript(SCRIPTS.ui, [name, 200])
    step(!before.error, before.error ? 'Fenster lesen: ' + before.error + (before.raw ? ` [${before.raw.slice(0, 200)}]` : '') : `Fenster gelesen: ${before.output.split('\n').length - 1} Bedienelemente`)
    if (before.error) return { ok, lines }
    if (before.output.split('\n').length - 1 < 3) {
      const d = await osascript(DIAG, [name], { timeoutSec: 60 })
      lines.push('  Diagnose: ' + (d.output || d.error || '').split('\n').join('\n    '))
    }
    const press = async names => { for (const n of names) { const r = await osascript(SCRIPTS.click, [name, n, '']); if (!r.error) return true } return false }
    const seq = [['7', ['7', 'Sieben', 'Seven']], ['+', ['Addieren', 'Add', '+', 'Plus', 'Addition']], ['8', ['8', 'Acht', 'Eight']], ['=', ['Ergebnis', 'Gleich', 'Ist gleich', 'Equals', '=']]]
    let clicked = true
    for (const [label, names] of seq) {
      if (!(await press(names))) { clicked = false; step(false, `Klick auf „${label}“: kein passendes Bedienelement`); break }
    }
    if (clicked) {
      const after = await osascript(SCRIPTS.ui, [name, 200])
      const shows = /(^|[^0-9])15([^0-9]|$)/m.test(after.output || '')
      step(shows, shows ? 'Geklickt: 7 + 8 – in der Anzeige steht 15' : 'Geklickt, aber 15 steht nicht in der Anzeige')
      if (!shows) lines.push('  Anzeige: ' + (after.output || after.error || '').split('\n').slice(0, 8).join(' | '))
    } else lines.push('  Elemente: ' + before.output.split('\n').slice(0, 40).join(' | '))
  } finally {
    spawn('/usr/bin/pkill', ['-x', 'Calculator'], { stdio: 'ignore' })
  }
  return { ok, lines }
}
