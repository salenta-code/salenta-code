import AgenticOSKit
import AppKit
import SwiftUI

// "Automatisch": du schreibst den Auftrag, Salenta Code entscheidet, wer ihn am besten erledigt.
//  • Coding (Bug, Feature, Theme, Supabase …) → Claude Code im passenden Projekt (nach deinen Bereichen und Repos)
//  • alles andere (CRM, Mails, Termine, Recherche, Browser, Obsidian) → dein Agent
//  • ausdrücklich genannt (Codex, Junie, ChatGPT) → genau der
// Die Entscheidung siehst du vor dem Senden und kannst sie mit einem Klick ändern.

struct RouteDecision: Equatable {
    var target: MissionTarget
    var directory: String?
    var projectName: String?
    var reason: String
}

enum Router {
    static let codingWords = [
        "bug", "fix", "fixe", "fehler im code", "code", "coden", "programmier", "implementier", "refactor", "theme",
        "liquid", "css", "html", "javascript", "typescript", "react", "swift", "python", "supabase", "edge function",
        "migration", "deploy", "repo", "commit", "pull request", "branch", "build", "kompiliert", "komponente",
        "endpoint", "api-route", "frontend", "backend", "datenbank", "schema", "feature", "funktion einbauen",
        "einbauen", "umbauen", "seite bauen", "app bauen", "test schreiben", "tests", "crash", "stacktrace", "lint",
        "n8n workflow", "webhook", "vorschläge", "falsch generiert", "wird nicht angezeigt", "klappt nicht", "funktioniert nicht",
    ]

    /// Änderungs-Verben: zusammen mit einem genannten Projekt eindeutig ein Code-Auftrag.
    static let changeWords = [
        "ändere", "änder ", "baue", "bau ", "füge", "hinzufügen", "entferne", "verschieb", "passe ", "pass ", "ersetze", "verbesser",
        "optimier", "aktualisier", "update", "gestalte", "erweitere", "mach ", "mache ", "beschleunig", "ladezeit", "umbenenn",
    ]

    /// Fehlersuche → Junie.
    static let debugWords = [
        "debug", "bug", "fehler finden", "fehlersuche", "warum geht", "warum funktioniert", "funktioniert nicht",
        "klappt nicht", "geht nicht mehr", "kaputt", "crash", "stürzt ab", "stacktrace", "exception", "error",
        "falsch generiert", "falsche", "wird nicht angezeigt", "fehlerhaft", "repariere", "reparier",
    ]

    /// Prüfen / zweite Meinung → Codex.
    static let reviewWords = ["review", "prüf den code", "code prüfen", "gegenprüf", "zweite meinung", "überprüf die änderung", "diff prüfen"]

    /// Hinweise aus deinen Bereichen: Name, Kürzel und Stichwörter zeigen auf passende Projektordner.
    static var projectHints: [(words: [String], match: [String], label: String)] {
        Company.allCases.filter { $0.rawValue != "privat" }.map { c in
            let words = ([c.title, c.rawValue] + c.tags + c.keywords).map { $0.lowercased() }.filter { $0.count >= 3 }
            return (words, words, c.title)
        }
    }

    /// Steht `phrase` als eigenes Wort im Text? („mit pi“ trifft nicht „mit pizza“, „pi soll“ nicht „api soll“.)
    static func mentions(_ t: String, _ phrase: String) -> Bool {
        let p = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: phrase) + "(?![\\p{L}\\p{N}])"
        return t.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Hast du einen Agent ausdrücklich genannt? Dann gilt genau der – die KI-Agentenwahl entscheidet nicht darüber.
    static func named(_ raw: String) -> Bool {
        let t = raw.lowercased()
        if ["@codex", "mit codex", "codex soll", "@junie", "mit junie", "junie soll", "@claude", "claude code"].contains(where: { t.contains($0) }) { return true }
        return AgentKind.coders.contains { k in mentions(t, "@" + k.rawValue) || mentions(t, "mit " + k.title.lowercased()) || mentions(t, k.title.lowercased() + " soll") }
    }

    static func decide(_ raw: String, projects: [Project], recent: [String]) -> RouteDecision {
        let t = raw.lowercased()
        func has(_ w: String) -> Bool { t.contains(w) }

        // Ausdrücklich genannt
        if has("@codex") || has("mit codex") || has("codex soll") { return pick(.codex, t, projects, recent, "Du hast Codex genannt") }
        if has("@junie") || has("mit junie") || has("junie soll") { return pick(.junie, t, projects, recent, "Du hast Junie genannt") }
        if has("@claude") || has("claude code") { return pick(.claude, t, projects, recent, "Du hast Claude Code genannt") }
        if has("chatgpt") { return RouteDecision(target: .chatgpt, reason: L("Du hast ChatGPT genannt")) }
        // Jeder weitere Coding-Agent: „@name“, „mit <Name>“ oder „<Name> soll“
        for k in AgentKind.coders where ![.codex, .junie, .claude].contains(k) {
            let title = k.title.lowercased()
            if mentions(t, "@" + k.rawValue) || mentions(t, "mit " + title) || mentions(t, title + " soll") {
                return pick(MissionTarget.from(k), t, projects, recent, String(format: L("Du hast %@ genannt"), k.title))
            }
        }

        let debugging = debugWords.contains { has($0) }
        let review = reviewWords.contains { has($0) }
        // Projekt steht wörtlich im Auftrag und es geht um eine Änderung oder um die Oberfläche („Ändere die Farbe vom Button im shop“)
        // – das ist Arbeit am Code, auch ohne Fachwort.
        let namesProject = projects.contains { p in
            let n = (p.path as NSString).lastPathComponent.lowercased(), m = p.name.lowercased()
            return (n.count >= 4 && t.contains(n)) || (m.count >= 4 && t.contains(m))
        }
        let coding = codingWords.contains { has($0) }
            || (namesProject && (WorkPhases.isUI(t) || changeWords.contains { has($0) }))
        if (coding || debugging || review), let p = project(for: t, projects: projects) {
            if review {
                return RouteDecision(target: .codex, directory: p.path, projectName: p.name,
                                     reason: "Prüfen/Review in \(p.name) – Codex als zweite Meinung")
            }
            if debugging, Billing.autoOK(.junie), OpenModels.available(.junie) {
                return RouteDecision(target: .junie, directory: p.path, projectName: p.name,
                                     reason: "Fehler finden und beheben in \(p.name) – Junie")
            }
            return RouteDecision(target: .claude, directory: p.path, projectName: p.name,
                                 reason: "Bauen/Ändern in \(p.name) – Claude Code arbeitet direkt im Projekt")
        }
        if coding && (has("in der app") || has("im code") || has("im repo")) {
            return pick(.claude, t, projects, recent, "Sieht nach Coding aus")
        }
        return RouteDecision(target: .osAgent, reason: L("Alltag, Tools, Recherche oder Browser – dein Agent mit allen Anbindungen"))
    }

    private static func pick(_ target: MissionTarget, _ t: String, _ projects: [Project], _ recent: [String], _ why: String) -> RouteDecision {
        if let p = project(for: t, projects: projects) {
            return RouteDecision(target: target, directory: p.path, projectName: p.name, reason: "\(why) · Projekt \(p.name)")
        }
        let d = recent.first
        return RouteDecision(target: target, directory: d, projectName: d.map { ($0 as NSString).lastPathComponent }, reason: why)
    }

    /// Bereich aus dem Text (für die Aufgabe).
    static func company(for raw: String) -> Company? { Company.match(in: raw) }

    /// Alle passenden Projekte (für Vorschläge).
    static func candidates(for t: String, projects: [Project]) -> [Project] {
        var out: [Project] = []
        for h in projectHints where h.words.contains(where: { t.contains($0) }) {
            out += projects.filter { p in
                let n = p.name.lowercased(), last = (p.path.lowercased() as NSString).lastPathComponent
                return h.match.contains { n.contains($0) || last.contains($0) }
            }
        }
        // Projekte, deren Ordnername direkt im Text vorkommt
        out += projects.filter { p in
            let n = (p.path as NSString).lastPathComponent.lowercased()
            return n.count >= 4 && t.contains(n)
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.path).inserted }
    }

    static let stop: Set<String> = ["bitte", "einen", "eine", "einer", "dass", "damit", "wird", "werden", "wieder", "immer", "noch",
                                    "nicht", "auch", "mache", "machen", "soll", "sollen", "kannst", "mal", "this", "that", "with",
                                    "from", "your", "when", "what", "über", "oder", "aber", "dann", "sind", "habe", "haben", "alle",
                                    "projekt", "request", "pull", "checks", "branch", "finde", "behebe", "ursache", "dich", "hole", "sieh", "bitte", "datei", "dateien", "ändern", "machen"]

    /// Skills, die zum Auftrag passen (Wortüberlappung mit Name und Beschreibung).
    static func suggestSkills(_ raw: String, skills: [Skill]) -> [Skill] {
        let words = Set(raw.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 4 && !stop.contains($0) })
        guard !words.isEmpty else { return [] }
        // Ganze Wörter vergleichen statt Teilstücke: sonst passt „Pull Request“ zu „change-request“ und „Chat-Verlauf“ zu „chatgpt-ads“.
        let scored: [(Skill, Int)] = skills.map { s in
            let nameTokens = Set(s.name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 })
            let descTokens = Set(s.description.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 4 })
            var score = 0, hits = 0
            for w in words {
                if nameTokens.contains(w) || nameTokens.contains(where: { $0.count >= 6 && w.count >= 6 && ($0.hasPrefix(w) || w.hasPrefix($0)) }) { score += 3; hits += 1 }
                if descTokens.contains(w) { score += 1; hits += 1 }
            }
            return (s, hits >= 2 ? score : 0)   // mindestens zwei Treffer – ein einzelnes Allerweltswort reicht nicht
        }
        var seen = Set<String>()
        return scored.filter { $0.1 >= 3 }.sorted { $0.1 > $1.1 }.map(\.0).filter { seen.insert($0.name).inserted }
    }

    /// Auswahlliste für die Planung: zuerst die Skills, die dem Wortlaut nach passen, danach alle übrigen – jeder Name einmal.
    /// So sieht das Entscheidungsmodell alles, was installiert ist, und nicht nur die Treffer der Stichwortsuche
    /// (ein englisch beschriebener Skill passte sonst nie zu einem deutschen Auftrag).
    static func skillMenu(_ raw: String, skills: [Skill], limit: Int = 140) -> [Skill] {
        var seen = Set<String>()
        return Array((Array(suggestSkills(raw + " " + bridge(raw), skills: skills).prefix(40)) + skills).filter { seen.insert($0.name).inserted }.prefix(limit))
    }

    /// Deutsche Auftragswörter → englische Begriffe, wie sie in Skill-Beschreibungen stehen. Nur für die Reihenfolge der Auswahlliste.
    static let bridgeWords: [(de: String, en: String)] = [
        ("sicherheit", "security vulnerabilities"), ("lücke", "security vulnerabilities"), ("schwachstelle", "security vulnerabilities"),
        ("prüf", "review"), ("test", "testing tests"), ("fehler", "debug debugging"), ("absturz", "debug crash"), ("ursache", "debug debugging"),
        ("oberfläche", "frontend design interface"), ("gestalt", "design frontend"), ("design", "design frontend"), ("seite", "page frontend"),
        ("mobil", "mobile responsive"), ("handy", "mobile responsive"), ("barriere", "accessibility"), ("ladezeit", "performance speed"),
        ("datenbank", "database"), ("doku", "documentation docs"), ("übersetz", "translate translation"), ("suchmaschine", "search"),
        ("auffindbar", "search"), ("bereitstell", "deploy deployment"), ("veröffentlich", "deploy release"), ("architektur", "architecture"),
        ("aufräum", "refactor simplify"), ("vereinfach", "simplify refactor"), ("plan", "plan planning"), ("recherch", "research"),
    ]
    static func bridge(_ raw: String) -> String {
        let t = raw.lowercased()
        return bridgeWords.filter { t.contains($0.de) }.map(\.en).joined(separator: " ")
    }

    /// Die Auswahlliste als Text: die passendsten Skills mit Beschreibung, alle übrigen mit Namen – nach Quelle gruppiert.
    /// Nichts Installiertes bleibt verborgen, und die Liste bleibt auch bei mehreren hundert Skills kurz.
    static func skillCatalogText(_ raw: String, skills: [Skill], detailed: Int = 70, describe: Int = 110) -> String {
        let menu = skillMenu(raw, skills: skills, limit: .max)
        guard !menu.isEmpty else { return "(none)" }
        var text = menu.prefix(detailed).map { "- \($0.name) [\($0.source)]: \(String($0.description.prefix(describe)))" }.joined(separator: "\n")
        let rest = Array(menu.dropFirst(detailed))
        if !rest.isEmpty {
            text += "\nAll other installed skills, names only (pick one by its exact name when the name clearly fits the task):"
            for source in Array(Set(rest.map(\.source))).sorted() {
                text += "\n[\(source)] " + rest.filter { $0.source == source }.map(\.name).joined(separator: ", ")
            }
        }
        return text
    }

    /// Kann dieser Agent den Skill laden? Die Quelle sagt, wo er liegt (Claude Code, Plugin, Codex, Junie, gemeinsamer Agents-Ordner).
    static func loadable(_ s: Skill, by agent: AgentKind?) -> Bool {
        guard let agent else { return false }
        switch agent.harness {
        case .claude: return ["Claude Code", "Plugin", "Agents"].contains(s.source)
        case .codex: return ["Codex", "Agents"].contains(s.source)
        case .junie: return ["Junie", "Agents"].contains(s.source)
        default: return s.source == "Agents"
        }
    }

    static func project(for raw: String, projects: [Project]) -> Project? {
        // Agent-Namen zählen nicht als Projekt („mit Salenta Harness“ ist kein Hinweis auf das Projekt „salenta“)
        var t = raw.lowercased()
        // Nur als eigenes Wort entfernen – „Pi“ darf aus „rezept-api“ nichts herausschneiden.
        for k in AgentKind.allCases {
            let p = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: k.title.lowercased()) + "(?![\\p{L}\\p{N}-])"
            t = t.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        // 1. Projektname steht wörtlich im Auftrag – das ist eindeutiger als ein Bereich. Der längste Treffer gewinnt
        //    („betreuer-testprojekt“ schlägt ein zufällig enthaltenes kürzeres Wort).
        func hit(_ p: Project) -> Int {
            let n = (p.path as NSString).lastPathComponent.lowercased(), m = p.name.lowercased()
            return max(n.count >= 3 && t.contains(n) ? n.count : 0, m.count >= 3 && t.contains(m) ? m.count : 0)
        }
        let named = projects.filter { hit($0) > 0 }.sorted { (hit($0), $0.isGit ? 1 : 0) > (hit($1), $1.isGit ? 1 : 0) }
        if let best = named.first { return best }
        // 2. über deine Bereiche (Stichwörter)
        for h in projectHints where h.words.contains(where: { t.contains($0) }) {
            // Git-Repos bevorzugen, dann zuletzt genutzt (Reihenfolge der Liste)
            let cands = projects.filter { p in
                let n = p.name.lowercased(), path = p.path.lowercased()
                return h.match.contains { n.contains($0) || (path as NSString).lastPathComponent.contains($0) }
            }
            if let best = cands.first(where: \.isGit) ?? cands.first { return best }
        }
        // Ordnername steht direkt im Auftrag (z. B. „im Repo my-shop“)
        let direct = projects.filter { p in
            let n = (p.path as NSString).lastPathComponent.lowercased()
            return n.count >= 4 && t.contains(n)
        }
        return direct.first(where: \.isGit) ?? direct.first
    }
}

// MARK: - Status eines Auftrags

enum MissionPhase: Int, Comparable {
    case waiting = 0, running = 1, review = 2, failed = 3, closed = 4
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .waiting: L("Wartet auf dich")
        case .running: L("Läuft")
        case .review: L("Fertig – kurz prüfen")
        case .failed: L("Abgebrochen")
        case .closed: L("Abgeschlossen")
        }
    }

    var color: Color {
        switch self {
        case .waiting: .orange
        case .running: .green
        case .review: .blue
        case .failed: .red
        case .closed: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .waiting: "hand.raised.fill"
        case .running: "circle.fill"
        case .review: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .closed: "archivebox"
        }
    }
}

extension MissionRecord {
    func phase(session: AgentSession?) -> MissionPhase {
        if archived == true { return .closed }
        if let s = session, s.running {
            // Dialog-Sitzung, in der seit einer Weile nichts passiert → der Agent wartet auf dich.
            if runMode == .interaktiv {
                let file = transcript.map { URL(fileURLWithPath: $0) }
                let mod = file.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                if let mod, mod < Date().addingTimeInterval(-45) { return .waiting }
            }
            return .running
        }
        if ended == nil && session == nil { return ok == false ? .failed : .review }
        return ok == false ? .failed : .review
    }
}

/// Kleiner farbiger Punkt / Symbol für den Status.
struct PhaseBadge: View {
    let phase: MissionPhase
    var body: some View {
        Image(systemName: phase.symbol)
            .font(.system(size: phase == .running ? 7 : 11))
            .foregroundStyle(phase.color)
            .symbolEffect(.pulse, isActive: phase == .running || phase == .waiting)
            .help(phase.title)
    }
}

// MARK: - KI-Wahl: ein kurzer Blick des Entscheidungsmodells auf den Auftrag (Agent, Modell, Denktiefe, Projekt, Skills) –
// das stärkste Modell, das du schon hast (Claude oder Codex); ohne beides der Salenta Harness

struct AIRouteDecision {
    var target: MissionTarget
    var model: String?        // Claude: opus/sonnet/haiku · Codex: Modell-ID (selten)
    var effort: String?       // Codex: low/medium/high
    var directory: String?
    var skills: [String]
    var reason: String
    /// Welche Integrationen (MCP) zugeschaltet werden – nil = alle verbundenen.
    var tools: [String]? = nil
    /// Installierte Erweiterungen, die genutzt werden sollen, und fehlende, die helfen würden.
    var extensions: [String]? = nil
    var suggest: [String]? = nil
    /// Wie anspruchsvoll ist der Auftrag (trivial, small, medium, large) – und schafft ihn ein kleines lokales Modell sicher?
    var complexity: String? = nil
    var localOK: Bool? = nil
    /// Woran man erkennt, dass der Auftrag erledigt ist – geht an Agent und Prüfer.
    var doneWhen: String? = nil
}

enum AIRouter {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "router.ai") as? Bool ?? true }

    /// Fragt Claude Haiku (dein Abo, ~3–8 s). Fällt bei Fehlern oder Zeitüberschreitung auf die Stichwort-Regeln zurück.
    static func decide(_ text: String, projects: [Project], skills: [Skill], installed: Set<AgentKind>,
                       tools: [String] = [], fallback: RouteDecision, completion: @escaping (AIRouteDecision) -> Void) {
        // Agents mit Kosten pro Nutzung nimmt die automatische Wahl nie von sich aus
        let installed = installed.filter { Billing.autoOK($0) }
        let fallbackAI = AIRouteDecision(target: fallback.target, model: defaultModel(for: fallback.target, text: text), effort: nil,
                                         directory: fallback.directory, skills: [], reason: fallback.reason)
        // Entscheiden kann jedes Modell, das schon da ist (Claude, Codex, sonst der Salenta Harness) – nicht nur Claude
        guard enabled, installed.contains(.claude) || HelperLLM.currentDecider != nil else {
            log("skipped: enabled=\(enabled) decider=\(HelperLLM.deciderLabel)")
            return completion(fallbackAI)
        }

        let projList = projects.prefix(60).map { "- \($0.name): \($0.path)" }.joined(separator: "\n")
        // Alle installierten Skills stehen zur Wahl – die mit Wortüberlappung zuerst, danach der Rest.
        let skillList = Router.skillCatalogText(text, skills: skills)
        // Jeder installierte Agent mit Stärken, den Modellen seiner CLI und dem Stand seines Limits: Das Entscheidungsmodell
        // vergleicht alle, statt einen festen Favoriten zu nehmen.
        let order: [AgentKind] = [.claude, .codex, .junie, .cursor, .opencode, .gemini, .grok, .kiro, .pi, .kimi, .deepseek, .harness, .openrouter, .ollama]
        var offered: [AgentKind: Set<String>] = [:]
        func modelsLine(_ a: AgentKind) -> String {
            if a == .claude { return " · models: opus (strongest), sonnet (default), haiku (small)" }
            let list = a == .ollama ? [LocalFirst.shared.model].compactMap { $0 }.map { ModelOption(value: $0, label: $0) } : ModelCatalog.shared.latest(for: a, limit: 6)
            offered[a] = Set(list.map(\.value))
            return list.isEmpty ? "" : " · models: " + list.map { $0.value + ($0.hint.isEmpty ? "" : " (" + $0.hint + ")") }.joined(separator: ", ")
        }
        func limitLine(_ a: AgentKind) -> String {
            let p = Usage.shared.pressure(a)
            return p >= 1 ? " · LIMIT REACHED" : p >= 0.05 ? " · \(Int(p * 100)) % of its limit used" : ""
        }
        let agentsList = (order.filter { installed.contains($0) }.map { "\($0.rawValue) – \($0.title): \($0.strength)\(modelsLine($0))\(limitLine($0))" }
            + ["os – OS Agent (runs on Claude): everything that is not coding – mail, calendar, CRM/integrations (MCP), research, browser tasks, writing texts, planning; can also delegate coding itself when a task mixes both"])
            .joined(separator: "\n")
        let offeredModels = offered

        let ext = ExtensionStore.shared
        let installedExt = ext.installedList.filter { !$0.howTo.isEmpty }
            .map { "- \($0.id) (\($0.kind.rawValue)\($0.id.hasPrefix("custom:") ? ", added by the user" : "")\($0.usable(claudeBased: false) ? "" : ", claude/os only")): \($0.purpose.prefix(110))" }.joined(separator: "\n")
        let missingExt = ExtensionCatalog.all.filter { !ext.isInstalled($0) && !$0.install.isEmpty && !$0.when.isEmpty }
            .map { "- \($0.id): \($0.purpose.prefix(90))" }.joined(separator: "\n")
        let usageHint = Usage.shared.routerHint
        let history = Learning.routerHint(MissionStore.shared.missions)
        let toolList = tools.isEmpty ? "(none)" : tools.map { "- " + $0 }.joined(separator: "\n")
        let prompt = """
        You route a task to the best AI agent on the user's Mac. Answer ONLY with one JSON object, no prose.
        Task:
        \"\"\"\(text.prefix(4000))\"\"\"

        Agents:
        \(agentsList)

        Models (field "model"):
        - for claude and os: "opus" for hard tasks (architecture, multi-file features, tricky bugs, important texts); \
        otherwise leave empty (the agent's own default)
        - for every other agent: an exact model id from that agent's list above when one model is clearly the best for this \
        task; otherwise leave empty (the agent's own default)
        - "effort" (claude and codex): "low" for trivial/mechanical tasks, "medium" for almost everything (default – Opus needs no more),
          "high" only for genuinely hard bugs, deep reviews, security or architecture. Never max/xhigh.

        Projects on this Mac (pick "directory" only for coding agents, must be one of these paths or empty):
        \(projList.isEmpty ? "(none)" : projList)

        Installed skills – everything the user has; the source in brackets says which agent can load it \
        (Claude Code, Plugin, Agents → claude and os · Codex, Agents → codex). Go through the whole list and pick every \
        skill that clearly helps THIS task, exact names, up to 5 (empty if none fits):
        \(skillList)

        Connected tools/integrations (MCP servers). Pick in "tools" ONLY the ones this task really needs \
        (for os and claude; "browser" = web browser automation). Fewer tools = faster and more focused:
        \(toolList)

        Installed extensions, including repos the user added himself (those marked "claude/os only" do nothing for other \
        agents). Pick in "extensions" every one this task should use, by id, up to 4:
        \(installedExt.isEmpty ? "(none)" : installedExt)

        Not installed but available. Put in "suggest" (max 2) only those that would clearly make THIS task better or cheaper:
        \(missingExt.isEmpty ? "(none)" : missingExt)

        \(LocalFirst.shared.routerHint)

        Current usage of the subscriptions: \(usageHint)
        If an agent is above 60 %, prefer another suitable agent for tasks it does not strictly need; above 85 % avoid it.
        For claude above 60 %, use "opus" only when really necessary.
        \(history.isEmpty ? "" : "\n" + history + "\nPrefer agents that worked well for this kind of task, and the ones the user picks himself.\n")
        Decision rules:
        - No code involved (mail, calendar, CRM, research, texts, browser, planning) → os.
        - Code: there is no fixed favourite. Compare ALL coding agents listed above, with their models, and pick the agent + \
        model that is strongest for THIS task. Weigh what the task needs (building, finding a root cause, review, UI work, \
        very large context, long multi-step work), the strengths and models listed, what worked here before, and how much \
        of each limit is used. If two are equally good, take the one with more of its limit left.
        - If a project is named or obvious, set "directory" for coding agents.
        - Skills and extensions are part of the plan – decide them together with agent and model. Combine several when they \
        cover different needs of the task (for example a token saver + a design skill + a test skill, or a docs helper + a \
        security plugin). Pick one only if its description clearly matches THIS task's domain and technology – nothing that \
        merely sounds related. Never pick marketing, ads, sales or office skills for coding tasks, and never coding skills \
        for mail/CRM tasks. If a skill or extension is decisive for the task, prefer an agent that can load it.
        - "complexity": trivial (one obvious edit or a short text), small (one file, clear change), medium (several files or \
        some investigation), large (feature, refactor, debugging across the codebase, anything risky).
        - "localOK": true ONLY if a small local model could finish it reliably in one go: trivial/small, clearly specified, \
        no investigation, no debugging, no security/auth/payment/database/deploy topics, no multi-step tool use. When unsure: false.

        - "done_when": for tasks that change code or files: ONE short, checkable sentence in \(Profile.languageCode == "de" ? "German" : "English") \
        saying when the task is done from the user's point of view (what works or is visible afterwards). Only use what the task says – \
        do not invent requirements. Empty for questions, research and non-coding tasks.

        JSON schema: {"done_when":"","agent":"claude|junie|codex|os|cursor|opencode|gemini|grok|kiro|pi|kimi","model":"","effort":"","directory":"","skills":[],"tools":[],"extensions":[],"suggest":[],"complexity":"trivial|small|medium|large","localOK":false,"reason":"max 12 words, in \(Profile.languageCode == "de" ? "German" : "English")"}
        """

        DispatchQueue.global(qos: .userInitiated).async {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("aos-route-\(UUID().uuidString).txt")
            try? prompt.write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            let decidedBy = HelperLLM.deciderLabel
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-l", "-i", "-c", HelperLLM.command(model: "haiku", maxTurns: 3, file: file.path, decision: true)]   // -i: PATH aus .zshrc (claude, codex)
            p.currentDirectoryURL = Paths.support
            var env = ProcessInfo.processInfo.environment
            env["AOS_SOURCE"] = "router"
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            let errPipe = Pipe()
            p.standardError = errPipe
            var out = Data()
            let done = DispatchSemaphore(value: 0)
            do { try p.run() } catch { log("start failed: \(error)"); DispatchQueue.main.async { completion(fallbackAI) }; return }
            DispatchQueue.global().async { out = pipe.fileHandleForReading.readDataToEndOfFile(); done.signal() }
            if done.wait(timeout: .now() + 40) == .timedOut { p.terminate(); log("timeout"); DispatchQueue.main.async { completion(fallbackAI) }; return }
            while p.isRunning { usleep(20_000) }  // kein waitUntilExit: das dreht den RunLoop und kann SwiftUI mitten im Zeichnen abstürzen lassen
            var parsed = parse(out, projects: projects, skills: skills, installed: installed, tools: tools, models: offeredModels)
            // Sichtbar machen, wer entschieden hat
            if parsed != nil, HelperLLM.harnessDecides {
                let text = String(decoding: out, as: UTF8.self)
                let who = text.contains("\"via\":\"harness\"") ? "Salenta Harness" : text.contains("\"via\": \"codex\"") || text.contains("\"via\":\"codex\"") ? "Codex" : decidedBy
                if !who.isEmpty { parsed!.reason += " · " + L("entschieden von") + " " + who }
            }
            log("exit \(p.terminationStatus) · \(parsed == nil ? "FALLBACK" : "ok \(parsed!.target.rawValue) \(parsed!.model ?? "-")")\n"
                + String(decoding: out.prefix(1500), as: UTF8.self) + "\n"
                + String(decoding: errPipe.fileHandleForReading.availableData.prefix(800), as: UTF8.self))
            DispatchQueue.main.async { completion(parsed ?? fallbackAI) }
        }
    }

    /// Letzte Entscheidungen in logs/router.log (zum Nachvollziehen).
    private static func log(_ text: String) {
        let url = Paths.root.appendingPathComponent("logs/router.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = "\n=== \(Date()) ===\n" + text + "\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    private static func parse(_ data: Data, projects: [Project], skills: [Skill], installed: Set<AgentKind>, tools: [String], models: [AgentKind: Set<String>] = [:]) -> AIRouteDecision? {
        // claude --output-format json → {"result": "<antwort>"}
        guard let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = outer["result"] as? String,
              let s = result.firstIndex(of: "{"), let e = result.lastIndex(of: "}"),
              let j = try? JSONSerialization.jsonObject(with: Data(result[s...e].utf8)) as? [String: Any] else { return nil }
        let agent = (j["agent"] as? String ?? "os").lowercased()
        var target: MissionTarget = agent == "os" ? .osAgent : AgentKind(rawValue: agent).map { MissionTarget.from($0) } ?? .osAgent
        if let k = target.agent, target != .osAgent, !installed.contains(k) { target = .osAgent }
        // Die Auswahl darf nur hochstufen, nie herunter: ohne Angabe läuft der Agent mit seinem eigenen Standard –
        // genau wie im Terminal. (Früher wählte die Vorauswahl oft „sonnet“/„haiku“ bzw. niedrige Denktiefe → schwächere Ergebnisse.)
        // Andere Agents: genau ein Modell aus der Liste, die ihre CLI gerade anbietet – alles andere fällt auf ihren Standard zurück.
        let rawModel = (j["model"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var model: String? = rawModel.lowercased() == "opus" ? "opus" : nil
        if target != .claude, target != .osAgent { model = pickModel(rawModel, for: target.agent, offered: models) }
        let effort: String = (j["effort"] as? String).map { $0.lowercased() }.flatMap { ["low", "medium", "high"].contains($0) ? $0 : nil } ?? "medium"
        let dirRaw = (j["directory"] as? String) ?? ""
        let dir = projects.first { $0.path == dirRaw }?.path
        // Nur Skills, die der gewählte Agent auch laden kann – bis zu fünf, damit sich mehrere ergänzen können
        var seenSkills = Set<String>()
        let chosen = (j["skills"] as? [String] ?? []).filter { n in skills.contains { $0.name == n && Router.loadable($0, by: target.agent) } && seenSkills.insert(n).inserted }.prefix(5)
        let reason = (j["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let known = Set(tools.map { $0.lowercased() })
        let pickedTools: [String]? = (j["tools"] as? [String]).map { $0.map { $0.lowercased() }.filter { known.contains($0) } }
        let claudeBased = target == .claude || target == .osAgent || target.agent?.harness == .claude
        let pickedExt = Array((j["extensions"] as? [String] ?? []).filter { id in
            ExtensionStore.shared.installedList.contains { $0.id == id && !$0.howTo.isEmpty && $0.usable(claudeBased: claudeBased) }
        }.prefix(4))
        let suggested = (j["suggest"] as? [String] ?? []).filter { id in ExtensionCatalog.find(id).map { !ExtensionStore.shared.isInstalled($0) } ?? false }
        let complexity = (j["complexity"] as? String).flatMap { ["trivial", "small", "medium", "large"].contains($0.lowercased()) ? $0.lowercased() : nil }
        let localOK = (j["localOK"] as? Bool) ?? (j["localOK"] as? String).map { $0.lowercased() == "true" }
        return AIRouteDecision(target: target,
                               model: model,
                               effort: (target == .codex || target == .claude) ? effort : nil,
                               directory: (target == .osAgent) ? nil : dir,
                               skills: Array(chosen), reason: reason.isEmpty ? L("Von der KI gewählt") : reason,
                               tools: (target == .osAgent || target == .claude) && !tools.isEmpty ? pickedTools : nil,
                               extensions: pickedExt,
                               suggest: Array(suggested.prefix(2)),
                               complexity: complexity, localOK: localOK,
                               doneWhen: (j["done_when"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : String($0.prefix(300)) })
    }

    /// Modellwunsch für einen Agent außer Claude: gilt nur, wenn er zum Agent passt und in dessen angebotener Liste steht.
    static func pickModel(_ raw: String, for agent: AgentKind?, offered: [AgentKind: Set<String>]) -> String? {
        guard let agent, !raw.isEmpty, !["opus", "sonnet", "haiku"].contains(raw.lowercased()),
              ModelCatalog.fits(raw, agent), offered[agent]?.contains(raw) == true else { return nil }
        return raw
    }

    /// Ohne KI: Standardmodell aus der Länge/Art des Auftrags.
    static func defaultModel(for target: MissionTarget, text: String) -> String? {
        guard target == .claude || target == .osAgent else { return nil }
        let t = text.lowercased()
        let hard = ["architektur", "architecture", "refactor", "umbauen", "migration", "komplex", "sicherheit", "security", "performance"]
        if hard.contains(where: { t.contains($0) }) || text.count > 900 { return "opus" }
        return nil   // Standard des Agents
    }
}
