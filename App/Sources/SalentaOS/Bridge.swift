import AgenticOSKit
import AppKit
import Foundation
import UserNotifications

/// Verbindet das OS mit seinem MCP-Server (bin/aos-mcp):
/// schreibt den Zustand nach data/status.json und führt Befehle aus data/commands.jsonl aus.
/// So können Claude Code, Codex und Junie das OS sehen und steuern.
final class Bridge: ObservableObject {
    weak var app: AppModel?
    weak var tasks: TaskStore?
    weak var agents: AgentManager?
    weak var calendar: CalendarService?
    weak var mail: MailService?
    weak var hub: MCPHub?
    weak var projects: ProjectCatalog?
    weak var skills: SkillCatalog?

    @Published var lastCommand: String?

    private var timer: Timer?
    private var watcher: DirectoryWatcher?
    private var offset: UInt64 = 0
    private var started = false

    private var commandsURL: URL { Paths.data.appendingPathComponent("commands.jsonl") }
    private var statusURL: URL { Paths.data.appendingPathComponent("status.json") }

    func start() {
        guard !started else { return }
        started = true
        // Alte Befehle beim Start nicht erneut ausführen.
        offset = (try? FileManager.default.attributesOfItem(atPath: commandsURL.path)[.size] as? UInt64) ?? 0
        watcher = DirectoryWatcher(url: Paths.data) { [weak self] in self?.readCommands() }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.writeStatus() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.writeStatus() }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: Zustand für Agents

    /// Kompakter Lagebericht – auch als Kontext für den Assistenten.
    func snapshot() -> [String: Any] {
        var s: [String: Any] = ["stand": DateCoding.stamp(Date())]
        if let agents {
            s["agents"] = agents.sessions.map { a -> [String: Any] in
                var d: [String: Any] = ["agent": a.kind.title, "auftrag": a.label, "modus": a.mode.title,
                                        "ordner": a.directory.path, "start": DateCoding.stamp(a.startedAt),
                                        "status": a.running ? "läuft" : (a.succeeded ? "fertig" : "abgebrochen")]
                if let t = a.taskID { d["aufgabe_id"] = t }
                if let tail = a.resultTail(maxChars: 600), !a.running { d["ergebnis"] = tail }
                return d
            }
        }
        if let calendar {
            s["termine"] = calendar.events.prefix(40).map { e in
                ["titel": e.title, "start": DateCoding.stamp(e.start), "ende": DateCoding.stamp(e.end),
                 "ganztaegig": e.allDay, "kalender": e.calendar, "ort": e.location ?? ""] as [String: Any]
            }
        }
        if let mail {
            s["mail_ungelesen"] = mail.unread ?? 0
            s["mails"] = mail.items.map { ["von": $0.sender, "betreff": $0.subject] }
        }
        if let tasks {
            s["aufgaben_offen"] = tasks.open.count
            s["fokus"] = tasks.focus.prefix(15).map { ["id": $0.id, "titel": $0.title, "bereich": $0.company.title, "status": $0.status.title] }
        }
        if let projects {
            s["projekte"] = projects.local.map { ["name": $0.name, "pfad": $0.path, "git": $0.isGit, "quelle": $0.source] as [String: Any] }
        }
        if let skills {
            s["skills"] = skills.skills.map { ["name": $0.name, "beschreibung": String($0.description.prefix(200)), "quelle": $0.source] }
        }
        if let v = Obsidian.vault {
            s["obsidian_vault"] = v.path
            s["obsidian_lage"] = Obsidian.lageFile?.path ?? ""
            s["obsidian_journal"] = Obsidian.journalFile()?.path ?? ""
        }
        return s
    }

    func writeStatus() {
        let s = snapshot()
        guard let d = try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return }
        try? d.write(to: statusURL, options: .atomic)
        // Obsidian: Lage für alle Agents (ohne Zeitstempel-Zeile, damit nur echte Änderungen geschrieben werden).
        Obsidian.writeLage(contextText().components(separatedBy: "\n").dropFirst().joined(separator: "\n"))
    }

    /// Lesbarer Kontext für das Sprachmodell.
    func contextText() -> String {
        var lines = ["Stand: \(Date().formatted(date: .complete, time: .shortened))"]
        if let tasks {
            lines.append("Fokus-Aufgaben:")
            for t in tasks.focus.prefix(10) { lines.append("- [\(t.id)] \(t.title) (\(t.company.title), \(t.status.title))") }
        }
        if let calendar {
            lines.append("Termine heute:")
            for e in calendar.events(onDayOffset: 0) { lines.append("- \(e.allDay ? "ganztägig" : e.start.timeString) \(e.title)") }
        }
        if let agents, !agents.sessions.isEmpty {
            lines.append("Agents:")
            for a in agents.sessions { lines.append("- \(a.kind.title): \(a.label) – \(a.running ? "läuft" : (a.succeeded ? "fertig" : "abgebrochen"))") }
        }
        if let mail, let n = mail.unread { lines.append("Ungelesene Mails: \(n)") }
        if let v = Obsidian.vault {
            lines.append("Obsidian-Vault (Wissen & Journal): \(v.path) – Tools obsidian_suchen / obsidian_lesen / obsidian_schreiben")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Befehle

    private func readCommands() {
        guard let h = try? FileHandle(forReadingFrom: commandsURL) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < offset { offset = 0 }
        guard size > offset else { return }
        try? h.seek(toOffset: offset)
        let data = h.readDataToEndOfFile()
        offset = size
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let cmd = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            execute(cmd)
        }
    }

    /// Merkt sich, welcher Auftrag aus welchem Befehl entstand (für delegieren/ergebnis in bin/aos-mcp).
    static func registerDelegation(cmdID: String?, parent: String?, session: AgentSession) {
        if let parent, !parent.isEmpty { MissionStore.shared.link(session.id.uuidString, parent: parent, delegated: true) }
        guard let cmdID else { return }
        let dir = Paths.data.appendingPathComponent("delegations", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let j: [String: Any] = ["mission": session.id.uuidString, "log": session.logFile.path, "ordner": session.directory.path]
        if let d = try? JSONSerialization.data(withJSONObject: j) { try? d.write(to: dir.appendingPathComponent("\(cmdID).json")) }
    }

    private func execute(_ c: [String: Any]) {
        let kind = c["art"] as? String ?? ""
        lastCommand = kind
        switch kind {
        case "agent_starten" where (c["agent"] as? String) == "os":
            // Eigener Agent (alle Anbindungen + Browser), z. B. über das MCP-Werkzeug angestoßen.
            guard let agents, let tasks, let hub, let auftrag = c["auftrag"] as? String else { return }
            let first = auftrag.components(separatedBy: .newlines).first ?? auftrag
            let title = first.count > 90 ? String(first.prefix(88)) + "…" : first
            let company = (c["bereich"] as? String).flatMap { Company.from(tag: $0) } ?? .privat
            let task = TaskItem(title: title, notes: auftrag, company: company, status: .warten, agent: .claude, source: "mcp")
            tasks.add(task)
            let cmdID = c["id"] as? String, parent = c["eltern"] as? String
            OSAgent.start(Agents.missionPrompt(auftrag, task: task, mode: .autonom), agents: agents, hub: hub, taskID: task.id, label: title,
                          model: c["modell"] as? String) { s in
                Self.registerDelegation(cmdID: cmdID, parent: parent, session: s)
            }
            notify("OS-Agent gestartet: \(title)")
        case "agent_starten":
            guard let agents, let tasks, let agentRaw = c["agent"] as? String, var agent = AgentKind(rawValue: agentRaw),
                  let auftrag = c["auftrag"] as? String else { return }
            let mode: RunMode = (c["modus"] as? String) == "interaktiv" ? .interaktiv : .autonom
            var model = c["modell"] as? String
            var effort = c["denktiefe"] as? String
            // Wird der gewünschte Agent knapp, übernimmt einer mit freiem Kontingent.
            if mode == .autonom, AgentKind.coders.contains(agent) {
                let target = MissionTarget.from(agent)
                let installed = Set(AgentKind.allCases.filter { OpenModels.available($0) })
                let adj = Usage.shared.adjust(AIRouteDecision(target: target, model: model, effort: effort, directory: nil, skills: [], reason: ""),
                                              installed: installed)
                if let a = adj.target.agent { agent = a; model = adj.model; effort = adj.effort }
            }
            let first = auftrag.components(separatedBy: .newlines).first ?? auftrag
            let title = first.count > 90 ? String(first.prefix(88)) + "…" : first
            let company = (c["bereich"] as? String).flatMap { Company.from(tag: $0) } ?? .privat
            let task = TaskItem(title: title, notes: auftrag, company: company, status: .warten, agent: agent, source: "mcp")
            tasks.add(task)
            let dir = (c["ordner"] as? String).map { ($0 as NSString).expandingTildeInPath }
            let s = agents.start(agent, in: dir, prompt: Agents.missionPrompt(auftrag, task: task, mode: mode, coding: AgentKind.coders.contains(agent)), taskID: task.id, mode: mode, label: title,
                                 model: agent == .claude ? model : nil,
                                 effort: agent == .codex ? effort : nil)
            Self.registerDelegation(cmdID: c["id"] as? String, parent: c["eltern"] as? String, session: s)
            notify("\(agent.title) gestartet: \(title)")
        case "seite_oeffnen":
            let map: [String: Page] = ["cockpit": .cockpit, "mission": .mission, "tasks": .tasks, "agents": .agents, "mail": .mail,
                                       "calendar": .calendar, "mcp": .mcp, "wissen": .wissen,
                                       "projekte": .projects, "verbrauch": .usage,
                                       "nachtschicht": .nightshift, "rueckblick": .recap, "betreuer": .stewards]
            if let p = (c["seite"] as? String).flatMap({ map[$0] }) {
                app?.page = p
                AppDelegate.showMainWindow()
            }
        case "nachtschicht_hinzufuegen":
            guard let auftrag = c["auftrag"] as? String else { return }
            let dir = (c["ordner"] as? String).flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
            NightShift.shared.add(auftrag, directory: dir, agent: (c["agent"] as? String) ?? "auto")
            notify("🌙 " + L("Für die Nachtschicht vorgemerkt: ") + String(auftrag.prefix(80)))
        case "leistung_messen":
            PerfProbe.run()
        case "betreuer_nachricht":
            guard let text = c["text"] as? String, let ordner = c["ordner"] as? String, !ordner.isEmpty else { return }
            let id = Steward.shared.adopt((ordner as NSString).expandingTildeInPath)
            Steward.shared.send(id, text)
            notify("🧭 " + L("An den Projekt-Betreuer: ") + String(text.prefix(80)))
        case "benachrichtigen":
            notify(c["text"] as? String ?? "")
        default:
            break
        }
        writeStatus()
    }

    func notify(_ text: String) {
        app?.show(text)
        let content = UNMutableNotificationContent()
        content.title = "Salenta Code"
        content.body = text
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
