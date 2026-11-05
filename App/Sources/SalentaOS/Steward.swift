import AgenticOSKit
import SwiftUI
import UserNotifications

// Projekt-Betreuer: ein Koordinator pro Repo, der selbst keinen Code schreibt, sondern plant, Helfer losschickt,
// Ergebnisse prüft und das Projekt dauerhaft pflegt.
//
// Was er anders macht:
//  • läuft lokal mit deinen Abos (Claude, Codex, Kimi …) – kein Cloud-Aufpreis pro Unter-Agent
//  • wählt pro Aufgabe den passenden Agent und das Modell, weicht bei Limits aus
//  • Tagesbudget und Höchstzahl paralleler Helfer – kein Token-Feuerwerk
//  • jede Aufgabe läuft in einer eigenen Arbeitskopie mit Prüfschleife (Build, Tests, Review)
//  • Vertrauen wächst messbar: nach grünen Runden schlägt er vor, Grünes selbst zu übernehmen
//  • hört auf Signale: täglicher Rundgang, rote CI auf GitHub
//  • alles, was gelernt wird, landet im gemeinsamen Projektwissen für alle Agents

struct StewardTask: Codable, Identifiable, Hashable {
    enum State: String, Codable { case idea, queued, running, review, done, red, dropped }
    var id = UUID().uuidString
    var title: String
    var detail: String = ""
    var agent: String = "auto"
    var model: String = ""
    var state: State = .queued
    var source: String = "betreuer"      // du, betreuer, rundgang, ci, kunde
    var missionID: String?
    var created = Date()
    var started: Date?
    var finished: Date?
    var note: String?
    var priority: Int = 2                // 1 hoch, 2 normal, 3 niedrig
    var ref: String?                     // z. B. CI-Lauf-URL – gegen Dubletten
}

struct StewardMessage: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var role: String                     // du, betreuer, system
    var text: String
    var date = Date()
}

struct StewardSetup: Codable, Hashable {
    var stack: [String] = []
    var commands: [String: String] = [:] // install, dev, typecheck, lint, test, build
    var envFiles: [String] = []
    var remote: String?
    var defaultBranch: String = "main"
    var baseline: Bool?
    var baselineNote: String?
    var date = Date()
}

struct StewardProject: Codable, Identifiable, Hashable {
    var id: String                       // Repo-Wurzel
    var name: String
    var goal: String = ""
    var tasks: [StewardTask] = []
    var messages: [StewardMessage] = []
    var setup: StewardSetup?
    var trust: Int = 1                   // 0 nur vorschlagen · 1 selbst starten · 2 Grünes selbst übernehmen
    var parallel: Int = 2
    var dailyRuns: Int = 8
    var runs: [String: Int] = [:]        // Tag → gestartete Helfer
    var paused = false
    var roundHour: Int = 7
    var lastRound: Date?
    var watchCI = true
    var customers = false
    var lastCI: Date?
    var greenStreak = 0
    var trustOffered = false
    var thinking: Bool? = nil
    var created = Date()

    var today: String { DateCoding.day(Date()) }
    var runsToday: Int { runs[today] ?? 0 }
    func count(_ s: StewardTask.State) -> Int { tasks.filter { $0.state == s }.count }
}

final class Steward: ObservableObject {
    static let shared = Steward()
    @Published var projects: [StewardProject] = []

    weak var agents: AgentManager?
    weak var hub: MCPHub?
    weak var tasks: TaskStore?
    weak var projectsCatalog: ProjectCatalog?
    private var timer: Timer?
    private var url: URL { Paths.data.appendingPathComponent("stewards.json") }

    init() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: url), let p = try? dec.decode([StewardProject].self, from: d) {
            projects = p.map { var x = $0; x.thinking = nil; return x }
        }
    }

    func attach(agents: AgentManager, hub: MCPHub, tasks: TaskStore, projects: ProjectCatalog) {
        self.agents = agents; self.hub = hub; self.tasks = tasks; self.projectsCatalog = projects
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.tick() }
    }

    func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        let snapshot = projects
        DispatchQueue.global(qos: .utility).async { [url] in
            if let d = try? enc.encode(snapshot) { try? d.write(to: url, options: .atomic) }
        }
    }

    func project(_ id: String) -> StewardProject? { projects.first { $0.id == id } }

    private func update(_ id: String, _ change: (inout StewardProject) -> Void) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        change(&projects[i])
        save()
    }

    func say(_ id: String, _ role: String, _ text: String) {
        update(id) { p in
            p.messages.append(StewardMessage(role: role, text: text))
            if p.messages.count > 200 { p.messages.removeFirst(p.messages.count - 200) }
        }
    }

    // MARK: Übernehmen

    /// Projekt in Betreuung nehmen: einrichten und nach dem Ziel fragen.
    @discardableResult
    func adopt(_ path: String) -> String {
        let root = Git.root(of: path) ?? path
        if projects.contains(where: { $0.id == root }) { return root }
        var p = StewardProject(id: root, name: (root as NSString).lastPathComponent)
        p.messages.append(StewardMessage(role: "betreuer", text: L("Hallo! Ich betreue ab jetzt dieses Projekt. Ich schaue mir gerade an, wie es aufgebaut ist und wie man es baut und testet. Was ist das Ziel für die nächsten Wochen?")))
        projects.append(p)
        save()
        runSetup(root)
        return root
    }

    func release(_ id: String) { projects.removeAll { $0.id == id }; save() }

    // MARK: Einrichten

    func runSetup(_ id: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let s = Self.detect(id)
            DispatchQueue.main.async {
                self.update(id) { $0.setup = s }
                var lines = [L("Eingerichtet:") + " " + (s.stack.isEmpty ? L("Stack unklar") : s.stack.joined(separator: ", "))]
                for k in ["dev", "test", "typecheck", "lint", "build"] { if let c = s.commands[k] { lines.append("• \(k): `\(c)`") } }
                if !s.envFiles.isEmpty { lines.append(L("• Umgebungsdateien (bleiben lokal):") + " " + s.envFiles.joined(separator: ", ")) }
                if s.remote == nil { lines.append(L("• Kein GitHub-Remote – CI-Wache ist aus.")) }
                self.say(id, "system", lines.joined(separator: "\n"))
            }
        }
    }

    static func detect(_ dir: String) -> StewardSetup {
        var s = StewardSetup()
        let fm = FileManager.default
        func has(_ f: String) -> Bool { fm.fileExists(atPath: (dir as NSString).appendingPathComponent(f)) }
        if has("package.json"), let d = fm.contents(atPath: (dir as NSString).appendingPathComponent("package.json")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            let pm = has("pnpm-lock.yaml") ? "pnpm" : has("yarn.lock") ? "yarn" : has("bun.lockb") || has("bun.lock") ? "bun" : "npm"
            s.stack.append(pm)
            let deps = ((j["dependencies"] as? [String: Any]) ?? [:]).merging((j["devDependencies"] as? [String: Any]) ?? [:]) { a, _ in a }
            for (k, label) in [("next", "Next.js"), ("react", "React"), ("vue", "Vue"), ("svelte", "Svelte"), ("astro", "Astro"),
                               ("@supabase/supabase-js", "Supabase"), ("vite", "Vite"), ("vitest", "Vitest"), ("typescript", "TypeScript"),
                               ("tailwindcss", "Tailwind"), ("@shopify/cli", "Shopify")] where deps[k] != nil { s.stack.append(label) }
            let scripts = j["scripts"] as? [String: String] ?? [:]
            s.commands["install"] = pm == "npm" ? (has("package-lock.json") ? "npm ci" : "npm install") : "\(pm) install"
            for k in ["dev", "typecheck", "lint", "test", "build"] where scripts[k] != nil {
                s.commands[k] = (k == "test" && (scripts[k]?.contains("vitest") == true) && scripts[k]?.contains("run") != true)
                    ? "\(pm) run test -- --run" : "\(pm) run \(k)"
            }
        }
        if has("Package.swift") { s.stack.append("Swift"); s.commands["build"] = s.commands["build"] ?? "swift build"; if has("Tests") { s.commands["test"] = "swift test" } }
        if has("Cargo.toml") { s.stack.append("Rust"); s.commands["build"] = "cargo build"; s.commands["test"] = "cargo test" }
        if has("go.mod") { s.stack.append("Go"); s.commands["build"] = "go build ./..."; s.commands["test"] = "go test ./..." }
        if has("pyproject.toml") || has("requirements.txt") { s.stack.append("Python"); if has("tests") || has("pytest.ini") { s.commands["test"] = "pytest -q" } }
        if has("supabase") { s.stack.append("Supabase-Projekt") }
        if has("shopify.theme.toml") || has("config/settings_schema.json") { s.stack.append("Shopify-Theme") }
        if let cfg = ProjectConfig.load(dir) {
            if let dev = cfg.dev { s.commands["dev"] = dev }
            if let v = cfg.verify, !v.isEmpty { s.commands["verify"] = v.joined(separator: " && ") }
        }
        s.envFiles = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0 == ".env" || $0.hasPrefix(".env.") || $0 == ".dev.vars" }.sorted()
        let remote = Git.run(["remote", "get-url", "origin"], in: dir, timeout: 10).out.trimmingCharacters(in: .whitespacesAndNewlines)
        s.remote = remote.isEmpty || remote.contains("fatal") ? nil : remote
        let head = Git.run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: dir, timeout: 10).out.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("origin/") { s.defaultBranch = String(head.dropFirst(7)) }
        else {
            let cur = Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: dir, timeout: 10).out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cur.isEmpty, !cur.contains("fatal") { s.defaultBranch = cur }
        }
        return s
    }

    /// Erkannte Befehle als Prüfschleife festschreiben (.salenta-os.json im Repo).
    func saveVerifyConfig(_ id: String) {
        guard let s = project(id)?.setup else { return }
        var cfg = ProjectConfig.load(id) ?? ProjectConfig()
        cfg.verify = ["typecheck", "lint", "test", "build"].compactMap { s.commands[$0] }
        if cfg.dev == nil { cfg.dev = s.commands["dev"] }
        ProjectConfig.save(cfg, dir: id)
        say(id, "system", L("Prüfschleife festgelegt in .salenta-os.json: ") + (cfg.verify ?? []).joined(separator: " · "))
    }

    // MARK: Gespräch mit dem Betreuer

    func send(_ id: String, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        say(id, "du", t)
        think(id, trigger: t)
    }

    /// Der Betreuer denkt nach: liest Ziel, Stand, Ergebnisse, Projektwissen und Signale – antwortet und plant.
    func think(_ id: String, trigger: String) {
        guard let p = project(id), p.thinking != true else { return }
        update(id) { $0.thinking = true }
        let installed = AgentKind.coders.filter { OpenModels.available($0) && !AgentHealth.needsLogin($0) }
        var models: [AgentKind: [String]] = [:]
        for a in installed { models[a] = ModelCatalog.shared.latest(for: a, limit: 5).map(\.value) }
        let tight = Set(installed.filter { Usage.shared.isTight($0) })
        let customerNotes: [String] = []
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.ask(p, trigger: trigger, installed: installed, models: models, tight: tight, customers: customerNotes)
            DispatchQueue.main.async { self.apply(id, result) }
        }
    }

    private struct Plan {
        var reply: String
        var goal: String?
        var tasks: [StewardTask]
        var drop: [String]
        var learnings: [(text: String, kind: String)]
    }

    private static func ask(_ p: StewardProject, trigger: String, installed: [AgentKind], models: [AgentKind: [String]],
                            tight: Set<AgentKind>, customers: [String]) -> Plan? {
        guard Detection.which("claude") != nil else { return nil }
        let lang = Profile.languageCode == "de" ? "German (informal du, short and direct)" : "English"
        let agentList = installed.map { a in
            "- \(a.rawValue) (\(a.title)): \(a.strength)" + ((models[a] ?? []).isEmpty ? "" : " · models: " + (models[a] ?? []).joined(separator: ", "))
                + (tight.contains(a) ? " · NEARLY AT LIMIT, avoid" : "")
        }.joined(separator: "\n")
        let open = p.tasks.filter { [.idea, .queued, .running, .review, .red].contains($0.state) }
            .map { "- [\($0.id.prefix(6))] \($0.state.rawValue): \($0.title)" + ($0.note.map { " — \($0.prefix(160))" } ?? "") }
            .joined(separator: "\n")
        let recent = p.tasks.filter { $0.state == .done || $0.state == .dropped }.suffix(10)
            .map { "- \($0.state.rawValue): \($0.title)" + ($0.note.map { " — \($0.prefix(120))" } ?? "") }.joined(separator: "\n")
        let chat = p.messages.suffix(12).map { "\($0.role): \($0.text.prefix(600))" }.joined(separator: "\n")
        let memory = ProjectMemory.promptBlock(p.id)?.text ?? ""
        let setup = p.setup.map { s in
            "Stack: \(s.stack.joined(separator: ", ")). Commands: " + s.commands.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")
        } ?? "not analysed yet"
        let capacity = max(0, p.dailyRuns - p.runsToday)
        let prompt = """
        You are the long-term STEWARD (coordinator) of the software project "\(p.name)" (\(p.id)).
        You never write code yourself. You plan, split work into small independent tasks that coding agents execute in \
        isolated git worktrees (each task is built, tested and reviewed automatically), and you keep the project healthy over weeks.
        The owner is a busy founder, not a developer: speak plainly, be brief, no jargon.

        Goal: \(p.goal.isEmpty ? "(not set yet – ask for it if the trigger does not give one)" : p.goal)
        Setup: \(setup)
        Trust level: \(p.trust) (0 = only propose, 1 = start tasks automatically, 2 = also merge green results).
        Capacity left today: \(capacity) task runs, max \(p.parallel) in parallel.

        Open tasks:
        \(open.isEmpty ? "(none)" : open)

        Recently finished:
        \(recent.isEmpty ? "(none)" : recent)

        \(memory)

        \(customers.isEmpty ? "" : "Customer reports (possible bugs):\n" + customers.joined(separator: "\n"))

        Conversation (latest last):
        \(chat)

        Trigger now: \(trigger)

        Rules:
        - Tasks must be concrete, small enough for one agent run (≤ ~1 hour), independent where possible, with clear done criteria in "detail".
        - Do not duplicate open tasks. Prefer fixing red tasks (re-plan them) before adding new features.
        - Pick the best agent per task from the list and a fitting model (cheap/fast for small fixes, strong for hard work).
        - Never plan work on the tool that runs you ("Salenta Code"); only on this project.
        - Never plan deploys to production, publishing, deleting data or sending messages to customers – propose those to the owner in "reply".
        - If the goal is unclear, ask ONE question in "reply" and return no tasks.
        - "drop": ids (6 chars) of open tasks that are obsolete.
        - "learnings": durable project facts worth remembering (decisions, conventions, pitfalls). Max 3.

        Available agents:
        \(agentList)

        Answer ONLY with JSON in \(lang):
        {"reply":"","goal":"","tasks":[{"title":"short imperative","detail":"what + done criteria","agent":"<id>","model":"","priority":2}],"drop":[""],"learnings":[{"text":"","kind":"regel"}]}
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("aos-steward-\(UUID().uuidString).md")
        try? prompt.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let model = tight.contains(.claude) ? "haiku" : "sonnet"
        let r = Proc.zsh(LocalFirst.cliEnv() + "claude -p --model \(model) --output-format json --max-turns 1 --strict-mcp-config < \(Shell.quote(file.path))",
                         in: NSTemporaryDirectory(), timeout: 240)
        guard let res = Verifier.claudeResult(r.out), let a = res.firstIndex(of: "{"), let b = res.lastIndex(of: "}"),
              let data = res[a...b].data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let tasks = ((j["tasks"] as? [[String: Any]]) ?? []).compactMap { t -> StewardTask? in
            guard let title = t["title"] as? String, !title.isEmpty, !Digest.isToolTopic(title) else { return nil }
            var agent = (t["agent"] as? String ?? "auto").lowercased()
            if AgentKind(rawValue: agent).map({ installed.contains($0) }) != true { agent = "auto" }
            var model = t["model"] as? String ?? ""
            if let k = AgentKind(rawValue: agent), !model.isEmpty, !(models[k] ?? []).contains(model) { model = "" }
            return StewardTask(title: title, detail: t["detail"] as? String ?? "", agent: agent, model: model,
                               priority: t["priority"] as? Int ?? 2)
        }
        let learnings = ((j["learnings"] as? [[String: Any]]) ?? []).compactMap { l -> (text: String, kind: String)? in
            guard let t = l["text"] as? String, !t.isEmpty else { return nil }
            return (t, l["kind"] as? String ?? "lernen")
        }
        let goal = (j["goal"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Plan(reply: (j["reply"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    goal: goal.isEmpty ? nil : goal, tasks: tasks, drop: (j["drop"] as? [String]) ?? [], learnings: learnings)
    }

    private func apply(_ id: String, _ plan: Plan?) {
        update(id) { $0.thinking = nil }
        guard let plan else {
            say(id, "system", L("Der Betreuer konnte gerade nicht nachdenken (Claude nicht erreichbar oder am Limit). Ich versuche es beim nächsten Signal wieder."))
            return
        }
        update(id) { p in
            if let g = plan.goal, p.goal.isEmpty || plan.goal != p.goal { if p.goal.isEmpty { p.goal = g } }
            for d in plan.drop where !d.isEmpty {
                if let i = p.tasks.firstIndex(where: { $0.id.hasPrefix(d) && $0.state != .running }) { p.tasks[i].state = .dropped; p.tasks[i].note = L("vom Betreuer verworfen") }
            }
            let known = Set(p.tasks.filter { $0.state != .dropped && $0.state != .done }.map { $0.title.lowercased() })
            for var t in plan.tasks where !known.contains(t.title.lowercased()) {
                t.state = p.trust == 0 ? .idea : .queued
                p.tasks.append(t)
            }
        }
        if !plan.reply.isEmpty { say(id, "betreuer", plan.reply) }
        if !plan.learnings.isEmpty { ProjectMemory.add(id, plan.learnings, source: L("Projekt-Betreuer")) }
        dispatch(id)
    }

    // MARK: Takt

    private func tick() {
        for p in projects where !p.paused {
            evaluate(p.id)
            signals(p.id)
            dispatch(p.id)
        }
    }

    /// Helfer starten, solange Platz und Tagesbudget da sind.
    func dispatch(_ id: String) {
        guard let agents, var p = project(id), !p.paused, p.tasks.contains(where: { $0.state == .queued }) else { return }
        var running = p.count(.running)
        var launched = false
        while running < p.parallel, p.runsToday < p.dailyRuns,
              let i = p.tasks.indices.filter({ p.tasks[$0].state == .queued }).min(by: { p.tasks[$0].priority < p.tasks[$1].priority }) {
            launch(&p, i, agents: agents)
            running += 1
            launched = true
        }
        guard launched, let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[idx] = p
        save()
    }

    private func launch(_ p: inout StewardProject, _ i: Int, agents: AgentManager) {
        var t = p.tasks[i]
        var k = AgentKind(rawValue: t.agent) ?? Router.decide(t.title + " " + t.detail, projects: projectsCatalog?.local ?? [], recent: [p.id]).target.agent ?? .claude
        if !OpenModels.available(k) || Usage.shared.isTight(k) || AgentHealth.needsLogin(k) {
            k = ([k] + Usage.alternatives(k)).first { OpenModels.available($0) && !Usage.shared.isTight($0) && !AgentHealth.needsLogin($0) } ?? .claude
        }
        let commands = p.setup.map { s in ["test", "typecheck", "lint", "build"].compactMap { c in s.commands[c].map { "\(c): \($0)" } }.joined(separator: " · ") } ?? ""
        let prompt = """
        \(t.title)

        \(t.detail)

        ---
        \(L("Du arbeitest als Helfer des Projekt-Betreuers von")) \(p.name). \(L("Ziel des Projekts")): \(p.goal.isEmpty ? "–" : p.goal)
        \(L("Erledige genau diese Aufgabe, vollständig und ohne Rückfragen; triff sinnvolle Annahmen."))
        \(commands.isEmpty ? "" : L("Prüfe am Ende mit") + " " + commands + ".")
        \(L("Nichts deployen, nichts veröffentlichen, keine Nachrichten an Kunden. Was offen bleibt, schreib am Ende unter „Offen:“."))
        """
        var model = t.model.isEmpty ? nil : t.model
        // kleine Aufgaben lokal (spart Kosten) – wenn ein lokales Modell da ist
        if LocalFirst.shared.forSmall, LocalFirst.shared.ready, let m = LocalFirst.shared.model,
           LocalFirst.shared.localMisfit(AIRouteDecision(target: .claude, model: nil, effort: nil, directory: p.id, skills: [], reason: ""),
                                         text: t.title + " " + t.detail) == nil {
            k = .ollama; model = m
        }
        let s = agents.start(k, in: p.id, prompt: prompt, mode: .autonom, label: "🧭 " + t.title, model: model)
        t.state = .running
        t.started = Date()
        t.missionID = s.id.uuidString
        t.agent = k.rawValue
        p.tasks[i] = t
        p.runs[p.today, default: 0] += 1
        p.runs = p.runs.filter { $0.key >= DateCoding.day(Date().addingTimeInterval(-7 * 86400)) }
    }

    /// Laufende Aufgaben auswerten (inkl. Prüfschleife und Korrekturrunde).
    private func evaluate(_ id: String) {
        guard let p = project(id) else { return }
        for t in p.tasks where t.state == .running {
            guard let r = Self.outcome(t, agents: agents) else { continue }
            var merged = false
            if r.state == .review, p.trust >= 2, let mid = r.missionID, let rec = MissionStore.shared.mission(mid), let wt = rec.worktree,
               rec.verify?.passed == true {
                let (ok, msg) = Worktrees.merge(wt, message: t.title)
                if ok {
                    merged = true
                    finishMission(mid, outcome: "merged")
                    say(id, "system", "✓ " + L("Übernommen (grün): ") + t.title)
                } else {
                    say(id, "system", L("Konnte nicht selbst übernehmen: ") + msg)
                }
            }
            update(id) { p in
                guard let i = p.tasks.firstIndex(where: { $0.id == t.id }) else { return }
                p.tasks[i].state = merged ? .done : r.state
                p.tasks[i].note = r.note
                p.tasks[i].missionID = r.missionID ?? p.tasks[i].missionID
                p.tasks[i].finished = Date()
                if r.state == .review || merged { p.greenStreak += 1 } else if r.state == .red { p.greenStreak = 0 }
            }
            if r.state == .red {
                // Rot nach Korrekturrunde: der Betreuer plant neu (kein Endlos-Loop: nur einmal pro Aufgabe)
                think(id, trigger: L("Aufgabe ist rot geblieben: ") + t.title + " — " + (r.note ?? ""))
            }
            notifyIfIdle(id)
        }
        // Vertrauen anbieten
        if let q = project(id), q.trust == 1, q.greenStreak >= 5, !q.trustOffered {
            update(id) { $0.trustOffered = true }
            say(id, "betreuer", L("Die letzten 5 Aufgaben waren alle grün. Soll ich grüne Ergebnisse ab jetzt selbst übernehmen? (oben bei „Vertrauen“ umstellen)"))
        }
    }

    private func finishMission(_ mid: String, outcome: String) {
        guard let rec = MissionStore.shared.mission(mid) else { return }
        PreviewServer.shared.stop(mid)
        MissionStore.shared.setOutcome(mid, outcome)
        Learning.record(rec, outcome: outcome)
        MissionStore.shared.clearWorktree(mid)
        if let agents, let tasks { MissionStore.shared.archive(mid, agents: agents, tasks: tasks) }
    }

    /// Ergebnis einer Aufgabe – nil, solange sie (inkl. Prüfung/Korrektur) noch läuft.
    static func outcome(_ t: StewardTask, agents: AgentManager?) -> (state: StewardTask.State, note: String?, missionID: String?)? {
        guard let start = t.missionID else { return (.red, L("nicht gestartet"), nil) }
        var cur = start
        var n = 0
        while n < 10, let next = MissionStore.shared.missions.last(where: { $0.parent == cur && $0.delegated != true }) { cur = next.id; n += 1 }
        guard let rec = MissionStore.shared.mission(cur) else { return nil }
        if agents?.sessions.contains(where: { $0.id.uuidString == cur && $0.running }) == true { return nil }
        guard let ended = rec.ended else {
            // Sitzung weg, aber nie beendet (App-Neustart): nach 3 h als rot werten
            return Date().timeIntervalSince(rec.started) > 3 * 3600 ? (.red, L("abgebrochen"), cur) : nil
        }
        if rec.worktree != nil {
            if rec.verify == nil && Date().timeIntervalSince(ended) < 90 { return nil }
            if let v = rec.verify, v.finished == nil { return nil }
            if rec.verify?.passed == false && (rec.fixRound ?? 0) < 1 && Date().timeIntervalSince(ended) < 150 { return nil }
        }
        if rec.ok == false { return (.red, rec.digest?.summary ?? L("abgebrochen"), cur) }
        if rec.verify?.passed == false { return (.red, rec.verify?.diagnosis?.why ?? L("Prüfung rot"), cur) }
        if rec.worktree == nil && rec.outcome == "merged" { return (.done, rec.digest?.summary, cur) }
        return (rec.worktree == nil ? .done : .review, rec.digest?.summary, cur)
    }

    // MARK: Signale

    private func signals(_ id: String) {
        guard let p = project(id) else { return }
        // Täglicher Rundgang
        let cal = Calendar.current
        if cal.component(.hour, from: Date()) >= p.roundHour, p.lastRound.map({ !cal.isDateInToday($0) }) ?? true, !p.goal.isEmpty {
            update(id) { $0.lastRound = Date() }
            think(id, trigger: L("Täglicher Rundgang: Was ist heute für das Ziel am wichtigsten? Gibt es Liegengebliebenes oder Risiken?"))
        }
        // CI auf GitHub (alle 15 Minuten)
        if p.watchCI, p.setup?.remote?.contains("github") == true, (p.lastCI.map { Date().timeIntervalSince($0) > 900 } ?? true) {
            update(id) { $0.lastCI = Date() }
            let branch = p.setup?.defaultBranch ?? "main"
            DispatchQueue.global(qos: .utility).async {
                let r = Proc.zsh("gh run list --branch \(Shell.quote(branch)) --limit 1 --json conclusion,status,displayTitle,url,workflowName", in: id, timeout: 40)
                guard r.code == 0, let a = r.out.firstIndex(of: "["), let d = String(r.out[a...]).data(using: .utf8),
                      let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]], let run = arr.first,
                      run["conclusion"] as? String == "failure", let url = run["url"] as? String else { return }
                let title = "\(run["workflowName"] as? String ?? "CI"): \(run["displayTitle"] as? String ?? "")"
                DispatchQueue.main.async {
                    guard let q = self.project(id), !q.tasks.contains(where: { $0.ref == url }) else { return }
                    self.update(id) { p in
                        p.tasks.append(StewardTask(title: L("CI ist rot – reparieren: ") + title,
                                                   detail: L("Der letzte CI-Lauf auf") + " \(branch) " + L("ist fehlgeschlagen") + " (\(url)). "
                                                       + L("Lies die Logs mit `gh run view --log-failed`, finde die Ursache und behebe sie. Fertig, wenn die betroffenen Checks lokal grün sind."),
                                                   state: p.trust == 0 ? .idea : .queued, source: "ci", priority: 1, ref: url))
                    }
                    self.say(id, "system", "🔴 " + L("CI ist rot: ") + title)
                    ModStore.shared.fire(.ciFailed, rec: nil, result: title + " – " + url, directory: id)
                    self.dispatch(id)
                }
            }
        }
    }

    private func notifyIfIdle(_ id: String) {
        guard let p = project(id), p.count(.running) == 0, p.count(.queued) == 0 else { return }
        let review = p.count(.review), red = p.count(.red)
        guard review + red > 0 else { return }
        let text = "\(p.name): " + String(format: L("%d fertig zum Übernehmen, %d brauchen dich"), review, red)
        let c = UNMutableNotificationContent()
        c.title = "🧭 " + L("Projekt-Betreuer"); c.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "steward-" + id, content: c, trigger: nil))
        Notifier.push("🧭 " + p.name, text, priority: 3, tags: "compass")
    }

    // MARK: Aktionen aus der Oberfläche

    func start(_ id: String, task: String) {
        update(id) { p in if let i = p.tasks.firstIndex(where: { $0.id == task }) { p.tasks[i].state = .queued } }
        dispatch(id)
    }

    func drop(_ id: String, task: String) {
        update(id) { p in if let i = p.tasks.firstIndex(where: { $0.id == task }), p.tasks[i].state != .running { p.tasks[i].state = .dropped } }
    }

    func addTask(_ id: String, title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        update(id) { p in p.tasks.append(StewardTask(title: t, state: .queued, source: "du", priority: 1)) }
        dispatch(id)
    }

    /// Fertig geprüfte Aufgabe übernehmen oder verwerfen.
    func resolve(_ id: String, task: String, accept: Bool, completion: @escaping (String) -> Void) {
        guard let t = project(id)?.tasks.first(where: { $0.id == task }), let mid = t.missionID,
              let rec = MissionStore.shared.mission(mid), let wt = rec.worktree else {
            update(id) { p in if let i = p.tasks.firstIndex(where: { $0.id == task }) { p.tasks[i].state = accept ? .done : .dropped } }
            completion(accept ? L("Erledigt") : L("Verworfen")); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let (ok, msg): (Bool, String)
            if accept { (ok, msg) = Worktrees.merge(wt, message: t.title) } else { Worktrees.discard(wt, keepBranch: false); (ok, msg) = (true, L("Verworfen")) }
            DispatchQueue.main.async {
                if ok {
                    self.finishMission(mid, outcome: accept ? "merged" : "discarded")
                    self.update(id) { p in if let i = p.tasks.firstIndex(where: { $0.id == task }) { p.tasks[i].state = accept ? .done : .dropped } }
                }
                completion(ok ? "✓ " + msg : msg)
            }
        }
    }

    /// Rote Aufgabe noch einmal versuchen (Korrekturrunde mit dem vorgeschlagenen Agent).
    func retry(_ id: String, task: String) {
        guard let agents, let hub, let t = project(id)?.tasks.first(where: { $0.id == task }), let mid = t.missionID,
              let rec = MissionStore.shared.mission(mid) else { start(id, task: task); return }
        Verifier.fix(rec, agents: agents, hub: hub, agent: rec.verify?.diagnosis?.agent, model: rec.verify?.diagnosis?.model) { s in
            self.update(id) { p in
                if let i = p.tasks.firstIndex(where: { $0.id == task }) { p.tasks[i].state = .running; p.tasks[i].missionID = s.id.uuidString }
            }
        }
    }
}
