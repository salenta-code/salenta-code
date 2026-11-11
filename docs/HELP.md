# Salenta Code – Help

Salenta Code is your workspace for AI coding agents on the Mac. You write what should get done. Salenta Code picks the right agent, gives it the right tools, lets it work in a safe working copy and shows you at the end what changed. You decide what gets taken over.

## Getting started

1. **Install:** download `Salenta-Code.dmg` from the GitHub page, open it and drag the app into the **Applications** folder – like any Mac app. The app is notarized by Apple and starts without a warning. Updates arrive by themselves afterwards.
2. **Open Salenta Code.** On first launch, setup checks what's missing on your Mac (e.g. Git, GitHub CLI, Node, Claude Code) and installs it with one click if you like.
3. **Sign in to a coding agent.** You need at least one: Claude Code, Codex, Cursor, Gemini CLI, Junie and others. You sign in with your own account – Salenta Code doesn't sell or resell model access.
4. **Add a project.** Under **Projects › Add project**: choose a folder on your Mac, connect a GitHub repo (it gets cloned) or create a new project. Salenta Code never scans your Mac on its own.
5. **Write your first task** – at the top under **New task**.

## Starting a task

Type what should happen – the way you'd tell a colleague:

- “Add a dark mode switch to the home page”
- “Why does the login test fail? Find the bug and fix it.”
- “Check the last refactor for security holes – don't change anything.”

Then:

- **Choose project:** click **Choose project** (or name the project in the text). The chosen project shows as a chip in the field – the **×** removes it again. A project always applies to one task only.
- **Automatic** picks the right agent and model. You can choose any agent yourself instead.
- **+** opens more options: attach files, choose skills, **Plan first, then implement**, several agents in parallel.
- **⌘↩** starts. With “Automatic” you first see a proposal (“This is how I would do it”) with agent, model, project, skills and extensions – everything can be changed, then **Start**.

## While the agent works

- Every running task appears in the sidebar under **Tasks**. A green dot means: working right now.
- **Helpers** (sub-agents started by the agent, e.g. for checking) and **mods** are indented under their main task – marked “↳ Helper” or “↳ Mod”.
- Inside the task you see every step live, the context usage and which integrations are active.
- You can write more at any time – the agent continues in the same task.
- **Rewind:** at each of your messages you can jump back to the state before it.

## Approvals – what the agent may do

Agents may change files in the project and run common commands (tests, build, lint, git status …). **Risky steps ask you first** via the approval bar at the top:

- `git push`, force push, deleting, deploying, database changes, publishing, messages to customers

Under **Settings › Rules** you set your own block rules (globally or per project). In the menu bar you can turn on “Let agents work without asking” for a limited time – block rules still apply.

You set up **Salenta Harness** (our own agent) under **Settings › Models**:

- **How it works:** “On its own” only asks for risky steps. “With approval” also shows you every command that can change something.
- **Browser control:** open, read, click and type on pages. **Computer control:** open apps, read windows, click, type and use menus. Before first use Salenta Code asks for how long (15 minutes, 1 hour, all day). Sending, buying, paying, deleting and posting always ask one by one – even in auto mode.
- For computer control, allow Salenta Code once under System Settings › Privacy & Security › Accessibility and confirm the prompt about “System Events”.
- **Check harness** tests key, model, tools, browser and computer control on your Mac – without changing anything.

## Reviewing and taking over changes

Every coding task works in its **own working copy** of your project. Your project folder stays untouched until you take over – so several agents can work at the same time.

- `.env` files, local settings and `node_modules` come along automatically so building and testing works. Add more files to a `.worktreeinclude` file in the project (one per line).
- At the end you see **Changes** with all files and the diff. Configured checks (tests, build) run automatically; a second agent can review if you like. For UI changes Salenta Code takes screenshots at desktop and true phone width (390 px) and the review looks at them – broken layouts fail. Whether content runs past the edge is measured. Anything that was already red or broken before the task does not block.
- **Take over** – the changes go into your branch. Salenta Code then asks whether to **also upload them to GitHub** (normal push, never force).
- **Commits belong to your GitHub account:** in GitHub projects Salenta Code links its own commits and those of the helpers to your account (via GitHub's noreply address; your git configuration stays untouched). Otherwise preview services such as Vercel block the pull request.
- **Pull request …** – one click for commit, push and pull request. Title, description and changelog are already written (from the task and the changes), and you can edit everything. In the same window you see every changed file with its diff, choose **As draft** and the **base**: your branch – or another task's branch, so the PRs build on each other (stacked). Your GitHub sign-in (`gh`) is used.
- **Push more:** while the PR is open, the task stays open. If the agent keeps working, **Push more** uploads the new changes to the same PR – with a rewritten description if you like. **Close** cleans up the working copy; PR and branch stay on GitHub.
- **Discard** – the working copy is deleted, your project stays as it was.

Under **Projects**, a blue arrow with a number shows how many commits aren't on GitHub yet – a click uploads them.

## Projects and the project steward

- **Projects** shows all your projects with branch, open changes, CI status, live preview, terminal and rules. Every colored status explains in one sentence what's wrong and has a button to fix it.
- **Continue** opens a new task directly in that project.
- **Project knowledge** (brain icon): what all agents have learned about the project – pinned entries are given to every agent.
- **Decision model:** before every task the strongest model you already have (Claude or Codex, whichever is available) decides which agent runs it, with which model and thinking depth. No extra key is needed. Can be switched off under Settings › Models – then a small fast model decides.
- **Agent, model, skills and extensions in one go:** The decision model has no fixed favourite. It compares all installed agents (Claude Code, Codex, Cursor and others) with the models their CLI currently offers and the state of their limits, and takes the combination that is strongest for this task. It also goes through all installed skills and extensions – including the repos you added yourself under Extensions – and hands the agent the ones that fit the task: several together when they complement each other (for example a token saver, a design skill and a browser test). An agent only gets what it can load: plugins and Claude skills go to Claude Code, MCP servers to every agent. When Claude Code runs on its own, the instructions of the chosen skills are placed directly in the task (up to six, chosen ones first); anything not loaded is stated there. The proposal before the start shows agent, model, skills and extensions, and you can remove each one. It only picks pay-per-use agents if you allow that under Costs. The project steward plans its helpers by the same rule.
- **Project steward:** hand a project over for stewardship. It works through longer orders (numbered lists too) in your order and reports progress per point. If a result already is a pull request, the button reads “Merge PR #…” and merges exactly that PR. Its helpers run unattended: they wait at most four minutes for an approval, then continue without that step. Pay-per-use agents (e.g. Salenta Harness) are only used when you name the agent in your message. A coordinator plans tasks, starts helpers, watches CI and reports when it needs you. You decide how much it may do on its own.

## Agents, skills and extensions

- **Automatic** assigns like this: building/changing → Claude Code, debugging → Junie, review → Codex, everyday work/research/integrations → your OS agent. If an agent is at its limit, Salenta Code automatically takes another one.
- **Work plan in phases:** every coding task gets a fixed flow – *Understand & plan → Implement → Clean up → Check like the CI → Security → Self-review → Finish*. Each phase lists exactly the installed extensions and skills that help there: e.g. planning tools while planning, docs helpers and frontend design while implementing (for UI tasks), code simplifier while cleaning up, browser tests when checking interfaces, security review for sensitive topics (login, payments, keys, deploy). Token savers run the whole time.
- **Check like the CI:** the agent runs the same checks that run automatically afterwards – including the safe check steps from your GitHub workflows (lint, types, tests, build). So the push to GitHub is green right away as often as possible.
- **Extensions** shows vetted plugins, skills and MCP servers – install with one click. New ones are suggested daily.
- **Integrations** shows all connected services (MCP), sorted by purpose, with status and a repair button.

## Mods – your own automation

Mods react to events and then do something: start an agent, run a command, notify you or call a webhook.

Examples: “After taking over: security check”, “When CI turns red: find the bug”, “When a task is done: write the changelog”. Under **Mods** you find a gallery to get started. Daily and weekly mods catch up if your Mac was asleep at that time.

## Working locally and offline

With **Ollama**, models run right on your Mac – free and private. Under **Settings › Models**:

- **Recommended models** that fit your Mac's memory – download with one click, active immediately. The list updates when new models come out.
- **Switch when the internet is down:** if the internet goes away, tasks continue with the local model.
- **Small tasks locally:** typos, renaming, comments, texts – saves subscription quota. Only when the agent selection rates the task as small and safe, the local model is strong enough, and it didn't fail recently in that project. If the local model can't cope, Claude takes over automatically.
- **Work local only (offline mode):** everything runs on the local model only – tasks, helpers, mods, reviews, summaries. Nothing goes to a cloud AI. Can also be switched in the menu bar.

Under **Usage › Local instead of cloud** you see how much ran locally and what that saved.

## Usage and limits

**Usage** shows per agent how close you are to the limit (e.g. Claude's 5-hour and weekly limits), tokens per day and model, and how successful each agent was. When it gets tight, Salenta Code redistributes new tasks automatically.

## Mail, calendar, tasks, knowledge

Salenta Code is also your daily cockpit – everything synced with the Mac:

- **Mail:** all accounts from Apple Mail – read, reply, archive, hand to an agent.
- **Calendar:** all calendars on the Mac (iCloud, Google, Exchange) – create, move and edit events.
- **Tasks:** your to-dos, optionally synced with Apple Reminders. Agents read and complete them too.
- **Knowledge:** your Obsidian vault – folders, tags, search, edit notes. Agents read it as context and write to the journal.

## Menu bar and widgets

- The **menu bar icon** shows running agents, waiting approvals and updates. Quick switches there: stay awake, agents without asking, local only, notifications, start at login.
- **Widgets:** right-click the desktop › Edit Widgets › Salenta Code.
- **Stay awake:** the Mac doesn't sleep while agents work – with protection for low battery and heat.
- **Night shift:** collect tasks for the night; they run one after another, the report is ready in the morning.

## Voice input and app language

- **Dictation:** wherever you write there's a microphone – or ⌥⌘D. Speak, press again, the text lands in the field. The recording bar shows at the bottom of the window.
- **English or German:** Salenta Code follows your Mac's language. Under **Settings › General › Language** you can set it for the app – your agents then answer in that language too.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘K | Command palette – find and start anything |
| ⌘↩ | Start task / confirm proposal |
| ⌘N | New task |
| ⌘0 | Mission Control (everything that's running) |
| ⌘1 | Cockpit |
| ⌘2 | Tasks |
| ⌘3 | Agents |
| ⌘⇧M | Mail |
| ⌘⇧K | Calendar |
| ⌘T | Start Claude Code in a terminal |
| ⌘? | This help |
| ⌃⌥ Space | Bring Salenta Code to the front from anywhere, or hide it |

Hover over any button to see what it does.

## Updates

Salenta Code checks for new versions automatically. An update is only installed if the checksum matches, it's signed by the same developer and the new version's self-test is green – and only when no agents are running. The previous version is kept: **Settings › Models › Updates › Restore previous version**.

## Privacy and security

- Your data stays on your Mac (`~/Library/Application Support/Salenta Code`). There is no Salenta Code cloud.
- API keys live only in the macOS Keychain – never in files, repos or notes.
- Working copies never commit `.env` files or linked dependencies.
- With **Local only**, no text leaves your Mac for an AI.

## When something goes wrong

- **Agent doesn't start / “not signed in”:** sign in once in Terminal (e.g. `claude`, then `/login`). Meanwhile Salenta Code automatically uses another agent.
- **Integration red:** click **Repair** under **Integrations**.
- **Local model gives poor results:** download a bigger model (Settings › Models) – small models are only good for small tasks.
- **App doesn't respond:** after two crashes in a row, Salenta Code starts in **safe mode** automatically. **Salenta Code › Measure performance** creates a report you can attach to a bug ticket.
- **Report a bug or suggest an idea:** on GitHub under *Issues*.
