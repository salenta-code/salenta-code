import AgenticOSKit
import SwiftUI

// Recherche-Agent: Beim Planen schaut er parallel im Internet nach dem aktuellen Stand zum Auftrag –
// Trends, bewährte Lösungen, neue Versionen, Fallstricke – und macht konkrete Vorschläge.
// Du hakst an, was ins Projekt soll; „Plan umsetzen“ nimmt nur das Angehakte mit.

struct ResearchItem: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var title: String
    var detail: String
    var why: String = ""
    var sources: [String] = []
    var recommend: Bool = true
    var effort: String = ""          // klein, mittel, groß
    var selected: Bool = true
}

struct ResearchResult: Codable, Hashable {
    enum State: String, Codable { case running, done, failed }
    var state: State = .running
    var summary: String = ""
    var items: [ResearchItem] = []
    var error: String?
    var started = Date()
}

final class Research: ObservableObject {
    static let shared = Research()
    @Published private(set) var results: [String: ResearchResult] = [:]   // Auftrag → Ergebnis
    private var url: URL { Paths.data.appendingPathComponent("research.json") }

    /// Ab Werk an: Beim Planen recherchiert der Agent mit.
    static var enabled: Bool { UserDefaults.standard.object(forKey: "research.onPlan") as? Bool ?? true }

    init() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: url), let r = try? dec.decode([String: ResearchResult].self, from: d) {
            results = r.mapValues { var x = $0; if x.state == .running { x.state = .failed; x.error = L("abgebrochen") }; return x }
        }
    }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let snap = results.filter { $0.value.started > Date().addingTimeInterval(-30 * 86400) }
        DispatchQueue.global(qos: .utility).async { [url] in if let d = try? enc.encode(snap) { try? d.write(to: url, options: .atomic) } }
    }

    func result(_ mid: String) -> ResearchResult? { results[mid] }

    func toggle(_ mid: String, _ item: String) {
        guard var r = results[mid], let i = r.items.firstIndex(where: { $0.id == item }) else { return }
        r.items[i].selected.toggle(); results[mid] = r; save()
    }

    func selectAll(_ mid: String, recommendedOnly: Bool) {
        guard var r = results[mid] else { return }
        for i in r.items.indices { r.items[i].selected = recommendedOnly ? r.items[i].recommend : true }
        results[mid] = r; save()
    }

    /// Was beim Umsetzen in den Auftrag soll.
    func promptBlock(_ mid: String) -> String? {
        guard let r = results[mid], r.state == .done, !r.items.isEmpty else { return nil }
        let take = r.items.filter(\.selected), skip = r.items.filter { !$0.selected }
        var out = ""
        if !take.isEmpty {
            out += L("Aus der Recherche übernehmen (vom Nutzer ausgewählt):") + "\n"
                + take.map { "- \($0.title): \($0.detail)" + ($0.sources.first.map { " (" + $0 + ")" } ?? "") }.joined(separator: "\n")
        }
        if !skip.isEmpty {
            out += (out.isEmpty ? "" : "\n\n") + L("Bewusst NICHT übernehmen:") + "\n" + skip.map { "- " + $0.title }.joined(separator: "\n")
        }
        return out.isEmpty ? nil : out
    }

    /// Recherche starten (im Hintergrund, mit Websuche). Läuft parallel zum Plan.
    func start(_ mid: String, request: String, directory: String) {
        guard results[mid]?.state != .running else { return }
        guard LocalFirst.shared.isOnline, !LocalFirst.shared.localOnly, Detection.which("claude") != nil else {
            results[mid] = ResearchResult(state: .failed, error: LocalFirst.shared.localOnly ? L("„Nur lokal“ ist an – keine Websuche") : L("Keine Internetverbindung oder Claude Code fehlt"))
            return
        }
        results[mid] = ResearchResult()
        save()
        let stack = Steward.detect(directory).stack.joined(separator: ", ")
        let lang = Profile.languageCode == "de" ? "German (informal du, plain words, no jargon)" : "English"
        let today = Date().formatted(.iso8601.year().month().day())
        let prompt = """
        You are a RESEARCH agent supporting the planning of a software task. Today is \(today).
        Task from the owner: \(request)
        Project: \((directory as NSString).lastPathComponent)\(stack.isEmpty ? "" : " · stack: " + stack)

        Use web search to find the CURRENT state of the art for exactly this task (prefer sources from the last 12 months):
        - current best practices and proven approaches, recommended libraries/services and their latest stable versions
        - relevant trends users now expect (UX, AI features, security, performance, accessibility, legal/GDPR if relevant)
        - known pitfalls, deprecations or breaking changes to avoid
        Then turn it into 3–8 concrete, actionable suggestions for THIS project. No generic advice. Do not change any files.
        Mark "recommend": true only for suggestions that clearly pay off for this task; nice-to-haves get false.
        "effort": "klein" | "mittel" | "groß". Every suggestion needs at least one real source URL you actually opened.

        Answer ONLY with JSON in \(lang):
        {"summary":"2–3 sentences: what matters most right now","items":[{"title":"short","detail":"what exactly to do","why":"benefit in one sentence","sources":["https://…"],"recommend":true,"effort":"klein"}]}
        """
        DispatchQueue.global(qos: .utility).async {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("aos-research-\(UUID().uuidString).md")
            try? prompt.write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            let r = Proc.zsh("claude -p --model sonnet --output-format json --max-turns 20 --strict-mcp-config --allowedTools WebSearch,WebFetch < \(Shell.quote(file.path))",
                             in: NSTemporaryDirectory(), timeout: 600)
            var out = ResearchResult(state: .failed)
            if let res = Verifier.claudeResult(r.out), let a = res.firstIndex(of: "{"), let b = res.lastIndex(of: "}"), a < b,
               let j = try? JSONSerialization.jsonObject(with: Data(res[a...b].utf8)) as? [String: Any] {
                out.state = .done
                out.summary = j["summary"] as? String ?? ""
                out.items = ((j["items"] as? [[String: Any]]) ?? []).compactMap { i in
                    guard let t = i["title"] as? String, !t.isEmpty else { return nil }
                    let rec = i["recommend"] as? Bool ?? false
                    let src = ((i["sources"] as? [String]) ?? []).filter { $0.hasPrefix("http") }
                    return ResearchItem(title: t, detail: i["detail"] as? String ?? "", why: i["why"] as? String ?? "",
                                        sources: src, recommend: rec, effort: i["effort"] as? String ?? "", selected: rec)
                }
                if out.items.isEmpty { out.state = .failed; out.error = L("Keine verwertbaren Vorschläge gefunden") }
            } else {
                out.error = Verifier.claudeFailure(r.out, code: r.code)
            }
            DispatchQueue.main.async { self.results[mid] = out; self.save() }
        }
    }
}

/// Karte im Plan-Auftrag: Vorschläge aus der Recherche zum Anhaken.
struct ResearchCard: View {
    let missionID: String
    let request: String
    let directory: String
    @ObservedObject private var research = Research.shared
    @State private var open = true

    var body: some View {
        let r = research.result(missionID)
        VStack(alignment: .leading, spacing: Grid.s) {
            HStack(spacing: Grid.s) {
                Image(systemName: "globe.europe.africa.fill").foregroundStyle(Color.accentColor)
                Text("Recherche: Was ist gerade aktuell?").font(.callout.weight(.semibold))
                Spacer()
                switch r?.state {
                case .running?:
                    ProgressView().controlSize(.small)
                    Text("sucht im Internet …").font(.caption).foregroundStyle(.secondary)
                case .done?:
                    let n = r?.items.filter(\.selected).count ?? 0
                    Text(String(format: L("%d von %d ausgewählt"), n, r?.items.count ?? 0)).font(.caption).foregroundStyle(.secondary)
                    Menu {
                        Button(L("Nur empfohlene")) { research.selectAll(missionID, recommendedOnly: true) }
                        Button(L("Alle")) { research.selectAll(missionID, recommendedOnly: false) }
                    } label: { Image(systemName: "checklist") }.menuStyle(.borderlessButton).fixedSize()
                    .help(L("Recherche-Vorschläge auswählen"))
                    Button { open.toggle() } label: { Image(systemName: open ? "chevron.up" : "chevron.down") }.buttonStyle(.borderless)
                    .help(open ? L("Recherche einklappen") : L("Recherche ausklappen"))
                case .failed?:
                    Button(L("Erneut recherchieren")) { research.start(missionID, request: request, directory: directory) }.controlSize(.small)
                case nil:
                    Button(L("Recherchieren")) { research.start(missionID, request: request, directory: directory) }.controlSize(.small)
                }
            }
            if let r, r.state == .failed, let e = r.error { Text(e).font(.caption).foregroundStyle(.orange) }
            if let r, r.state == .done, open {
                // Eigener Scrollbereich: viele Vorschläge dürfen Verlauf und Eingabe nie aus dem Fenster schieben
                BoundedScroll(maxFraction: 0.42) {
                    VStack(alignment: .leading, spacing: Grid.s) {
                        if !r.summary.isEmpty { Text(r.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        ForEach(r.items) { item in row(item) }
                        Text("Angehakt = kommt mit in den Plan, wenn du auf „Plan umsetzen“ klickst. Nicht angehakt = wird bewusst weggelassen.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(Grid.m)
        .background(ModernCardBackground(radius: 12))
        .frame(maxWidth: 780)
        .padding(.horizontal, Grid.l)
    }

    private func row(_ i: ResearchItem) -> some View {
        HStack(alignment: .top, spacing: Grid.s) {
            Toggle("", isOn: Binding(get: { i.selected }, set: { _ in research.toggle(missionID, i.id) })).labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(i.title).fontWeight(.medium)
                    if i.recommend { Text(L("empfohlen")).font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor) }
                    if !i.effort.isEmpty { Text(L("Aufwand") + ": " + i.effort).font(.caption2).foregroundStyle(.tertiary) }
                }
                Text(i.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !i.why.isEmpty { Text("→ " + i.why).font(.caption).foregroundStyle(.secondary) }
                HStack(spacing: 8) {
                    ForEach(i.sources.prefix(3), id: \.self) { s in
                        if let u = URL(string: s) { Link(u.host?.replacingOccurrences(of: "www.", with: "") ?? s, destination: u).font(.caption2) }
                    }
                }
            }
        }
    }
}
