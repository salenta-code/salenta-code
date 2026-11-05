import AgenticOSKit
import AppKit
import SwiftUI

// MARK: - Lernende Agentenwahl: was lief bei welcher Art von Auftrag wirklich gut?

enum Learning {
    enum Kind: String, CaseIterable { case debug, review, build, other }

    static func kind(of text: String) -> Kind {
        let t = text.lowercased()
        if Router.reviewWords.contains(where: { t.contains($0) }) { return .review }
        if Router.debugWords.contains(where: { t.contains($0) }) { return .debug }
        if Router.codingWords.contains(where: { t.contains($0) }) { return .build }
        return .other
    }

    /// Gut = übernommen / PR / geprüft grün. Schlecht = abgebrochen, verworfen, Prüfung rot, Limit.
    static func score(_ m: MissionRecord) -> Bool? {
        switch m.outcome {
        case "merged", "pr": return true
        case "discarded", "limit": return false
        default: break
        }
        if m.ok == false { return false }
        if let p = m.verify?.passed { return p }
        if m.archived == true && m.ok == true { return true }
        return nil
    }

    struct AgentStat { let agent: String; let title: String; let runs: Int; let good: Int; var rate: Double { runs == 0 ? 0 : Double(good) / Double(runs) } }

    static func stats(_ missions: [MissionRecord], days: Double = 30) -> [AgentStat] {
        let from = Date().addingTimeInterval(-days * 86400)
        let scored = missions.filter { $0.started >= from }.compactMap { m -> (String, String, Bool)? in
            guard let s = score(m) else { return nil }
            return (m.agent, m.agentTitle, s)
        }
        return Dictionary(grouping: scored, by: \.0).map { agent, list in
            AgentStat(agent: agent, title: list.first?.1 ?? agent, runs: list.count, good: list.filter(\.2).count)
        }.sorted { $0.runs > $1.runs }
    }

    /// Kurzfassung für die KI-Wahl: pro Auftragsart, welcher Agent wie oft gut war, und was du selbst gewählt hast.
    static func routerHint(_ missions: [MissionRecord]) -> String {
        let from = Date().addingTimeInterval(-60 * 86400)
        let recent = missions.filter { $0.started >= from }
        var lines: [String] = []
        for k in Kind.allCases {
            let ofKind = recent.filter { kind(of: $0.request) == k }
            let byAgent = Dictionary(grouping: ofKind, by: \.agent)
            let parts = byAgent.compactMap { agent, list -> String? in
                let scored = list.compactMap(score)
                let manual = list.filter { $0.manual == true }.count
                guard !scored.isEmpty || manual > 0 else { return nil }
                return "\(agent) \(scored.filter { $0 }.count)/\(scored.count) good\(manual > 0 ? ", user picked it \(manual)×" : "")"
            }
            if !parts.isEmpty { lines.append("- \(k.rawValue): " + parts.sorted().joined(separator: "; ")) }
        }
        return lines.isEmpty ? "" : "Past results on this Mac (last 60 days):\n" + lines.joined(separator: "\n")
    }

    static func record(_ rec: MissionRecord, outcome: String) {
        append(["id": rec.id, "agent": rec.agent, "model": rec.model ?? "", "kind": kind(of: rec.request).rawValue, "outcome": outcome])
    }

    static func recordVerify(_ id: String, passed: Bool) {
        guard let rec = MissionStore.shared.mission(id) else { return }
        append(["id": id, "agent": rec.agent, "kind": kind(of: rec.request).rawValue, "verify": passed ? "passed" : "failed"])
    }

    private static func append(_ j: [String: String]) {
        var j = j
        j["zeit"] = ISO8601DateFormatter().string(from: Date())
        let url = Paths.root.appendingPathComponent("logs/learning.jsonl")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let d = try? JSONSerialization.data(withJSONObject: j), var line = String(data: d, encoding: .utf8) else { return }
        line += "\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }
}

// MARK: - Regeln: gelten für jeden Agent – als Hinweis im Auftrag und hart in der Freigabe

struct BlockRule: Codable, Hashable, Identifiable {
    var id: String { muster }
    var muster: String          // Regex auf Tool + Eingabe (z. B. "shopify theme (push|publish)")
    var ausser: String?         // erlaubt, wenn das auch vorkommt (z. B. "--unpublished|--development")
    var grund: String
    var fragen: Bool?           // true = nicht blocken, aber immer fragen (auch im Auto-Modus)
}

struct RuleFile: Codable {
    var regeln: [String] = []
    var blocken: [BlockRule] = []
}

enum Rules {
    static var file: URL { Paths.data.appendingPathComponent("rules.json") }

    static func load() -> RuleFile {
        guard let d = try? Data(contentsOf: file), let r = try? JSONDecoder().decode(RuleFile.self, from: d) else { return RuleFile() }
        return r
    }

    static func save(_ r: RuleFile) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let d = try? enc.encode(r) { try? d.write(to: file, options: .atomic) }
    }

    /// Text-Regeln für alle Projekte (gehen in jeden Coding-Auftrag).
    static var global: [String] { load().regeln.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }

    static let examples: [BlockRule] = [
        BlockRule(muster: "shopify theme (push|publish)", ausser: "--unpublished|--development|-d\\b",
                  grund: "Nie ins veröffentlichte Shopify-Theme schreiben – nur in eine Kopie", fragen: nil),
        BlockRule(muster: "git push.*(--force|-f\\b)", ausser: nil, grund: "Kein Force-Push", fragen: nil),
        BlockRule(muster: "supabase db (push|reset)|vercel.*--prod", ausser: nil, grund: "Produktion nur nach Rückfrage", fragen: true),
    ]
}

struct RulesEditor: View {
    /// nil = globale Regeln (data/rules.json), sonst Projektordner (.salenta-os.json)
    let projectDir: String?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var blocks: [BlockRule] = []
    @State private var verify = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.m) {
            Text(projectDir.map { L("Regeln für ") + ($0 as NSString).lastPathComponent } ?? L("Regeln für alle Projekte")).font(.title2.weight(.semibold))
            Text("Regeln gehen in jeden Auftrag. Blockier-Regeln setzt Salenta Code in der Freigabe hart durch – auch im Auto-Modus.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Regeln (eine pro Zeile)").font(.headline)
            TextEditor(text: $text).font(.body).frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
            HStack {
                Text("Blockieren / immer fragen").font(.headline)
                Spacer()
                Menu("Beispiel hinzufügen") {
                    ForEach(Rules.examples) { e in Button(e.grund) { if !blocks.contains(e) { blocks.append(e) } } }
                }.fixedSize()
                Button { blocks.append(BlockRule(muster: "", ausser: nil, grund: "", fragen: nil)) } label: { Image(systemName: "plus") }.help(L("Regel hinzufügen"))
            }
            ForEach($blocks) { $b in
                HStack {
                    TextField("Muster (Regex), z. B. shopify theme push", text: $b.muster).font(.system(.callout, design: .monospaced))
                    TextField("außer …", text: Binding(get: { b.ausser ?? "" }, set: { b.ausser = $0.isEmpty ? nil : $0 }))
                        .font(.system(.callout, design: .monospaced)).frame(width: 170)
                    TextField("Grund", text: $b.grund).frame(width: 220)
                    Toggle("nur fragen", isOn: Binding(get: { b.fragen == true }, set: { b.fragen = $0 ? true : nil })).toggleStyle(.checkbox)
                    Button(role: .destructive) { blocks.removeAll { $0 == b } } label: { Image(systemName: "trash") }.buttonStyle(.plain).help(L("Regel löschen"))
                }
            }
            if projectDir != nil {
                Text("Prüfbefehle für die Prüfschleife (eine pro Zeile, leer = automatisch erkennen)").font(.headline)
                TextEditor(text: $verify).font(.system(.callout, design: .monospaced)).frame(minHeight: 60)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
            }
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                Button("Speichern") { save(); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Grid.xl)
        .frame(width: 760)
        .onAppear(perform: load)
    }

    private func load() {
        if let dir = projectDir {
            let c = ProjectConfig.load(dir)
            text = (c?.rules ?? []).joined(separator: "\n")
            blocks = c?.block ?? []
            verify = (c?.verify ?? []).joined(separator: "\n")
        } else {
            let r = Rules.load()
            text = r.regeln.joined(separator: "\n")
            blocks = r.blocken
        }
    }

    private func save() {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let b = blocks.filter { !$0.muster.isEmpty }
        if let dir = projectDir {
            var c = ProjectConfig.load(dir) ?? ProjectConfig()
            c.rules = lines.isEmpty ? nil : lines
            c.block = b.isEmpty ? nil : b
            let v = verify.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            c.verify = v.isEmpty ? nil : v
            ProjectConfig.save(c, dir: dir)
        } else {
            Rules.save(RuleFile(regeln: lines, blocken: b))
        }
    }
}

// MARK: - Fokus-Modus: nur Freigaben, fertige Aufträge und dringende Mails melden sich

enum Focus {
    static var until: Date? {
        let t = UserDefaults.standard.double(forKey: "focus.until")
        return t > Date().timeIntervalSince1970 ? Date(timeIntervalSince1970: t) : nil
    }
    static var isOn: Bool { until != nil }
    static func set(_ d: Date?) { UserDefaults.standard.set(d?.timeIntervalSince1970 ?? 0, forKey: "focus.until") }

    static let urgentWords = ["dringend", "urgent", "asap", "sofort", "eilt", "frist", "mahnung", "kündigung", "wichtig", "important", "deadline"]
    static func isUrgent(subject: String, sender: String) -> Bool {
        let t = (subject + " " + sender).lowercased()
        let vips = (UserDefaults.standard.string(forKey: "focus.vips") ?? "").lowercased()
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return urgentWords.contains { t.contains($0) } || vips.contains { t.contains($0) }
    }
}

struct FocusButton: View {
    @AppStorage("focus.until") private var untilRaw = 0.0
    var body: some View {
        let on = untilRaw > Date().timeIntervalSince1970
        Menu {
            Button("1 Stunde") { untilRaw = Date().addingTimeInterval(3600).timeIntervalSince1970 }
            Button("2 Stunden") { untilRaw = Date().addingTimeInterval(7200).timeIntervalSince1970 }
            Button("Bis heute Abend (18 Uhr)") {
                untilRaw = (Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date().addingTimeInterval(3600)).timeIntervalSince1970
            }
            if on { Divider(); Button("Fokus beenden") { untilRaw = 0 } }
        } label: {
            Label(on ? L("Fokus bis ") + Date(timeIntervalSince1970: untilRaw).formatted(date: .omitted, time: .shortened) : L("Fokus"),
                  systemImage: on ? "moon.fill" : "moon")
                .font(.caption).foregroundStyle(on ? Color.purple : .secondary)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(L("Fokus: nur Freigaben, fertige Aufträge und dringende Mails melden sich"))
    }
}

// MARK: - Projekt-Cockpit: eine Karte pro Repo

struct ProjectStatus: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    var branch = ""
    var dirty = 0
    var ahead = 0
    var behind = 0
    var lastCommit = ""
    var lastCommitAge = ""
    var prs: [PR] = []
    var ci: String?          // success, failure, in_progress …
    var ciURL: String?
    var vercel: String?      // Projektname, falls verknüpft
    var sentry = false
    /// Worum es im Projekt geht: aus package.json („description“) oder dem ersten Absatz der README.
    var about = ""
    var loaded = false

    struct PR: Hashable { let number: Int; let title: String; let url: String; let draft: Bool; let checks: String? }
}

final class ProjectBoard: ObservableObject {
    @Published var items: [ProjectStatus] = []
    @Published var loading = false
    @AppStorage("projects.pinned") private var pinnedRaw = ""

    var pinned: Set<String> { Set(pinnedRaw.split(separator: "\n").map(String.init)) }
    func togglePin(_ path: String) {
        var p = pinned
        if p.contains(path) { p.remove(path) } else { p.insert(path) }
        pinnedRaw = p.sorted().joined(separator: "\n")
        objectWillChange.send()
    }

    /// Welche Projekte: angeheftete + alle, in denen in den letzten 30 Tagen gearbeitet wurde.
    func reload(catalog: [Project], missions: [MissionRecord], live: [String]) {
        let from = Date().addingTimeInterval(-30 * 86400)
        let gitProjects = catalog
        var paths: [String] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func add(_ p: String) {
            guard !paths.contains(p), p != home, FileManager.default.fileExists(atPath: p) else { return }
            paths.append(p)
        }
        // Nur deine Projekte – zuletzt aktive zuerst, keine automatisch gefundenen Ordner mehr.
        let mine = Set(gitProjects.map(\.path))
        pinned.sorted().filter { mine.contains($0) }.forEach(add)
        for m in missions.reversed() where m.started >= from {
            let dir = m.worktree?.base ?? m.directory
            if let p = gitProjects.first(where: { dir == $0.path || dir.hasPrefix($0.path + "/") }) { add(p.path) }
        }
        for l in live { if let p = gitProjects.first(where: { l == $0.path || l.hasPrefix($0.path + "/") }) { add(p.path) } }
        gitProjects.forEach { add($0.path) }
        let old = Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0) })
        items = paths.prefix(60).map { p in old[p] ?? ProjectStatus(path: p, name: (p as NSString).lastPathComponent) }
        loading = true
        let list = items
        DispatchQueue.global(qos: .utility).async {
            let group = DispatchGroup()
            let lock = NSLock()
            var results: [String: ProjectStatus] = [:]
            for item in list {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let s = Self.status(item)
                    lock.lock(); results[s.path] = s; lock.unlock()
                    group.leave()
                }
            }
            group.wait()
            DispatchQueue.main.async {
                self.items = self.items.map { results[$0.path] ?? $0 }
                self.loading = false
            }
        }
    }

    /// Ein Satz, worum es im Projekt geht.
    static func about(_ dir: String, pkg: String) -> String {
        if let d = try? JSONSerialization.jsonObject(with: Data(pkg.utf8)) as? [String: Any],
           let desc = (d["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty { return desc }
        let fm = FileManager.default
        for name in ["README.md", "readme.md", "README.de.md", "README", "Readme.md"] {
            let f = (dir as NSString).appendingPathComponent(name)
            guard let text = fm.contents(atPath: f).map({ String(decoding: $0, as: UTF8.self) }) else { continue }
            var para: [String] = []
            for raw in text.components(separatedBy: "\n") {
                let l = raw.trimmingCharacters(in: .whitespaces)
                if l.isEmpty { if !para.isEmpty { break } else { continue } }
                // Überschriften, Badges, Bilder, HTML und Code überspringen
                if l.hasPrefix("#") || l.hasPrefix("![") || l.hasPrefix("[![") || l.hasPrefix("<") || l.hasPrefix("```") || l.hasPrefix("---") || l.hasPrefix("|") { if !para.isEmpty { break } else { continue } }
                para.append(l)
            }
            var t = para.joined(separator: " ")
            t = t.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
                 .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            if !t.isEmpty { return t.count > 220 ? String(t.prefix(218)) + "…" : t }
        }
        return ""
    }

    private static func status(_ item: ProjectStatus) -> ProjectStatus {
        var s = item
        let dir = item.path
        guard Git.root(of: dir) != nil else { s.branch = ""; s.lastCommit = L("kein Git-Repo"); s.loaded = true; return s }
        s.branch = Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: dir, timeout: 10).out.trimmingCharacters(in: .whitespacesAndNewlines)
        s.dirty = Git.run(["status", "--porcelain"], in: dir, timeout: 15).out.split(separator: "\n").count
        let lr = Git.run(["rev-list", "--left-right", "--count", "@{u}...HEAD"], in: dir, timeout: 10)
        if lr.code == 0 {
            let n = lr.out.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" }).compactMap { Int($0) }
            if n.count == 2 { s.behind = n[0]; s.ahead = n[1] }
        }
        let log = Git.run(["log", "-1", "--format=%s\t%cr"], in: dir, timeout: 10).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = log.components(separatedBy: "\t")
        s.lastCommit = parts.first ?? ""
        s.lastCommitAge = parts.count > 1 ? parts[1] : ""
        let remote = Git.run(["remote", "get-url", "origin"], in: dir, timeout: 5).out
        if remote.contains("github.com"), Detection.which("gh") != nil {
            let pr = Proc.zsh("gh pr list --limit 8 --json number,title,url,isDraft,statusCheckRollup", in: dir, timeout: 25)
            if pr.code == 0, let st = pr.out.firstIndex(of: "["), let en = pr.out.lastIndex(of: "]"),
               let arr = try? JSONSerialization.jsonObject(with: Data(pr.out[st...en].utf8)) as? [[String: Any]] {
                s.prs = arr.map { p in
                    let checks = (p["statusCheckRollup"] as? [[String: Any]] ?? []).compactMap { ($0["conclusion"] as? String) ?? ($0["status"] as? String) }
                    let summary: String? = checks.isEmpty ? nil : checks.contains(where: { $0.uppercased() == "FAILURE" }) ? "failure"
                        : checks.allSatisfy({ $0.uppercased() == "SUCCESS" || $0.uppercased() == "SKIPPED" || $0.uppercased() == "NEUTRAL" }) ? "success" : "pending"
                    return ProjectStatus.PR(number: p["number"] as? Int ?? 0, title: p["title"] as? String ?? "",
                                            url: p["url"] as? String ?? "", draft: p["isDraft"] as? Bool ?? false, checks: summary)
                }
            }
            let run = Proc.zsh("gh run list --limit 1 --branch \(Shell.quote(s.branch)) --json status,conclusion,url", in: dir, timeout: 25)
            if run.code == 0, let st = run.out.firstIndex(of: "["), let en = run.out.lastIndex(of: "]"),
               let arr = try? JSONSerialization.jsonObject(with: Data(run.out[st...en].utf8)) as? [[String: Any]], let r = arr.first {
                let concl = (r["conclusion"] as? String) ?? ""
                s.ci = concl.isEmpty ? (r["status"] as? String) : concl
                s.ciURL = r["url"] as? String
            }
        }
        let fm = FileManager.default
        if let d = fm.contents(atPath: (dir as NSString).appendingPathComponent(".vercel/project.json")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            s.vercel = (j["projectName"] as? String) ?? (dir as NSString).lastPathComponent
        }
        let pkg = (fm.contents(atPath: (dir as NSString).appendingPathComponent("package.json"))).map { String(decoding: $0, as: UTF8.self) } ?? ""
        s.about = Self.about(dir, pkg: pkg)
        s.sentry = pkg.contains("@sentry/") || fm.fileExists(atPath: (dir as NSString).appendingPathComponent("sentry.properties"))
            || fm.fileExists(atPath: (dir as NSString).appendingPathComponent(".sentryclirc"))
        s.loaded = true
        return s
    }
}

struct ProjectsView: View {
    @StateObject private var board = ProjectBoard()
    @EnvironmentObject private var catalog: ProjectCatalog
    @EnvironmentObject private var live: LiveMonitor
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var mail: MailService
    @ObservedObject private var missions = MissionStore.shared
    @State private var rulesFor: String?
    @State private var memoryFor: String?
    @State private var globalRules = false
    @State private var previewFor: String?
    @State private var adding = false

    private let columns = [GridItem(.adaptive(minimum: 360, maximum: 560), spacing: Grid.l)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Grid.l) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Projekte").font(.largeTitle.weight(.semibold))
                        Text("Wo es brennt, was offen ist, was die Agents gerade tun – pro Repo.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if board.loading { ProgressView().controlSize(.small) }
                    Button { globalRules = true } label: { Label("Regeln für alle", systemImage: "shield.lefthalf.filled") }
                    Button { adding = true } label: { Label("Projekt hinzufügen", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                }
                TipsCard()
                LazyVGrid(columns: columns, alignment: .leading, spacing: Grid.l) {
                    ForEach(board.items) { p in card(p) }
                }
                if board.items.isEmpty && !board.loading {
                    ContentUnavailableView {
                        Label("Noch keine Projekte", systemImage: "folder.badge.plus")
                    } description: {
                        Text("Verbinde ein Repo von GitHub, wähle einen Ordner auf deinem Mac oder leg ein neues Projekt an.")
                    } actions: {
                        Button("Projekt hinzufügen") { adding = true }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(Grid.xl)
            .frame(maxWidth: 1400, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Projekte")
        .toolbar { ToolbarItem { Button { refresh() } label: { Label("Aktualisieren", systemImage: "arrow.clockwise") }.help(L("Aktualisieren")) } }
        .task { refresh() }
        .onChange(of: catalog.local.count) { _, _ in refresh() }
        .sheet(item: Binding(get: { rulesFor.map { IdentifiedPath(path: $0) } }, set: { rulesFor = $0?.path })) { p in
            RulesEditor(projectDir: p.path)
        }
        .sheet(isPresented: $globalRules) { RulesEditor(projectDir: nil) }
        .sheet(isPresented: $adding) { AddProjectSheet() }
        .sheet(item: Binding(get: { memoryFor.map { IdentifiedPath(path: $0) } }, set: { memoryFor = $0?.path })) { p in
            ProjectMemorySheet(directory: p.path)
        }
        .sheet(item: Binding(get: { previewFor.map { IdentifiedPath(path: $0) } }, set: { previewFor = $0?.path })) { p in
            PreviewSheet(id: "proj:" + p.path, title: (p.path as NSString).lastPathComponent)
        }
    }

    struct IdentifiedPath: Identifiable { var id: String { path }; let path: String }

    private func refresh() {
        board.reload(catalog: catalog.local, missions: missions.missions, live: live.projects.map(\.path))
    }

    private func runs(_ p: ProjectStatus) -> [MissionRecord] {
        missions.missions.filter { m in
            let d = m.worktree?.base ?? m.directory
            return d == p.path || d.hasPrefix(p.path + "/")
        }.suffix(30).reversed()
    }

    private func mails(_ p: ProjectStatus) -> [MailItem] {
        let words = Set([p.name.lowercased()] + (Company.allCases.first { c in
            ([c.title, c.rawValue] + c.tags + c.keywords).contains { $0.count >= 3 && p.name.lowercased().contains($0.lowercased()) }
        }.map { ([$0.title, $0.rawValue] + $0.tags + $0.keywords).map { $0.lowercased() } } ?? [])).filter { $0.count >= 4 }
        return mail.items.filter { m in
            let t = (m.subject + " " + m.sender).lowercased()
            return words.contains { t.contains($0) }
        }
    }

    private func health(_ p: ProjectStatus, _ r: [MissionRecord]) -> (Color, String) {
        if p.ci == "failure" || p.prs.contains(where: { $0.checks == "failure" }) { return (.red, L("Checks rot")) }
        if r.contains(where: { $0.archived != true && $0.verify?.passed == false }) { return (.red, L("Prüfung rot")) }
        if r.contains(where: { m in agents.sessions.contains { $0.id.uuidString == m.id && $0.running } }) { return (.green, L("Agent arbeitet")) }
        if r.contains(where: { $0.archived != true && $0.worktree != nil }) { return (.blue, L("Änderungen warten")) }
        if p.dirty > 0 || p.ahead > 0 { return (.orange, L("Nicht committet / nicht gepusht")) }
        return (.secondary, L("Ruhig"))
    }

    /// Was ist los – in einem Satz – und was hilft. Jeder farbige Status bekommt eine Erklärung und einen Knopf.
    struct Issue { let color: Color; let symbol: String; let text: String; let actions: [(String, String, () -> Void)] }

    private func issues(_ p: ProjectStatus, _ r: [MissionRecord]) -> [Issue] {
        var out: [Issue] = []
        let open = r.filter { $0.archived != true }
        func fix(_ prompt: String) { app.draft = "Im Projekt \(p.name): " + prompt; app.draftDir = p.path; app.page = .home }
        if p.ci == "failure" {
            out.append(Issue(color: .red, symbol: "xmark.octagon.fill",
                text: String(format: L("Die automatischen Tests auf GitHub (CI) sind auf „%@“ fehlgeschlagen."), p.branch),
                actions: [(L("Beheben lassen"), "wrench.and.screwdriver", { fix("Die CI auf \(p.branch) ist rot – finde heraus warum (gh run view --log-failed) und behebe es.") }),
                          (L("Auf GitHub ansehen"), "safari", { if let u = p.ciURL, let url = URL(string: u) { NSWorkspace.shared.open(url) } })]))
        }
        for pr in p.prs where pr.checks == "failure" {
            out.append(Issue(color: .red, symbol: "xmark.octagon.fill",
                text: String(format: L("Pull Request #%d „%@“: die Prüfungen auf GitHub sind rot."), pr.number, pr.title),
                actions: [(L("Beheben lassen"), "wrench.and.screwdriver", { fix("Beim Pull Request #\(pr.number) („\(pr.title)“) sind die Checks rot. Hol dir den Branch (gh pr checkout \(pr.number)), finde die Ursache und behebe sie.") }),
                          (L("PR ansehen"), "safari", { if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) } })]))
        }
        for m in open where m.verify?.passed == false {
            let failed = m.verify?.checks.filter { $0.ok == false }.map(\.name).joined(separator: ", ") ?? ""
            out.append(Issue(color: .red, symbol: "xmark.seal.fill",
                text: String(format: L("Auftrag „%@“: die Prüfung ist rot"), m.title) + (failed.isEmpty ? "." : " (\(failed))."),
                actions: [(L("Auftrag öffnen"), "arrow.right.circle", { app.page = .chat(m.id) })]))
        }
        let waiting = open.filter { m in m.worktree != nil && m.verify?.passed != false && !agents.sessions.contains { $0.id.uuidString == m.id && $0.running } }
        if let m = waiting.first {
            out.append(Issue(color: .blue, symbol: "tray.full.fill",
                text: waiting.count == 1 ? String(format: L("„%@“ ist fertig – die Änderungen warten auf deine Prüfung."), m.title)
                                         : String(format: L("%d Aufträge sind fertig – ihre Änderungen warten auf deine Prüfung."), waiting.count),
                actions: [(L("Ansehen"), "eye", { app.page = .chat(m.id) })]))
        }
        if p.dirty > 0 {
            out.append(Issue(color: .orange, symbol: "pencil.circle.fill",
                text: String(format: L("%d Datei(en) im Projektordner geändert, aber nicht gespeichert (nicht committet)."), p.dirty),
                actions: [(L("Committen lassen"), "checkmark.circle", { fix("Es gibt nicht committete Änderungen. Sieh sie dir an (git status, git diff), fasse sie sinnvoll zusammen und committe sie mit klaren Nachrichten. Nichts pushen.") }),
                          (L("Terminal"), "terminal", { _ = agents.start(.shell, in: p.path); app.page = .agents })]))
        }
        if p.ahead > 0 {
            out.append(Issue(color: .orange, symbol: "arrow.up.circle.fill",
                text: String(format: L("%d Commit(s) sind nur auf deinem Mac, noch nicht auf GitHub."), p.ahead),
                actions: [(L("Hochladen"), "arrow.up", { Worktrees.offerPush(repo: p.path, branch: p.branch, app: app); DispatchQueue.main.asyncAfter(deadline: .now() + 4) { refresh() } })]))
        }
        if p.behind > 0 {
            out.append(Issue(color: .secondary, symbol: "arrow.down.circle",
                text: String(format: L("Auf GitHub gibt es %d neuere Commit(s)."), p.behind),
                actions: [(L("Holen (Pull)"), "arrow.down", {
                    DispatchQueue.global(qos: .userInitiated).async {
                        let r = Git.run(["pull", "--ff-only"], in: p.path, timeout: 120)
                        DispatchQueue.main.async { app.show(r.code == 0 ? "✓ " + L("Aktualisiert") : L("Holen ging nicht automatisch – lokale Änderungen im Weg?")); refresh() }
                    }
                })]))
        }
        return out
    }

    @ViewBuilder private func issueBox(_ list: [Issue]) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: Grid.s) {
                ForEach(Array(list.prefix(1).enumerated()), id: \.offset) { _, i in
                    VStack(alignment: .leading, spacing: 4) {
                        Label { Text(i.text).lineLimit(2) } icon: { Image(systemName: i.symbol).foregroundStyle(i.color) }
                            .font(.callout).help(i.text)
                        HStack(spacing: Grid.s) {
                            ForEach(Array(i.actions.enumerated()), id: \.offset) { n, a in
                                if n == 0 {
                                    Button(action: a.2) { Label(a.0, systemImage: a.1) }.controlSize(.small).buttonStyle(.borderedProminent).tint(i.color == .secondary ? .accentColor : i.color)
                                } else {
                                    Button(action: a.2) { Label(a.0, systemImage: a.1) }.controlSize(.small)
                                }
                            }
                        }
                        .padding(.leading, 22)
                    }
                }
                if list.count > 1 {
                    Text(String(format: L("+ %d weitere Hinweise"), list.count - 1)).font(.caption2).foregroundStyle(.secondary)
                        .padding(.leading, 22)
                        .help(list.dropFirst().map(\.text).joined(separator: "\n"))
                }
            }
            .padding(Grid.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill((list.first?.color ?? .secondary).opacity(0.08)))
        }
    }

    @ViewBuilder private func card(_ p: ProjectStatus) -> some View {
        let r = runs(p)
        let (color, label) = health(p, r)
        let openRuns = r.filter { $0.archived != true }
        let m = mails(p)
        VStack(alignment: .leading, spacing: Grid.s) {
            HStack(spacing: Grid.s) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(p.name).font(.headline).lineLimit(1)
                if board.pinned.contains(p.path) { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                Text(label).font(.caption).foregroundStyle(color == .secondary ? .secondary : color)
                    .help(L("Was das bedeutet und was hilft, steht direkt darunter"))
            }
            // Worum es geht – und was gerade passiert
            Text(p.about.isEmpty ? L("Keine Beschreibung – leg eine README an oder trag „description“ in package.json ein.") : p.about)
                .font(.callout).foregroundStyle(p.about.isEmpty ? .tertiary : .secondary)
                .lineLimit(2, reservesSpace: true)
                .help(p.about)
            nowLine(p, r)
            issueBox(issues(p, r))
            HStack(spacing: Grid.m) {
                Label(p.branch.isEmpty ? "…" : p.branch, systemImage: "arrow.triangle.branch").font(.caption)
                if p.dirty > 0 { Label("\(p.dirty)", systemImage: "pencil").font(.caption).foregroundStyle(.orange).help(L("geänderte Dateien")) }
                if p.ahead > 0 {
                    Button { Worktrees.offerPush(repo: p.path, branch: p.branch, app: app); DispatchQueue.main.asyncAfter(deadline: .now() + 4) { refresh() } } label: {
                        Label("\(p.ahead)", systemImage: "arrow.up.circle.fill").font(.caption)
                    }
                    .buttonStyle(.plain).foregroundStyle(.blue)
                    .help(L("Nicht auf GitHub – klicken zum Hochladen (Push)"))
                }
                if p.behind > 0 { Label("\(p.behind)", systemImage: "arrow.down").font(.caption).help(L("neue Commits auf dem Server")) }
                if let ci = p.ci {
                    Button { if let u = p.ciURL, let url = URL(string: u) { NSWorkspace.shared.open(url) } } label: {
                        Label("CI", systemImage: ci == "success" ? "checkmark.circle.fill" : ci == "failure" ? "xmark.circle.fill" : "clock")
                            .font(.caption).foregroundStyle(ci == "success" ? .green : ci == "failure" ? .red : .orange)
                    }.buttonStyle(.plain)
                }
                Spacer()
            }
            if !p.prs.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(p.prs.prefix(2), id: \.number) { pr in
                        Button { if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) } } label: {
                            HStack(spacing: 4) {
                                Image(systemName: pr.checks == "failure" ? "xmark.circle.fill" : pr.checks == "success" ? "checkmark.circle.fill" : "arrow.triangle.pull")
                                    .foregroundStyle(pr.checks == "failure" ? .red : pr.checks == "success" ? .green : .secondary)
                                Text("#\(pr.number) \(pr.title)").lineLimit(1)
                                if pr.draft { Text("Entwurf").font(.caption2).foregroundStyle(.tertiary) }
                            }.font(.caption)
                        }.buttonStyle(.plain)
                    }
                    if p.prs.count > 2 { Text("+ \(p.prs.count - 2) " + L("weitere Pull Requests")).font(.caption2).foregroundStyle(.tertiary) }
                }
            }
            if openRuns.count > 1 {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(openRuns.dropFirst().prefix(2)) { run in
                        Button { app.page = .chat(run.id) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: run.agentSymbol).frame(width: 14)
                                Text(run.title).lineLimit(1)
                                Spacer()
                                if let v = run.verify, let ok = v.passed {
                                    Image(systemName: ok ? "checkmark.seal.fill" : "xmark.seal.fill").foregroundStyle(ok ? .green : .red)
                                }
                            }.font(.caption)
                        }.buttonStyle(.plain)
                    }
                }
            }
            if !m.isEmpty {
                Button { app.page = .mail } label: {
                    Label("\(m.count) " + L("Mail(s) zum Projekt") + (m.first.map { ": " + $0.subject } ?? ""), systemImage: "envelope")
                        .font(.caption).lineLimit(1)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Divider()
            HStack(spacing: Grid.s) {
                Button {
                    var ctx = "Im Projekt \(p.name): "
                    if let failing = openRuns.first(where: { $0.verify?.passed == false }) { ctx += "\n\nOffen ist noch: „\(failing.title)“ – die Prüfung ist rot." }
                    else if p.ci == "failure" { ctx += "\n\nDie CI auf \(p.branch) ist rot – finde heraus warum und behebe es." }
                    app.draft = ctx
                    app.draftDir = p.path
                    app.page = .home
                } label: { Label("Weiterarbeiten", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                Button {
                    PreviewServer.shared.start(id: "proj:" + p.path, dir: p.path) { u in if u == nil { app.show(L("Kein Dev-Server gefunden – \"dev\" in .salenta-os.json eintragen")) } }
                    previewFor = p.path
                } label: { Image(systemName: "play.display") }.help(L("Live-Vorschau der App"))
                Button { _ = agents.start(.shell, in: p.path); app.page = .agents } label: { Image(systemName: "terminal") }.help(L("Terminal im Projekt"))
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: p.path)) } label: { Image(systemName: "folder") }.help(L("Im Finder"))
                Button { catalog.remove(p.path) } label: { Image(systemName: "minus.circle") }.help(L("Aus der Liste nehmen (Ordner bleibt)"))
                Button { rulesFor = p.path } label: { Image(systemName: "shield.lefthalf.filled") }.help(L("Regeln und Prüfbefehle"))
                Button { memoryFor = p.path } label: { Image(systemName: "brain.head.profile") }.help(L("Projektwissen – was alle Agents über dieses Projekt gelernt haben"))
                Button { app.page = .steward(Steward.shared.adopt(p.path)) } label: { Image(systemName: "safari") }
                    .help(!Steward.shared.projects.contains(where: { p.path.hasPrefix($0.id) }) ? L("In Betreuung geben – ein Koordinator plant und pflegt das Projekt") : L("Projekt-Betreuer öffnen"))
                if let v = p.vercel {
                    Button { if let u = URL(string: "https://vercel.com/dashboard") { NSWorkspace.shared.open(u) } } label: { Text("▲").font(.caption) }
                        .help("Vercel: \(v)")
                }
                if p.sentry {
                    Button { if let u = URL(string: "https://sentry.io/issues/") { NSWorkspace.shared.open(u) } } label: { Image(systemName: "ant") }
                        .help(L("Sentry-Fehler ansehen"))
                }
                Spacer()
                Button { board.togglePin(p.path); refresh() } label: { Image(systemName: board.pinned.contains(p.path) ? "pin.slash" : "pin") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Anheften"))
            }
        }
        .padding(Grid.l)
        // Alle Karten gleich hoch – egal wie viel los ist
        .frame(height: 360, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(color.opacity(color == .secondary ? 0.15 : 0.45)))
    }

    /// „Gerade“: was im Projekt gerade passiert – laufender oder offener Auftrag, sonst der letzte Commit.
    @ViewBuilder private func nowLine(_ p: ProjectStatus, _ r: [MissionRecord]) -> some View {
        let open = r.filter { $0.archived != true }
        let running = open.first { m in agents.sessions.contains { $0.id.uuidString == m.id && $0.running } }
        if let m = running ?? open.first {
            Button { app.page = .chat(m.id) } label: {
                HStack(spacing: 4) {
                    Image(systemName: running != nil ? "bolt.fill" : m.agentSymbol).foregroundStyle(running != nil ? .green : .secondary).frame(width: 14)
                    Text(running != nil ? L("Gerade:") : L("Offen:")).foregroundStyle(.secondary)
                    Text(m.title).lineLimit(1)
                    Spacer(minLength: 0)
                    if let ok = m.verify?.passed { Image(systemName: ok ? "checkmark.seal.fill" : "xmark.seal.fill").foregroundStyle(ok ? .green : .red) }
                }.font(.caption)
            }.buttonStyle(.plain).help(L("Auftrag öffnen"))
        } else if !p.lastCommit.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary).frame(width: 14)
                Text(L("Zuletzt:")).foregroundStyle(.secondary)
                Text(p.lastCommit).lineLimit(1)
                if !p.lastCommitAge.isEmpty { Text("· " + p.lastCommitAge).foregroundStyle(.tertiary).lineLimit(1).layoutPriority(1) }
            }.font(.caption)
        }
    }
}
