import AgenticOSKit
import AppKit
import SwiftUI

// Mods: kleine Automatiken, die bei Ereignissen von selbst loslaufen – z. B. nach dem Übernehmen den Changelog
// pflegen, Tests nachziehen, eine Sicherheitsprüfung machen oder abends einen Tagesbericht schreiben.
// Jeder Mod ist eine kleine JSON-Datei in data/mods/ – fertige aus der Galerie, eigene per Beschreibung von der KI.

struct Mod: Codable, Identifiable, Hashable {
    enum Event: String, Codable, CaseIterable {
        case missionFinished, verifyPassed, verifyFailed, merged, prCreated, daily, weekly, ciFailed, customerBug, nightDone
        var title: String {
            switch self {
            case .missionFinished: L("Auftrag fertig")
            case .verifyPassed: L("Prüfung grün")
            case .verifyFailed: L("Prüfung rot")
            case .merged: L("Änderungen übernommen")
            case .prCreated: L("Pull Request erstellt")
            case .daily: L("Täglich")
            case .weekly: L("Montags")
            case .ciFailed: L("CI auf GitHub rot")
            case .customerBug: L("Kunde meldet Fehler (Salenta)")
            case .nightDone: L("Nachtschicht fertig")
            }
        }
    }
    enum Action: String, Codable { case agent, shell, notify, webhook }

    var id: String
    var name: String
    var description: String
    var event: Event
    var action: Action
    var agent: String? = nil        // claude, codex, os …
    var model: String? = nil
    var prompt: String? = nil       // für action=agent – Platzhalter {title} {request} {dir} {repo} {branch} {agent} {result} {date}
    var command: String? = nil      // für action=shell
    var url: String? = nil          // für action=webhook
    var time: String? = nil         // für event=daily, "18:00"
    var ask: Bool? = nil            // vorher fragen
    var worktree: Bool? = nil       // Agent in eigener Arbeitskopie (Standard: ja)
    var enabled: Bool = true
    var project: String? = nil      // nur für dieses Repo (Name enthält …)
    var onlyIf: String? = nil       // nur, wenn der Auftragstitel das enthält
}

enum ModGallery {
    static let all: [Mod] = [
        Mod(id: "changelog", name: "Changelog pflegen", description: "Nach dem Übernehmen schreibt ein Agent einen kurzen Eintrag in CHANGELOG.md – du siehst ihn als Änderung zum Übernehmen.",
            event: .merged, action: .agent, agent: "claude", model: "haiku",
            prompt: "Ergänze in CHANGELOG.md (anlegen, falls es fehlt, Format „Keep a Changelog“) unter „Unreleased“ einen kurzen, verständlichen Eintrag für diese übernommene Änderung: „{title}“. Ursprünglicher Auftrag: {request}. Sonst nichts ändern."),
        Mod(id: "tests", name: "Tests nachziehen", description: "Prüft nach dem Übernehmen, ob die Änderung durch Tests abgedeckt ist, und schreibt fehlende Tests (Codex als zweite Meinung).",
            event: .merged, action: .agent, agent: "codex",
            prompt: "Die Änderung „{title}“ wurde gerade übernommen ({request}). Prüfe, ob sie durch automatische Tests abgedeckt ist. Wenn nicht, schreibe wenige, sinnvolle Tests im Stil des Projekts und führe sie aus. Ändere keinen Produktionscode."),
        Mod(id: "security", name: "Sicherheits-Check nach dem Übernehmen", description: "Lässt Claude Code mit /security-review über die übernommene Änderung schauen und meldet nur echte Probleme.",
            event: .merged, action: .agent, agent: "claude", model: "sonnet",
            prompt: "Führe /security-review für die zuletzt übernommene Änderung („{title}“) aus. Melde nur echte Sicherheitsprobleme mit Datei und Zeile. Ändere nichts, wenn alles in Ordnung ist."),
        Mod(id: "audit", name: "Abhängigkeiten prüfen", description: "Nach dem Übernehmen: npm audit bzw. pip-audit – bei kritischen Lücken bekommst du eine Meldung.",
            event: .merged, action: .shell,
            command: "if [ -f package.json ]; then npm audit --omit=dev --audit-level=high; elif [ -f requirements.txt ]; then (command -v pip-audit >/dev/null && pip-audit -r requirements.txt) || echo 'pip-audit nicht installiert'; else echo 'Keine Paketliste gefunden'; fi"),
        Mod(id: "docs", name: "Doku aktuell halten", description: "Aktualisiert README und CLAUDE.md, wenn sich durch die Änderung etwas Wichtiges geändert hat (als Änderung zum Prüfen).",
            event: .merged, action: .agent, agent: "claude", model: "haiku",
            prompt: "Die Änderung „{title}“ wurde übernommen. Passe README.md und CLAUDE.md nur an, wenn sich dadurch Bedienung, Setup, Befehle oder Projektregeln geändert haben. Wenn nicht nötig: nichts ändern und kurz sagen warum."),
        Mod(id: "deploy", name: "Nach dem Übernehmen deployen", description: "Führt den Deploy-Befehl aus .salenta-os.json („deploy“) aus – fragt jedes Mal vorher.",
            event: .merged, action: .shell, command: "python3 -c \"import json;c=json.load(open('.salenta-os.json'));import subprocess,sys;sys.exit(subprocess.call(c['deploy'],shell=True))\"", ask: true),
        Mod(id: "webhook", name: "Meldung an Slack/Discord", description: "Schickt fertige Aufträge und Prüfergebnisse an einen Webhook (Slack, Discord, Teams, n8n).",
            event: .verifyPassed, action: .webhook, url: ""),
        Mod(id: "daily", name: "Tagesbericht", description: "Jeden Abend fasst der OS-Agent zusammen, was erledigt wurde, was offen ist und was rot ist – ins Journal (Obsidian).",
            event: .daily, action: .agent, agent: "os", model: "haiku",
            prompt: "Fasse für heute ({date}) zusammen, was in Salenta Code passiert ist: erledigte und offene Aufträge, übernommene Änderungen, rote Prüfungen, offene Freigaben. Kurz, mit den wichtigsten nächsten Schritten. Schreibe es mit obsidian_schreiben (modus journal), falls ein Vault verbunden ist.",
            time: "18:00", worktree: false),
        Mod(id: "weekly-deps", name: "Abhängigkeiten wöchentlich auffrischen", description: "Montags hebt Codex kleine Updates (Patch/Minor) an, führt die Tests aus – du bekommst es als Änderung zum Prüfen.",
            event: .weekly, action: .agent, agent: "codex",
            prompt: "Aktualisiere in {repo} nur Patch- und Minor-Versionen der Abhängigkeiten (keine Major-Sprünge), führe Build und Tests aus und behebe kleine Brüche. Wenn etwas Größeres nötig wäre: nichts ändern und kurz begründen.",
            time: "09:00"),
        Mod(id: "weekly-deadcode", name: "Aufräum-Bericht der Woche", description: "Montags sucht ein Agent ungenutzten Code, doppelte Logik und veraltete TODOs – nur ein Bericht, er ändert nichts.",
            event: .weekly, action: .agent, agent: "claude", model: "haiku",
            prompt: "Suche in {repo} nach ungenutztem Code, doppelter Logik und veralteten TODOs. Ändere nichts. Liste die 10 lohnendsten Aufräum-Punkte mit Datei und kurzem Grund.",
            time: "08:30"),
        Mod(id: "release-notes", name: "Wochen-Notizen ins Journal", description: "Montags schreibt der OS-Agent verständliche Release-Notes der letzten Woche ins Obsidian-Journal – gut für Kunden-Updates.",
            event: .weekly, action: .agent, agent: "os", model: "haiku",
            prompt: "Schreibe verständliche Release-Notes (für Kunden, ohne Technik-Sprech) zu allen in der letzten Woche übernommenen Änderungen. Speichere sie mit obsidian_schreiben (modus journal).",
            time: "08:00", worktree: false),
        Mod(id: "a11y", name: "Barrierefreiheit prüfen", description: "Wenn sich Oberflächen geändert haben: ein Agent prüft Kontraste, Beschriftungen und Tastaturbedienung – als Änderung zum Prüfen.",
            event: .merged, action: .agent, agent: "claude", model: "sonnet",
            prompt: "Prüfe die gerade übernommene Änderung „{title}“ auf Barrierefreiheit (Kontraste, alt-Texte, Labels, Tastatur, Fokus). Behebe nur klare Probleme in den geänderten Oberflächen. Wenn keine Oberfläche betroffen ist: nichts ändern.",
            onlyIf: nil),
        Mod(id: "ci-fix", name: "Rote CI sofort reparieren", description: "Wird die CI auf GitHub rot, startet ein Agent: Logs lesen, Ursache finden, beheben – als Änderung zum Prüfen.",
            event: .ciFailed, action: .agent, agent: "claude", model: "sonnet",
            prompt: "Die CI von {repo} ist rot ({result}). Lies die Logs mit `gh run view --log-failed`, finde die Ursache und behebe sie. Fertig, wenn die betroffenen Checks lokal grün sind."),
        Mod(id: "customer-bug", name: "Kunden-Fehler sofort anschauen", description: "Meldet ein Kunde in Salenta einen Fehler, prüft ein Agent sofort, ob er im Projekt steckt – fragt vorher.",
            event: .customerBug, action: .agent, agent: "claude", model: "sonnet",
            prompt: "Ein Kunde meldet: {result}\nPrüfe in {repo}, ob das ein Fehler im Projekt ist. Wenn ja: beheben und kurz erklären, was es war. Wenn nein: begründen.",
            ask: true),
        Mod(id: "night-summary", name: "Nachtschicht-Bericht aufs Handy", description: "Wenn die Nachtschicht fertig ist, kommt eine kurze Zusammenfassung als Mitteilung.",
            event: .nightDone, action: .notify, prompt: "🌙 {result}"),
    ]
}

final class ModStore: ObservableObject {
    static let shared = ModStore()
    @Published private(set) var mods: [Mod] = []
    @Published private(set) var log: [String] = []
    weak var agents: AgentManager?
    weak var hub: MCPHub?
    weak var app: AppModel?
    private var timer: Timer?
    private var dir: URL {
        let d = Paths.data.appendingPathComponent("mods", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    init() {
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.tickDaily() }
    }

    func attach(agents: AgentManager, hub: MCPHub, app: AppModel) {
        self.agents = agents; self.hub = hub; self.app = app
    }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        mods = files.filter { $0.pathExtension == "json" }.compactMap { try? JSONDecoder().decode(Mod.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name < $1.name }
        if let t = try? String(contentsOf: Paths.root.appendingPathComponent("logs/mods.log"), encoding: .utf8) {
            log = Array(t.split(separator: "\n").suffix(40).reversed().map(String.init))
        }
    }

    func save(_ m: Mod) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        if let d = try? enc.encode(m) { try? d.write(to: dir.appendingPathComponent("\(m.id).json"), options: .atomic) }
        load()
    }

    func remove(_ m: Mod) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(m.id).json"))
        load()
    }

    func isInstalled(_ id: String) -> Bool { mods.contains { $0.id == id } }

    private func write(_ line: String) {
        let url = Paths.root.appendingPathComponent("logs/mods.log")
        let entry = "\(Date().formatted(date: .numeric, time: .shortened))  \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(entry.utf8)); try? h.close() }
        else { try? entry.write(to: url, atomically: true, encoding: .utf8) }
        DispatchQueue.main.async { self.log.insert(entry.trimmingCharacters(in: .newlines), at: 0); if self.log.count > 40 { self.log.removeLast() } }
    }

    // MARK: Auslösen

    /// Ein Ereignis ist passiert – alle passenden, eingeschalteten Mods laufen los.
    func fire(_ event: Mod.Event, rec: MissionRecord?, result: String = "", directory: String? = nil) {
        for m in mods where m.enabled && m.event == event {
            // Mods lösen sich nicht gegenseitig in Endlosschleife aus
            if let r = rec, r.routeReason?.hasPrefix("Mod:") == true { continue }
            // Filter: nur für ein bestimmtes Projekt / nur bei passendem Titel
            if let p = m.project, !p.isEmpty {
                let dir = directory ?? rec.map { $0.worktree?.base ?? $0.directory } ?? ""
                guard (dir as NSString).lastPathComponent.localizedCaseInsensitiveContains(p) else { continue }
            }
            if let w = m.onlyIf, !w.isEmpty, !(rec?.title ?? result).localizedCaseInsensitiveContains(w) { continue }
            run(m, rec: rec, result: result, directory: directory)
        }
    }

    private func fill(_ text: String, rec: MissionRecord?, result: String, dir forced: String? = nil) -> String {
        let dir = forced ?? rec.map { $0.worktree?.base ?? $0.directory } ?? Paths.root.path
        var t = text
        let vars: [String: String] = [
            "title": rec?.title ?? "", "request": String((rec?.request ?? "").prefix(1500)), "dir": dir,
            "repo": (dir as NSString).lastPathComponent, "branch": rec?.worktree?.branch ?? "", "agent": rec?.agentTitle ?? "",
            "result": String(result.prefix(1500)), "date": Date().formatted(date: .complete, time: .omitted),
        ]
        for (k, v) in vars { t = t.replacingOccurrences(of: "{\(k)}", with: v) }
        return t
    }

    func run(_ m: Mod, rec: MissionRecord?, result: String = "", directory: String? = nil) {
        if m.ask == true {
            let a = NSAlert()
            a.messageText = L("Mod „\(m.name)“ ausführen?")
            a.informativeText = m.description + (rec.map { "\n\n" + L("Auftrag: ") + $0.title } ?? "")
            a.addButton(withTitle: L("Ausführen")); a.addButton(withTitle: L("Überspringen"))
            guard a.runModal() == .alertFirstButtonReturn else { write("⏭ \(m.name) übersprungen"); return }
        }
        let dir = directory ?? rec.map { $0.worktree?.base ?? $0.directory } ?? Paths.root.path
        switch m.action {
        case .agent:
            guard let agents, let hub, let prompt = m.prompt else { return }
            let text = fill(prompt, rec: rec, result: result, dir: dir)
            // hängt in der Seitenleiste unter dem Auftrag, der ihn ausgelöst hat – deshalb ohne dessen Titel
            let label = "Mod: \(m.name)"
            let parentID = rec.map { MissionStore.shared.rootID(of: $0.id) }
            write("▶ \(m.name)" + (rec.map { " · \($0.title)" } ?? ""))
            if m.agent == "os" {
                OSAgent.start(text, agents: agents, hub: hub, taskID: nil, label: label, model: m.model) { s in
                    MissionStore.shared.setReason(s.id.uuidString, "Mod: \(m.name)")
                    if let p = parentID { MissionStore.shared.link(s.id.uuidString, parent: p, delegated: true) }
                }
            } else {
                let kind = AgentKind(rawValue: m.agent ?? "claude") ?? .claude
                let s = agents.start(kind, in: dir, prompt: text, taskID: nil, mode: .autonom, label: label,
                                     model: m.model, worktree: m.worktree ?? true)
                MissionStore.shared.setReason(s.id.uuidString, "Mod: \(m.name)")
                if let p = parentID { MissionStore.shared.link(s.id.uuidString, parent: p, delegated: true) }
            }
        case .shell:
            guard let cmd = m.command else { return }
            write("▶ \(m.name)")
            DispatchQueue.global(qos: .utility).async {
                let r = Proc.zsh(self.fill(cmd, rec: rec, result: result, dir: dir), in: dir, timeout: 900)
                let tail = String(r.out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400))
                self.write((r.code == 0 ? "✓ " : "✗ ") + "\(m.name): " + tail.replacingOccurrences(of: "\n", with: " ⏎ "))
                if r.code != 0 {
                    DispatchQueue.main.async { self.app?.show("✗ Mod \(m.name): " + String(tail.prefix(120))) }
                    Notifier.push("Mod: \(m.name)", tail, priority: 4, tags: "warning")
                }
            }
        case .notify:
            let t = fill(m.prompt ?? "{title}", rec: rec, result: result, dir: dir)
            app?.show(t)
            Notifier.push(m.name, t)
        case .webhook:
            guard let u = m.url, let url = URL(string: u), !u.isEmpty else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let text = "\(m.event.title): \(rec?.title ?? "")" + (rec?.verify?.review.map { "\n" + $0.summary } ?? "")
            // Slack/Discord/Teams verstehen "text"/"content"
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "content": text, "event": m.event.rawValue,
                                                                        "title": rec?.title ?? "", "repo": (dir as NSString).lastPathComponent])
            URLSession.shared.dataTask(with: req).resume()
            write("↗ \(m.name): \(rec?.title ?? "")")
        }
    }

    /// Wann jeder tägliche/wöchentliche Mod zuletzt lief – gemerkt über Neustarts hinweg.
    private var lastDaily: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "mods.lastDaily") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "mods.lastDaily") }
    }
    /// „9:00“ → „09:00“, damit der Vergleich mit der Uhrzeit stimmt
    static func hhmm(_ t: String) -> String {
        let p = t.split(separator: ":").map { String($0) }
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return "18:00" }
        return String(format: "%02d:%02d", h, m)
    }
    private func tickDaily() {
        let now = Date()
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let hm = f.string(from: now)
        let day = DateCoding.day(now)
        let monday = Calendar.current.component(.weekday, from: now) == 2
        // Fällig ab der eingestellten Uhrzeit – war der Mac da gerade aus oder im Ruhezustand, läuft er beim nächsten Mal nach
        for m in mods where m.enabled && (m.event == .daily || (m.event == .weekly && monday)) && hm >= Self.hhmm(m.time ?? "18:00") && lastDaily[m.id] != day {
            lastDaily[m.id] = day
            if m.event == .weekly, m.agent != "os" {
                // wöchentliche Projekt-Mods laufen in jedem betreuten Projekt (sonst im zuletzt genutzten)
                let dirs = Steward.shared.projects.map(\.id)
                for d in dirs.isEmpty ? [agents?.directories.first].compactMap({ $0 }) : dirs {
                    if let p = m.project, !p.isEmpty, !(d as NSString).lastPathComponent.localizedCaseInsensitiveContains(p) { continue }
                    run(m, rec: nil, directory: d)
                }
            } else {
                run(m, rec: nil)
            }
        }
    }
}

// MARK: - Seite "Mods"

struct ModsView: View {
    @ObservedObject private var store = ModStore.shared
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var hub: MCPHub
    @EnvironmentObject private var app: AppModel
    @State private var idea = ""
    @State private var editing: Mod?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Grid.xl) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mods").font(.largeTitle.weight(.semibold))
                    Text("Kleine Automatiken, die bei Ereignissen von selbst loslaufen – nach dem Übernehmen, bei roter Prüfung, jeden Abend. Einschalten, fertig.")
                        .foregroundStyle(.secondary)
                }

                // Eigener Mod per Beschreibung
                VStack(alignment: .leading, spacing: Grid.s) {
                    Text("Eigenen Mod bauen lassen").font(.headline)
                    HStack {
                        TextField("z. B. „Wenn eine Prüfung rot ist, schick mir eine WhatsApp über Salenta“", text: $idea)
                            .textFieldStyle(.roundedBorder)
                        Button("Bauen") { build() }.buttonStyle(.borderedProminent).disabled(idea.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("Der OS-Agent schreibt dir daraus einen Mod (eine kleine JSON-Datei in data/mods/). Du siehst ihn danach hier und kannst ihn anpassen.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(Grid.m)
                .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))

                if !store.mods.isEmpty {
                    VStack(alignment: .leading, spacing: Grid.s) {
                        Text("Deine Mods").font(.title3.weight(.semibold))
                        ForEach(store.mods) { m in
                            HStack(alignment: .top) {
                                Toggle("", isOn: Binding(get: { m.enabled }, set: { var x = m; x.enabled = $0; store.save(x) })).toggleStyle(.switch).labelsHidden()
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.name).font(.callout.weight(.semibold))
                                    Text("\(m.event.title)\((m.event == .daily || m.event == .weekly) ? " " + (m.time ?? "18:00") : "") → \(actionTitle(m))").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Jetzt testen") { store.run(m, rec: MissionStore.shared.missions.last) }.controlSize(.small)
                                Button { editing = m } label: { Image(systemName: "pencil") }.buttonStyle(.plain).help(L("Mod bearbeiten"))
                                Button(role: .destructive) { store.remove(m) } label: { Image(systemName: "trash") }.buttonStyle(.plain).help(L("Mod löschen"))
                            }
                            .padding(Grid.s)
                            .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: Grid.s) {
                    Text("Galerie").font(.title3.weight(.semibold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: Grid.m)], spacing: Grid.m) {
                        ForEach(ModGallery.all) { m in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(m.name).font(.headline)
                                    Spacer()
                                    if store.isInstalled(m.id) {
                                        Label("aktiv", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                                    } else {
                                        Button("Hinzufügen") {
                                            if m.action == .webhook { editing = m } else { store.save(m) }
                                        }.buttonStyle(.borderedProminent).controlSize(.small)
                                    }
                                }
                                Text(m.description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                Text("\(m.event.title) → \(actionTitle(m))").font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(Grid.m)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
                        }
                    }
                }

                if !store.log.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Zuletzt gelaufen").font(.headline)
                        ForEach(store.log.prefix(15), id: \.self) { Text($0).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
            }
            .padding(Grid.xl)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Mods")
        .onAppear { store.load() }
        .sheet(item: $editing) { m in ModEditor(mod: m) }
    }

    private func actionTitle(_ m: Mod) -> String {
        switch m.action {
        case .agent: (m.agent == "os" ? "OS-Agent" : (AgentKind(rawValue: m.agent ?? "")?.title ?? "Agent")) + (m.model.map { " (\($0))" } ?? "")
        case .shell: L("Befehl")
        case .notify: L("Meldung")
        case .webhook: "Webhook"
        }
    }

    private func build() {
        let schema = """
        {"id":"kurzer-name","name":"Anzeigename","description":"Was der Mod tut (1 Satz)",
         "event":"missionFinished|verifyPassed|verifyFailed|merged|prCreated|daily","action":"agent|shell|notify|webhook",
         "agent":"claude|codex|os (bei action=agent; os = OS-Agent mit allen Integrationen wie Salenta/WhatsApp)","model":"haiku|sonnet|opus (optional)",
         "prompt":"Auftrag an den Agent, Platzhalter {title} {request} {dir} {repo} {branch} {agent} {result} {date}",
         "command":"Shell-Befehl (bei action=shell, läuft im Repo)","url":"Webhook-URL (bei action=webhook)",
         "time":"18:00 (bei event=daily)","ask":true,"worktree":true,"enabled":true}
        """
        let prompt = """
        Baue einen Salenta-Code-Mod nach dieser Beschreibung: „\(idea)“.
        Ein Mod ist eine JSON-Datei in \(Paths.data.appendingPathComponent("mods").path)/<id>.json mit diesem Schema:
        \(schema)
        Regeln: Nur die Felder, die gebraucht werden. Bei allem, was etwas verschickt, veröffentlicht, deployt oder löscht: "ask": true.
        Keine Passwörter oder Tokens in die Datei schreiben. Schreibe die Datei und sag in einem Satz, was der Mod tut.
        """
        OSAgent.start(prompt, agents: agents, hub: hub, taskID: nil, label: "Mod bauen: " + String(idea.prefix(60)), model: "sonnet") { s in
            app.page = .chat(s.id.uuidString)
        }
        idea = ""
    }
}

struct ModEditor: View {
    @State var mod: Mod
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            TextField("Name", text: $mod.name)
            TextField("Beschreibung", text: $mod.description)
            Picker("Wann", selection: $mod.event) { ForEach(Mod.Event.allCases, id: \.self) { Text($0.title).tag($0) } }
            if mod.event == .daily || mod.event == .weekly { TextField("Uhrzeit (HH:MM)", text: Binding(get: { mod.time ?? "18:00" }, set: { mod.time = $0 })) }
            TextField("Nur für Projekt (Name enthält, leer = alle)", text: Binding(get: { mod.project ?? "" }, set: { mod.project = $0.isEmpty ? nil : $0 }))
            TextField("Nur wenn der Titel enthält (leer = immer)", text: Binding(get: { mod.onlyIf ?? "" }, set: { mod.onlyIf = $0.isEmpty ? nil : $0 }))
            switch mod.action {
            case .agent:
                TextField("Agent (claude, codex, os …)", text: Binding(get: { mod.agent ?? "claude" }, set: { mod.agent = $0 }))
                TextField("Modell (optional)", text: Binding(get: { mod.model ?? "" }, set: { mod.model = $0.isEmpty ? nil : $0 }))
                TextField("Auftrag", text: Binding(get: { mod.prompt ?? "" }, set: { mod.prompt = $0 }), axis: .vertical).lineLimit(3...8)
            case .shell:
                TextField("Befehl", text: Binding(get: { mod.command ?? "" }, set: { mod.command = $0 }), axis: .vertical).lineLimit(2...6)
                    .font(.system(.body, design: .monospaced))
            case .webhook:
                TextField("Webhook-URL (Slack, Discord, Teams, n8n)", text: Binding(get: { mod.url ?? "" }, set: { mod.url = $0 }))
            case .notify:
                TextField("Text", text: Binding(get: { mod.prompt ?? "" }, set: { mod.prompt = $0 }))
            }
            Toggle("Vorher fragen", isOn: Binding(get: { mod.ask == true }, set: { mod.ask = $0 ? true : nil }))
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                Button("Speichern") { ModStore.shared.save(mod); dismiss() }.buttonStyle(.borderedProminent)
                    .disabled(mod.action == .webhook && (mod.url ?? "").isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 480)
    }
}
