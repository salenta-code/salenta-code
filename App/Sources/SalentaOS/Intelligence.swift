import AgenticOSKit
import AppKit
import SwiftUI

// Salenta Intelligence – die Intelligenz-Schicht von Salenta Code, läuft auf deinem Mac (kein Server dazwischen):
//  • Supervisor: merkt, wenn ein Agent hängt oder sich im Kreis dreht – meldet, startet neu oder übergibt an einen anderen Anbieter
//  • Progressive Delegation: pro Projekt einstellbar, was der Agent allein darf; Vertrauen wächst mit grünen Runden
//  • Nächtliches Lernen: nachts aus den Aufträgen des Tages Vorschläge fürs Projektwissen ableiten – du bestätigst morgens
// Dazu gehören Agentenwahl, Prüfschleife, Hintergrund-Assistent und Mitteilungs-Zentrale (eigene Dateien).

enum Intelligence {
    static let name = "Salenta Intelligence"
}

// MARK: - Supervisor

final class Supervisor: ObservableObject {
    static let shared = Supervisor()

    @Published private(set) var interventions: [String] = []   // letzte Eingriffe (für die Einstellungen)
    private weak var agents: AgentManager?
    private weak var hub: MCPHub?
    private var timer: Timer?
    private var lastSize: [UUID: (UInt64, Date)] = [:]
    private var warned: Set<UUID> = []
    private var handled: Set<UUID> = []
    private let d = UserDefaults.standard

    var enabled: Bool { d.object(forKey: "sup.on") as? Bool ?? true }
    var autoRecover: Bool { d.object(forKey: "sup.recover") as? Bool ?? true }
    /// Minuten ohne jede Ausgabe, bis der Supervisor eingreift (Warnung bei der Hälfte)
    var stallMinutes: Int { d.object(forKey: "sup.stall") as? Int ?? 20 }

    func start(agents: AgentManager, hub: MCPHub) {
        self.agents = agents; self.hub = hub
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.check()
            NightLearning.tickIfDue()
        }
    }

    private func check() {
        guard enabled, let agents else { return }
        let now = Date()
        for s in agents.sessions where s.running && s.mode == .autonom && !s.isOSAgent && !handled.contains(s.id) {
            guard let rec = MissionStore.shared.mission(s.id.uuidString) else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: rec.log)[.size] as? UInt64) ?? 0
            if let prev = lastSize[s.id], prev.0 == size {
                let idle = now.timeIntervalSince(prev.1) / 60
                if idle >= Double(stallMinutes) / 2, !warned.contains(s.id) {
                    warned.insert(s.id)
                    NotifyCenter.shared.post(.runFailed, title: String(format: L("%@ zeigt seit %d Minuten keinen Fortschritt"), s.displayName, Int(idle)),
                                             body: s.label, route: .page("chat:" + rec.id))
                }
                if idle >= Double(stallMinutes) { recover(s, rec, why: String(format: L("hing %d Minuten ohne Ausgabe"), Int(idle))) }
            } else {
                lastSize[s.id] = (size, now)
                warned.remove(s.id)
            }
            if let loop = Self.loopingError(rec.log) { recover(s, rec, why: L("dreht sich im Kreis: ") + loop) }
        }
        // Aufräumen
        let live = Set(agents.sessions.filter(\.running).map(\.id))
        lastSize = lastSize.filter { live.contains($0.key) }
    }

    /// Derselbe Fehler mindestens viermal in den letzten Zeilen → Schleife.
    static func loopingError(_ log: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: log) else { return nil }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: end > 8000 ? end - 8000 : 0)
        let tail = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        let errors = tail.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("✗") || $0.lowercased().contains("error:") }
            .map { $0.replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression) }
        let counts = Dictionary(grouping: errors, by: { $0 }).mapValues(\.count)
        return counts.first { $0.value >= 4 }.map { String($0.key.prefix(120)) }
    }

    private func recover(_ s: AgentSession, _ rec: MissionRecord, why: String) {
        handled.insert(s.id)
        interventions.insert("\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)) · \(s.displayName): \(why)", at: 0)
        interventions = Array(interventions.prefix(10))
        guard autoRecover, let agents, let hub else {
            NotifyCenter.shared.post(.runFailed, title: String(format: L("%@ hängt"), s.displayName), body: why, route: .page("chat:" + rec.id))
            return
        }
        s.terminate()
        let other = Verifier.reviewer(for: rec.agent)
        let target = other.rawValue == rec.agent ? rec.agent : other.rawValue
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Handoff.continueMission(rec, message: L("Der vorherige Agent kam nicht weiter (") + why + L("). Übernimm bitte, finde den Grund und erledige den Auftrag vollständig – ohne denselben Weg zu wiederholen."),
                                    target: target, agents: agents, hub: hub,
                                    note: "Supervisor: \(s.displayName) " + why + " → \(AgentKind(rawValue: target)?.title ?? target)") { n in
                NotifyCenter.shared.post(.runFailed, title: String(format: L("%@ hing – %@ macht weiter"), s.displayName, n.displayName),
                                         body: rec.title, route: .page("chat:" + n.id.uuidString))
            }
        }
    }
}

// MARK: - Progressive Delegation

enum Delegation {
    static let threshold = 5

    private static func key(_ dir: String) -> String { "deleg." + ProjectMemory.root(of: dir) }
    static func autoApply(_ dir: String) -> Bool { UserDefaults.standard.bool(forKey: key(dir) + ".apply") }
    static func autoPush(_ dir: String) -> Bool { UserDefaults.standard.bool(forKey: key(dir) + ".push") }
    static func set(_ dir: String, apply: Bool? = nil, push: Bool? = nil) {
        if let apply { UserDefaults.standard.set(apply, forKey: key(dir) + ".apply") }
        if let push { UserDefaults.standard.set(push, forKey: key(dir) + ".push") }
    }

    /// Grüne Runden hintereinander in diesem Projekt: grün beim ersten Versuch und von dir übernommen.
    static func streak(_ dir: String, missions: [MissionRecord]) -> Int {
        let root = ProjectMemory.root(of: dir)
        let list = missions.filter { m in
            let d = m.worktree?.base ?? m.directory
            return (d == root || d.hasPrefix(root + "/")) && m.ended != nil && m.parent == nil && m.delegated != true
        }.sorted { ($0.ended ?? .distantPast) > ($1.ended ?? .distantPast) }
        var n = 0
        for m in list {
            if m.outcome == nil && m.archived != true { continue }   // noch offen – zählt nicht, bricht nicht
            guard m.verify?.passed == true, (m.outcome == "merged" || m.outcome == "pr") else { break }
            n += 1
        }
        return n
    }

    static let sensitive = ["auth", "login", "password", "passwort", "payment", "stripe", "billing", "migration", "migrations/", ".env",
                            ".github/workflows", "secret", "token", "security", "rls", "policy", "deploy"]

    /// Klein genug und unkritisch? (höchstens 5 Dateien, 200 Zeilen, keine heiklen Pfade)
    static func small(_ wt: WorktreeInfo) -> (Bool, String) {
        let dir = Worktrees.top(wt)
        let names = Git.run(["diff", "--name-only", Worktrees.baseRef(wt) + "...HEAD"], in: dir, timeout: 15).out
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let stat = Git.run(["diff", "--shortstat", Worktrees.baseRef(wt) + "...HEAD"], in: dir, timeout: 15).out
        let nums = stat.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
        let lines = nums.count >= 3 ? nums[1] + nums[2] : (nums.count == 2 ? nums[1] : 0)
        if names.isEmpty { return (false, L("keine Änderungen")) }
        if names.count > 5 || lines > 200 { return (false, String(format: L("%d Dateien, %d Zeilen – zu groß"), names.count, lines)) }
        if let s = names.first(where: { n in sensitive.contains { n.lowercased().contains($0) } }) { return (false, L("heikler Bereich: ") + s) }
        return (true, String(format: L("%d Dateien, %d Zeilen"), names.count, lines))
    }

    /// Nach grüner Prüfung: selbst übernehmen, wenn das Projekt es erlaubt und das Vertrauen reicht.
    static func maybeApply(_ rec: MissionRecord, completion: @escaping (Bool, String) -> Void) {
        guard let wt = rec.worktree, autoApply(wt.base), rec.pr == nil, rec.plan != true else { return }
        let missions = MissionStore.shared.missions
        DispatchQueue.global(qos: .userInitiated).async {
            let n = streak(wt.base, missions: missions)
            guard n >= threshold else { return }
            let (ok, why) = small(wt)
            guard ok else {
                DispatchQueue.main.async { completion(false, L("Nicht selbst übernommen: ") + why) }
                return
            }
            let (merged, msg) = Worktrees.merge(wt, message: rec.title)
            var text = msg
            if merged, autoPush(wt.base) {
                let (pushed, pmsg) = GitSync.upload(repo: wt.base)
                text += " · " + pmsg
                _ = pushed
            }
            DispatchQueue.main.async {
                if merged {
                    MissionStore.shared.setOutcome(rec.id, "merged")
                    Learning.record(rec, outcome: "merged")
                    MissionStore.shared.clearWorktree(rec.id)
                    MissionStore.shared.setReason(rec.id, String(format: L("Selbst übernommen (Vertrauen: %d grüne Runden)"), n))
                }
                completion(merged, merged ? L("Selbst übernommen: ") + text : text)
            }
        }
    }
}

// MARK: - Nächtliches Lernen

struct LessonSuggestion: Codable, Hashable, Identifiable {
    var id = UUID().uuidString
    var root: String
    var text: String
    var kind: String
    var date = Date()
}

enum NightLearning {
    private static var url: URL { Paths.data.appendingPathComponent("memory-suggestions.json") }

    static func all() -> [LessonSuggestion] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let d = try? Data(contentsOf: url), let l = try? dec.decode([LessonSuggestion].self, from: d) else { return [] }
        return l
    }
    static func save(_ l: [LessonSuggestion]) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(l) { try? d.write(to: url, options: .atomic) }
    }
    static func suggestions(for dir: String) -> [LessonSuggestion] {
        let root = ProjectMemory.root(of: dir)
        return all().filter { $0.root == root }
    }
    static func accept(_ s: LessonSuggestion) {
        ProjectMemory.add(s.root, [(s.text, s.kind)], source: Intelligence.name)
        save(all().filter { $0.id != s.id })
    }
    static func reject(_ s: LessonSuggestion) { save(all().filter { $0.id != s.id }) }

    static var enabled: Bool { UserDefaults.standard.object(forKey: "night.learn") as? Bool ?? true }

    /// Einmal pro Nacht ab 3 Uhr (oder beim ersten Start danach)
    static func tickIfDue() {
        guard enabled else { return }
        let cal = Calendar.current
        guard cal.component(.hour, from: Date()) >= 3 else { return }
        let today = DateCoding.day(Date())
        guard UserDefaults.standard.string(forKey: "night.learned") != today else { return }
        UserDefaults.standard.set(today, forKey: "night.learned")
        start()
    }

    /// Aus dem Hauptthread aufrufen: nimmt eine Kopie der Aufträge mit in den Hintergrund.
    static func start() {
        let missions = MissionStore.shared.missions
        DispatchQueue.global(qos: .utility).async { run(missions: missions) }
    }

    static func run(missions: [MissionRecord], hours: Double = 30) {
        let from = Date().addingTimeInterval(-hours * 3600)
        let recent = missions.filter { ($0.ended ?? .distantPast) >= from && !$0.isOSAgent }
        let byRoot = Dictionary(grouping: recent) { ProjectMemory.root(of: $0.worktree?.base ?? $0.directory) }
        var found: [LessonSuggestion] = []
        for (root, list) in byRoot where FileManager.default.fileExists(atPath: root) {
            let known = ProjectMemory.load(root).map { $0.text.lowercased() }
            var lessons: [(String, String)] = []
            // 1. Prüfungen, die mehrmals rot waren
            let failed = list.flatMap { $0.verify?.checks ?? [] }.filter { $0.ok == false }
            for (name, items) in Dictionary(grouping: failed, by: \.name) where items.count >= 2 {
                lessons.append((String(format: L("Die Prüfung „%@“ (%@) war zuletzt mehrmals rot – vor dem Abschluss immer selbst ausführen und grün bekommen."),
                                       name, items[0].command), "stolperfalle"))
            }
            // 2. Prüfbefehle, die verlässlich grün liefen – damit jeder Agent sie kennt
            let passed = list.flatMap { $0.verify?.checks ?? [] }.filter { $0.ok == true }
            for (name, items) in Dictionary(grouping: passed, by: \.name) where items.count >= 3 {
                lessons.append((String(format: L("%@ in diesem Projekt: %@"), name, items[0].command), "befehl"))
            }
            // 3. Lokales Modell: aus Fehlern, die erst nach Nachbessern gelöst wurden, eine Lehre ziehen
            let fixed = list.filter { ($0.fixRound ?? 0) >= 1 && $0.verify?.passed == true }
            if !fixed.isEmpty {
                let ctx = fixed.prefix(5).compactMap { m -> String? in
                    guard let p = missions.first(where: { $0.id == m.parent })?.verify else { return nil }
                    return "- Task: \(m.title.prefix(100))\n  First attempt failed: \(p.failures.prefix(2).joined(separator: " | ").prefix(400))"
                }.joined(separator: "\n")
                if !ctx.isEmpty, let ans = Watchman.shared.localAsk("""
                These coding tasks failed their checks first and were fixed afterwards. Write at most 2 short, concrete lessons \
                (one per line, max 20 words, in \(Profile.languageCode == "de" ? "German" : "English")) that would have avoided the failure next time. \
                Only lessons about this project, no generic advice. If nothing useful, answer NONE.
                \(ctx)
                """) {
                    for line in ans.split(separator: "\n").map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: "-•* \t")) })
                        where line.count > 12 && line.count < 220 && !line.uppercased().contains("NONE") {
                        lessons.append((line, "lernen"))
                    }
                }
            }
            for (t, k) in lessons where !known.contains(where: { $0.contains(t.lowercased().prefix(40)) }) {
                found.append(LessonSuggestion(root: root, text: t, kind: k))
            }
        }
        guard !found.isEmpty else { return }
        var list = all()
        for f in found where !list.contains(where: { $0.root == f.root && $0.text == f.text }) { list.append(f) }
        save(Array(list.suffix(60)))
        NotifyCenter.shared.post(.briefing, title: String(format: L("Nachts gelernt: %d Vorschläge fürs Projektwissen"), found.count),
                                 body: L("In den Projekten unter „…“ › Projektwissen bestätigen oder verwerfen."), route: .page("projects"))
    }
}

/// Vorschläge aus der Nacht im Projektwissen-Fenster
struct LessonSuggestionsView: View {
    let directory: String
    var onAccept: () -> Void = {}
    @State private var items: [LessonSuggestion] = []

    var body: some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label(String(format: L("%@ schlägt vor (nachts gelernt)"), Intelligence.name), systemImage: "moon.stars").font(.callout.weight(.semibold))
                    ForEach(items) { s in
                        HStack(alignment: .top, spacing: 6) {
                            Text(s.kind).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
                            Text(s.text).font(.caption).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button { NightLearning.accept(s); reload(); onAccept() } label: { Image(systemName: "checkmark") }
                                .buttonStyle(.borderless).help(L("Ins Projektwissen übernehmen"))
                            Button { NightLearning.reject(s); reload() } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless).help(L("Verwerfen"))
                        }
                    }
                }
                .padding(Grid.s)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.07)))
            }
        }
        .task { reload() }
    }

    private func reload() {
        let dir = directory
        Task { items = await Task.detached { NightLearning.suggestions(for: dir) }.value }
    }
}

// MARK: - Einstellungen › Salenta Intelligence

struct IntelligenceSettings: View {
    @ObservedObject private var sup = Supervisor.shared
    @State private var tick = 0

    var body: some View {
        Section(Intelligence.name) {
            Text("Die Intelligenz-Schicht von Salenta Code. Läuft auf deinem Mac, ohne Server dazwischen: wählt Agent und Modell, prüft jedes Ergebnis, beobachtet laufende Agents, lernt aus jedem Auftrag und meldet sich, wenn etwas zu tun ist. Vorsortieren und nächtliches Lernen laufen mit einem lokalen Modell, wenn eins geladen ist.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Supervisor: hängende Agents erkennen", isOn: bind("sup.on", true))
            Toggle("Hängende Agents automatisch an einen anderen Anbieter übergeben", isOn: bind("sup.recover", true))
            Stepper(value: Binding(get: { sup.stallMinutes }, set: { UserDefaults.standard.set($0, forKey: "sup.stall"); tick += 1 }), in: 10...60, step: 5) {
                Text(String(format: L("Eingreifen nach %d Minuten ohne Ausgabe"), sup.stallMinutes))
            }
            if !sup.interventions.isEmpty {
                ForEach(sup.interventions, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
            Toggle("Nächtliches Lernen: morgens Vorschläge fürs Projektwissen", isOn: bind("night.learn", true))
            Button("Jetzt aus den letzten 30 Stunden lernen") { NightLearning.start() }
            Text(String(format: L("Selbst übernehmen stellst du pro Projekt ein (Projektkarte › „…“). Voraussetzung: %d grüne Runden hintereinander, höchstens 5 Dateien und 200 Zeilen, nichts aus Login, Zahlung, Datenbank-Migrationen, Secrets oder Deploy."), Delegation.threshold))
                .font(.caption).foregroundStyle(.secondary)
        }
        .id(tick)
    }

    private func bind(_ key: String, _ def: Bool) -> Binding<Bool> {
        Binding(get: { UserDefaults.standard.object(forKey: key) as? Bool ?? def }, set: { UserDefaults.standard.set($0, forKey: key); tick += 1 })
    }
}
