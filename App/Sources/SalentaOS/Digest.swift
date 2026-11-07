import AgenticOSKit
import SwiftUI

// Ergebnis-Karte: Am Ende eines Auftrags steht oft ein langer Bericht mit Befunden und Vorschlägen.
// Salenta Code macht daraus eine kurze Zusammenfassung, aufklappbare Befunde und Vorschläge zum Abhaken –
// mit einem Klick umsetzen (passender Agent und Modell), einzeln als Aufträge starten oder erst planen lassen.

struct DigestProposal: Codable, Hashable, Identifiable {
    var id: String { title }
    var title: String
    var detail: String = ""
    var agent: String = ""
    var model: String = ""
}

struct DigestSection: Codable, Hashable, Identifiable {
    var id: String { title }
    var title: String
    var items: [String]
}

struct MissionDigest: Codable, Hashable {
    var summary: String
    var sections: [DigestSection] = []
    var proposals: [DigestProposal] = []
    var question: String?
    /// Hinweise zum Werkzeug selbst (Salenta Code / Agent-CLIs) – kein Vorschlag fürs Projekt
    var toolNotes: [String]? = nil
    var byAI = false
    var created = Date()
    var version: Int? = nil
}

enum Digest {
    private static var running: Set<String> = []

    /// Lohnt sich eine Ergebnis-Karte? (längerer Bericht am Ende)
    /// Version der Aufbereitung – ältere Karten werden einmal neu erzeugt.
    static let version = 2

    static func worth(_ rec: MissionRecord) -> Bool {
        guard rec.ended != nil || rec.ok != nil, rec.ok != false else { return false }
        return (finalText(rec)?.count ?? 0) > 700
    }

    /// Schlussbericht aus dem Verlauf (Ende des Logs, ohne Farbcodes).
    static func finalText(_ rec: MissionRecord) -> String? {
        guard let t = try? String(contentsOfFile: rec.log, encoding: .utf8) else { return nil }
        let clean = t.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        return String(clean.suffix(14_000))
    }

    /// Im Hintergrund erzeugen: sofort nach Regeln, dann genauer per Haiku.
    static func make(_ id: String) {
        guard !running.contains(id), let rec = MissionStore.shared.mission(id), let text = finalText(rec) else { return }
        running.insert(id)
        let quick = heuristic(text)
        MissionStore.shared.setDigest(id, quick)
        var models: [AgentKind: [String]] = [:]
        let installed = AgentKind.coders.filter { OpenModels.available($0) && Billing.autoOK($0) }
        for a in installed { models[a] = ModelCatalog.shared.latest(for: a, limit: 6).map(\.value) }
        DispatchQueue.global(qos: .utility).async {
            let ai = Self.ai(rec: rec, text: text, installed: installed, models: models)
            DispatchQueue.main.async {
                running.remove(id)
                if let ai { MissionStore.shared.setDigest(id, ai) }
            }
        }
    }

    /// Ohne KI: fett gesetzte Überschriften als Abschnitte, Listenpunkte als Einträge; Vorschläge aus „machbar/Vorschlag/Offen“.
    static func heuristic(_ text: String) -> MissionDigest {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var sections: [DigestSection] = []
        var cur: DigestSection?
        var summary = ""
        for l in lines where !l.isEmpty {
            let isHeading = (l.hasPrefix("**") && l.hasSuffix("**")) || l.hasPrefix("#")
            let bold = l.range(of: "^\\*\\*([^*]{2,60})\\*\\*:?\\s*(.*)$", options: .regularExpression) != nil
            if isHeading {
                if let c = cur, !c.items.isEmpty { sections.append(c) }
                cur = DigestSection(title: l.trimmingCharacters(in: CharacterSet(charactersIn: "#* :")), items: [])
            } else if l.hasPrefix("- ") || l.hasPrefix("• ") || l.range(of: "^\\d+[.)] ", options: .regularExpression) != nil || bold {
                let item = l.replacingOccurrences(of: "^(- |• |\\d+[.)] )", with: "", options: .regularExpression)
                if cur == nil { cur = DigestSection(title: L("Ergebnis"), items: []) }
                cur?.items.append(item)
            } else if summary.isEmpty, l.count > 40, !l.hasPrefix("Führt aus"), !l.hasPrefix("Ändert"), !l.hasPrefix("Liest") {
                summary = l
            }
        }
        if let c = cur, !c.items.isEmpty { sections.append(c) }
        let keys = ["machbar", "vorschlag", "empfehl", "nächste", "offen", "to-do", "todo", "plan", "sollte"]
        var proposals: [DigestProposal] = []
        var toolNotes: [String] = []
        for s in sections where keys.contains(where: { s.title.lowercased().contains($0) }) {
            for i in s.items.prefix(8) {
                let t = i.replacingOccurrences(of: "**", with: "")
                if isToolTopic(t) { toolNotes.append(t) } else { proposals.append(DigestProposal(title: String(t.prefix(140)))) }
            }
        }
        for l in lines where isToolTopic(l) && l.lowercased().hasPrefix("**problem") { toolNotes.append(l.replacingOccurrences(of: "**", with: "")) }
        return MissionDigest(summary: summary.isEmpty ? L("Der Agent hat einen Bericht geschrieben.") : String(summary.prefix(400)),
                             sections: Array(sections.filter { s in !keys.contains { k in s.title.lowercased().contains(k) } }.prefix(8)),
                             proposals: proposals, toolNotes: toolNotes.isEmpty ? nil : Array(toolNotes.prefix(3)))
    }

    /// Geht es um das Werkzeug, das die Agents startet (Salenta Code, CLI-Optionen), statt um das Projekt?
    static func isToolTopic(_ t: String) -> Bool {
        let l = t.lowercased()
        return l.contains("salenta os") || l.contains("salenta-os") || l.contains("salenta code") || l.contains("salenta-code") || l.contains("--full-auto") || l.contains("startoption")
    }

    private static func ai(rec: MissionRecord, text: String, installed: [AgentKind], models: [AgentKind: [String]]) -> MissionDigest? {
        guard Detection.which("claude") != nil, Usage.shared.cachedPressure(.claude) < 1.0 else { return nil }
        let lang = Profile.languageCode == "de" ? "German (informal du)" : "English"
        let options = installed.map { a in
            "- \(a.rawValue) (\(a.title)): \(a.strength)" + ((models[a] ?? []).isEmpty ? "" : " · models: " + (models[a] ?? []).joined(separator: ", "))
                + (Usage.shared.isTight(a) ? " · NEARLY AT LIMIT, avoid" : "")
        }.joined(separator: "\n")
        let project = (Digest.workDir(rec) as NSString).lastPathComponent
        let prompt = """
        An AI agent finished this task: \(rec.title)
        The task is about the project/repo "\(project)". The agent was started by a desktop tool called "Salenta Code" \
        (it launches coding agents like Claude Code, Codex, Kimi). Salenta Code is NOT the project.
        Its final report (end of the log) is below. Turn it into a clear digest for a busy founder who is not a developer.
        - summary: 2-3 short sentences, what was done and the most important result.
        - sections: group the findings (max 6 sections, max 6 short items each, each item one line, plain words).
        - proposals: concrete next actions the agent suggested or that clearly follow (max 8), each with the best agent from the list \
        and a fitting model (cheap/fast for small fixes, strong for complex work). Empty if nothing to do.
        - question: if the agent asked the user something, the question in one sentence, else empty.
        - learnings: up to 5 DURABLE facts about the project "\(project)" that future agents should know (decisions taken, \
        pitfalls, correct commands, conventions, where things live). Only lasting, project-specific facts – no status, no todos, \
        nothing about Salenta Code. kind is one of: entscheidung, stolperfalle, befehl, regel, lernen.
        - toolNotes: problems the agent hit with the TOOL that ran it (Salenta Code, an agent CLI that would not start, wrong CLI options) – \
        one short line each. These are NEVER proposals: proposals are only actions inside the project "\(project)".

        Available agents:
        \(options)

        Report:
        \(text.suffix(12_000))

        Answer ONLY with JSON in \(lang):
        {"summary":"","sections":[{"title":"","items":[""]}],"proposals":[{"title":"short imperative","detail":"1 sentence","agent":"<id>","model":""}],"question":"","toolNotes":[""],"learnings":[{"text":"","kind":"lernen"}]}
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("aos-digest-\(UUID().uuidString).md")
        try? prompt.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let r = Proc.zsh(LocalFirst.cliEnv() + "claude -p --model haiku --output-format json --max-turns 3 --strict-mcp-config < \(Shell.quote(file.path))",
                         in: NSTemporaryDirectory(), timeout: 150)
        guard let res = Verifier.claudeResult(r.out), let a = res.firstIndex(of: "{"), let b = res.lastIndex(of: "}"),
              let data = res[a...b].data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let summary = j["summary"] as? String else { return nil }
        let sections = ((j["sections"] as? [[String: Any]]) ?? []).compactMap { s -> DigestSection? in
            guard let t = s["title"] as? String, let items = s["items"] as? [String], !items.isEmpty else { return nil }
            return DigestSection(title: t, items: items)
        }
        let proposals = ((j["proposals"] as? [[String: Any]]) ?? []).compactMap { p -> DigestProposal? in
            guard let t = p["title"] as? String, !t.isEmpty else { return nil }
            var agent = (p["agent"] as? String ?? "").lowercased()
            if AgentKind(rawValue: agent).map({ installed.contains($0) }) != true { agent = installed.contains(.claude) ? "claude" : (installed.first?.rawValue ?? "claude") }
            var model = p["model"] as? String ?? ""
            if let k = AgentKind(rawValue: agent), !model.isEmpty, !(models[k] ?? []).contains(model) { model = "" }
            // Nur hochstufen, nie herunter: kleine Modelle (haiku, mini, flash …) nicht vorschlagen – sonst gilt der Standard des Agents.
            let ml = model.lowercased()
            if ["haiku", "sonnet", "mini", "nano", "flash", "lite", "small"].contains(where: { ml.contains($0) }) { model = "" }
            return DigestProposal(title: t, detail: p["detail"] as? String ?? "", agent: agent, model: model)
        }
        let q = (j["question"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Sicherheitsnetz: was trotzdem das Werkzeug betrifft, wandert aus den Vorschlägen in die Hinweise
        var notes = ((j["toolNotes"] as? [String]) ?? []).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let projectProposals = proposals.filter { p in
            if isToolTopic(p.title + " " + p.detail) { notes.append(p.title); return false }
            return true
        }
        // Dauerhafte Erkenntnisse ins gemeinsame Projektwissen (für alle Agents)
        let learnings = ((j["learnings"] as? [[String: Any]]) ?? []).compactMap { l -> (text: String, kind: String)? in
            guard let t = l["text"] as? String, !t.isEmpty, !isToolTopic(t) else { return nil }
            return (t, l["kind"] as? String ?? "lernen")
        }
        if !learnings.isEmpty {
            DispatchQueue.main.async { ProjectMemory.add(Digest.workDir(rec), learnings, source: rec.agentTitle + " · " + rec.title) }
        }
        if !notes.isEmpty { logToolNotes(notes, rec: rec) }
        return MissionDigest(summary: summary, sections: sections, proposals: projectProposals, question: q.isEmpty ? nil : q,
                             toolNotes: notes.isEmpty ? nil : notes, byAI: true, version: Digest.version)
    }

    /// Probleme mit Salenta Code selbst (statt mit dem Projekt) – nicht für den Nutzer, sondern fürs Diagnose-Protokoll.
    static func logToolNotes(_ notes: [String], rec: MissionRecord) {
        let url = Paths.root.appendingPathComponent("logs/tool-notes.log")
        let text = notes.map { "\(DateCoding.stamp(Date())) [\(rec.agent)] \(rec.title.prefix(60)): \($0)\n" }.joined()
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
        else { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }

    /// Arbeitsordner für Folgeaufträge: das Repo, in dem gearbeitet wurde (bei OS-Agent: das der Helfer).
    static func workDir(_ rec: MissionRecord) -> String {
        if let b = rec.worktree?.base { return b }
        let kids = MissionStore.shared.missions.filter { $0.parent == rec.id }
        if let b = kids.compactMap({ $0.worktree?.base }).first { return b }
        return rec.directory
    }
}

/// Die Karte am Ende eines Auftrags.
struct DigestCard: View {
    enum Part { case summary, next }
    let rec: MissionRecord
    var part: Part = .summary
    /// Nummer des Schritts „Wie geht's weiter?“ (2, wenn vorher übernommen werden muss)
    var step: Int? = nil
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var hub: MCPHub
    @EnvironmentObject private var app: AppModel
    @State private var expanded = false
    @State private var agentOverride: String?
    @State private var installed: [AgentKind] = []
    @State private var showAll = false
    @ObservedObject private var changeState = ChangeState.shared

    /// Kein „Schritt 2“, wenn es nichts zu übernehmen gab.
    private var stepShown: Int? { changeState.empty.contains(rec.id) ? nil : step }

    var body: some View {
        if let d = rec.digest {
            Group {
                switch part {
                case .summary: summary(d)
                case .next: if !d.proposals.isEmpty { next(d) }
                }
            }
            .task {
                guard installed.isEmpty else { return }
                installed = await Task.detached { AgentKind.coders.filter { OpenModels.available($0) } }.value
            }
        }
    }

    // MARK: Was gemacht wurde

    private func summary(_ d: MissionDigest) -> some View {
        VStack(alignment: .leading, spacing: Grid.s) {
            HStack(spacing: 6) {
                Image(systemName: headIcon).foregroundStyle(headColor)
                Text(headline).font(.headline)
                if !d.byAI { ProgressView().controlSize(.mini); Text(L("wird aufbereitet …")).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if !d.sections.isEmpty {
                    Button(expanded ? L("Weniger") : L("Details") + " (\(d.sections.reduce(0) { $0 + $1.items.count }))") {
                        withAnimation(.snappy) { expanded.toggle() }
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
            Text(d.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let q = d.question {
                Label(q, systemImage: "questionmark.bubble.fill").font(.callout).foregroundStyle(.orange)
                    .help(L("Antworte unten im Eingabefeld"))
            }
            if expanded {
                ForEach(d.sections) { s in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(s.items, id: \.self) { i in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("•").foregroundStyle(.secondary)
                                    Text(LocalizedStringKey(i)).font(.callout).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.leading, 4).padding(.top, 2)
                    } label: {
                        Text(s.title).font(.callout.weight(.semibold)) + Text("  \(s.items.count)").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            // Hinweise zum Werkzeug selbst sind nichts, was du reparieren kannst – sie gehen ins Diagnose-Protokoll.
            if UserDefaults.standard.bool(forKey: "dev.toolNotes"), let notes = d.toolNotes, !notes.isEmpty {
                Label(L("Entwickler-Hinweis: ") + notes.joined(separator: " · "), systemImage: "wrench.adjustable")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(Grid.l)
        .background(ModernCardBackground(radius: 14))
        .frame(maxWidth: 780)
        .padding(.horizontal, Grid.l)
    }

    private var headline: String {
        if rec.ok == false { return L("Nicht fertig geworden") }
        if rec.plan == true { return L("Plan ist fertig") }
        return L("Fertig – das wurde gemacht")
    }
    private var headIcon: String { rec.ok == false ? "exclamationmark.triangle.fill" : rec.plan == true ? "list.bullet.clipboard" : "checkmark.circle.fill" }
    private var headColor: Color { rec.ok == false ? .orange : .green }

    // MARK: Wie geht's weiter?

    private func next(_ d: MissionDigest) -> some View {
        let shown = showAll ? d.proposals : Array(d.proposals.prefix(4))
        let agentKey = agentOverride ?? mostCommonAgent(d.proposals) ?? d.proposals[0].agent
        let kind = AgentKind(rawValue: agentKey) ?? .claude
        let suggested: String = d.proposals.first(where: { $0.agent == agentKey })?.model ?? ""
        let model: String = agentOverride == nil ? suggested : ModelCatalog.selected(for: kind)
        let project: String = (Digest.workDir(rec) as NSString).lastPathComponent
        let intro: String = String(format: L("Der Agent schlägt %d nächste Schritte für %@ vor. Du musst nichts davon machen – starte einzelne oder alle auf einmal."), d.proposals.count, project)
        let withText: String = L("mit") + " " + kind.title + (model.isEmpty ? "" : " · " + model)
        return VStack(alignment: .leading, spacing: Grid.s) {
            HStack(alignment: .top, spacing: Grid.s) {
                if let step = stepShown { StepBadge(number: step) }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wie geht's weiter? (optional)").font(.headline)
                    Text(intro)
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(shown) { p in
                HStack(alignment: .top, spacing: Grid.s) {
                    Image(systemName: "arrow.right.circle").foregroundStyle(.secondary).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.title).font(.callout)
                        if !p.detail.isEmpty { Text(p.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                    Spacer()
                    Button(L("Starten")) { separately([p]) }
                        .controlSize(.small)
                        .help(startHelp(p))
                }
            }
            if d.proposals.count > 4 {
                Button(showAll ? L("Weniger zeigen") : String(format: L("Alle %d zeigen"), d.proposals.count)) { withAnimation(.snappy) { showAll.toggle() } }
                    .buttonStyle(.link).font(.caption)
            }
            HStack(spacing: Grid.s) {
                Button { implement(d.proposals, agent: agentKey, model: model) } label: {
                    Label(L("Alle Vorschläge umsetzen"), systemImage: "hammer.fill")
                }
                .buttonStyle(.borderedProminent)
                Text(withText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button(L("Erst einen Plan machen lassen (ändert noch nichts)")) { plan(d.proposals, agent: agentKey, model: model) }
                    Button(L("Jeden Vorschlag als eigenen Auftrag, parallel")) { separately(d.proposals) }
                    Divider()
                    Menu(L("Anderen Agent wählen")) {
                        Button(L("Empfehlung des Agents")) { agentOverride = nil }
                        Divider()
                        ForEach(installed) { a in Button { agentOverride = a.rawValue } label: { Label(a.title, systemImage: a.symbol) } }
                    }
                } label: { Label(L("Mehr"), systemImage: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
        .padding(Grid.l)
        .background(ModernCardBackground(radius: 14))
        .frame(maxWidth: 780)
        .padding(.horizontal, Grid.l)
    }

    private func startHelp(_ p: DigestProposal) -> String {
        let agent: String = AgentKind(rawValue: p.agent)?.title ?? "Claude Code"
        let model: String = p.model.isEmpty ? "" : " · " + p.model
        return L("Als eigenen Auftrag starten mit") + " " + agent + model
    }

    private func mostCommonAgent(_ ps: [DigestProposal]) -> String? {
        Dictionary(grouping: ps.filter { !$0.agent.isEmpty }, by: \.agent).max { $0.value.count < $1.value.count }?.key
    }

    private func list(_ ps: [DigestProposal]) -> String {
        ps.enumerated().map { "\($0.offset + 1). \($0.element.title)" + ($0.element.detail.isEmpty ? "" : " – " + $0.element.detail) }.joined(separator: "\n")
    }

    private func implement(_ ps: [DigestProposal], agent: String, model: String) {
        let msg = L("Setze jetzt diese Punkte aus deinem Bericht um:") + "\n" + list(ps) + "\n\n" + L("Arbeite sie nacheinander ab und prüfe am Ende Build und Tests.")
        Handoff.continueMission(rec, message: msg, target: agent, agents: agents, hub: hub,
                                note: L("Vorschläge werden umgesetzt"), model: model.isEmpty ? nil : model) { s in app.page = .chat(s.id.uuidString) }
    }

    private func plan(_ ps: [DigestProposal], agent: String, model: String) {
        let msg = L("Erstelle zuerst einen genauen Plan für diese Punkte – ändere noch nichts:") + "\n" + list(ps)
        Handoff.continueMission(rec, message: msg, target: agent, agents: agents, hub: hub,
                                note: L("Plan wird erstellt"), model: model.isEmpty ? nil : model) { s in
            MissionStore.shared.setPlan(s.id.uuidString, group: nil)
            app.page = .chat(s.id.uuidString)
        }
    }

    private func separately(_ ps: [DigestProposal]) {
        let dir = Digest.workDir(rec)
        var first: AgentSession?
        for p in ps {
            let kind = AgentKind(rawValue: agentOverride ?? p.agent) ?? .claude
            let prompt = p.title + (p.detail.isEmpty ? "" : "\n\n" + p.detail)
                + "\n\n---\n" + L("Hintergrund: Vorschlag aus dem Auftrag") + " „\(rec.title)“."
            let s = agents.start(kind, in: dir, prompt: prompt, mode: .autonom, label: p.title,
                                 model: agentOverride == nil && !p.model.isEmpty ? p.model : nil)
            MissionStore.shared.link(s.id.uuidString, parent: rec.id, delegated: true)
            if first == nil { first = s }
        }
        app.show(String(format: L("%d Aufträge gestartet"), ps.count))
        if let f = first { app.page = .chat(f.id.uuidString) }
    }
}
