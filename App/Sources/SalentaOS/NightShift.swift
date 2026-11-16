import AgenticOSKit
import SwiftUI
import UserNotifications

// Nachtschicht: Abends Aufgaben in die Warteschlange legen – nachts arbeiten die Agents sie nacheinander ab
// (Mac bleibt wach, Prüfschleife, Selbstkorrektur, Limit-Ausweichen) – morgens liegt ein Briefing bereit.

struct NightItem: Codable, Identifiable, Hashable {
    enum State: String, Codable { case queued, running, green, red, failed, skipped }
    var id = UUID().uuidString
    var text: String
    var directory: String?
    var agent: String = "auto"          // "auto" oder AgentKind.rawValue
    var state: State = .queued
    var missionID: String?
    var started: Date?
    var ended: Date?
    var note: String?

    var title: String {
        let first = text.components(separatedBy: .newlines).first ?? text
        return first.count > 80 ? String(first.prefix(78)) + "…" : first
    }
}

struct NightReport: Codable, Hashable {
    var started: Date
    var ended: Date?
    var items: [NightItem]
    var seen = false
    var green: Int { items.filter { $0.state == .green }.count }
    var red: Int { items.filter { $0.state == .red || $0.state == .failed }.count }
}

final class NightShift: ObservableObject {
    static let shared = NightShift()

    @Published var items: [NightItem] = []
    @Published private(set) var active = false
    @Published var scheduledAt: Date?
    @Published var report: NightReport?
    @Published var autoApprove = false

    weak var agents: AgentManager?
    weak var projects: ProjectCatalog?
    private var timer: Timer?
    private var startedAwake = false
    private var url: URL { Paths.data.appendingPathComponent("nightshift.json") }

    private struct Saved: Codable {
        var items: [NightItem]; var active: Bool; var scheduledAt: Date?; var report: NightReport?; var autoApprove: Bool?
    }

    init() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: url), let s = try? dec.decode(Saved.self, from: d) {
            items = s.items; active = s.active; scheduledAt = s.scheduledAt; report = s.report; autoApprove = s.autoApprove ?? false
        }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.tick() }
    }

    func attach(agents: AgentManager, projects: ProjectCatalog) {
        self.agents = agents; self.projects = projects
    }

    func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        if let d = try? enc.encode(Saved(items: items, active: active, scheduledAt: scheduledAt, report: report, autoApprove: autoApprove)) {
            try? d.write(to: url, options: .atomic)
        }
    }

    // MARK: Warteschlange

    func add(_ text: String, directory: String?, agent: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        items.append(NightItem(text: t, directory: directory, agent: agent))
        save()
    }

    func remove(_ id: String) { items.removeAll { $0.id == id && $0.state != .running }; save() }

    func move(_ from: IndexSet, _ to: Int) { items.move(fromOffsets: from, toOffset: to); save() }

    var queued: [NightItem] { items.filter { $0.state == .queued } }

    /// Morgen früh (Ende der Nacht): bis dann werden neue Aufgaben gestartet.
    static var morning: Date {
        let cal = Calendar.current
        let h = UserDefaults.standard.object(forKey: "night.morning") as? Int ?? 7
        let t = cal.date(bySettingHour: h, minute: 0, second: 0, of: Date())!
        return t > Date().addingTimeInterval(3600) ? t : cal.date(byAdding: .day, value: 1, to: t)!
    }

    static var evening: Date {
        let cal = Calendar.current
        let h = UserDefaults.standard.object(forKey: "night.evening") as? Int ?? 22
        let t = cal.date(bySettingHour: h, minute: 0, second: 0, of: Date())!
        return t > Date() ? t : Date()
    }

    func schedule() { scheduledAt = Self.evening; save(); if scheduledAt! <= Date() { begin() } }

    func begin() {
        guard !active, !queued.isEmpty else { return }
        active = true
        scheduledAt = nil
        report = NightReport(started: Date(), items: [])
        // Mac bis morgen wach halten (zugeklappt, wenn eingerichtet)
        if !Awake.shared.active { Awake.shared.start(until: Self.morning.addingTimeInterval(3600)); startedAwake = true }
        if autoApprove { ApprovalMode.set(Self.morning) }
        log("Nachtschicht gestartet: \(queued.count) Aufgaben")
        save()
        tick()
    }

    func stop() {
        active = false
        scheduledAt = nil
        for i in items.indices where items[i].state == .running { items[i].state = .skipped; items[i].note = L("abgebrochen") }
        finish()
    }

    // MARK: Ablauf

    private func tick() {
        guard Energy.backgroundAgentsOK else { return }      // am Akku wartet die Nachtschicht aufs Netzteil
        if let s = scheduledAt, s <= Date(), !active { begin(); return }
        guard active, let agents else { return }
        // läuft gerade etwas?
        if let i = items.firstIndex(where: { $0.state == .running }) {
            guard let result = evaluate(items[i]) else { return }   // noch nicht fertig
            items[i].state = result.state
            items[i].ended = Date()
            items[i].note = result.note
            items[i].missionID = result.missionID ?? items[i].missionID
            report?.items.removeAll { $0.id == items[i].id }
            report?.items.append(items[i])
            save()
        }
        // nächste Aufgabe – solange es noch Nacht ist
        if Date() < Self.morning, let next = items.firstIndex(where: { $0.state == .queued }) {
            launch(next, agents: agents)
        } else if !items.contains(where: { $0.state == .running }) {
            finish()
        }
    }

    private func launch(_ i: Int, agents: AgentManager) {
        var item = items[i]
        var kind = AgentKind(rawValue: item.agent)
        var dir = item.directory
        if item.agent == "auto" || kind == nil {
            let d = Router.decide(item.text, projects: projects?.local ?? [], recent: agents.directories)
            kind = d.target.agent
            if dir == nil { dir = d.directory }
        }
        var k = kind ?? .claude
        if !OpenModels.available(k) || Usage.shared.isTight(k) {
            k = ([k] + Usage.alternatives(k)).first { OpenModels.available($0) && !Usage.shared.isTight($0) } ?? .claude
        }
        let prompt = item.text + "\n\n---\n" + L("""
        Nachtschicht: Niemand ist wach, der Rückfragen beantworten kann. Triff sinnvolle Annahmen und arbeite den Auftrag vollständig ab. \
        Prüfe am Ende Build und Tests. Was offen bleibt oder eine Entscheidung braucht, schreib am Ende unter „Offen:“.
        """)
        let s = agents.start(k, in: dir, prompt: prompt, mode: .autonom, label: "🌙 " + item.title)
        item.state = .running
        item.started = Date()
        item.missionID = s.id.uuidString
        item.agent = k.rawValue
        items[i] = item
        log("Start: \(item.title) → \(k.title)")
        save()
    }

    /// Ist die Aufgabe fertig (inkl. Prüfung und ggf. Korrekturrunde/Übergabe)? nil = läuft noch.
    private func evaluate(_ item: NightItem) -> (state: NightItem.State, note: String?, missionID: String?)? {
        guard let start = item.missionID else { return (.failed, L("nicht gestartet"), nil) }
        // der neueste Teil der Kette (Korrekturrunde, Übergabe bei Limit …)
        var cur = start
        var guardCount = 0
        while guardCount < 10, let next = MissionStore.shared.missions.last(where: { $0.parent == cur && $0.delegated != true }) {
            cur = next.id; guardCount += 1
        }
        guard let rec = MissionStore.shared.mission(cur) else { return nil }
        if agents?.sessions.contains(where: { $0.id.uuidString == cur && $0.running }) == true { return nil }
        guard let ended = rec.ended else { return nil }
        // kurz warten, bis die Prüfschleife angelaufen ist
        if rec.worktree != nil {
            if rec.verify == nil && Date().timeIntervalSince(ended) < 90 { return nil }
            if let v = rec.verify, v.finished == nil { return nil }
            if rec.verify?.passed == false && Verifier.autoFix && (rec.fixRound ?? 0) < 2 && Date().timeIntervalSince(ended) < 240 { return nil }   // Autokorrektur kommt gleich (bis zu zwei Runden)
        }
        if rec.ok == false { return (.failed, rec.digest?.summary ?? L("abgebrochen"), cur) }
        if rec.verify?.passed == false { return (.red, rec.verify?.diagnosis?.why ?? L("Prüfung rot"), cur) }
        return (.green, rec.digest?.summary, cur)
    }

    private func finish() {
        active = false
        report?.ended = Date()
        // erledigte Aufgaben aus der Warteschlange nehmen (sie stehen im Bericht)
        items.removeAll { $0.state != .queued }
        if autoApprove { ApprovalMode.set(nil) }
        if startedAwake { Awake.shared.stop(); startedAwake = false }
        save()
        guard let r = report, !r.items.isEmpty else { return }
        let text = String(format: L("Nachtschicht fertig: %d grün, %d brauchen dich"), r.green, r.red)
        log(text)
        let c = UNMutableNotificationContent()
        c.title = "🌙 Salenta Code"; c.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        Notifier.push("🌙 Nachtschicht", text, priority: 3, tags: "crescent_moon")
        ModStore.shared.fire(.nightDone, rec: nil, result: text)
    }

    func log(_ text: String) {
        let f = Paths.root.appendingPathComponent("logs/nightshift.log")
        let line = "\(Date().formatted(.iso8601)) \(text)\n"
        if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: f, atomically: true, encoding: .utf8) }
    }
}

// MARK: - Oberfläche

/// Warteschlange + Start (Seite „Nachtschicht“).
struct NightShiftView: View {
    @ObservedObject private var night = NightShift.shared
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var app: AppModel
    @State private var text = ""
    @State private var dir = ""
    @State private var agent = "auto"
    @AppStorage("night.evening") private var evening = 22
    @AppStorage("night.morning") private var morning = 7

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Grid.l) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "moon.stars.fill").font(.title).foregroundStyle(.indigo)
                        Text("Nachtschicht").font(.largeTitle.weight(.semibold))
                    }
                    Text("Leg abends Aufgaben in die Warteschlange. Nachts arbeiten die Agents sie nacheinander ab – der Mac bleibt wach, jede Änderung wird geprüft und bei Bedarf automatisch korrigiert. Morgens wartet ein Briefing.")
                        .foregroundStyle(.secondary)
                }
                if let r = night.report, r.ended != nil || night.active { NightBriefingCard(report: r) }

                // neue Aufgabe
                VStack(alignment: .leading, spacing: Grid.s) {
                    TextField("Was soll heute Nacht erledigt werden? (eine Aufgabe pro Eintrag)", text: $text, axis: .vertical)
                        .lineLimit(2...6).textFieldStyle(.roundedBorder)
                        .dictation($text)
                    HStack {
                        Picker("Projekt", selection: $dir) {
                            Text("Automatisch").tag("")
                            ForEach(agents.directories, id: \.self) { d in Text((d as NSString).lastPathComponent).tag(d) }
                        }
                        .fixedSize()
                        Picker("Agent", selection: $agent) {
                            Text("Automatisch").tag("auto")
                            ForEach(AgentKind.coders.filter { OpenModels.available($0) }) { a in Text(a.title).tag(a.rawValue) }
                        }
                        .fixedSize()
                        Spacer()
                        Button { night.add(text, directory: dir.isEmpty ? nil : dir, agent: agent); text = "" } label: {
                            Label("Hinzufügen", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }
                .padding(Grid.m)
                .background(ModernCardBackground(radius: 12))

                // Warteschlange
                VStack(alignment: .leading, spacing: 6) {
                    Text("Warteschlange (\(night.items.count))").font(.headline)
                    if night.items.isEmpty {
                        Text("Noch leer – z. B. „Tests für den Checkout schreiben“, „Sentry einbinden“, „README aufräumen“.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    List {
                        ForEach(night.items) { it in
                            HStack(spacing: 8) {
                                stateIcon(it.state)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(it.title).lineLimit(2)
                                    Text([it.directory.map { ($0 as NSString).lastPathComponent } ?? L("Projekt automatisch"),
                                          AgentKind(rawValue: it.agent)?.title ?? L("Agent automatisch")].joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let m = it.missionID {
                                    Button(L("Ansehen")) { app.page = .chat(m) }.buttonStyle(.link)
                                }
                                if it.state == .queued {
                                    Button { night.remove(it.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help(L("Aus der Nachtschicht entfernen"))
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .onMove { night.move($0, $1) }
                    }
                    .frame(minHeight: CGFloat(max(1, night.items.count)) * 44 + 8, maxHeight: 360)
                    .listStyle(.inset)
                }

                // Start
                VStack(alignment: .leading, spacing: Grid.s) {
                    Toggle(isOn: Binding(get: { night.autoApprove }, set: { night.autoApprove = $0; night.save() })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Freigaben nachts automatisch erteilen")
                            Text("Sonst wartet ein Agent bis zu 15 Minuten auf dich und bricht dann ab. Deine Sperr-Regeln (z. B. Shopify-Live-Theme, Force-Push) gelten trotzdem. Endet morgens automatisch.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Stepper("Start um \(evening) Uhr", value: $evening, in: 17...23).fixedSize()
                        Stepper("Ende bis \(morning) Uhr", value: $morning, in: 4...10).fixedSize()
                    }
                    HStack {
                        if night.active {
                            Label("Läuft – \(night.items.filter { $0.state == .running }.count) aktiv, \(night.queued.count) wartend", systemImage: "moon.zzz.fill")
                                .foregroundStyle(.indigo)
                            Spacer()
                            Button("Beenden", role: .destructive) { night.stop() }
                        } else if let s = night.scheduledAt {
                            Label("Startet um \(s.formatted(date: .omitted, time: .shortened))", systemImage: "clock")
                            Spacer()
                            Button("Jetzt starten") { night.begin() }
                            Button("Abbrechen") { night.scheduledAt = nil; night.save() }
                        } else {
                            Spacer()
                            Button("Jetzt starten") { night.begin() }.disabled(night.queued.isEmpty)
                            Button { night.schedule() } label: { Label("Heute Nacht um \(evening) Uhr", systemImage: "moon.stars") }
                                .buttonStyle(.borderedProminent).tint(.indigo).disabled(night.queued.isEmpty)
                        }
                    }
                }
                .padding(Grid.m)
                .background(ModernCardBackground(radius: 12))
            }
            .padding(Grid.xl)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle("Nachtschicht")
    }

    @ViewBuilder private func stateIcon(_ s: NightItem.State) -> some View {
        switch s {
        case .queued: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .green: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .red: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .skipped: Image(systemName: "forward.end.circle").foregroundStyle(.secondary)
        }
    }
}

/// Morgen-Briefing: was nachts passiert ist – mit einem Klick zum Übernehmen oder Nachbessern.
struct NightBriefingCard: View {
    let report: NightReport
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var night = NightShift.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.s) {
            HStack {
                Image(systemName: report.ended == nil ? "moon.zzz.fill" : "sunrise.fill").foregroundStyle(report.ended == nil ? .indigo : .orange)
                Text(report.ended == nil ? L("Nachtschicht läuft") : L("Morgen-Briefing")).font(.headline)
                Spacer()
                if let e = report.ended {
                    Text("\(report.started.formatted(date: .omitted, time: .shortened)) – \(e.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { night.report?.seen = true; night.report = nil; night.save() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help(L("Briefing schließen"))
                }
            }
            HStack(spacing: Grid.l) {
                Label("\(report.green) " + L("fertig und grün"), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                if report.red > 0 { Label("\(report.red) " + L("brauchen dich"), systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange) }
            }
            .font(.callout.weight(.medium))
            ForEach(report.items) { it in
                Button { if let m = it.missionID { app.page = .chat(m) } } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: it.state == .green ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(it.state == .green ? .green : .red)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(it.title).lineLimit(1)
                            if let n = it.note { Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                        Spacer()
                        Text(it.state == .green ? L("Übernehmen") : L("Ansehen")).font(.caption.weight(.medium))
                            .foregroundStyle(it.state == .green ? .green : .orange)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Grid.m)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.indigo.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.indigo.opacity(0.25)))
    }
}
