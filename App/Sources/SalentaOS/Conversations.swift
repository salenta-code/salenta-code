import AgenticOSKit
import AppKit
import SwiftUI

// Oberfläche wie Claude: links deine Aufträge als Unterhaltungen, rechts der Verlauf –
// was du geschrieben hast, was der Agent gerade tut (Schritt für Schritt) und sein Ergebnis.

/// Ein Auftrag an einen Agent – bleibt auch nach einem Neustart sichtbar (data/missions.json).
struct MissionRecord: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var request: String
    var agent: String
    var mode: String
    var directory: String
    var started: Date
    var ended: Date?
    var ok: Bool?
    var log: String
    var taskID: String?
    /// Verlaufsdatei von Claude Code / Codex (Dialog-Sitzungen) – damit sie als Chat lesbar ist.
    var transcript: String? = nil
    /// Abgeschlossen: verschwindet aus der Liste "Aufträge".
    var archived: Bool? = nil
    /// Gewähltes Modell (für die Anzeige) und warum dieser Agent gewählt wurde.
    var model: String? = nil
    var routeReason: String? = nil
    /// Arbeitskopie bei Coding-Aufträgen (bis du übernimmst oder verwirfst).
    var worktree: WorktreeInfo? = nil
    /// Vorheriger Teil (Weitermachen/Übergabe) oder Auftraggeber (Delegation).
    var parent: String? = nil
    var delegated: Bool? = nil
    /// Prüfschleife (Build, Tests, Review) und wie oft schon nachgebessert wurde.
    var verify: VerifyReport? = nil
    var fixRound: Int? = nil
    /// Wie es ausging (merged, pr, discarded, failed, limit) – für die lernende Agentenwahl.
    var outcome: String? = nil
    /// Adresse des Pull Requests, sobald einer offen ist (Auftrag bleibt dann für Nachträge offen)
    var pr: String? = nil
    /// Von dir selbst gewählt (nicht "Automatisch") und welche Tools zugeschaltet wurden.
    var manual: Bool? = nil
    var tools: [String]? = nil
    /// Nur geplant (noch nichts geändert) und Gruppe paralleler Lösungen.
    var plan: Bool? = nil
    var group: String? = nil
    /// Aufbereitete Zusammenfassung mit Befunden und Vorschlägen (Ergebnis-Karte).
    var digest: MissionDigest? = nil
    /// Automatisch mitgegebene Erweiterungen und Skills (Token-Sparer, passende Skills).
    var auto: [String]? = nil
    /// Stand der Arbeitskopie vor dieser Runde (Commit) – für „Zurück zu hier“.
    var checkpoint: String? = nil

    var agentKind: AgentKind { AgentKind(rawValue: agent) ?? .claude }
    var isOSAgent: Bool { agent == "os" }
    var agentTitle: String { isOSAgent ? "OS-Agent" : agentKind.title }
    var agentSymbol: String { isOSAgent ? "sparkles" : agentKind.symbol }
    var runMode: RunMode { RunMode(rawValue: mode) ?? .autonom }
}

final class MissionStore: ObservableObject {
    static let shared = MissionStore()
    @Published var missions: [MissionRecord] = []
    private var url: URL { Paths.data.appendingPathComponent("missions.json") }

    /// „Im Projekt salenta (/Users/…/salenta): Text“ → „salenta: Text“ – keine Pfade in Titeln
    static func tidy(_ title: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "^Im Projekt (.+?) \\(/[^)]*\\):\\s*") else { return title }
        return re.stringByReplacingMatches(in: title, range: NSRange(title.startIndex..., in: title), withTemplate: "$1: ")
    }

    init() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: url), let m = try? dec.decode([MissionRecord].self, from: d) {
            missions = m.map { var r = $0; r.title = Self.tidy(r.title); return r }
        }
        // Prüfungen, die beim letzten Beenden noch liefen, gibt es nicht mehr – sonst bliebe „Prüft …“ ewig stehen.
        for i in missions.indices where missions[i].verify != nil && missions[i].verify?.finished == nil {
            missions[i].verify = nil
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(Array(missions.suffix(300))).write(to: url, options: .atomic)
    }

    func record(_ s: AgentSession, prompt: String) {
        let request = prompt.components(separatedBy: "\n\n---\n").first ?? prompt
        missions.append(MissionRecord(id: s.id.uuidString, title: Self.tidy(s.label), request: request, agent: s.isOSAgent ? "os" : s.kind.rawValue,
                                      mode: s.mode.rawValue, directory: s.directory.path, started: s.startedAt,
                                      log: s.logFile.path, taskID: s.taskID, model: s.model ?? s.effort, worktree: s.worktree))
        save()
    }

    func setReason(_ id: String, _ reason: String) {
        guard let i = missions.firstIndex(where: { $0.id == id }) else { return }
        missions[i].routeReason = reason
        save()
    }

    func persist() { save() }

    func setPlan(_ id: String, group: String?) {
        guard let i = missions.firstIndex(where: { $0.id == id }) else { return }
        if group == nil { missions[i].plan = true } else { missions[i].group = group }
        save()
    }

    func setVerify(_ id: String, _ report: VerifyReport) {
        guard let i = missions.firstIndex(where: { $0.id == id }) else { return }
        missions[i].verify = report
        if report.finished != nil { save() }
    }

    func setFixRound(_ id: String, _ n: Int) {
        guard let i = missions.firstIndex(where: { $0.id == id }) else { return }
        missions[i].fixRound = n
        save()
    }

    func setAuto(_ id: String, _ names: [String]) {
        guard let i = missions.firstIndex(where: { $0.id == id }) else { return }
        missions[i].auto = names
        save()
    }

    func setDigest(_ id: String, _ d: MissionDigest) {
        guard let i = missions.firstIndex(where: { $0.id == id }) else { return }
        missions[i].digest = d
        save()
    }

    func setOutcome(_ id: String, _ outcome: String) {
        guard let i = missions.firstIndex(where: { $0.id == id }) else { return }
        missions[i].outcome = outcome
        save()
    }

    func setMeta(_ id: String, manual: Bool, tools: [String]?) {
        guard let i = missions.firstIndex(where: { $0.id == id }) else { return }
        missions[i].manual = manual
        missions[i].tools = tools
        save()
    }

    func setPR(_ id: String, _ url: String?) {
        guard let i = missions.firstIndex(where: { $0.id == id }) else { return }
        missions[i].pr = url
        save()
    }

    func clearWorktree(_ id: String) {
        guard let i = missions.firstIndex(where: { $0.id == id }) else { return }
        missions[i].worktree = nil
        save()
    }

    func recordResume(_ s: AgentSession, title: String, transcript: String) {
        missions.append(MissionRecord(id: s.id.uuidString, title: title, request: title, agent: s.kind.rawValue,
                                      mode: RunMode.interaktiv.rawValue, directory: s.directory.path, started: s.startedAt,
                                      log: s.logFile.path, taskID: nil, transcript: transcript))
        save()
    }

    func finish(_ s: AgentSession) {
        guard let i = missions.firstIndex(where: { $0.id == s.id.uuidString }) else { return }
        missions[i].ended = Date()
        missions[i].ok = s.succeeded
        save()
    }

    func link(_ id: String, parent: String, delegated: Bool) {
        guard let i = missions.firstIndex(where: { $0.id == id }) else { return }
        missions[i].parent = parent
        missions[i].delegated = delegated
        save()
    }

    /// Ein Folgeauftrag ersetzt den vorherigen in der Liste (der Verlauf bleibt über "Vorher" erreichbar).
    func setCheckpoint(_ id: String, _ sha: String) {
        guard let i = missions.firstIndex(where: { $0.id == id }) else { return }
        missions[i].checkpoint = sha
        save()
    }

    func supersede(_ id: String) {
        guard let i = missions.firstIndex(where: { $0.id == id }) else { return }
        missions[i].archived = true
        save()
    }

    func setTranscript(_ id: String, _ path: String) {
        guard let i = missions.firstIndex(where: { $0.id == id }), missions[i].transcript != path else { return }
        missions[i].transcript = path
        save()
    }

    /// Auftrag abschließen: aus der Liste, Sitzung beenden, Aufgabe erledigt.
    func archive(_ id: String, agents: AgentManager, tasks: TaskStore) {
        guard let i = missions.firstIndex(where: { $0.id == id }) else { return }
        missions[i].archived = true
        if missions[i].ended == nil { missions[i].ended = Date() }
        if let s = agents.sessions.first(where: { $0.id.uuidString == id }) { agents.close(s.id) }
        if let t = missions[i].taskID, let task = tasks.tasks.first(where: { $0.id == t }), !task.isDone { tasks.toggleDone(t) }
        // Helfer und Mods dieses Auftrags gehen mit – sonst bleiben sie verwaist in der Seitenleiste stehen
        for k in missions.indices where missions[k].parent == id && missions[k].delegated == true && missions[k].archived != true {
            let running = agents.sessions.contains { $0.id.uuidString == missions[k].id && $0.running }
            if !running { archive(missions[k].id, agents: agents, tasks: tasks) }
        }
        save()
    }

    /// Hauptauftrag einer Kette (Helfer → Auftrag, Fortsetzung → erster Teil bleibt egal: wir nehmen den Auftrag selbst).
    func rootID(of id: String) -> String {
        var cur = id, n = 0
        while let r = mission(cur), r.delegated == true, let p = r.parent, n < 10 { cur = p; n += 1 }
        return cur
    }

    var open: [MissionRecord] { recent.filter { $0.archived != true } }
    var closed: [MissionRecord] { recent.filter { $0.archived == true } }

    func remove(_ id: String) {
        missions.removeAll { $0.id == id || ($0.parent == id && $0.delegated == true) }
        save()
    }

    func mission(_ id: String) -> MissionRecord? { missions.first { $0.id == id } }

    var recent: [MissionRecord] { missions.sorted { $0.started > $1.started } }
}

// MARK: - Lesbarer Verlauf aus der Mitschrift

enum StepKind { case read, write, run, search, web, tool, plan, think, error, done, info }

enum ChatBlock: Identifiable {
    case text(Int, String)
    case step(Int, StepKind, String, String)   // Zeit, Text
    case status(Int, Bool, String)
    case raw(Int, String)

    var id: Int {
        switch self {
        case .text(let i, _), .step(let i, _, _, _), .status(let i, _, _), .raw(let i, _): i
        }
    }
}

/// Liest das Lauf-Protokoll im Hintergrund – nur wenn es gewachsen ist, und höchstens die letzten 2 MB.
/// (Früher: bei jedem Neuzeichnen und jede Sekunde die ganze Datei auf dem Hauptthread gelesen und zerlegt.)
final class LogTail: ObservableObject {
    @Published private(set) var blocks: [ChatBlock] = []
    private var path = ""
    private var size: UInt64 = .max
    private var timer: Timer?
    private var busy = false

    func watch(_ path: String, live: Bool) {
        if path != self.path { self.path = path; size = .max }
        load()
        timer?.invalidate(); timer = nil
        if live {
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.load() }
            timer?.tolerance = 0.4
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func load() {
        guard !busy, !path.isEmpty else { return }
        busy = true
        let path = self.path, known = size
        DispatchQueue.global(qos: .userInitiated).async {
            let now = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64) ?? 0
            guard now != known else { DispatchQueue.main.async { self.busy = false }; return }
            var text = ""
            if let h = try? FileHandle(forReadingFrom: path.isEmpty ? URL(fileURLWithPath: "/dev/null") : URL(fileURLWithPath: path)) {
                try? h.seek(toOffset: now > 2_000_000 ? now - 2_000_000 : 0)
                text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
                try? h.close()
            }
            let parsed = ChatParser.parse(text)
            DispatchQueue.main.async {
                self.busy = false
                guard path == self.path else { return }
                self.size = now
                self.blocks = parsed
            }
        }
    }
}

enum ChatParser {
    static func parse(_ log: String) -> [ChatBlock] {
        let clean = log.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        var blocks: [ChatBlock] = []
        var text: [String] = []
        var raw: [String] = []
        var n = 0
        func flush() {
            if !text.isEmpty { blocks.append(.text(n, text.joined(separator: "\n"))); n += 1; text = [] }
            if !raw.isEmpty { blocks.append(.raw(n, raw.joined(separator: "\n"))); n += 1; raw = [] }
        }
        let stepRx = try! NSRegularExpression(pattern: "^(\\d\\d:\\d\\d) (\\S+)\\s+(.*)$")
        for line in clean.components(separatedBy: "\n") {
            if line.hasPrefix("▶ ") { continue }
            if line.hasPrefix("━━ ") {
                flush()
                blocks.append(.status(n, line.contains("Fertig"), String(line.dropFirst(3)))); n += 1
                continue
            }
            if let m = stepRx.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let t = Range(m.range(at: 1), in: line), let sym = Range(m.range(at: 2), in: line), let rest = Range(m.range(at: 3), in: line) {
                flush()
                blocks.append(.step(n, kind(String(line[sym])), String(line[t]), String(line[rest]))); n += 1
                continue
            }
            if line.hasPrefix("      ") {   // Plan-Punkte oder Fehler unter einem Schritt
                flush()
                let s = line.trimmingCharacters(in: .whitespaces)
                blocks.append(.step(n, s.hasPrefix("✗") ? .error : .plan, "", s)); n += 1
                continue
            }
            if line.hasPrefix("  ") { if !raw.isEmpty { flush() }; text.append(String(line.dropFirst(2))); continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !text.isEmpty { text.append("") }
                continue
            }
            if !text.isEmpty { flush() }
            raw.append(line)
        }
        flush()
        return blocks
    }

    private static func kind(_ s: String) -> StepKind {
        switch s {
        case "📖": .read
        case "📝", "✏️": .write
        case "⚙️": .run
        case "🔎": .search
        case "🌐": .web
        case "🗒": .plan
        case "💭": .think
        default: .tool
        }
    }

    static func symbol(_ k: StepKind) -> String {
        switch k {
        case .read: "doc.text.magnifyingglass"
        case .write: "pencil.line"
        case .run: "terminal"
        case .search: "magnifyingglass"
        case .web: "globe"
        case .tool: "puzzlepiece.extension"
        case .plan: "checklist"
        case .think: "brain"
        case .error: "exclamationmark.triangle"
        case .done: "checkmark.circle"
        case .info: "info.circle"
        }
    }
}

// MARK: - Unterhaltung

struct ConversationView: View {
    let id: String
    @EnvironmentObject private var tasks: TaskStore
    @EnvironmentObject private var hub: MCPHub
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = MissionStore.shared
    @Environment(\.openWindow) private var openWindow
    @State private var reply = ""
    @State private var showTerminal = false
    @State private var nextAgent = ""
    @State private var installedAgents: [AgentKind] = []
    @State private var modelTick = 0
    @StateObject private var tail = LogTail()
    @ObservedObject private var catalog = ModelCatalog.shared

    static let handoffAgents: [(String, String, String)] = [
        ("os", "OS-Agent", "sparkles"), ("claude", "Claude Code", "sparkle"),
        ("codex", "Codex", "chevron.left.forwardslash.chevron.right"), ("junie", "Junie", "j.square"),
    ]

    private var session: AgentSession? { agents.sessions.first { $0.id.uuidString == id } }
    private var record: MissionRecord? { store.mission(id) }

    var body: some View {
        if let rec = record {
            VStack(spacing: 0) {
                header(rec)
                MissionStatusBar(rec: rec, session: session).id(rec.id)
                Divider()
                if rec.runMode == .interaktiv, !showTerminal, let t = rec.transcript {
                    DialogChat(path: t, session: session)
                } else if let s = session, rec.runMode == .interaktiv || showTerminal {
                    VStack(spacing: 0) {
                        UserBubble(text: rec.request).padding(Grid.l)
                        TerminalContainer(session: s).id(s.id)
                            .padding(Grid.m)
                            .background(Color(hex: 0x16161B))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .padding([.horizontal, .bottom], Grid.l)
                    }
                } else {
                    transcript(rec)
                }
                // Ergebnis-Karte und Änderungen: zusammen höchstens ~45 % des Fensters, scrollbar.
                // So kann der untere Bereich das Fenster nie sprengen – Kopf, Verlauf und Eingabe bleiben sichtbar.
                // Ergebnis in klarer Reihenfolge: 1. was gemacht wurde, 2. prüfen und übernehmen, 3. wie es weitergeht.
                // Höchstens gut die Hälfte des Fensters, scrollbar – Verlauf und Eingabe bleiben sichtbar.
                if hasLowerPanel(rec) {
                    BoundedScroll(maxFraction: 0.55) {
                        VStack(spacing: Grid.s) {
                            let idle = session?.running != true
                            if rec.digest != nil, idle { DigestCard(rec: rec, part: .summary) }
                            if rec.plan == true, rec.ok == true, idle, rec.archived != true {
                                PlanBar(rec: rec)
                            } else if let wt = rec.worktree, idle, rec.archived != true {
                                ChangesPanel(rec: rec, wt: wt)
                            } else if rec.group != nil, rec.archived != true {
                                ParallelCompare(rec: rec).frame(maxWidth: 780).padding(.horizontal, Grid.l)
                            }
                            if rec.digest != nil, idle, rec.plan != true {
                                DigestCard(rec: rec, part: .next, step: rec.worktree != nil && rec.archived != true ? 2 : nil)
                            }
                        }
                        .padding(.vertical, Grid.s)
                    }
                }
                composer(rec)
            }
            .navigationTitle(rec.title)
            .task(id: rec.id) { await findTranscript(rec) }
            .task(id: "\(rec.id)-\(rec.ended?.timeIntervalSince1970 ?? 0)") {
                // ältere oder gerade fertige Aufträge: Ergebnis-Karte einmal erzeugen
                if (rec.digest == nil || (rec.digest?.byAI == true && (rec.digest?.version ?? 1) < Digest.version)),
                   session?.running != true, rec.runMode == .autonom, Digest.worth(rec) { Digest.make(rec.id) }
            }
        } else {
            ContentUnavailableView("Auftrag nicht gefunden", systemImage: "questionmark.bubble")
        }
    }

    private func hasLowerPanel(_ rec: MissionRecord) -> Bool {
        let idle = session?.running != true
        return (rec.digest != nil && idle && rec.plan != true)
            || (rec.plan == true && rec.ok == true && idle && rec.archived != true)
            || (rec.worktree != nil && idle && rec.archived != true)
            || (rec.group != nil && rec.archived != true)
    }

    private func header(_ rec: MissionRecord) -> some View {
        HStack(spacing: Grid.m) {
            Image(systemName: rec.agentSymbol).font(.title3).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(rec.title).font(.headline).lineLimit(1)
                Text("\(rec.agentTitle)\(rec.model.map { " (\($0))" } ?? "") · \(rec.runMode == .autonom ? L("arbeitet selbstständig") : L("im Dialog"))\(rec.projectName.isEmpty ? "" : " · " + rec.projectName)")
                    .font(.caption).foregroundStyle(.secondary)
                if let r = rec.routeReason {
                    Label(r, systemImage: "wand.and.sparkles").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                if let a = rec.auto, !a.isEmpty {
                    Label(L("Automatisch dabei: ") + a.joined(separator: ", "), systemImage: "bolt.badge.automatic")
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        .help(L("Installierte Token-Sparer und passende Skills, die Salenta Code diesem Auftrag mitgegeben hat"))
                }
            }
            Spacer()
            if let s = session { StatusPill(session: s) } else {
                Text(rec.ok == true ? "Fertig" : (rec.ended == nil ? "Beendet" : "Abgebrochen"))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            if session != nil && rec.runMode == .interaktiv && rec.transcript != nil {
                Toggle(isOn: $showTerminal) { Image(systemName: "terminal") }
                    .toggleStyle(.button).help("Terminal statt Chat anzeigen")
            }
            if let s = session, rec.runMode == .autonom {
                Toggle(isOn: $showTerminal) { Image(systemName: "terminal") }
                    .toggleStyle(.button).help("Rohes Terminal anzeigen")
                if s.running {
                    Button(role: .destructive) { agents.close(s.id) } label: { Image(systemName: "stop.fill") }.help("Stoppen")
                }
            }
            Button { openWindow(id: "live") } label: { Image(systemName: "macwindow.on.rectangle") }.help("Im Live-Fenster ansehen")
            if rec.archived != true {
                Button {
                    store.archive(rec.id, agents: agents, tasks: tasks)
                    app.page = .home
                } label: { Label("Abschließen", systemImage: "checkmark.circle") }
                    .buttonStyle(.borderedProminent).tint(session?.running == true ? .gray : .green)
                    .help(session?.running == true ? "Beendet den Agent und schließt den Auftrag" : "Erledigt – aus der Liste nehmen")
            }
        }
        .padding(.horizontal, Grid.l)
        .padding(.vertical, Grid.m)
    }

    private func transcript(_ rec: MissionRecord) -> some View {
        let blocks = tail.blocks
        return Group {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Grid.m) {
                        ThreadLinks(rec: rec)
                        UserBubble(text: rec.request)
                        if let wt = rec.worktree, session?.running != true {
                            rewindButton(rec, wt)
                        }
                        if blocks.isEmpty && session == nil {
                            Text(rec.runMode == .interaktiv
                                 ? "Diese Sitzung lief im Dialog im Terminal. Den ganzen Verlauf findest du unter „Verlauf“."
                                 : "Keine Mitschrift vorhanden.")
                                .foregroundStyle(.secondary)
                        } else if blocks.isEmpty {
                            HStack(spacing: Grid.s) {
                                ProgressView().controlSize(.small)
                                Text("\(rec.agentTitle) startet …").foregroundStyle(.secondary)
                            }
                        }
                        ForEach(blocks) { b in BlockView(block: b) }
                        if session?.running == true, !blocks.isEmpty {
                            HStack(spacing: Grid.s) {
                                ProgressView().controlSize(.small)
                                Text("arbeitet …").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: 780, alignment: .leading)
                    .padding(Grid.xl)
                    .frame(maxWidth: .infinity)
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: blocks.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
        }
        .task(id: "\(rec.log)|\(session?.running == true)") { tail.watch(rec.log, live: session?.running == true) }
        .onDisappear { tail.stop() }
    }

    /// „Zurück zu hier“: Code der Arbeitskopie auf den Stand vor dieser Nachricht, Nachricht zurück ins Eingabefeld.
    private func rewindButton(_ rec: MissionRecord, _ wt: WorktreeInfo) -> some View {
        HStack {
            Spacer()
            Button {
                let a = NSAlert()
                a.messageText = L("Zurück zum Stand vor dieser Nachricht?")
                a.informativeText = L("Der Code in der Arbeitskopie wird auf den Stand vor dieser Nachricht gesetzt. Der jetzige Stand wird vorher als Checkpoint gesichert – du kannst also wieder vor. Dein Repo bleibt unberührt.")
                a.addButton(withTitle: L("Zurückspulen")); a.addButton(withTitle: L("Abbrechen"))
                guard a.runModal() == .alertFirstButtonReturn else { return }
                let text = rec.request
                DispatchQueue.global(qos: .userInitiated).async {
                    let sha = rec.checkpoint ?? Git.run(["merge-base", "HEAD", wt.baseBranch], in: Worktrees.top(wt)).out
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let ok = !sha.isEmpty && Checkpoints.restore(wt, to: sha)
                    DispatchQueue.main.async {
                        if ok {
                            reply = text
                            app.show(L("✓ Zurückgespult – Code steht vor dieser Nachricht. Ändere sie unten und sende neu."))
                        } else {
                            app.show(L("Zurückspulen fehlgeschlagen – Stand nicht gefunden"))
                        }
                    }
                }
            } label: {
                Label(L("Zurück zu hier"), systemImage: "arrow.uturn.backward")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L("Code auf den Stand vor dieser Nachricht setzen und die Nachricht zum Ändern ins Eingabefeld legen"))
        }
    }

    /// Agent für die nächste Runde (gleicher oder anderer) – mit Modellwahl wie beim neuen Auftrag.
    private func agentPicker(_ rec: MissionRecord) -> some View {
        let key = nextAgent.isEmpty ? rec.agent : nextAgent
        let kind = AgentKind(rawValue: key)
        let model = kind.map { ModelCatalog.selected(for: $0) } ?? ""
        _ = modelTick
        return Menu {
            Button { nextAgent = "os" } label: { Label("OS-Agent", systemImage: "sparkles") }
            Divider()
            ForEach(installedAgents) { a in
                if ModelCatalog.supportsModel(a) {
                    Menu {
                        Button { nextAgent = a.rawValue; ModelCatalog.select("", for: a); modelTick += 1 } label: {
                            Label(L("Standard-Modell"), systemImage: "wand.and.sparkles")
                        }
                        Divider()
                        ForEach(catalog.latest(for: a)) { o in
                            Button {
                                nextAgent = a.rawValue; ModelCatalog.select(o.value, for: a); modelTick += 1
                            } label: {
                                if ModelCatalog.selected(for: a) == o.value { Label(o.label, systemImage: "checkmark") } else { Text(o.label) }
                            }
                        }
                        Divider()
                        Button(L("Eigenes Modell eingeben …")) {
                            if let v = ModelPrompt.ask(agent: a, current: ModelCatalog.selected(for: a)) {
                                nextAgent = a.rawValue; ModelCatalog.select(v, for: a); modelTick += 1
                            }
                        }
                    } label: { Label(a.title, systemImage: a.symbol) }
                } else {
                    Button { nextAgent = a.rawValue } label: { Label(a.title, systemImage: a.symbol) }
                }
            }
        } label: {
            let title = key == "os" ? "OS-Agent" : (kind?.title ?? rec.agentTitle)
            Label(title + (model.isEmpty ? "" : " · " + model), systemImage: key == "os" ? "sparkles" : (kind?.symbol ?? rec.agentSymbol))
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.accentColor.opacity(nextAgent.isEmpty || nextAgent == rec.agent ? 0.08 : 0.2)))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(L("Mit welchem Agent und Modell es weitergeht – z. B. Claude plant, Codex setzt um"))
        .task {
            guard installedAgents.isEmpty else { return }
            let list = await Task.detached { AgentKind.coders.filter { OpenModels.available($0) } }.value
            installedAgents = list
        }
    }

    private func composer(_ rec: MissionRecord) -> some View {
        // Läuft die Sitzung im Dialog und bleibt es beim selben Agent, geht die Antwort direkt ins Terminal
        let switching = !nextAgent.isEmpty && nextAgent != rec.agent
        let live = session?.running == true && rec.runMode == .interaktiv && !switching
        return HStack(alignment: .bottom, spacing: Grid.s) {
            agentPicker(rec)
            TextField(live ? "Antwort an \(rec.agentTitle) …" : (switching ? L("Auftrag für den neuen Agent …")
                      : (session?.running == true ? "Arbeitet gerade – du kannst gleich nachfragen" : "Nachfragen oder weitermachen …")),
                      text: $reply, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .onSubmit { send(rec) }
                .disabled(session?.running == true && !live && !switching)
            MicButton { t in reply += (reply.isEmpty ? "" : " ") + t }
            Button { send(rec) } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }.help(L("Senden"))
                .buttonStyle(.plain)
                .foregroundStyle(reply.isEmpty ? Color.secondary : Color.accentColor)
                .disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(Grid.m)
        .background(RoundedRectangle(cornerRadius: 18).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.secondary.opacity(0.25)))
        .frame(maxWidth: 780)
        .padding(Grid.l)
        .frame(maxWidth: .infinity)
    }

    /// Sucht die Verlaufsdatei der Dialog-Sitzung (Claude Code / Codex), damit sie als Chat erscheint.
    private func findTranscript(_ rec: MissionRecord) async {
        guard rec.runMode == .interaktiv, rec.agentKind == .claude || rec.agentKind == .codex, session?.running == true || rec.transcript == nil else { return }
        // Auch bei fortgesetzten Sitzungen: legt der Agent eine neue Verlaufsdatei an, wechseln wir auf sie.
        for _ in 0..<60 {
            if let url = DialogChat.locate(agent: rec.agentKind, directory: rec.directory, after: rec.started) {
                await MainActor.run { store.setTranscript(rec.id, url.path) }
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func send(_ rec: MissionRecord) {
        let t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        reply = ""
        if let s = session, s.running, rec.runMode == .interaktiv, nextAgent.isEmpty || nextAgent == rec.agent {
            s.view.send(txt: t + "\r")
            return
        }
        // Folgeauftrag – gleicher oder anderer Agent (mit gewähltem Modell) – mit dem bisherigen Verlauf als Kontext.
        let switching = !nextAgent.isEmpty && nextAgent != rec.agent
        if switching, let s = session, s.running { s.terminate() }
        let target = nextAgent.isEmpty ? rec.agent : nextAgent
        nextAgent = ""
        Handoff.continueMission(rec, message: t, target: target, agents: agents, hub: hub) { s in
            app.page = .chat(s.id.uuidString)
        }
    }
}

struct UserBubble: View {
    let text: String
    var body: some View {
        HStack {
            Spacer(minLength: 80)
            Text(text)
                .textSelection(.enabled)
                .padding(.horizontal, Grid.l)
                .padding(.vertical, Grid.m)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.secondary.opacity(0.12)))
        }
    }
}

struct BlockView: View {
    let block: ChatBlock
    var body: some View {
        switch block {
        case .text(_, let t):
            MarkdownText(t).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        case .step(_, let k, let time, let t):
            HStack(alignment: .firstTextBaseline, spacing: Grid.s) {
                Image(systemName: ChatParser.symbol(k)).frame(width: 16)
                    .foregroundStyle(k == .error ? Color.red : Color.secondary)
                Text(t).font(.callout).foregroundStyle(k == .error ? Color.red : (k == .think ? Color.secondary.opacity(0.8) : Color.secondary))
                    .lineLimit(k == .think ? 2 : 1)
                Spacer()
                if !time.isEmpty { Text(time).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary) }
            }
            .padding(.leading, k == .plan ? Grid.l : 0)
        case .status(_, let ok, let t):
            Label(t, systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(ok ? Color.green : Color.orange)
                .padding(.vertical, Grid.xs)
        case .raw(_, let t):
            Text(t).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Grid.s)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
        }
    }
}

struct StatusPill: View {
    @ObservedObject var session: AgentSession
    var body: some View {
        HStack(spacing: 5) {
            if session.running { ProgressView().controlSize(.mini) }
            Text(session.running ? "\(session.displayName) arbeitet" : (session.succeeded ? "\(session.displayName) fertig" : "Beendet"))
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(session.running ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12)))
        .foregroundStyle(session.running ? Color.green : Color.secondary)
    }
}

// MARK: - Start wie bei Claude

struct HomeView: View {
    @ObservedObject private var missions = MissionStore.shared
    @EnvironmentObject private var tasks: TaskStore
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var calendar: CalendarService
    @EnvironmentObject private var app: AppModel
    @State private var seed = ""

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 11 ? "Guten Morgen" : h < 18 ? "Hallo" : "Guten Abend"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Grid.xl) {
                Spacer(minLength: 60)
                HStack(spacing: Grid.m) {
                    LiveMark(size: 36, active: agents.runningCount > 0)
                    Text("\(greeting), \(Profile.name)").font(.system(size: 34, weight: .regular, design: .serif))
                }
                MissionComposer(style: .claude, seed: $seed)
                    .frame(maxWidth: 760)
                HStack(spacing: Grid.m) {
                    if Focus.isOn { Label("Fokus aktiv – nur Freigaben, fertige Aufträge und dringende Mails melden sich", systemImage: "moon.fill").font(.caption).foregroundStyle(.purple) }
                    Spacer(); UsageMini(); FocusButton(); AwakeButton(); AutoModeButton()
                }.frame(maxWidth: 760).padding(.top, -Grid.l)
                suggestions.frame(maxWidth: 760)
                running.frame(maxWidth: 760)
                Spacer(minLength: 40)
            }
            .padding(Grid.xl)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("")
    }

    private var suggestions: some View {
        let items = Array(tasks.focus.prefix(3))
        return HStack(spacing: Grid.s) {
            ForEach(items) { t in
                Button { seed = t.title + (t.notes.isEmpty ? "" : "\n\n" + t.notes) } label: {
                    Label(t.title, systemImage: "checklist").lineLimit(1)
                        .font(.callout)
                        .padding(.horizontal, Grid.m).padding(.vertical, 7)
                        .background(Capsule().strokeBorder(Color.secondary.opacity(0.3)))
                }
                .buttonStyle(.plain)
            }
            if let next = calendar.next {
                Label("\(next.start.timeString) \(next.title)", systemImage: "calendar").lineLimit(1)
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, Grid.m).padding(.vertical, 7)
            }
        }
    }

    @ViewBuilder private var running: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            let open = missions.open.map { rec in (rec, rec.phase(session: agents.sessions.first { $0.id.uuidString == rec.id })) }
            VStack(alignment: .leading, spacing: Grid.l) {
                ForEach([MissionPhase.waiting, .running, .review, .failed], id: \.self) { ph in
                    let list = open.filter { $0.1 == ph }
                    if !list.isEmpty {
                        VStack(alignment: .leading, spacing: Grid.s) {
                            HStack(spacing: 6) {
                                PhaseBadge(phase: ph)
                                Text("\(ph.title) · \(list.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            ForEach(list, id: \.0.id) { rec, phase in OverviewRow(rec: rec, phase: phase) }
                        }
                    }
                }
                let today = missions.closed.filter { Calendar.current.isDateInToday($0.ended ?? $0.started) }.count
                if today > 0 {
                    Label("\(today) heute abgeschlossen", systemImage: "archivebox").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct OverviewRow: View {
    let rec: MissionRecord
    let phase: MissionPhase
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var tasks: TaskStore
    @ObservedObject private var store = MissionStore.shared

    var body: some View {
        HStack(spacing: Grid.s) {
            Button { app.page = .chat(rec.id) } label: {
                HStack(spacing: Grid.s) {
                    Image(systemName: rec.agentSymbol).foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rec.title).lineLimit(1)
                        Text("\(rec.agentTitle)\(rec.projectName.isEmpty ? "" : " · " + rec.projectName) · \(relativeDay(rec.started))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if phase == .review || phase == .failed {
                Button("Abschließen") { store.archive(rec.id, agents: agents, tasks: tasks) }
                    .controlSize(.small)
            }
        }
        .padding(Grid.m)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
    }
}

/// Eintrag in der Seitenleiste "Aufträge".
struct MissionRow: View {
    let rec: MissionRecord
    var helpers: Int = 0
    @EnvironmentObject private var agents: AgentManager
    var body: some View {
        let s = agents.sessions.first { $0.id.uuidString == rec.id }
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            let ph = rec.phase(session: s)
            HStack(spacing: Grid.s) {
                Image(systemName: rec.agentSymbol).frame(width: 16).foregroundStyle(ph == .running ? Color.green : .secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(rec.title).lineLimit(1)
                    Text("\(rec.delegated == true ? (rec.routeReason?.hasPrefix("Mod:") == true ? "↳ Mod · " : "↳ Helfer · ") : "")\(rec.agentTitle) · \(ph.title)").font(.caption2).foregroundStyle(ph == .running || ph == .waiting ? ph.color : .secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if helpers > 0 {
                    Text("\(helpers)").font(.caption2.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .help(String(format: L("%d Helfer"), helpers))
                }
                PhaseBadge(phase: ph)
            }
        }
    }
}

struct RunningDot: View {
    @ObservedObject var session: AgentSession
    var body: some View {
        if session.running { Circle().fill(Color.green).frame(width: 7, height: 7) }
    }
}


/// Dialog-Sitzung als Chat (aus der Verlaufsdatei), darunter die letzten Zeilen live – für Rückfragen des Agents.
struct DialogChat: View {
    let path: String
    let session: AgentSession?
    @State private var entries: [TranscriptEntry] = []
    let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Grid.m) {
                        ForEach(entries) { e in ChatEntryRow(entry: e).id(e.id) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: 780, alignment: .leading)
                    .padding(Grid.xl)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: entries.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            if let s = session, s.running {
                LiveStrip(session: s).frame(maxWidth: 780).padding(.horizontal, Grid.l)
            }
        }
        .onAppear(perform: load)
        .onReceive(timer) { _ in if session?.running == true || entries.isEmpty { load() } }
    }

    private func load() {
        let url = URL(fileURLWithPath: path)
        DispatchQueue.global(qos: .userInitiated).async {
            let e = Transcript.read(url)
            DispatchQueue.main.async { if e.count != entries.count { entries = e } }
        }
    }

    static func locate(agent: AgentKind, directory: String, after: Date) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if agent == .claude {
            let enc = directory.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
            let dir = Paths.home.appendingPathComponent(".claude/projects/\(enc)")
            candidates = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        } else {
            let c = Calendar.current.dateComponents([.year, .month, .day], from: after)
            let dir = Paths.home.appendingPathComponent(String(format: ".codex/sessions/%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
            candidates = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? [])
                .filter { Transcript.cwd(of: $0) == directory }
        }
        return candidates
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { u -> (URL, Date)? in
                guard let d = (try? u.resourceValues(forKeys: [.creationDateKey]))?.creationDate, d >= after.addingTimeInterval(-5) else { return nil }
                return (u, d)
            }
            .sorted { $0.1 < $1.1 }
            .first?.0
    }
}

/// Chat-Zeile im Stil von Claude: deine Nachricht rechts, Antworten als Text, Werkzeuge als dezente Schritte.
struct ChatEntryRow: View {
    let entry: TranscriptEntry
    var body: some View {
        switch entry.role {
        case .user: UserBubble(text: entry.text)
        case .assistant: MarkdownText(entry.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            HStack(spacing: Grid.s) {
                Image(systemName: toolSymbol(entry.text)).frame(width: 16).foregroundStyle(.secondary)
                Text(toolText(entry.text)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func toolSymbol(_ t: String) -> String {
        if t.hasPrefix("Read") { return "doc.text.magnifyingglass" }
        if t.hasPrefix("Edit") || t.hasPrefix("Write") || t.hasPrefix("MultiEdit") || t.hasPrefix("apply_patch") { return "pencil.line" }
        if t.hasPrefix("Bash") || t.hasPrefix("shell") || t.hasPrefix("exec") { return "terminal" }
        if t.hasPrefix("Grep") || t.hasPrefix("Glob") { return "magnifyingglass" }
        if t.hasPrefix("Web") { return "globe" }
        if t.hasPrefix("mcp__") { return "puzzlepiece.extension" }
        return "wrench.and.screwdriver"
    }

    private func toolText(_ t: String) -> String {
        let map = ["Read": "Liest", "Edit": "Ändert", "MultiEdit": "Ändert", "Write": "Schreibt", "Bash": "Führt aus",
                   "Grep": "Sucht", "Glob": "Sucht Dateien", "WebSearch": "Sucht im Web", "WebFetch": "Öffnet",
                   "TodoWrite": "Plan aktualisiert", "Task": "Startet Helfer"]
        let name = t.components(separatedBy: ":").first ?? t
        let rest = t.dropFirst(name.count).drop { $0 == ":" || $0 == " " }
        let home = Paths.home.path
        let detail = String(rest).replacingOccurrences(of: home, with: "~")
        if let de = map[name] { return detail.isEmpty ? de : "\(de) \(detail)" }
        if name.hasPrefix("mcp__") {
            let p = name.components(separatedBy: "__")
            return p.count >= 3 ? "\(p[1]): \(p[2].replacingOccurrences(of: "_", with: " "))" : name
        }
        return t.replacingOccurrences(of: home, with: "~")
    }
}

/// Die letzten Terminal-Zeilen, schön dargestellt – zeigt Rückfragen wie „Darf ich …? 1. Ja 2. Nein“.
struct LiveStrip: View {
    @ObservedObject var session: AgentSession
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let lines = session.screenTail(7).map { $0.trimmingCharacters(in: .init(charactersIn: " ")) }.filter { !$0.isEmpty }
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Live", systemImage: "dot.radiowaves.left.and.right").font(.caption.weight(.semibold)).foregroundStyle(.green)
                    Text(lines.joined(separator: "\n"))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(Grid.m)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.07)))
                .padding(.top, Grid.s)
            }
        }
    }
}


/// "Vorher: …" (frühere Teile des Auftrags) und "Helfer: …" (delegierte Teilaufträge).
struct ThreadLinks: View {
    let rec: MissionRecord
    @ObservedObject private var store = MissionStore.shared
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var agents: AgentManager

    var body: some View {
        let chain = previous()
        let children = store.missions.filter { $0.parent == rec.id && $0.delegated == true }
        if !chain.isEmpty || !children.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(chain) { p in
                    Button { app.page = .chat(p.id) } label: {
                        Label("Vorher: \(p.agentTitle) – \(String(p.request.prefix(70)))", systemImage: "arrow.turn.left.up")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.buttonStyle(.plain)
                }
                ForEach(children) { c in
                    Button { app.page = .chat(c.id) } label: {
                        HStack(spacing: 6) {
                            PhaseBadge(phase: c.phase(session: agents.sessions.first { $0.id.uuidString == c.id }))
                            Text("Helfer \(c.agentTitle): \(c.title)").font(.caption).lineLimit(1)
                        }
                    }.buttonStyle(.plain)
                }
            }
            .padding(Grid.s)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
        }
    }

    private func previous() -> [MissionRecord] {
        var out: [MissionRecord] = []
        var cur = rec
        while let pid = cur.parent, cur.delegated != true, let p = store.mission(pid), out.count < 10 {
            out.insert(p, at: 0)
            cur = p
        }
        return out
    }
}


extension MissionRecord {
    /// Name des Projekts, in dem gearbeitet wird – nicht der interne Arbeitsordner („projekt-113dd91f“)
    /// und nichts beim OS-Agent, der im App-Ordner läuft.
    var projectName: String {
        if let b = worktree?.base, !b.isEmpty { return (b as NSString).lastPathComponent }
        let d = directory
        if d.isEmpty || d == Paths.root.path || d.hasPrefix(Paths.support.path) { return "" }
        if d.contains("/worktrees/") || d.contains("/.salenta-worktrees/") {
            let n = (d as NSString).lastPathComponent
            if let r = n.range(of: "-[0-9a-f]{6,}$", options: .regularExpression) { return String(n[..<r.lowerBound]) }
        }
        return (d as NSString).lastPathComponent
    }
}
