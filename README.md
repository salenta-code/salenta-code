# Salenta Code

> **The free, open-source workspace for AI coding agents on the Mac.**

**One window for all your AI agents on the Mac.** Write what should get done – Salenta Code picks the right agent
(Claude Code, Codex, Cursor, Gemini CLI, OpenCode, Grok Build, Kiro, Pi, Junie or its own OS Agent) together with the
best model, skills and tools, shows live what it is doing, verifies the result before you merge, and keeps an overview of
your projects, mails and limits – so you can stay focused on the work.

*Deutsch weiter unten.*

- **Native macOS app** (SwiftUI, macOS 14+). English and German UI.
- **Works with the agents you have installed** – Claude Code, Codex, Cursor, Gemini CLI, OpenCode, Grok Build, Kiro, Pi, Junie – each with your own sign-in or API key. Open-source models (Qwen, DeepSeek, Kimi, GLM …) via OpenRouter or locally via Ollama.
- **Everything local.** Tokens stay in `~/Library/Application Support`, your data in `data/` (git-ignored).

## Features

| | |
|---|---|
| **New task** | A Claude-style prompt box. *Automatic* routing: building → Claude Code in the matching repo, debugging → Junie, review → Codex, everything else → OS Agent. Suggests repos and skills you can accept with one click. |
| **Verification loop** | When a coding agent finishes, Salenta Code builds and tests its worktree (swift, npm/pnpm/yarn, cargo, go, pytest, Shopify Theme Check or your own commands), screenshots UI changes (dev server + headless Chrome) and lets a *second* model review the diff (Codex reviews Claude and vice versa). Red? One automatic fix round, then you decide: merge, pull request (with the verification report) or discard. |
| **Projects** | One card per repo: branch, uncommitted/unpushed changes, open pull requests with check status, CI, Vercel/Sentry links, related mails, running and waiting tasks – *Continue* starts a task with all of that as context. |
| **Usage & limits** | Token usage per agent and model (from Claude Code and Codex logs, Codex limits straight from OpenAI), 5-hour and weekly gauges. When an agent gets tight, new tasks automatically go to agents with headroom (or Opus → Sonnet); when one hits its limit mid-task, another agent takes over. |
| **Learning routing** | The router remembers what worked: merged, PR, discarded, verification results and your own picks per kind of task – and uses it for the next decision. It also switches on only the MCP tools a task needs. |
| **Persistent sessions** | Every agent runs in a background tmux session (`brew install tmux`) – close Salenta Code and the agents keep working; on start it reattaches to all of them. Without tmux, dialogs resume (`--resume`) and interrupted runs continue from where they stopped. |
| **Proposal before start** | *Automatic* analyses the task and proposes agent, model, project, skills and extensions – start, change or reject it (then it simply runs Claude Code as usual). Missing tools that would help are suggested with one-click install. |
| **Extensions** | Curated free plugins, MCP servers and skills (Playwright, Context7, Security Guidance, Superpowers, Caveman, Serena, Sentry, Vercel, Supabase …) with explanation and one-click install – plus a daily search for new top repos (≥ 3,000 ⭐, maintained, licensed) that pass an automatic prompt-injection and malware check. |
| **Mods** | Small automations that run on events: update the changelog after a merge, write missing tests, security review, dependency audit, deploy (asks first), Slack/Discord webhook, daily report. Describe your own mod and the OS Agent builds it. |
| **Models** | The model list comes from each CLI and shows only current models (all others one click away). Open-source models via OpenRouter (pay per use) or Ollama (local, free). API-key mode for teams. |
| **Voice input** | Microphone button or ⌥⌘D: Apple's on-device speech model live, refined by Whisper large-v3-turbo (local). |
| **Vibe-coding tools** | Paste screenshots into a task, plan first, solve with 2–3 agents in parallel and pick the best, live preview of the worktree, checkpoints, secret scan, push notifications to your phone (ntfy). |
| **Rules** | Text rules for every task plus hard block rules (regex) enforced in the approval step even in auto mode – globally or per repo (`.salenta-os.json`, which also holds your verify commands). |
| **Focus mode** | Only approvals, finished tasks and urgent mails get through. |
| **OS Agent** | A background agent (engine: Claude Code headless) with all connected MCP integrations, Salenta Code itself (to-dos, calendar, mail, Obsidian) and a browser (Playwright, your Chrome via extension or its own profile). Delegates coding to Claude Code / Junie / Codex and works with the results. |
| **Approvals** | Reading runs freely; sending, changing, deleting, `git push`, deploys ask you in a bar at the top. *Auto mode* (1 h / until tonight / always) with a log of everything auto-approved. |
| **Tasks as chats** | Every task is a conversation: your message, each step (reads, runs, edits, thinks), the result. Status: running · waiting for you · done – review · failed. *Close* when done. Hand a task over to another agent mid-way. |
| **Stay awake** | Keep the Mac running so agents work through the night – timed, until tomorrow morning, or automatically while agents are busy. Optionally with the lid closed (one-time sudoers rule you install yourself): display off, chatty apps frozen, sound off, Low Power Mode; battery and heat guards; a crash-safe recovery journal plus a launchd backstop; iPhone hotspot failover and a "continue" nudge for agents after a network drop. |
| **Live window** | ⌘L – everything that is working right now, large and in real time, optionally always on top. |
| **Claude Code & Codex history** | All sessions from other terminals (last 30 days) as chats; continue any of them inside Salenta Code. |
| **Integrations** | Salenta Code is an MCP client: imports servers from Claude Code, Claude Desktop, Codex, Cursor, Junie; catalog with 60+ servers; OAuth; run any tool from a form; install servers into all agents with one click. Every connected server gets its own page. |
| **Mail & Calendar** | Native: all Apple Mail accounts (read, reply, signatures per account) and all macOS calendars (EventKit). |
| **Knowledge** | Optional Obsidian vault: the app keeps `Salenta Code/Lage.md` (current state) and a daily journal; every agent gets it as context. |
| **Apps** | Web apps embedded in the window (logins persist) or Mac apps as launchers – add, edit, reorder, remove in the sidebar. |
| **Areas** | Your own areas (companies, projects, clients) with colors, `#tags` and keywords that match repos. |

## Install

Requirements: macOS 14+, Apple Command Line Tools (`xcode-select --install`). Recommended: at least one agent CLI
(`claude`, `codex` or `junie`), Node.js (browser for the OS Agent), Google Chrome, GitHub CLI.

```bash
git clone https://github.com/salenta-code/salenta-code.git
cd salenta-code
./Install.command        # or double-click it in Finder
```

The app is installed to `~/Applications/Salenta Code.app`. On first start a short setup detects what is on your Mac
(agent CLIs, MCP servers, Obsidian, Chrome), asks for your name and areas and connects calendar and mail.
Everything can be changed later in Settings (⌘,).

Agent CLIs (install the ones you use – Salenta Code detects them automatically):

| Agent | Install | Login |
|---|---|---|
| Claude Code | `curl -fsSL https://claude.ai/install.sh \| bash` | `claude auth login` |
| Codex | `npm i -g @openai/codex` | `codex login` |
| Cursor | `curl https://cursor.com/install -fsS \| bash` | `cursor-agent login` |
| Gemini CLI | `npm i -g @google/gemini-cli` | first start |
| OpenCode | `curl -fsSL https://opencode.ai/install \| bash` | `opencode auth login` |
| Grok Build | see x.ai/cli | `grok login` |
| Kiro | `curl -fsSL https://cli.kiro.dev/install \| bash` | `kiro-cli login` |
| Pi | `npm i -g @mariozechner/pi-coding-agent` | `pi` → `/login` |
| Junie | see junie.jetbrains.com | |

Rebuild after changes: menu **Salenta Code › Rebuild and restart** or `cd App && ./build.sh --open`.
A second install next to an existing one: `AOS_APP_NAME="Salenta Code Dev" AOS_BUNDLE_ID=io.example.aos-dev App/build.sh --open`.

## How it fits together

- `App/` – the SwiftUI app (Swift package, built with `App/build.sh`)
- `bin/aos` – to-do CLI for you and the agents · `bin/aos-mcp` – Salenta Code as an MCP server (to-dos, calendar, mail, Obsidian, delegation, approvals) · `bin/aos-live` – turns agent output into readable live steps
- `data/` – your to-dos, areas, tasks, MCP list (git-ignored) · `data/mcp-catalog.json` – integration catalog
- `AGENTS.md` – rules every agent reads

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). License: [Apache 2.0](LICENSE) (see [NOTICE](NOTICE) – the Salenta name and logo are not licensed).

## Your agents, your accounts

Salenta Code only starts the official command-line tools on your own Mac – it never sees, stores or forwards your
sign-in, and it does not provide or resell access to any AI model. Each provider's terms apply to how you use their
tool (e.g. Anthropic counts non-interactive `claude -p` runs against a separate monthly Agent SDK allowance). For teams
and companies we recommend API keys (Settings › Models). Third-party extensions are installed at your own risk.

---

## Deutsch

**Ein Fenster für alle deine KI-Agents auf dem Mac.** Du schreibst, was erledigt werden soll – Salenta Code wählt den
passenden Agent (Claude Code, Codex, Junie oder den eigenen OS-Agent), zeigt live, was er tut, fragt vor dem
Senden und behält den Überblick, was läuft, auf dich wartet oder fertig ist.

- Kostenlos und Open Source (Apache 2.0). Arbeitet mit deinen installierten Agents – jeweils mit deinem eigenen Login oder API-Schlüssel. Alles bleibt lokal.
- **Automatisch:** Bauen → Claude Code im passenden Repo, Fehlersuche → Junie, Review → Codex, alles andere → OS-Agent. Repos und Skills werden vorgeschlagen.
- **Freigaben** vor dem Senden oder Ändern, **Auto-Modus** mit Protokoll.
- **Aufträge als Chat** mit Status, Übergabe an einen anderen Agent, **Live-Fenster** (⌘L).
- **Prüfschleife:** Build, Tests, Screenshot und Review durch ein zweites Modell, bevor du übernimmst – bei Rot bessert der Agent einmal selbst nach.
- **Projekte:** eine Karte pro Repo mit Git-Stand, Pull Requests, CI, Mails und laufenden Aufträgen.
- **Verbrauch:** Tokens und Limits pro Agent und Modell; wird es eng, übernehmen automatisch andere Agents.
- **Sitzungen bleiben:** mit tmux laufen Agents weiter, auch wenn die App zu ist, und kommen beim Start wieder.
- **Regeln** (auch hart blockierend), **Fokus-Modus**, Mail → Auftrag mit einem Klick.
- **Vorschlag vor dem Start** (Agent, Modell, Skills, Erweiterungen – starten, ändern oder ablehnen), **Erweiterungen** mit Ein-Klick-Installation und täglicher, geprüfter Suche nach neuen Top-Repos, **Mods** (Automatiken bei Ereignissen), **Spracheingabe** (Apple + Whisper, lokal), Open-Source-Modelle über **OpenRouter** oder **Ollama**.
- **Integrationen** per MCP (Import aus Claude Code, Codex, Cursor …, Katalog, OAuth), Mail und Kalender nativ, Obsidian als Gedächtnis, eigene Web- und Mac-Apps, eigene Bereiche.

Installation: Repo klonen, `Install.command` doppelklicken. Beim ersten Start führt eine kurze Einrichtung durch alles.
Die Oberfläche folgt der Sprache deines Macs (Deutsch oder Englisch).
