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
    var skills: [String]? = nil          // vom Betreuer gewählte Skills für diesen Helfer
    var exts: [String]? = nil            // vom Betreuer gewählte Erweiterungen für diesen Helfer
    var pr: Int? = nil                   // Pull Request auf GitHub, der dieses Ergebnis trägt
    var prBranch: String? = nil          // Korrektur auf einem bestehenden PR-Branch (statt neuem PR)
    var effort: String? = nil            // Denkstufe passend zur Aufgabe: low, medium, high
    var prRetry: Int? = nil              // automatische Reparaturen nach gescheitertem PR
    var order: String? = nil             // gehört zu diesem Auftrag von dir (Team-Auftrag)
    var offlineWT: WorktreeInfo? = nil   // offline fertig geworden – wird hochgeladen, sobald Internet da ist
    var offlineMid: String? = nil
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

/// Ein Auftrag von dir: der Betreuer plant ihn als Team (Hauptaufgabe + abgegrenzte Zuarbeiten), betreut ihn bis zum Schluss
/// und meldet ein fertiges Ergebnis.
struct StewardOrder: Codable, Identifiable, Hashable {
    var id = String(UUID().uuidString.prefix(8))
    var text: String
    var lead: String? = nil               // von dir gewählter Haupt-Agent (nil = der Betreuer wählt)
    var teamSize: Int = 1                 // wie viele verschiedene Agents höchstens mitarbeiten
    var created = Date()
    var planned = false
    var finished: Date? = nil
    var summary: String? = nil
    var rounds: Int? = nil                // Fortsetzungsrunden: nach jeder Runde prüft der Betreuer, was noch fehlt
    var waveSig: String? = nil            // Teilaufgaben, nach denen zuletzt weitergeplant wurde (keine Doppel-Runde)
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
    var extraToday: [String: Int]? = nil  // „Heute +10“: zusätzliche Aufträge nur für diesen Tag
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
    // Optional, damit ältere stewards.json weiter laden
    var extensions: [String]? = nil      // ausgewählte Erweiterungen – jeder Helfer nutzt sie
    var untilDone: Bool? = nil           // arbeitet ohne Pause weiter, bis das Ziel erreicht ist
    var improve: Bool? = nil             // danach selbst Verbesserungen suchen
    var goalReached: Date? = nil
    var progress: String? = nil          // Einschätzung des Betreuers, z. B. „60 % – Checkout fehlt noch“
    var blocked: String? = nil           // braucht dich, bevor es weitergeht
    var idleThinks: Int? = nil           // Planungen ohne neue Aufgaben in Folge
    var lastContinue: Date? = nil
    var followUp: Bool? = nil            // ohne Dauerbetrieb: nach dieser Welle noch einmal fragen, ob von deinem Wunsch etwas fehlt
    // GitHub (über die GitHub CLI)
    var github: Bool? = nil              // Ergebnisse als Pull Request liefern (nil = automatisch, wenn GitHub da ist)
    var autoMerge: Bool? = nil           // grüne, geprüfte PRs selbst mergen (nil = wie Vertrauen „Grünes übernehmen“)
    var mergeAll: Bool? = nil            // auch PRs von anderen mergen (Standard: nur eigene)
    var postReviews: Bool? = nil         // Review als Kommentar auf GitHub (Standard: an)
    var prs: [StewardPR]? = nil
    var lastPRScan: Date? = nil
    var prBase: String? = nil            // Ziel-Branch der Pull Requests (Standard: Haupt-Branch des Repos auf GitHub)

    var orders: [StewardOrder]? = nil    // deine Aufträge: ein Prompt → ein Team → ein fertiges Ergebnis

    var chosenExtensions: [Extension] { (extensions ?? []).compactMap { ExtensionCatalog.find($0) } }
    var continuous: Bool { untilDone == true }

    var today: String { DateCoding.day(Date()) }
    var runsToday: Int { runs[today] ?? 0 }
    /// 0 = kein Tagesbudget (unbegrenzt – gebremst wird dann nur durch Parallel-Grenze, Limits und Energiesparen)
    var unlimited: Bool { dailyRuns <= 0 }
    var budgetLeft: Bool { unlimited || runsToday < dailyRuns + (extraToday?[today] ?? 0) }
    var budgetText: String { unlimited ? "\(runsToday) " + L("heute · ohne Budget") : "\(runsToday)/\(dailyRuns + (extraToday?[today] ?? 0)) " + L("heute") }
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
        guard let d = try? Data(contentsOf: url) else {
            if FileManager.default.fileExists(atPath: url.path) { Steward.log("stewards.json vorhanden, aber nicht lesbar – nichts geladen") }
            return
        }
        if let p = try? dec.decode([StewardProject].self, from: d) {
            projects = p.map { var x = $0; x.thinking = nil; return x }
        } else {
            // Nie still alle Betreuer verlieren: lesbare einzeln übernehmen, die Datei vorher sichern
            try? d.write(to: url.deletingPathExtension().appendingPathExtension("defekt-\(Int(Date().timeIntervalSince1970)).json"))
            if let raw = try? JSONSerialization.jsonObject(with: d) as? [Any] {
                var ok: [StewardProject] = []
                for item in raw {
                    guard let one = try? JSONSerialization.data(withJSONObject: item),
                          var x = try? dec.decode(StewardProject.self, from: one) else { continue }
                    x.thinking = nil
                    ok.append(x)
                }
                projects = ok
            }
        }
    }

    func attach(agents: AgentManager, hub: MCPHub, tasks: TaskStore, projects: ProjectCatalog) {
        Git.primeIdentity()   // Commit-Identität (GitHub-Noreply) im Hintergrund nachschlagen
        GH.prime()   // gh-Anmeldung früh prüfen – entscheidet, ob Ergebnisse als Pull Request gehen
        self.agents = agents; self.hub = hub; self.tasks = tasks; self.projectsCatalog = projects
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.tick() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.recoverIfLost() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.resumeInterruptedFixes() }
    }

    /// Du hast gerade selbst einen Betreuer beendet – nur dann darf die Liste kleiner gespeichert werden, ohne zu fragen.
    private var releasing = false
    private static let saveQueue = DispatchQueue(label: "steward.save", qos: .utility)

    func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        let snapshot = projects
        let allowShrink = releasing
        releasing = false
        Self.saveQueue.async { [url] in
            // Was liegt schon auf der Platte? Nie still Betreuer verlieren:
            //  • eine leere Liste über vorhandene Betreuer schreiben wir nur, wenn du sie selbst beendet hast
            //  • fallen Betreuer weg, wird die alte Datei vorher gesichert
            let before = ((try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Any] })?.count ?? 0
            if snapshot.count < before {
                if snapshot.isEmpty && !allowShrink {
                    Steward.log("Speichern übersprungen: leere Betreuer-Liste würde \(before) vorhandene überschreiben")
                    return
                }
                let backup = url.deletingPathExtension().appendingPathExtension("backup.json")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.copyItem(at: url, to: backup)
                Steward.log("Betreuer-Liste \(before) → \(snapshot.count) (Sicherung: stewards.backup.json)")
            }
            if let d = try? enc.encode(snapshot) { try? d.write(to: url, options: .atomic) }
        }
    }

    func project(_ id: String) -> StewardProject? { projects.first { $0.id == id } }

    func update(_ id: String, _ change: (inout StewardProject) -> Void) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        change(&projects[i])
        Self.dedupePRTasks(&projects[i])
        save()
    }

    /// Pro Pull Request höchstens eine offene Korrekturaufgabe (die älteste bleibt, Dubletten werden verworfen).
    static func dedupePRTasks(_ p: inout StewardProject) {
        var seen = Set<Int>()
        for i in p.tasks.indices where p.tasks[i].prBranch != nil && [.queued, .idea].contains(p.tasks[i].state) {
            guard let n = p.tasks[i].pr else { continue }
            let busy = p.tasks.contains { $0.pr == n && $0.prBranch != nil && $0.state == .running }
            if seen.contains(n) || busy { p.tasks[i].state = .dropped; p.tasks[i].note = L("doppelt – für diesen PR läuft schon eine Korrektur") }
            else { seen.insert(n) }
        }
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
        if var gone = UserDefaults.standard.stringArray(forKey: "steward.released"), gone.contains(root) {
            gone.removeAll { $0 == root }; UserDefaults.standard.set(gone, forKey: "steward.released")
        }
        var p = StewardProject(id: root, name: (root as NSString).lastPathComponent)
        p.messages.append(StewardMessage(role: "betreuer", text: L("Hallo! Ich betreue ab jetzt dieses Projekt. Ich schaue mir gerade an, wie es aufgebaut ist und wie man es baut und testet. Was ist das Ziel für die nächsten Wochen?")))
        projects.append(p)
        save()
        runSetup(root)
        return root
    }

    func release(_ id: String) {
        projects.removeAll { $0.id == id }
        var gone = Set(UserDefaults.standard.stringArray(forKey: "steward.released") ?? [])
        gone.insert(id)
        UserDefaults.standard.set(Array(gone), forKey: "steward.released")
        releasing = true
        save()
    }

    /// Notfall: Die Betreuer-Liste ist leer, obwohl es frische Helfer-Aufträge gibt (z. B. Datei überschrieben).
    /// Dann die Betreuer daraus wiederherstellen: Projekt, Ziel (steht in jedem Helfer-Auftrag) und Vertrauen
    /// (hat er schon selbst gemergt, durfte er Grünes übernehmen). Von dir beendete Betreuer kommen nicht zurück.
    func recoverIfLost() {
        guard projects.isEmpty else { return }
        let gone = Set(UserDefaults.standard.stringArray(forKey: "steward.released") ?? [])
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        let recs = MissionStore.shared.missions.filter { $0.title.hasPrefix("🧭") && $0.started > cutoff }
        var byRepo: [String: [MissionRecord]] = [:]
        for r in recs {
            let dir = r.worktree?.base ?? r.directory
            guard let root = Git.root(of: dir), !root.contains("/.salenta-os/worktrees/") else { continue }
            byRepo[root, default: []].append(r)
        }
        let marker = L("Ziel des Projekts") + ": "
        for (repo, rs) in byRepo.sorted(by: { $0.key < $1.key }) where !gone.contains(repo) {
            var goal = ""
            for r in rs.sorted(by: { $0.started > $1.started }) {
                let f = FileManager.default.temporaryDirectory.appendingPathComponent("aos-prompt-\(r.id).md")
                guard let t = try? String(contentsOf: f, encoding: .utf8),
                      let line = t.components(separatedBy: "\n").first(where: { $0.contains(marker) }),
                      let range = line.range(of: marker) else { continue }
                let g = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !g.isEmpty, g != "–" { goal = g; break }
            }
            let merged = rs.contains { $0.outcome == "merged" }
            let id = adopt(repo)
            update(id) { p in
                if p.goal.isEmpty { p.goal = goal }
                if merged { p.trust = 2 }
                p.paused = true   // erst nach deinem OK wieder aktiv – er soll nichts tun, was du vielleicht beendet hattest
                p.messages.append(StewardMessage(role: "status", text: "♻︎ " + L("Betreuer wiederhergestellt – die gespeicherte Liste war leer. Ziel und Vertrauen aus den letzten Aufträgen übernommen. Er ist pausiert: kurz prüfen und oben einschalten – oder „Betreuung beenden“.")))
            }
            Steward.log("Wiederhergestellt: \((repo as NSString).lastPathComponent) · Ziel \(goal.isEmpty ? "fehlt" : "übernommen") · Vertrauen \(merged ? 2 : 1)")
        }
    }

    // MARK: Aufträge von dir – ein Prompt, ein Team, ein fertiges Ergebnis

    /// Übernimmt deinen Auftrag für dieses Projekt: plant ihn als Team, setzt ihn um, prüft, liefert (PR/Merge) und meldet sich am Ende.
    @discardableResult
    func takeOrder(_ path: String, text: String, lead: AgentKind?, teamSize: Int) -> String {
        let id = adopt(path)
        let order = StewardOrder(text: text, lead: lead?.rawValue, teamSize: max(1, min(teamSize, 4)))
        update(id) { p in
            p.orders = (p.orders ?? []) + [order]
            if p.goal.isEmpty { p.goal = String(text.prefix(300)) }
            if p.paused { p.paused = false }
            p.messages.append(StewardMessage(role: "du", text: text))
        }
        say(id, "status", "🧭 " + (order.teamSize > 1
            ? String(format: L("Übernommen – ich plane ein Team aus bis zu %d Agents und betreue den Auftrag bis zum fertigen Ergebnis."), order.teamSize)
            : L("Übernommen – ich plane den Auftrag, setze ihn um und betreue ihn bis zum fertigen Ergebnis.")))
        planOrder(id, order.id)
        return id
    }

    private func planOrder(_ id: String, _ orderID: String, attempt: Int = 0, followUp: Bool = false) {
        guard let p = project(id), let o = p.orders?.first(where: { $0.id == orderID }), !o.planned else { return }
        if p.thinking == true {   // plant gerade etwas anderes → kurz danach
            if attempt < 30 { DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.planOrder(id, orderID, attempt: attempt + 1, followUp: followUp) } }
            return
        }
        if followUp {
            let done = p.tasks.filter { $0.order == o.id && ($0.state == .done || $0.state == .review) }.map { "- " + $0.title }.joined(separator: "\n")
            var f = "[[order:\(o.id)]] " + String(format: L("Fortsetzung deines Auftrags (Runde %d). Schon erledigt:"), (o.rounds ?? 0) + 1) + "\n" + done + "\n\n"
            f += L("Prüfe gegen den ursprünglichen Auftrag, was noch fehlt, und plane nur das. Ist alles umgesetzt – oder bleibt nur, was der Nutzer selbst entscheiden muss –, plane keine Aufgaben und nenne das Offene unter „blocked“.") + "\n\"\"\"\n" + o.text + "\n\"\"\""
            think(id, trigger: f)
            return
        }
        let leadText = o.lead.flatMap { AgentKind(rawValue: $0)?.title }
        var t = "[[order:\(o.id)]] " + L("Neuer Auftrag von dir – plane ihn als Team und setze ihn vollständig um:") + "\n\"\"\"\n" + o.text + "\n\"\"\"\n"
        t += L("So planst du: Zerlege den Auftrag in so wenige Teilaufgaben wie nötig (1–8), die zusammen genau diesen Auftrag fertig machen – nichts darüber hinaus.") + " "
        t += L("Die erste Teilaufgabe ist die Hauptaufgabe (Kern und Struktur, Priorität 1); weitere Teilaufgaben sind klar abgegrenzte Zuarbeiten in anderen Dateien oder Bereichen (Tests, Oberfläche, Doku, Randfälle), damit sich niemand gegenseitig in die Quere kommt.") + " "
        t += L("Wähle für jede Teilaufgabe den Agent und das Modell, die dafür am stärksten sind, und die passenden Skills und Erweiterungen. Keine doppelte Arbeit: nie dieselbe Aufgabe an mehrere Agents.") + " "
        if o.teamSize > 1 { t += String(format: L("Nutze höchstens %d verschiedene Agents."), o.teamSize) + " " }
        else { t += L("Ein Agent reicht – nimm für alle Teilaufgaben denselben.") + " " }
        if let leadText { t += String(format: L("Die Hauptaufgabe macht %@ (vom Nutzer gewählt)."), leadText) + " " }
        t += L("Ist der Auftrag klein, ist eine einzige Teilaufgabe richtig.") + " "
        t += L("Ist es ein Plan oder Befund mit vielen Punkten: Bereits Erledigtes überspringen, die offenen Punkte in der dort genannten Reihenfolge umsetzen – jetzt nur die erste Welle (höchstens 8 Teilaufgaben), den Rest planst du in der nächsten Runde. Punkte, die nur der Nutzer entscheiden darf, nicht umsetzen, sondern unter „blocked“ nennen.")
        think(id, trigger: t)
    }

    /// Aufträge abschließen, sobald alle ihre Teilaufgaben erledigt sind – mit Ergebnis-Meldung.
    func checkOrders(_ id: String) {
        guard let p = project(id) else { return }
        for o in p.orders ?? [] where o.planned && o.finished == nil {
            let mine = p.tasks.filter { $0.order == o.id }
            guard !mine.isEmpty else { continue }
            // Grüne Ergebnisse, die nur noch auf dein „Übernehmen“ warten, blockieren die nächste Welle nicht –
            // sonst bleibt der Rest des Auftrags liegen, bis du zufällig vorbeischaust.
            let busy = mine.contains { [.idea, .queued, .running, .red].contains($0.state) }
            guard !busy else { continue }
            let waiting = mine.contains { $0.state == .review }
            let done = mine.filter { $0.state == .done || $0.state == .review }
            let sig = mine.filter { $0.state != .dropped }.map(\.id).sorted().joined(separator: ",")
            if o.waveSig == sig {   // nach genau diesen Teilaufgaben wurde schon weitergeplant
                if !waiting { finishOrder(id, o) }
                continue
            }
            // Noch eine Runde? Der Betreuer prüft gegen den Auftrag, ob noch etwas fehlt (große Pläne in Wellen)
            if !done.isEmpty, (o.rounds ?? 0) < 6 {
                update(id) { q in
                    if let i = q.orders?.firstIndex(where: { $0.id == o.id }) { q.orders?[i].rounds = (o.rounds ?? 0) + 1; q.orders?[i].planned = false; q.orders?[i].waveSig = sig }
                }
                planOrder(id, o.id, followUp: true)
                continue
            }
            finishOrder(id, o)
        }
    }

    private func finishOrder(_ id: String, _ o: StewardOrder) {
        guard let p = project(id), p.orders?.first(where: { $0.id == o.id })?.finished == nil else { return }
        let mine = p.tasks.filter { $0.order == o.id }
        do {
            let done = mine.filter { $0.state == .done }
            let prs = done.compactMap(\.pr).map { "#\($0)" }
            let agents = Set(done.compactMap { AgentKind(rawValue: $0.agent)?.title }).sorted()
            var s = done.isEmpty ? L("Dafür war nichts umzusetzen oder es braucht erst deine Entscheidung – siehe die Antwort des Betreuers oben.")
                : String(format: L("%d Teilaufgaben erledigt"), done.count) + (agents.isEmpty ? "" : " (" + agents.joined(separator: ", ") + ")")
                  + (prs.isEmpty ? "" : " · " + L("Pull Requests") + " " + prs.joined(separator: ", "))
            s += "\n" + done.map { "✓ " + $0.title }.joined(separator: "\n")
            update(id) { q in
                if let i = q.orders?.firstIndex(where: { $0.id == o.id }) { q.orders?[i].finished = Date(); q.orders?[i].summary = s }
            }
            say(id, "betreuer", "✅ " + L("Auftrag fertig:") + " " + String(o.text.prefix(120)) + "\n" + s)
            if !done.isEmpty { Celebration.shared.fire(L("Auftrag fertig"), p.name, symbol: "checkmark.seal", tint: .green) }
            NotifyCenter.shared.post(done.isEmpty ? .runFailed : .runDone, title: "✅ " + L("Auftrag fertig") + " – " + p.name,
                                     body: String(o.text.prefix(140)), route: .page("steward:" + id))
        }
    }

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
                // Lokal auf einem anderen Branch mit nicht hochgeladenen Commits? Der Betreuer arbeitet trotzdem sauber vom GitHub-Stand.
                let cur = Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: id, timeout: 10).out.trimmingCharacters(in: .whitespacesAndNewlines)
                let ahead = Int(Git.run(["rev-list", "--count", "@{u}..HEAD"], in: id, timeout: 10).out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                if s.remote?.contains("github") == true, !cur.isEmpty, cur != s.defaultBranch {
                    lines.append(String(format: L("• Dein Ordner steht auf Branch „%@“%@. Pull Requests des Betreuers gehen nach „%@“ und bauen auf dem Stand von GitHub auf – änderbar im Menü unter „Pull Requests gehen nach“."),
                                        cur, ahead > 0 ? String(format: L(" mit %d nicht hochgeladenen Commits"), ahead) : "", s.defaultBranch))
                }
                if let w = self.githubWatcher(for: id), w.id != id {
                    lines.append(String(format: L("• Achtung: Das ist ein weiterer Klon desselben GitHub-Repos wie „%@“. GitHub (PRs, CI) betreut nur der erste – hier laufen nur lokale Aufgaben."), w.id.replacingOccurrences(of: NSHomeDirectory(), with: "~")))
                }
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

    /// Erkannte Befehle als Prüfschleife festschreiben (in den App-Daten – nie im Code des Projekts).
    func saveVerifyConfig(_ id: String) {
        guard let s = project(id)?.setup else { return }
        var cfg = ProjectConfig.load(id) ?? ProjectConfig()
        cfg.verify = ["typecheck", "lint", "test", "build"].compactMap { s.commands[$0] }
        if cfg.dev == nil { cfg.dev = s.commands["dev"] }
        ProjectConfig.save(cfg, dir: id)
        say(id, "system", L("Prüfschleife festgelegt: ") + (cfg.verify ?? []).joined(separator: " · "))
    }

    // MARK: Gespräch mit dem Betreuer

    func send(_ id: String, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        say(id, "du", t)
        update(id) { p in p.blocked = nil; p.idleThinks = 0; if p.goalReached != nil, p.continuous, t.count > 12 { p.goalReached = nil } }
        // Denkt der Betreuer gerade? Dann geht deine Nachricht nicht verloren – er antwortet direkt danach darauf.
        if project(id)?.thinking == true { waitingAsk[id] = t; return }
        ownerAsk.insert(id)
        think(id, trigger: t)
    }
    /// Nachrichten von dir, die während des Nachdenkens ankamen (Antwort folgt gleich danach).
    private var waitingAsk: [String: String] = [:]
    /// Diese Planung wurde durch eine Nachricht von dir ausgelöst: Was er dir zusagt, wird auch eingereiht.
    private var ownerAsk = Set<String>()

    /// Der Betreuer denkt nach: liest Ziel, Stand, Ergebnisse, Projektwissen und Signale – antwortet und plant.
    func think(_ id: String, trigger: String) {
        guard let p = project(id), p.thinking != true else { return }
        update(id) { $0.thinking = true }
        // Lokale Modelle nur, wenn du „lokal“ eingeschaltet hast – sonst bremsen sie den Mac und schaffen Coding-Aufgaben selten
        // Agents mit Kosten pro Nutzung plant er nicht von sich aus ein – nennst du einen in deiner Nachricht ausdrücklich, gilt das als dein Ja.
        let usable = AgentKind.coders.filter { OpenModels.available($0) && !AgentHealth.unavailable($0) && !Self.isBroken($0)
            && ($0 != .ollama || LocalFirst.shared.useLocal) }
        let named = ownerAsk.contains(id) ? Self.namedAgents(in: trigger, among: usable) : []
        let installed = usable.filter { Billing.autoOK($0) || named.contains($0) }
        let metered = usable.filter { !installed.contains($0) }
        var models: [AgentKind: [String]] = [:]
        for a in installed { models[a] = a == .ollama ? [LocalFirst.shared.model].compactMap { $0 } : ModelCatalog.shared.latest(for: a, limit: 5).map(\.value) }
        let tight = Set(installed.filter { Usage.shared.isTight($0) })
        let customerNotes: [String] = []
        // Wissen für gute Planung: Modellhinweise, passende Skills, alle installierten Erweiterungen, Erfahrungswerte
        var hints: [AgentKind: [String]] = [:]
        for a in installed { hints[a] = a == .ollama ? (models[a] ?? []) : ModelCatalog.shared.latest(for: a, limit: 5).map { $0.value + ($0.hint.isEmpty ? "" : " (" + $0.hint + ")") } }
        let context = p.goal + " " + trigger + " " + p.tasks.filter { [.queued, .red, .idea].contains($0.state) }.map(\.title).joined(separator: " ")
        let skills = [Router.skillCatalogText(context, skills: SkillCatalog.current?.skills ?? [], detailed: 40, describe: 100)]
        let exts = ExtensionStore.shared.installedList.filter { !$0.howTo.isEmpty }
            .map { "- \($0.id) (\($0.kind.rawValue)\($0.id.hasPrefix("custom:") ? ", added by the owner" : "")\($0.usable(claudeBased: false) ? "" : ", agent claude only")): \($0.purpose.prefix(140)) · when: \($0.when.prefix(6).joined(separator: ", "))" }
        let experience = Learning.routerHint(MissionStore.shared.missions)
        let know = Knowledge(models: hints, skills: Array(skills), extensions: exts, experience: experience, missions: MissionStore.shared.missions)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.ask(p, trigger: trigger, installed: installed, metered: metered, models: models, tight: tight, customers: customerNotes, know: know)
            DispatchQueue.main.async { self.apply(id, result, trigger: trigger) }
        }
    }

    private static var lastFailure = ""

    // Agents, die sofort scheitern (nicht angemeldet, kaputt, kein Abo) – 6 Stunden nicht einplanen
    static func markBroken(_ k: AgentKind) {
        UserDefaults.standard.set(Date().addingTimeInterval(6 * 3600).timeIntervalSince1970, forKey: "steward.broken." + k.rawValue)
    }
    static func isBroken(_ k: AgentKind) -> Bool {
        UserDefaults.standard.double(forKey: "steward.broken." + k.rawValue) > Date().timeIntervalSince1970
    }
    static func clearBroken(_ k: AgentKind) { UserDefaults.standard.removeObject(forKey: "steward.broken." + k.rawValue) }

    /// Wie viele Tokens jeder Agent hier pro Auftrag braucht (Median, 7 Tage) – damit der Planer günstig delegiert.
    static func tokenHint(_ missions: [MissionRecord]) -> String {
        let since = Date().addingTimeInterval(-7 * 86400)
        let runs = Paths.root.appendingPathComponent("logs/runs", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: runs.path)) ?? []
        var by: [String: [Int]] = [:]
        for m in missions where m.started >= since && !m.isOSAgent {
            let suffix = "-\(m.agent)-\(m.id.prefix(6)).log.json"
            guard let f = files.first(where: { $0.hasSuffix(suffix) }),
                  let d = try? Data(contentsOf: runs.appendingPathComponent(f)),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let c = j["context"] as? Int, c > 0 else { continue }
            by[m.agent, default: []].append(c)
        }
        let lines = by.filter { $0.value.count >= 3 }.map { a, v -> String in
            let s = v.sorted(); return "\(a): ~\(s[s.count / 2] / 1000)k tokens per task (\(v.count) runs)"
        }.sorted()
        return lines.isEmpty ? "" : "\nToken use per task on this Mac (median): " + lines.joined(separator: "; ") + ". Prefer the cheaper agent when quality is similar."
    }
    private var failStreak: [String: Int] = [:]

    static func log(_ text: String) {
        let url = Paths.root.appendingPathComponent("logs/steward.log")
        let entry = "\n=== \(Date())\n" + text + "\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(entry.utf8)); try? h.close() }
        else { try? entry.write(to: url, atomically: true, encoding: .utf8) }
    }

    private struct Plan {
        var reply: String
        var goal: String?
        var clearGoal = false
        var tasks: [StewardTask]
        var drop: [String]
        var learnings: [(text: String, kind: String)]
        var reached: Bool = false
        var progress: String?
        var blocked: String?
    }

    struct Knowledge { var models: [AgentKind: [String]]; var skills: [String]; var extensions: [String]; var experience: String; var missions: [MissionRecord] = [] }

    private static func ask(_ p: StewardProject, trigger: String, installed: [AgentKind], metered: [AgentKind] = [], models: [AgentKind: [String]],
                            tight: Set<AgentKind>, customers: [String], know: Knowledge) -> Plan? {
        guard Detection.which("claude") != nil else { lastFailure = L("Claude Code ist nicht installiert"); return nil }
        let lang = Profile.languageCode == "de" ? "German (informal du, short and direct)" : "English"
        let agentList = installed.map { a in
            "- \(a.rawValue) (\(a.title)): \(a.strength)" + ((know.models[a] ?? []).isEmpty ? "" : " · models: " + (know.models[a] ?? []).joined(separator: ", "))
                + (tight.contains(a) ? " · NEARLY AT LIMIT, avoid" : "")
        }.joined(separator: "\n")
        let open = p.tasks.filter { [.idea, .queued, .running, .review, .red].contains($0.state) }
            .map { "- [\($0.id.prefix(6))] \($0.state.rawValue): \($0.title)" + ($0.note.map { " — \($0.prefix(160))" } ?? "") }
            .joined(separator: "\n")
        let recent = p.tasks.filter { $0.state == .done || $0.state == .dropped }.suffix(10)
            .map { "- \($0.state.rawValue): \($0.title)" + ($0.note.map { " — \($0.prefix(120))" } ?? "") }.joined(separator: "\n")
        let chat = chatContext(p.messages)
        let memory = ProjectMemory.promptBlock(p.id)?.text ?? ""
        let setup = p.setup.map { s in
            "Stack: \(s.stack.joined(separator: ", ")). Commands: " + s.commands.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")
        } ?? "not analysed yet"
        var know = know
        know.experience += Self.tokenHint(know.missions)          // im Hintergrund: liest die Lauf-Statistiken
        let capacity = p.unlimited ? 999 : max(0, p.dailyRuns + (p.extraToday?[p.today] ?? 0) - p.runsToday)
        let prompt = """
        You are the long-term STEWARD (coordinator) of the software project "\(p.name)" (\(p.id)).
        You never write code yourself. You plan, split work into small independent tasks that coding agents execute in \
        isolated git worktrees (each task is built, tested and reviewed automatically), and you keep the project healthy over weeks.
        The owner is a busy founder, not a developer: speak plainly, be brief, no jargon.

        Goal: \(p.goal.isEmpty ? "(not set yet – ask for it if the trigger does not give one)" : p.goal)
        Setup: \(setup)
        Trust level: \(p.trust) (0 = only propose, 1 = start tasks automatically, 2 = also merge green results).
        Capacity left today: \(capacity) task runs, max \(p.parallel) in parallel.
        Mode: \(p.continuous ? (p.goalReached != nil && p.improve == true
            ? "GOAL REACHED – IMPROVEMENT MODE: keep the project getting better on your own: real bugs, missing tests, error handling, performance, security, accessibility, UX polish, dead code, docs. Only worthwhile, low-risk tasks; never invent features that change the product's direction."
            : "WORK UNTIL DONE: the owner wants you to keep going without stopping until the goal is fully reached. Every time the queue is empty you are asked again: judge honestly whether the goal is reached; if not, plan the next tasks right away.")
            : "normal (plan when asked)")
        \(p.count(.review) > 0 && p.trust < 2 ? "\(p.count(.review)) results wait for the owner to merge – do not plan tasks that depend on those unmerged changes." : "")
        \(p.chosenExtensions.isEmpty ? "" : "Extensions the owner chose for this project (every helper is told to use them; give tasks that need Claude plugins or skills to the agent claude):\n" + p.chosenExtensions.map { "- \($0.name): \($0.purpose)" }.joined(separator: "\n"))

        Open tasks:
        \(open.isEmpty ? "(none)" : open)

        Open pull requests on GitHub (the GitHub watcher reviews, fixes and merges them automatically – do not duplicate that work):
        \((p.prs ?? []).isEmpty ? "(none)" : (p.prs ?? []).map { prLine($0, p) }.joined(separator: "\n"))

        Recently finished:
        \(recent.isEmpty ? "(none)" : recent)

        \(memory)

        \(customers.isEmpty ? "" : "Customer reports (possible bugs):\n" + customers.joined(separator: "\n"))

        Conversation (latest last):
        \(chat)

        Trigger now: \(trigger)

        Rules:
        - Tasks must be concrete, small enough for one agent run (≤ ~1 hour), independent where possible, with clear done criteria in "detail". \
        Done criteria describe the change itself (behaviour, affected tests) – never "full test suite green", "CI green", "PR created" or "pushed": the pipeline does that automatically afterwards.
        - Do not duplicate open tasks. Prefer fixing red tasks (re-plan them) before adding new features.
        - Tasks that run at the same time must not change the same files (parallel edits of one file collide when they are merged). \
        If several tasks would add to the same file, give each its own file/module in "detail", or plan only the first one now and the rest after it.
        - Plan at most \(planLimit(p.parallel)) new tasks per answer – the next most important ones only. You are asked again as soon as the queue is empty.
        - If the owner gave a list of work (numbered points), that list is your backlog: work through it in his order, skip nothing silently, \
        and say in "progress" which points are done and which come next. Points that need his decision go into "reply" as a question, once.
        - Only promise in "reply" what this answer really does: a task counts as planned only if it is in "tasks" here or already open.
        - Pages a helper changes are screenshotted (desktop and phone width, overflow measured) and reviewed automatically after the run. \
        Never tell a helper to open or drive a browser to check its page, and never promise that in "reply": helpers run unattended, \
        and browser tools wait for an approval nobody answers.
        - Do NOT plan fixes for open pull requests or red CI: the GitHub watcher does that on its own.
        - Pick the best agent per task from the list and a fitting model (cheap/fast for small fixes, strong for hard work).
        - Never plan work on the tool that runs you ("Salenta Code"); only on this project.
        - Never plan deploys to production, publishing, deleting data or sending messages to customers – propose those to the owner in "reply".
        - If the goal is unclear, ask ONE question in "reply" and return no tasks.
        - Visual redesigns (new look, landing pages, brand feel) without a concrete style direction from the owner (reference sites, mood, \
        colours, examples he likes): do NOT let a helper guess – the result becomes generic. Plan first ONE task "Design-Richtungen": three clearly \
        different directions as one static page each, with screenshots, nothing merged; then set "blocked" so the owner picks one. Only after his \
        choice plan the build tasks, and split them small (first hero + home page, then the system, then sub-pages).
        - Done criteria describe the result (what works, which checks pass) – do not forbid helper files or folders unless really needed; \
        over-narrow rules ("only these directories") make good work fail the review.
        - "drop": ids (6 chars) of open tasks that are obsolete – also running ones (they are stopped). If the owner says to stop or skip something, put its id here; never only promise it in "reply".
        - "learnings": durable project facts worth remembering (decisions, conventions, pitfalls). Max 3.
        - "clear_goal": true only if the owner asks to remove or reset the goal (e.g. a message was meant for another project); else false.
        - "goal_reached": true only if the goal is really fully met (verified by finished green tasks), else false.
        - "progress": one short sentence how far the goal is, e.g. "about 60 % – payments still missing".
        - "blocked": fill ONLY if you cannot continue without the owner (missing access, decision, account, payment, deploy); else "".

        Available agents:
        \(agentList)
        \(metered.isEmpty ? "" : "Installed but paid per use – you may NOT plan these on your own: " + metered.map { "\($0.rawValue) (\($0.title))" }.joined(separator: ", ")
            + ". If the owner asks for one of them, say it costs per use and that he can allow it by naming that agent for the task in his message (or in the settings under costs); never guess another reason.")

        Model choice: use the strongest model (e.g. opus) for architecture, tricky bugs, security and large refactors;
        a mid model (sonnet) for normal features; small/fast models only for trivial edits, renames, copy changes and lint fixes.
        Thinking effort per task ("effort"): "low" for trivial/mechanical work, "medium" for almost everything (default – strong
        models like Opus need no more), "high" ONLY for genuinely hard debugging, security or architecture. Never use max/xhigh.

        \(know.experience.isEmpty ? "" : know.experience + "\nPrefer the agent that historically succeeds for this kind of task here.")

        Skills and extensions are part of the plan: for every task go through both lists and give the helper everything that
        clearly helps – several together when they cover different needs (for example a token saver + a design skill + a test
        skill). Nothing that merely sounds related.

        Installed extensions, including repos the owner added himself (pick per task in "extensions" by id, up to 4;
        those marked "agent claude only" do nothing for other agents):
        \(know.extensions.isEmpty ? "(none)" : know.extensions.joined(separator: "\n"))

        Installed skills – all of them, the closest word matches first with a description (pick per task in "skills" by
        exact name, up to 5; the source in brackets says which agent can load it: Claude Code, Plugin, Agents → claude ·
        Codex, Agents → codex):
        \(know.skills.isEmpty ? "(none)" : know.skills.joined(separator: "\n"))

        Answer ONLY with JSON in \(lang):
        {"reply":"","goal":"","tasks":[{"title":"short imperative","detail":"what + done criteria","agent":"<id>","model":"","priority":2,"effort":"medium","skills":[],"extensions":[]}],"drop":[""],"learnings":[{"text":"","kind":"regel"}],"clear_goal":false,"goal_reached":false,"progress":"","blocked":""}
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("aos-steward-\(UUID().uuidString).md")
        try? prompt.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        // Planen ist die wichtigste Entscheidung: im Dauerbetrieb das stärkste Modell
        // Planen ist die wichtigste Entscheidung: im Dauerbetrieb das stärkste Modell – klappt das nicht, Sonnet
        // Planen ist die wichtigste Entscheidung – immer das stärkste Modell (wenige, kurze Aufrufe). Im Limit Sonnet.
        let first = tight.contains(.claude) ? "sonnet" : "opus"
        var j: [String: Any]?
        var why = ""
        for model in (first == "opus" ? ["opus", "sonnet"] : ["sonnet"]) {
            let r = Proc.zsh(HelperLLM.command(model: model, maxTurns: 3, file: file.path),
                             in: NSTemporaryDirectory(), timeout: 420)
            if let res = Verifier.claudeResult(r.out), let a = res.firstIndex(of: "{"), let b = res.lastIndex(of: "}"), a < b,
               let parsed = try? JSONSerialization.jsonObject(with: Data(res[a...b].utf8)) as? [String: Any] {
                j = parsed; break
            }
            why = Verifier.claudeFailure(r.out, code: r.code)
            Self.log("\(p.name) · \(model) · exit \(r.code) · \(why)\n\(r.out.suffix(1500))")
            if why == L("Claude ist im Limit") || why == L("keine Internetverbindung") || why.hasPrefix(L("„Nur lokal“")) { break }
        }
        guard let j else { lastFailure = why; return nil }
        let tasks = ((j["tasks"] as? [[String: Any]]) ?? []).compactMap { t -> StewardTask? in
            guard let title = t["title"] as? String, !title.isEmpty, !Digest.isToolTopic(title) else { return nil }
            var agent = (t["agent"] as? String ?? "auto").lowercased()
            if AgentKind(rawValue: agent).map({ installed.contains($0) }) != true { agent = "auto" }
            var model = t["model"] as? String ?? ""
            if let k = AgentKind(rawValue: agent), !model.isEmpty, !(models[k] ?? []).contains(model) { model = "" }
            // Nur Skills, die es gibt und die der geplante Agent laden kann (bei „auto“ entscheidet sich der Agent erst beim Start)
            let catalog = SkillCatalog.current?.skills ?? []
            let planned = AgentKind(rawValue: agent)
            let sk = (t["skills"] as? [String] ?? []).filter { n in
                catalog.isEmpty || catalog.contains { $0.name == n && (planned == nil || Router.loadable($0, by: planned)) }
            }.prefix(5).map { $0 }
            let ex = (t["extensions"] as? [String] ?? []).filter { id in ExtensionStore.shared.installedList.contains { $0.id == id } }.prefix(4).map { $0 }
            let eff = (t["effort"] as? String ?? "medium").lowercased()
            return StewardTask(title: title, detail: t["detail"] as? String ?? "", agent: agent, model: model,
                               priority: t["priority"] as? Int ?? 2, skills: sk.isEmpty ? nil : sk, exts: ex.isEmpty ? nil : ex,
                               effort: ["low", "medium", "high"].contains(eff) ? eff : "medium")
        }
        let learnings = ((j["learnings"] as? [[String: Any]]) ?? []).compactMap { l -> (text: String, kind: String)? in
            guard let t = l["text"] as? String, !t.isEmpty else { return nil }
            return (t, l["kind"] as? String ?? "lernen")
        }
        let goal = (j["goal"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        func str(_ k: String) -> String? { let v = (j[k] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines); return v.isEmpty ? nil : v }
        return Plan(reply: (j["reply"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    goal: goal.isEmpty ? nil : goal, clearGoal: j["clear_goal"] as? Bool ?? false, tasks: tasks, drop: (j["drop"] as? [String]) ?? [], learnings: learnings,
                    reached: j["goal_reached"] as? Bool ?? false, progress: str("progress"), blocked: str("blocked"))
    }

    private func apply(_ id: String, _ plan: Plan?, trigger: String = "") {
        update(id) { $0.thinking = nil }
        guard let plan else {
            if let t = waitingAsk.removeValue(forKey: id) { ownerAsk.insert(id); think(id, trigger: t); return }
            let why = Self.lastFailure.isEmpty ? L("unbekannter Grund") : Self.lastFailure
            let retryMin = why == L("Claude ist im Limit") ? 30 : 3
            say(id, "system", String(format: L("Der Betreuer konnte gerade nicht nachdenken: %@. Neuer Versuch in %d Minuten."), why, retryMin))
            // Einmal automatisch neu versuchen (nicht endlos: eine Wiederholung pro Fehlschlag in Folge)
            if (failStreak[id] ?? 0) < 3 {
                failStreak[id, default: 0] += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(retryMin * 60)) { [weak self] in
                    guard let self, let p = self.project(id), !p.paused, p.thinking != true else { return }
                    self.think(id, trigger: trigger.isEmpty ? L("Bitte prüf den Stand und plan die nächsten Schritte.") : trigger)
                }
            }
            return
        }
        failStreak[id] = 0
        let fromOwner = ownerAsk.remove(id) != nil
        var finishedOrder: StewardOrder?
        var stopMissions: [String] = []
        update(id) { p in
            if plan.clearGoal { p.goal = ""; p.goalReached = nil }
            else if let g = plan.goal, p.goal.isEmpty { p.goal = g }
            // Verworfen wird auch, was gerade läuft – sonst sagt der Betreuer „breche ich ab“ und der Helfer arbeitet weiter
            for d in plan.drop where !d.isEmpty {
                if let i = p.tasks.firstIndex(where: { $0.id.hasPrefix(d) && ![.done, .dropped].contains($0.state) }) {
                    if [.running, .review].contains(p.tasks[i].state), let mid = p.tasks[i].missionID { stopMissions.append(mid) }
                    p.tasks[i].state = .dropped; p.tasks[i].note = L("vom Betreuer verworfen"); p.tasks[i].finished = Date()
                }
            }
            let known = Set(p.tasks.filter { $0.state != .dropped && $0.state != .done }.map { $0.title.lowercased() })
            let recentlyDropped = Set(p.tasks.filter { $0.state == .dropped && ($0.finished ?? $0.created) > Date().addingTimeInterval(-86400) }.map { $0.title.lowercased() })
            // Auftrag von dir? Teilaufgaben ihm zuordnen, Team-Grenzen einhalten, Auftrag gilt als geplant
            let orderID = trigger.range(of: #"\[\[order:([A-Za-z0-9-]+)\]\]"#, options: .regularExpression).map { String(trigger[$0].dropFirst(8).dropLast(2)) }
            let order = orderID.flatMap { oid in p.orders?.first { $0.id == oid } }
            var teamAgents: [String] = []
            // Nicht mehr einplanen, als heute und parallel überhaupt laufen kann – sonst wird das meiste später nur verworfen
            let room = max(2, min(p.parallel + 1, p.unlimited ? 6 : max(0, p.dailyRuns + (p.extraToday?[p.today] ?? 0) - p.runsToday)))
            // PR-Korrekturen reiht der GitHub-Wächter ein – sie nehmen deinen geplanten Aufgaben keinen Platz weg
            let openNow = p.tasks.filter { [.queued, .idea].contains($0.state) && $0.prBranch == nil }.count
            var added = 0
            // Offene PR-Korrekturen: der GitHub-Wächter führt sie schon – der Plan darf sie nicht ein zweites Mal einreihen
            var openPRs = Set(p.tasks.filter { ![.done, .dropped].contains($0.state) }.compactMap { $0.pr })
            var seen = known
            for (n, var t) in plan.tasks.enumerated() where !known.contains(t.title.lowercased()) && !recentlyDropped.contains(t.title.lowercased()) {
                // Antwort auf deine Nachricht: Was er dir zusagt, wird eingereiht (höchstens so viele, wie eine Planung liefern darf)
                if order == nil, fromOwner ? added >= Self.planLimit(p.parallel) : openNow + added >= room { break }
                if seen.contains(t.title.lowercased()) { continue }                       // doppelt im selben Plan
                if let r = t.title.range(of: #"#(\d+)"#, options: .regularExpression), let num = Int(t.title[r].dropFirst()),
                   t.title.lowercased().contains("pr"), openPRs.contains(num) { continue }
                seen.insert(t.title.lowercased())
                if let r = t.title.range(of: #"#(\d+)"#, options: .regularExpression), let num = Int(t.title[r].dropFirst()), t.title.lowercased().contains("pr") { openPRs.insert(num) }
                added += 1
                t.state = p.trust == 0 ? .idea : .queued
                // Du hast für diese Runde einen Agent mit Kosten pro Nutzung ausdrücklich genannt: dann bleibt es bei ihm
                if fromOwner, let k = AgentKind(rawValue: t.agent), Billing.isMetered(k) { t.source = "du" }
                if let order {
                    t.order = order.id
                    t.source = "du"
                    t.state = .queued        // dein Auftrag: sofort umsetzen, nicht nur vorschlagen
                    if n == 0, let lead = order.lead { t.agent = lead; if !ModelCatalog.fits(t.model, AgentKind(rawValue: lead) ?? .claude) { t.model = "" } }
                    if t.agent != "auto" {
                        if !teamAgents.contains(t.agent) {
                            if teamAgents.count < order.teamSize { teamAgents.append(t.agent) }
                            else { t.agent = teamAgents.first ?? t.agent; t.model = "" }   // Team voll → Haupt-Agent übernimmt
                        }
                    }
                }
                p.tasks.append(t)
            }
            // Mehr geplant, als in diese Runde passte (oder „kommt in der nächsten Runde“ versprochen)? Dann nachfragen, sobald alles durch ist
            // Nur setzen, nie hier löschen: eine spätere Planung ohne neue Aufgaben (z. B. nach einem Neustart oder Rundgang)
            // darf das Versprechen „kommt in der nächsten Runde“ nicht vergessen. Gelöscht wird es erst beim Nachfassen selbst.
            if order == nil, !p.continuous, added > 0 || plan.tasks.count > added { p.followUp = true }
            if let order, let i = p.orders?.firstIndex(where: { $0.id == order.id }) {
                p.orders?[i].planned = true
                if !p.tasks.contains(where: { $0.order == order.id && ![.done, .dropped].contains($0.state) }) { finishedOrder = order }
            }
        }
        for mid in stopMissions {
            if let s = agents?.sessions.first(where: { $0.id.uuidString == mid }) { agents?.close(s.id) }
            finishMission(mid, outcome: "dropped")
        }
        if !plan.reply.isEmpty { say(id, "betreuer", plan.reply) }
        if let o = finishedOrder { finishOrder(id, o) }   // nichts mehr zu tun → Ergebnis melden
        afterPlan(id, plan)
        if !plan.learnings.isEmpty { ProjectMemory.add(id, plan.learnings, source: L("Projekt-Betreuer")) }
        dispatch(id)
        // Kam währenddessen eine Nachricht von dir? Jetzt darauf antworten.
        if let t = waitingAsk.removeValue(forKey: id) { ownerAsk.insert(id); think(id, trigger: t) }
    }

    /// Ein offener PR für die Planung – mit der Angabe, wer ihn übernimmt. Sonst verspricht der Betreuer „übernehme ich selbst“,
    /// obwohl PRs, die das Aussehen ändern, immer auf dich warten.
    static func prLine(_ pr: StewardPR, _ p: StewardProject) -> String {
        var s = "- #\(pr.number) \(pr.title) · CI \(pr.ci) · \(pr.mergeable)" + (pr.reviewOK.map { $0 ? " · review ok" : " · review issues" } ?? "")
        let auto = p.mergesPRs && (pr.ours || p.mergeAll == true)
        if pr.changesLook { s += " · changes the look: ONLY THE OWNER merges it (never say you will merge it; ask him to look at the preview)" }
        else if !auto { s += " · the owner merges it" }
        else { s += " · merged automatically once green and reviewed" }
        return s
    }

    /// Welche Agents nennt dieser Text ausdrücklich? Erst die vollen Namen, dann die Kurzform – aber nie eine Kurzform,
    /// die nur als Teil des Namens eines anderen Agents vorkommt.
    static func namedAgents(in text: String, among agents: [AgentKind]) -> Set<AgentKind> {
        var rest = text.lowercased()
        var out = Set<AgentKind>()
        for a in agents.sorted(by: { $0.title.count > $1.title.count }) where Router.mentions(rest, a.title.lowercased()) {
            out.insert(a)
            rest = rest.replacingOccurrences(of: a.title.lowercased(), with: " ")
        }
        for a in agents where !out.contains(a) && Router.mentions(rest, a.rawValue) { out.insert(a) }
        return out
    }

    /// So viele neue Aufgaben darf eine Planung liefern.
    static func planLimit(_ parallel: Int) -> Int { max(2, parallel + 1) }

    /// Gesprächs-Ausschnitt für die Planung. Deine Nachrichten bleiben ausführlich und auch dann im Blick, wenn viele
    /// Statusmeldungen dazwischenliegen – sonst ist ein längerer Auftrag nach wenigen Läufen vergessen.
    static func chatContext(_ messages: [StewardMessage]) -> String {
        let recent = Array(messages.suffix(12))
        let shown = Set(recent.map(\.id))
        let older = messages.filter { $0.role == "du" && !shown.contains($0.id) && $0.text.count > 40 }.suffix(3)
        func line(_ m: StewardMessage) -> String { "\(m.role): \(m.text.prefix(m.role == "du" ? 4000 : 600))" }
        var out = ""
        if !older.isEmpty {
            out += "Earlier messages from the owner (still valid unless a later message replaces them):\n"
                + older.map(line).joined(separator: "\n") + "\n\nLatest messages:\n"
        }
        return out + recent.map(line).joined(separator: "\n")
    }

    // MARK: Dauerbetrieb – bis das Ziel erreicht ist

    private func afterPlan(_ id: String, _ plan: Plan) {
        guard let before = project(id) else { return }
        let firstReach = plan.reached && before.goalReached == nil
        update(id) { p in
            if let pr = plan.progress { p.progress = pr }
            p.blocked = plan.blocked
            if plan.reached { if p.goalReached == nil { p.goalReached = Date() } }
            p.idleThinks = plan.tasks.isEmpty ? (p.idleThinks ?? 0) + 1 : 0
        }
        guard before.continuous else { return }
        if firstReach {
            say(id, "betreuer", "🎯 " + L("Ziel erreicht!") + (before.improve == true ? " " + L("Ich arbeite jetzt selbst an Verbesserungen weiter (Fehler, Tests, Tempo, Sicherheit, Bedienung).") : " " + L("Ich höre hier auf. Gib mir ein neues Ziel, dann mache ich weiter.")))
            Celebration.shared.fire(L("Ziel erreicht"), before.name, symbol: "flag.checkered", tint: .green)
            NotifyCenter.shared.post(.runDone, title: "🎯 " + L("Ziel erreicht") + " – " + before.name, body: before.goal, route: .page("steward:" + id))
        }
        if let b = plan.blocked {
            say(id, "system", "✋ " + L("Ich brauche dich, bevor es weitergeht: ") + b)
            NotifyCenter.shared.post(.runFailed, title: "🧭 " + before.name + ": " + L("braucht dich"), body: b, route: .page("steward:" + id))
        } else if (project(id)?.idleThinks ?? 0) >= 3, !plan.reached {
            update(id) { $0.blocked = L("Ich finde gerade keinen sinnvollen nächsten Schritt mehr. Schreib mir, was noch fehlt.") }
            say(id, "system", "✋ " + L("Ich finde gerade keinen sinnvollen nächsten Schritt mehr. Schreib mir, was noch fehlt."))
        }
    }

    /// Ist alles abgearbeitet, plant der Betreuer im Dauerbetrieb sofort die nächste Runde.
    private func continueIfIdle(_ id: String) {
        // Ohne Dauerbetrieb: einmal nachfassen, wenn die geplante Welle fertig ist – sonst bleibt „kommt in der nächsten Runde“ liegen
        if let p = project(id), !p.continuous, p.followUp == true, !p.paused, p.thinking != true, p.blocked == nil,
           p.count(.running) == 0, p.count(.queued) == 0, p.budgetLeft, (Usage.shared.blocked["claude"] ?? .distantPast) <= Date() {
            update(id) { $0.followUp = false }
            think(id, trigger: L("Die Aufgaben der letzten Runde sind durch. Fehlt von dem, was der Nutzer zuletzt wollte, noch etwas (auch was du für „die nächste Runde“ angekündigt hast)? Dann plane genau das jetzt; sonst keine Aufgaben."))
            return
        }
        guard let p = project(id), p.continuous, !p.paused, p.thinking != true, !p.goal.isEmpty, p.blocked == nil,
              p.count(.running) == 0, p.count(.queued) == 0,
              !p.tasks.contains(where: { $0.state == .review && $0.pr != nil }) else { return }   // offene PRs erst durchlaufen lassen
        if p.goalReached != nil && p.improve != true { return }          // Ziel erreicht, Verbessern aus → Ruhe
        if !p.budgetLeft { return }                                      // Tagesbudget aufgebraucht → morgen weiter
        if (Usage.shared.blocked["claude"] ?? .distantPast) > Date() { return }  // Planer im Limit → später weiter
        let wait: TimeInterval = p.goalReached != nil ? 20 * 60 : 90    // Verbessern ruhiger als Durcharbeiten
        if let l = p.lastContinue, Date().timeIntervalSince(l) < wait { return }
        update(id) { $0.lastContinue = Date() }
        let trigger = p.goalReached != nil
            ? L("Ziel ist erreicht – such selbst die nächsten lohnenden Verbesserungen und plane sie.")
            : L("Alles abgearbeitet. Ist das Ziel jetzt vollständig erreicht? Wenn nicht: plane sofort die nächsten Aufgaben bis dorthin.")
        think(id, trigger: trigger)
    }

    func setContinuous(_ id: String, _ on: Bool) {
        update(id) { p in
            p.untilDone = on
            p.blocked = nil; p.idleThinks = 0; p.lastContinue = nil
            if on { p.paused = false; if p.trust == 0 { p.trust = 1 } }
        }
        guard on, let p = project(id) else { return }
        if p.goal.isEmpty {
            say(id, "betreuer", L("Gern arbeite ich durch, bis alles erledigt ist. Was genau ist das Ziel? Schreib es mir in einem Satz."))
            return
        }
        say(id, "system", "∞ " + L("Dauerbetrieb an: Ich arbeite weiter, bis das Ziel erreicht ist.")
            + (p.trust < 2 ? " " + L("Tipp: Mit „Grünes selbst übernehmen“ muss ich nicht auf dich warten, bis geprüfte Ergebnisse übernommen sind.") : ""))
        if p.count(.running) == 0, p.count(.queued) == 0 { think(id, trigger: L("Dauerbetrieb gestartet. Prüf den Stand und plane die nächsten Aufgaben bis zum Ziel.")) }
        else { dispatch(id) }
    }

    func setImprove(_ id: String, _ on: Bool) {
        update(id) { $0.improve = on; $0.blocked = nil; $0.idleThinks = 0 }
        if on, project(id)?.goalReached != nil { continueIfIdle(id) }
    }

    func toggleExtension(_ id: String, _ ext: String) {
        update(id) { p in
            var e = p.extensions ?? []
            if let i = e.firstIndex(of: ext) { e.remove(at: i) } else { e.append(ext) }
            p.extensions = e
        }
    }

    /// Gehört dieser Auftrag (oder einer seiner Vorgänger) zu einem betreuten Projekt?
    func owner(ofMission mid: String) -> StewardProject? {
        var ids = [mid], cur = mid, n = 0
        while n < 10, let r = MissionStore.shared.mission(cur), let par = r.parent { ids.append(par); cur = par; n += 1 }
        return projects.first { p in p.tasks.contains { t in t.missionID.map(ids.contains) == true } }
    }

    /// Prüfung war rot, aber die Korrekturrunde ist nie gestartet, weil die App in dem Moment beendet wurde (Update, Neustart)?
    static func fixInterrupted(passed: Bool?, fixRound: Int, ended: Date?, archived: Bool, outcome: String?, hasWorktree: Bool, hasChild: Bool,
                               now: Date = Date()) -> Bool {
        guard passed == false, fixRound < 2, !archived, outcome == nil, hasWorktree, !hasChild, let ended else { return false }
        let age = now.timeIntervalSince(ended)
        return age >= 0 && age < 60 * 60
    }

    /// Nach dem Start: liegen gebliebene Korrekturrunden nachholen – sonst bleibt ein Ergebnis rot, das eine Runde später grün wäre.
    func resumeInterruptedFixes() {
        guard Verifier.autoFix, let agents, let hub else { return }
        let all = MissionStore.shared.missions
        for rec in all where Self.fixInterrupted(passed: rec.verify?.passed, fixRound: rec.fixRound ?? 0, ended: rec.ended, archived: rec.archived == true,
                                                 outcome: rec.outcome, hasWorktree: rec.worktree != nil,
                                                 hasChild: all.contains { $0.parent == rec.id && $0.delegated != true }) {
            guard !agents.sessions.contains(where: { $0.id.uuidString == rec.id && $0.running }) else { continue }
            let second = (rec.fixRound ?? 0) >= 1
            Verifier.fix(rec, agents: agents, hub: hub, agent: second ? Verifier.reviewer(for: rec.agent).rawValue : nil) { n in
                // Gehört der Auftrag zu einer Betreuer-Aufgabe? Dann läuft sie wieder (statt rot liegen zu bleiben)
                guard let p = self.owner(ofMission: rec.id) else { return }
                self.update(p.id) { q in
                    if let i = q.tasks.firstIndex(where: { $0.missionID == rec.id && [.red, .running, .review].contains($0.state) && $0.pr == nil }) {
                        q.tasks[i].state = .running; q.tasks[i].missionID = n.id.uuidString; q.tasks[i].started = Date()
                    }
                }
                self.say(p.id, "status", "↻ " + L("Korrekturrunde nachgeholt (die App wurde währenddessen neu gestartet): ") + rec.title)
            }
        }
    }

    // MARK: Takt

    private var lastBeat: Date?
    /// Nur für den Test in der Entwickler-Version: so tun, als hätte der Mac `minutes` lang geschlafen, während die Aufgaben
    /// dieses Projekts liefen (Startzeit und letzter Takt liegen entsprechend zurück). Der nächste Takt muss das ausgleichen.
    func testSleep(_ id: String, minutes: Double) -> Int {
        guard Paths.isDevBuild else { return 0 }
        var n = 0
        update(id) { q in
            for i in q.tasks.indices where q.tasks[i].state == .running {
                q.tasks[i].started = (q.tasks[i].started ?? Date()).addingTimeInterval(-minutes * 60); n += 1
            }
        }
        lastBeat = Date().addingTimeInterval(-minutes * 60)
        return n
    }
    private var mergeRetried = Set<String>()
    /// Wie lange stand alles still (Mac im Ruhezustand)? 0, wenn der Takt normal weiterlief.
    static func sleptGap(last: Date?, now: Date, beat: TimeInterval = 30) -> TimeInterval {
        guard let last else { return 0 }
        let gap = now.timeIntervalSince(last)
        return gap > max(300, beat * 6) ? gap - beat : 0
    }

    private func tick() {
        // Ruhezustand zählt nicht als Laufzeit: Sonst gilt ein Helfer nach dem Aufwachen als „hing fest“ und wird gestoppt,
        // obwohl er kaum gearbeitet hat.
        let now = Date()
        let gap = Self.sleptGap(last: lastBeat, now: now)
        lastBeat = now
        if gap > 0 {
            for p in projects where p.tasks.contains(where: { $0.state == .running }) {
                update(p.id) { q in for i in q.tasks.indices where q.tasks[i].state == .running { q.tasks[i].started = q.tasks[i].started?.addingTimeInterval(gap) } }
            }
        }
        guard Energy.due("steward", every: 120) else { return }
        for p in projects where !p.paused {
            evaluate(p.id)
            checkOrders(p.id)
            uploadOfflineWork(p.id)
            // Am Akku: Ergebnisse auswerten ja, aber keine neuen Helfer, keine Rundgänge, kein Weiterplanen
            guard Energy.backgroundAgentsOK else { continue }
            signals(p.id)
            scanPRs(p.id)
            dispatch(p.id)
            continueIfIdle(p.id)
        }
    }

    /// Helfer starten, solange Platz und Tagesbudget da sind.
    func dispatch(_ id: String) {
        guard let agents, var p = project(id), !p.paused, Energy.backgroundAgentsOK, p.tasks.contains(where: { $0.state == .queued }) else { return }
        var running = p.count(.running)
        var launched = false
        // Alle Helfer-Anbieter von dir pausiert → nichts starten, Aufgaben warten
        guard AgentKind.coders.contains(where: { OpenModels.available($0) && !Usage.isPaused($0) }) else { return }
        while running < PowerProfile.capParallel(p.parallel), p.budgetLeft,
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
        let wanted = k
        if t.source != "du", !Billing.autoOK(k) { k = .claude }   // kostet pro Nutzung → nur, wenn du es selbst willst
        // Von dir gewählter Agent: nicht still austauschen – nur, wenn er wirklich gesperrt ist oder fehlt
        let yours = t.source == "du" && t.agent != "auto"
        let hardBlocked = (Usage.shared.blocked[k.rawValue] ?? .distantPast) > Date()
        let broken = Self.isBroken(k)
        if !OpenModels.available(k) || AgentHealth.unavailable(k) || hardBlocked || broken || (!yours && Usage.shared.isTight(k)) {
            k = ([k] + Usage.alternatives(k)).first { OpenModels.available($0) && !Usage.shared.isTight($0) && !AgentHealth.unavailable($0)
                && ($0 != .ollama || LocalFirst.shared.useLocal)
                && !Self.isBroken($0) && ($0 != k || (!hardBlocked && !broken)) }
                ?? AgentKind.coders.first { OpenModels.available($0) && !Usage.isPaused($0) && !AgentHealth.needsLogin($0) } ?? .claude
        }
        if k != wanted {
            let why = Usage.isPaused(wanted) ? L("von dir pausiert") : hardBlocked ? L("im Limit") : AgentHealth.unavailable(wanted) ? L("nicht angemeldet") : (!OpenModels.available(wanted) || broken) ? L("nicht verfügbar") : String(format: L("fast am Limit (%d %%)"), Int(Usage.shared.cachedPressure(wanted) * 100))
            p.messages.append(StewardMessage(role: "status", text: "⇄ " + String(format: L("%@ ist %@ – diese Aufgabe übernimmt %@: %@"), wanted.title, why, k.title, t.title)))
        }
        let commands = p.setup.map { s in ["test", "typecheck", "lint", "build"].compactMap { c in s.commands[c].map { "\(c): \($0)" } }.joined(separator: " · ") } ?? ""
        var prompt = """
        \(t.title)

        \(t.detail)

        ---
        \(L("Du arbeitest als Helfer des Projekt-Betreuers von")) \(p.name). \(L("Ziel des Projekts")): \(p.goal.isEmpty ? "–" : p.goal)
        \(L("Erledige genau diese Aufgabe, vollständig und ohne Rückfragen; triff sinnvolle Annahmen."))
        \(commands.isEmpty ? "" : L("Prüfe am Ende mit") + " " + commands + " – " + L("aber nur die von deiner Änderung betroffenen Testdateien (z. B. `npx vitest run <datei>`), nie die komplette Test-Suite und keine Prüfungen parallel: die volle Prüfkette läuft danach automatisch in der CI. Das gilt auch, wenn Projektregeln eine volle Prüfkette verlangen.") + ".")
        \(L("Nichts deployen, nichts veröffentlichen, keine Nachrichten an Kunden. Was offen bleibt, schreib am Ende unter „Offen:“."))
        \(L("Du arbeitest unbeaufsichtigt: Nutze nur Werkzeuge, die die Aufgabe wirklich braucht. Wird eine Freigabe nicht erteilt, arbeite ohne diesen Schritt weiter und nenne ihn unter „Offen:“. Seiten werden nach deinem Lauf automatisch in Desktop- und Handybreite aufgenommen und geprüft – dafür brauchst du keinen Browser zu steuern."))
        """
        if let b = t.prBranch {
            // Die Arbeitskopie steht schon auf dem PR-Branch (Salenta Code holt ihn vorher) – Agents in einer Sandbox
            // haben oft kein Netz und könnten ihn selbst gar nicht holen.
            prompt += "\n\n" + String(format: L("Wichtig: Du korrigierst den bestehenden Pull Request auf Branch „%@“. Deine Arbeitskopie steht schon auf dem aktuellen Stand dieses Branches – nichts holen, nichts zurücksetzen, nicht pushen. Nur beheben; Commit und Upload übernimmt der Betreuer."), b)
        }
        // Ausgewählte Erweiterungen: Plugins und Skills kennt nur Claude Code, MCP-Server und CLIs alle Agents
        let picked = (t.exts ?? []).compactMap { ExtensionCatalog.find($0) }
        let ext = (p.chosenExtensions + picked.filter { e in !p.chosenExtensions.contains(e) })
            .filter { e in !e.howTo.isEmpty && ExtensionStore.shared.isInstalled(e)
                && e.usable(claudeBased: k.harness == .claude) && (k == .claude || !["junie", "claude", "security"].contains(where: { e.id.contains($0) })) }
        if let sk = t.skills, !sk.isEmpty {
            prompt += "\n\n" + L("Nutze diese Skills:") + " " + sk.map { "/" + $0 }.joined(separator: " ")
            if sk.count > 1 { prompt += "\n" + L("Kombiniere sie: Wende jeden in dem Teil der Arbeit an, zu dem er passt.") }
        }
        if !ext.isEmpty { prompt += "\n\n" + L("Nutze dafür:") + "\n" + ext.map { "- " + $0.howTo }.joined(separator: "\n") }
        var model = t.model.isEmpty ? nil : t.model
        if let m = model, !ModelCatalog.fits(m, k) || !ModelCatalog.listed(m, k) { model = nil }   // nach einem Agent-Wechsel: dessen eigenes Standardmodell
        // kleine Aufgaben lokal (spart Kosten) – wenn ein lokales Modell da ist
        if LocalFirst.shared.forSmall, LocalFirst.shared.ready, ext.isEmpty, !Energy.saving, let m = LocalFirst.shared.model,
           LocalFirst.shared.localMisfit(AIRouteDecision(target: .claude, model: nil, effort: nil, directory: p.id, skills: [], reason: ""),
                                         text: t.title + " " + t.detail) == nil {
            k = .ollama; model = m
        }
        // Codex denkt sonst mit der höchsten Stufe aus deiner Konfiguration – für Helfer reicht „medium“ (viel weniger Tokens),
        // nur dringende/harte Aufgaben (Priorität 1) bekommen „high“.
        let effort: String? = (k == .codex || k == .claude) ? (t.effort ?? "medium") : nil
        // Mit GitHub: frisch vom Ziel-Branch auf GitHub aufsetzen (Korrekturen: vom PR-Branch) – nie lokale, nicht hochgeladene Commits mitnehmen
        let baseRef: String? = t.prBranch ?? (p.viaPR ? (p.prBase ?? p.setup?.defaultBranch) : nil)
        // PR-Korrektur: Ziel-Branch vorher einmischen, damit Konflikte wirklich gelöst werden (der Helfer kann ihn ohne Netz nicht holen)
        let mergeIn: String? = t.prBranch != nil ? (p.prBase ?? p.setup?.defaultBranch ?? "main") : nil
        let s = agents.start(k, in: p.id, prompt: prompt, mode: .autonom, label: "🧭 " + t.title, model: model, effort: effort, baseRef: baseRef, mergeIn: mergeIn)
        t.state = .running
        t.started = Date()
        t.missionID = s.id.uuidString
        t.agent = k.rawValue
        t.model = model ?? ""          // was wirklich läuft – nicht das ursprünglich geplante Modell eines anderen Agents
        p.tasks[i] = t
        p.messages.append(StewardMessage(role: "status", text: "▶︎ " + String(format: L("Gestartet: %@ · %@"), t.title, k.title + (model.map { " " + $0 } ?? ""))))
        p.runs[p.today, default: 0] += 1
        p.runs = p.runs.filter { $0.key >= DateCoding.day(Date().addingTimeInterval(-7 * 86400)) }
    }

    /// Laufende Aufgaben auswerten (inkl. Prüfschleife und Korrekturrunde).
    private func evaluate(_ id: String) {
        guard let p = project(id) else { return }
        // Zeitlimit: hängt ein Helfer (z. B. wartet endlos), wird er gestoppt statt stundenlang Tokens und Strom zu verbrauchen
        let limit = Double(UserDefaults.standard.object(forKey: "steward.maxMinutes") as? Int ?? 90) * 60
        for t in p.tasks where t.state == .running {
            if let st = t.started, Date().timeIntervalSince(st) > limit, let mid = t.missionID,
               let s = agents?.sessions.first(where: { $0.id.uuidString == mid && $0.running }) {
                agents?.close(s.id)
                say(id, "status", "⏱ " + String(format: L("Gestoppt nach %d Minuten (hing fest): "), Int(limit / 60)) + t.title)
            }
        }
        // Fertige, aber nie geprüfte Ergebnisse (Neustart während des Laufs) wieder aufnehmen: Prüfung nachholen, dann liefern
        let unchecked = p.tasks.filter { t in
            guard t.state == .review, t.pr == nil, let mid = t.missionID, let rec = MissionStore.shared.mission(mid) else { return false }
            return rec.worktree != nil && rec.verify == nil
        }.map(\.id)
        if !unchecked.isEmpty {
            update(id) { q in for i in q.tasks.indices where unchecked.contains(q.tasks[i].id) { q.tasks[i].state = .running } }
        }
        // Geprüft und grün, aber noch nicht übernommen (z. B. Konflikt beim ersten Versuch): Bei „Grünes selbst übernehmen“
        // bleibt das nicht liegen – einmal je App-Start wird es noch einmal versucht (inkl. Zusammenführen durch den Helfer).
        let unmerged = p.tasks.filter { t in
            guard p.trust >= 2, !p.viaPR, t.state == .review, t.pr == nil, (t.prRetry ?? 0) < 2, !mergeRetried.contains(t.id),
                  let mid = t.missionID, let rec = MissionStore.shared.mission(mid) else { return false }
            return rec.worktree != nil && rec.verify?.passed == true
        }.map(\.id)
        if !unmerged.isEmpty {
            mergeRetried.formUnion(unmerged)
            update(id) { q in for i in q.tasks.indices where unmerged.contains(q.tasks[i].id) { q.tasks[i].state = .running } }
        }
        for t in (project(id)?.tasks ?? []) where t.state == .running {
            guard let r = Self.outcome(t, agents: agents) else { continue }
            var merged = false
            // Schon als PR geliefert (keine Korrektur)? Nie ein zweites Mal liefern oder lokal übernehmen – der PR ist das Ergebnis.
            let delivered = t.pr != nil && t.prBranch == nil
            if r.state == .review, !delivered, p.viaPR, let mid = r.missionID, let rec = MissionStore.shared.mission(mid), let wt = rec.worktree,
               rec.verify?.passed == true, p.trust >= 2 || t.prBranch != nil {
                // GitHub: grünes Ergebnis als Pull Request (oder Korrektur auf den bestehenden PR-Branch) – gemergt wird nach grüner CI.
                // Anmeldung von gh noch nicht geprüft? Dann warten – nie am PR-Weg vorbei lokal übernehmen.
                if GH.state == .unknown { continue }
                deliverPR(id, task: t, mid: mid, wt: wt)
                continue
            }
            if r.state == .review, p.hasGitHub, (p.github ?? true), GH.state == .no, p.trust >= 2 {
                // GitHub-Projekt, aber gh ist nicht angemeldet: Ergebnis bleibt zur Ansicht liegen statt still lokal gemergt zu werden
                update(id) { q in
                    if let i = q.tasks.firstIndex(where: { $0.id == t.id }), q.tasks[i].note?.hasPrefix("⚠️") != true {
                        q.tasks[i].note = "⚠️ " + L("GitHub CLI nicht angemeldet (gh auth login) – Ergebnis wartet, statt am Pull Request vorbei übernommen zu werden")
                    }
                }
                continue
            }
            if r.state == .review, !delivered, p.trust >= 2, let mid = r.missionID, let rec = MissionStore.shared.mission(mid), let wt = rec.worktree,
               rec.verify?.passed == true {
                let (ok, msg) = Worktrees.merge(wt, message: t.title)
                if ok {
                    merged = true
                    finishMission(mid, outcome: "merged")
                    say(id, "system", "✓ " + L("Übernommen (grün): ") + t.title)
                } else if msg == Worktrees.conflictMessage, (t.prRetry ?? 0) < 2, let agents = self.agents, let hub = self.hub {
                    // Inzwischen wurde anderes übernommen (z. B. ein parallel laufender Helfer hat dieselbe Datei geändert).
                    // Statt auf dich zu warten: den neuen Stand in die Arbeitskopie einmischen und den Helfer zusammenführen lassen –
                    // danach läuft die Prüfung neu und es wird übernommen.
                    let dir = Worktrees.top(wt)
                    let clean = Git.run(Git.identity(dir) + ["merge", "--no-edit", wt.baseBranch], in: dir, timeout: 60).code == 0
                    let fix = clean
                        ? L("Inzwischen wurden andere Änderungen in den Haupt-Branch übernommen. Der neue Stand ist schon in deine Arbeitskopie eingemischt (ohne Konflikte). Prüfe, dass alles zusammen funktioniert: Lass die Tests laufen und behebe nur, was durch das Zusammenführen kaputtging.")
                        : L("Inzwischen wurden andere Änderungen in den Haupt-Branch übernommen, die mit deinen kollidieren. Der neue Stand ist in deine Arbeitskopie eingemischt, die Konfliktstellen sind markiert (<<<<<<<, =======, >>>>>>>). Löse jeden Konflikt so, dass beide Änderungen erhalten bleiben, entferne die Markierungen und lass die Tests laufen. Ändere sonst nichts.")
                    update(id) { p in
                        if let i = p.tasks.firstIndex(where: { $0.id == t.id }) {
                            p.tasks[i].prRetry = (p.tasks[i].prRetry ?? 0) + 1
                            p.tasks[i].note = "🔀 " + L("Arbeitet den neuen Stand ein – andere Änderungen wurden inzwischen übernommen")
                        }
                    }
                    Handoff.continueMission(rec, message: fix, target: rec.agent, agents: agents, hub: hub, note: L("Neuen Stand einarbeiten")) { s in
                        self.update(id) { p in
                            if let i = p.tasks.firstIndex(where: { $0.id == t.id }) {
                                p.tasks[i].state = .running; p.tasks[i].missionID = s.id.uuidString; p.tasks[i].started = Date()
                            }
                        }
                    }
                    say(id, "status", "🔀 " + L("Konflikt mit neueren Änderungen – der Helfer arbeitet den neuen Stand ein: ") + t.title)
                    continue
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
            if !merged {
                let line: String = r.state == .review ? "✓ " + L("Fertig und geprüft: ") + t.title
                    : r.state == .red ? "✗ " + L("Rot: ") + t.title + (r.note.map { " – " + String($0.prefix(140)) } ?? "")
                    : "✓ " + L("Erledigt: ") + t.title
                say(id, "status", line)
            }
            // Der Agent, der wirklich lief (nach Limit-/Verfügbarkeits-Wechsel kann das ein anderer sein als geplant)
            let ran = r.missionID.flatMap { MissionStore.shared.mission($0) }.flatMap { AgentKind(rawValue: $0.agent) } ?? AgentKind(rawValue: t.agent)
            if r.state != .red, let k = ran { Self.clearBroken(k) }
            if r.state == .red, let st = t.started, Date().timeIntervalSince(st) < 120, let k = ran, k != .claude {
                Self.markBroken(k)
                say(id, "status", "⚠︎ " + String(format: L("%@ ist sofort gescheitert – wird 6 Stunden nicht eingeplant."), k.title))
            }
            if r.state == .red, t.prBranch != nil {
                // Rote PR-Korrektur: der GitHub-Wächter versucht es noch einmal (höchstens 2 Runden) – der Planer darf das nicht einreihen
                update(id) { $0.lastPRScan = nil }
            } else if r.state == .red {
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

    func finishMission(_ mid: String, outcome: String) {
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
        // Von dir gestoppt: verworfen – nie prüfen, übernehmen oder hochladen
        if rec.outcome == "stopped" { return (.dropped, L("von dir gestoppt"), cur) }
        if agents?.sessions.contains(where: { $0.id.uuidString == cur && $0.running }) == true { return nil }
        // Die Arbeitskopie gibt es nicht mehr (aufgeräumt, weil das Ergebnis längst als Pull Request vorliegt)? Dann ist nichts mehr
        // zu prüfen oder zu liefern – sonst hinge die Aufgabe stundenlang als „läuft“ fest und belegte einen Platz.
        if let wt = rec.worktree, !FileManager.default.fileExists(atPath: Worktrees.top(wt)) {
            if let n = t.pr, t.prBranch == nil { return (.review, String(format: L("PR #%d offen – wird nach grüner CI und Review gemergt"), n), cur) }
            return (.red, L("Arbeitskopie fehlt – bitte neu starten"), cur)
        }
        guard let ended = rec.ended else {
            // Sitzung weg, aber nie beendet (App-Neustart): nach 3 h als rot werten
            return Date().timeIntervalSince(rec.started) > 3 * 3600 ? (.red, L("abgebrochen"), cur) : nil
        }
        if rec.worktree != nil {
            if rec.verify == nil && Date().timeIntervalSince(ended) < 90 { return nil }
            // Prüfung nie gelaufen (z. B. Salenta Code wurde während des Laufs neu gestartet) → jetzt nachholen statt ungeprüft liegen zu lassen
            if rec.verify == nil, rec.ok != false { DispatchQueue.main.async { Verifier.run(cur) }; return nil }
            if let v = rec.verify, v.finished == nil { return nil }
            // Rot nach der Prüfung: Die Autokorrektur kommt gleich – bis zu zwei Runden (die zweite macht ein anderer Agent).
            // Vorher nicht als rot werten, sonst plant der Betreuer neu, während die zweite Runde noch läuft.
            if rec.verify?.passed == false && Verifier.autoFix && (rec.fixRound ?? 0) < 2 && Date().timeIntervalSince(ended) < 240 { return nil }
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
        // GitHub-Wächter: CI auf dem Haupt-Branch und Release-Workflows (alle 15 Minuten, nach einem Merge sofort)
        if p.watchCI, p.setup?.remote?.contains("github") == true, isGitHubWatcher(id), (p.lastCI.map { Date().timeIntervalSince($0) > (Energy.saving ? 1800 : 900) } ?? true) {
            update(id) { $0.lastCI = Date() }
            let branch = p.setup?.defaultBranch ?? "main"
            DispatchQueue.global(qos: .utility).async {
                let r = Proc.zsh("gh run list --limit 25 --json conclusion,status,displayTitle,url,workflowName,headBranch,event", in: id, timeout: 40)
                guard r.code == 0, let a = r.out.firstIndex(of: "["), let d = String(r.out[a...]).data(using: .utf8),
                      let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return }
                // Haupt-Branch und Veröffentlichungen (Release, Tags wie v1.2.3): je Workflow der neueste Lauf
                func relevant(_ run: [String: Any]) -> Bool {
                    let hb = run["headBranch"] as? String ?? "", ev = run["event"] as? String ?? ""
                    return hb == branch || ev == "release" || ev == "workflow_dispatch" && hb == branch
                        || (hb.hasPrefix("v") && hb.dropFirst().first?.isNumber == true)
                }
                var latest: [String: [String: Any]] = [:]
                for run in arr where relevant(run) {
                    let w = run["workflowName"] as? String ?? "CI"
                    if latest[w] == nil { latest[w] = run }
                }
                let failed = latest.values.filter { ($0["conclusion"] as? String) == "failure" && $0["url"] is String }
                guard !failed.isEmpty else { return }
                DispatchQueue.main.async {
                    for run in failed {
                        let url = run["url"] as! String
                        let hb = run["headBranch"] as? String ?? branch
                        let release = hb != branch || (run["event"] as? String) == "release"
                        let title = "\(run["workflowName"] as? String ?? "CI"): \(run["displayTitle"] as? String ?? "")"
                        guard let q = self.project(id), !q.tasks.contains(where: { $0.ref == url }) else { continue }
                        self.update(id) { p in
                            p.tasks.append(StewardTask(title: (release ? L("Veröffentlichung ist rot – reparieren: ") : L("CI ist rot – reparieren: ")) + title,
                                                       detail: (release ? L("Der Release-Lauf für") + " \(hb) " : L("Der letzte CI-Lauf auf") + " \(branch) ") + L("ist fehlgeschlagen") + " (\(url)). "
                                                           + L("Lies die Logs mit `gh run view --log-failed`, finde die Ursache und behebe sie. Fertig, wenn die betroffenen Checks lokal grün sind.")
                                                           + (release ? " " + L("Nichts selbst veröffentlichen – nur die Ursache im Code beheben.") : ""),
                                                       state: p.trust == 0 ? .idea : .queued, source: "ci", priority: 1, ref: url))
                        }
                        self.say(id, "system", "🔴 " + (release ? L("Veröffentlichung rot: ") : L("CI ist rot: ")) + title)
                        ModStore.shared.fire(.ciFailed, rec: nil, result: title + " – " + url, directory: id)
                        NotifyCenter.shared.post(.ciRed, title: "🔴 " + (self.project(id)?.name ?? "") + ": " + title, body: L("Der GitHub-Wächter hat eine Korrektur eingereiht."), route: .page("steward:" + id))
                    }
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
        // Das Ergebnis liegt schon als offener Pull Request vor: „Übernehmen“ heißt dann, genau diesen PR zu mergen –
        // nicht die (längst aufgeräumte) Arbeitskopie noch einmal hochzuladen oder die Aufgabe bloß abzuhaken.
        if accept, let p = project(id), let t = p.tasks.first(where: { $0.id == task }), let n = t.pr,
           p.prs?.contains(where: { $0.number == n }) == true {
            completion(String(format: L("Pull Request #%d wird gemergt …"), n))
            mergeNow(id, n) { msg in
                self.say(id, "system", msg)
                completion(msg)
            }
            return
        }
        guard let t = project(id)?.tasks.first(where: { $0.id == task }), let mid = t.missionID,
              let rec = MissionStore.shared.mission(mid), let wt = rec.worktree else {
            update(id) { p in if let i = p.tasks.firstIndex(where: { $0.id == task }) { p.tasks[i].state = accept ? .done : .dropped } }
            completion(accept ? L("Erledigt") : L("Verworfen")); return
        }
        if accept, project(id)?.viaPR == true { deliverPR(id, task: t, mid: mid, wt: wt); completion(L("Pull Request wird erstellt …")); return }
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
                if let i = p.tasks.firstIndex(where: { $0.id == task }) { p.tasks[i].state = .running; p.tasks[i].missionID = s.id.uuidString; p.tasks[i].started = Date() }
            }
        }
    }
}
