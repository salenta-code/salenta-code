# Salenta Code – rules for agents

This folder is Salenta Code: a native Mac app (`App/`) plus shared data (`data/`).
Claude Code, Codex, Junie and the built-in OS Agent work on the same to-dos the user sees in the app.

## To-dos

All to-dos live in `data/tasks.json`. The app reloads the file as soon as it changes. Prefer the CLI:

```bash
bin/aos list                          # open to-dos
bin/aos list heute --company arbeit   # areas come from data/areas.json
bin/aos add "Text #arbeit ! morgen"   # #area, ! = high, heute/morgen/fr/15.11.
bin/aos done <id> "Short summary of what you did"
bin/aos move <id> warten
bin/aos note <id> "Progress"
```

Set `AOS_SOURCE=claude` (or codex, junie) when you create to-dos.
Writing the JSON directly: format `{"version":1,"tasks":[…]}`, fields
`id, title, notes, company, status, priority (0-2), due (YYYY-MM-DD), agent, createdAt, doneAt, source`.
Status: `inbox | heute | woche | warten | erledigt`. Write atomically (temp file + rename).

## When you get a task from Salenta Code

1. The id is in the task. Work on it.
2. At the end: `bin/aos done <id> "Result in 1–3 sentences"`.
3. If you need the user: `bin/aos move <id> warten` and `bin/aos note <id> "Question: …"`.

## Ground rules

- Never put passwords, tokens or API keys into this folder, a repo or notes.
- Follow the user's own rules (Settings › Profile) – the OS Agent gets them with every task.

## Shared memory (Obsidian, optional)

If an Obsidian vault is connected, its path is in `data/status.json` → `obsidian_vault`.
- Before working: read `Salenta OS/Lage.md` in the vault (to-dos, calendar, running agents – kept up to date by the app).
- After working: add a short entry to `Salenta OS/Journal/YYYY-MM-DD.md` (`## HH:MM · Agent · Topic`) or use the MCP tool `obsidian_schreiben` with `modus: journal`.

## Working together

With the MCP tool `delegieren` (server `salenta-os`) you hand part of the work to another agent:
`claude` (build, features, refactoring), `junie` (debugging: find and fix bugs), `codex` (review, double-check, tests),
`os` (everyday work, integrations, mail, browser). Get the result with `warten: true` or later with `ergebnis`.
Helpers don't delegate further. `projekte_und_skills` lists all repos and installed skills on this Mac.

## Developing the app

See `App/CLAUDE.md`: Swift package, built with `App/build.sh`.
