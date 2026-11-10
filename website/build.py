#!/usr/bin/env python3
"""Baut die Webseite aus website/src: zweisprachige Texte ([[English||Deutsch]]), gemeinsamer Kopf und Fuß.
Ausgabe: index.html, impressum.html, datenschutz.html (fertige Seiten für GitHub Pages)
und preview.html (nur der Seiteninhalt, für die Vorschau)."""
import json, os, re, html

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "src")

# Anbieterdaten für Impressum und Datenschutz (öffentlich!). Fehlt die Anschrift, bleibt ein gut sichtbarer Platzhalter
# stehen – und der GitHub-Ablauf veröffentlicht die Seite dann nicht.
data = {"address": "", "email": "hello@salenta.ai"}
p = os.path.join(HERE, "impressum.json")
if os.path.exists(p):
    data.update(json.load(open(p, encoding="utf-8")))
ADDRESS = "<br>".join(html.escape(l) for l in data["address"].splitlines() if l.strip()) or \
    '<span class="todo">[ANSCHRIFT FEHLT – Straße Hausnummer, PLZ Ort in website/impressum.json eintragen]</span>'

def bi(s):
    s = s.replace("[[Stripe]]", "&#91;&#91;Stripe&#93;&#93;").replace("[[Postgres]]", "&#91;&#91;Postgres&#93;&#93;")
    s = re.sub(r'(\w[\w-]*)="\[\[(.+?)\|\|(.+?)\]\]"', r'\1="\2"', s)  # in Attributen: Englisch
    return re.sub(r"\[\[(.+?)\|\|(.+?)\]\]", r'<span data-l="en">\1</span><span data-l="de">\2</span>', s, flags=re.S)

AGENTS = [
    ("claude", "CC", "Claude Code", "Anthropic"), ("codex", "Cx", "Codex", "OpenAI"), ("cursor", "Cu", "Cursor", "CLI"),
    ("gemini", "Ge", "Gemini CLI", "Google"), ("junie", "Ju", "Junie", "JetBrains"), ("ollama", "Ol", "Ollama", "[[local||lokal]]"),
    ("github", "GH", "GitHub", "PR · CI"), ("mcp", "MCP", "MCP", "[[servers||Server]]"), ("obsidian", "Ob", "Obsidian", "[[notes||Notizen]]"),
]
def agents(hidden):
    items = "".join(
        f'<li class="ag"><img src="logos/{f}.svg" alt="" onerror="this.remove()"><span class="mono">{m}</span>{n} <small>{s}</small></li>'
        for f, m, n, s in AGENTS)
    attr = ' aria-hidden="true"' if hidden else ""
    return f'<ul{attr}>{items}</ul>'

LOGO = '''<svg class="mark" viewBox="0 0 512 512" aria-hidden="true"><defs><linearGradient id="lbg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2A2A30"/><stop offset="1" stop-color="#0A0A0C"/></linearGradient></defs><rect width="512" height="512" rx="114" fill="url(#lbg)"/><rect x="4" y="4" width="504" height="504" rx="110" fill="none" stroke="#fff" stroke-opacity=".14" stroke-width="8"/><path d="M118 256 H208 L236 168 L276 344 L316 136 L348 256 H394" fill="none" stroke="#fff" stroke-width="34" stroke-linecap="round" stroke-linejoin="round"/><circle cx="394" cy="256" r="22" fill="#fff"/></svg>'''

DMG = "https://github.com/salenta-code/salenta-code/releases/latest/download/Salenta-Code.dmg"

def header(home):
    h = "" if home else "index.html"
    return f'''<header class="top">
  <div class="wrap">
    <a class="brand" href="{h or '#'}" aria-label="Salenta Code">{LOGO}<span class="name">Salenta Code</span></a>
    <nav class="nav" id="nav" aria-label="[[Sections||Bereiche]]">
      <a href="{h}#coding">[[Coding||Coden]]</a>
      <a href="{h}#steward">[[Steward||Betreuer]]</a>
      <a href="{h}#harness">[[New||Neu]]</a>
      <a href="{h}#intelligence">Intelligence</a>
      <a href="{h}#costs">[[Costs||Kosten]]</a>
      <a href="{h}#ship">Pull Requests</a>
      <a href="{h}#local">[[Local||Lokal]]</a>
      <a href="{h}#workspace">[[Workspace||Arbeitsplatz]]</a>
      <a href="{h}#faq">FAQ</a>
      <a href="https://github.com/salenta-code/salenta-code">GitHub</a>
    </nav>
    <span class="grow"></span>
    <div class="lang" role="group" aria-label="Language / Sprache"><button type="button" id="lang-en" data-set="en" aria-pressed="true">EN</button><button type="button" id="lang-de" data-set="de" aria-pressed="false">DE</button></div>
    <a class="btn white sm dl-top" href="{DMG}"><svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2v8M4.5 7L8 10.5 11.5 7M3 13.5h10" stroke="currentColor" stroke-width="1.8" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg><span class="lbl">[[Download||Laden]]</span></a>
    <button type="button" class="menu-btn" aria-controls="nav" aria-expanded="false" aria-label="Menu"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 7h16M4 12h16M4 17h16"/></svg></button>
  </div>
</header>'''

def footer(home):
    h = "" if home else "index.html"
    return f'''<footer>
  <div class="wrap">
    <div><a class="brand" href="{h or '#'}">{LOGO}<span class="name">Salenta Code</span></a><p class="small">[[The free, open-source Mac workspace for AI coding agents.||Der kostenlose Open-Source-Arbeitsplatz für KI-Coding-Agents auf dem Mac.]]</p></div>
    <div><h5>Produkt</h5><ul><li><a href="{h}#coding">[[Coding||Coden]]</a></li><li><a href="{h}#intelligence">Salenta Intelligence</a></li><li><a href="{h}#ship">Pull Requests</a></li><li><a href="{h}#local">[[Local &amp; offline||Lokal &amp; offline]]</a></li><li><a href="{h}#workspace">[[Workspace||Arbeitsplatz]]</a></li></ul></div>
    <div><h5>[[Resources||Ressourcen]]</h5><ul><li><a href="{DMG}">[[Download (.dmg)||Download (.dmg)]]</a></li><li><a href="https://github.com/salenta-code/salenta-code/releases">[[Releases||Versionen]]</a></li><li><a href="https://github.com/salenta-code/salenta-code">[[Source code||Quellcode]]</a></li><li><a href="https://github.com/salenta-code/salenta-code/issues">[[Report a bug||Fehler melden]]</a></li></ul></div>
    <div><h5>[[Legal||Rechtliches]]</h5><ul><li><a href="impressum.html">Impressum</a></li><li><a href="datenschutz.html">[[Privacy||Datenschutz]]</a></li><li><a href="https://github.com/salenta-code/salenta-code/blob/main/LICENSE">[[License (Apache-2.0)||Lizenz (Apache-2.0)]]</a></li></ul></div>
    <div class="base"><span>© 2026 Salenta Code</span><span>[[Not affiliated with Anthropic, OpenAI, Google, JetBrains, Cursor or Ollama. Names are trademarks of their owners.||Keine Verbindung zu Anthropic, OpenAI, Google, JetBrains, Cursor oder Ollama. Namen sind Marken ihrer Inhaber.]]</span></div>
  </div>
</footer>'''

def head(title, desc):
    return f'''<title>{title}</title>
<meta name="description" content="{desc}">
<meta property="og:title" content="{title}">
<meta property="og:description" content="{desc}">
<meta property="og:type" content="website">
<meta property="og:url" content="https://code.salenta.ai/">
<meta property="og:image" content="https://code.salenta.ai/og.png">
<meta name="theme-color" content="#09090b">
<link rel="icon" href="favicon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="apple-touch-icon.png">
<link rel="preload" href="fonts/geist-latin-wght-normal.woff2" as="font" type="font/woff2" crossorigin>
<link rel="stylesheet" href="assets/site.css">'''

def page(name, title, desc, home=False):
    body = open(os.path.join(SRC, name), encoding="utf-8").read()
    body = body.replace("%%AGENTS%%", agents(False)).replace("%%AGENTS_DUP%%", agents(True))
    body = body.replace("%%ADDRESS%%", ADDRESS).replace("%%EMAIL%%", html.escape(data["email"]))
    inner = bi(header(home) + "\n" + ("<main>\n" + body + "\n</main>" if home else body) + "\n" + footer(home)) + '\n<script src="assets/site.js" defer></script>\n'
    full = f'<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n{head(title, desc)}\n</head>\n<body>\n{inner}</body>\n</html>\n'
    open(os.path.join(HERE, name), "w", encoding="utf-8").write(full)
    if home:
        prev = f'{head(title, desc)}\n<meta name="claude:viewport-fit-sides" content="cover">\n{inner}'
        open(os.path.join(HERE, "preview.html"), "w", encoding="utf-8").write(prev)

page("index.html", "Salenta Code", "The free, open-source Mac workspace for AI coding agents: Claude Code, Codex, Cursor, Gemini CLI, Junie and local models – with one-click pull requests, mail, calendar and tasks.", home=True)
page("impressum.html", "Impressum – Salenta Code", "Impressum von Salenta Code (code.salenta.ai)")
page("datenschutz.html", "Datenschutz – Salenta Code", "Datenschutzerklärung von Salenta Code (code.salenta.ai)")
left = [f for f in ("index.html", "impressum.html", "datenschutz.html") if "[[" in open(os.path.join(HERE, f), encoding="utf-8").read()]
print("gebaut", "· offene [[ in: " + ", ".join(left) if left else "· alles übersetzt", "· Anschrift fehlt" if not data["address"] else "")
