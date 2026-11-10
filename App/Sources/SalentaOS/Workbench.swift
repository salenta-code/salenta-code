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
    /// Beim letzten Aktualisieren automatisch geholte Commits
    var pulled = 0
    var loaded = false

    struct PR: Hashable {
        let number: Int; let title: String; let url: String; let draft: Bool; let checks: String?
        var mergeable: String = ""      // MERGEABLE, CONFLICTING, UNKNOWN
        /// Bereit zum Mergen: kein Entwurf, alle Prüfungen grün (oder keine), keine Konflikte.
        var ready: Bool { !draft && checks != "failure" && checks != "pending" && mergeable == "MERGEABLE" }
    }
}

final class ProjectBoard: ObservableObject {
    @Published var items: [ProjectStatus] = []
    @Published var loading = false
    @AppStorage("projects.pinned") private var pinnedRaw = ""

    @AppStorage("projects.hidden") private var hiddenRaw = ""
    /// Ausgeblendete Projekte zeigen (gedimmt, mit „Einblenden“)
    @Published var showHidden = false

    var pinned: Set<String> { Set(pinnedRaw.split(separator: "\n").map(String.init)) }
    var hidden: Set<String> { Set(hiddenRaw.split(separator: "\n").map(String.init)) }
    func toggleHidden(_ path: String) {
        var h = hidden
        if h.contains(path) { h.remove(path) } else { h.insert(path) }
        hiddenRaw = h.sorted().joined(separator: "\n")
        objectWillChange.send()
    }
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
            // Arbeitskopien der Agents sind keine eigenen Projekte; ausgeblendete nur auf Wunsch
            if Worktrees.isWorktree(p) || p.contains("/.claude/worktrees/") || p.contains("/.codex/worktrees/") { return }
            if hidden.contains(p) && !showHidden { return }
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
        let head = Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: dir, timeout: 10)
        s.branch = head.code == 0 ? head.out.trimmingCharacters(in: .whitespacesAndNewlines)
            : Git.run(["symbolic-ref", "--short", "HEAD"], in: dir, timeout: 5).out.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.code != 0 {
            // Neues Repo ohne Commits: keine rohen Git-Fehler zeigen
            s.lastCommit = L("noch keine Commits")
            s.dirty = Git.run(["status", "--porcelain"], in: dir, timeout: 15).out.split(separator: "\n").count
            s.about = Self.about(dir, pkg: "")
            s.loaded = true
            return s
        }
        s.dirty = Git.run(["status", "--porcelain"], in: dir, timeout: 15).out.split(separator: "\n").count
        // Immer den neuesten Stand von GitHub kennen – auch was andere Agents oder Rechner hochgeladen haben
        let hasRemote = Git.run(["remote", "get-url", "origin"], in: dir, timeout: 5).code == 0
        if hasRemote { Git.run(["fetch", "--quiet", "--prune", "origin"], in: dir, timeout: 40) }
        func counts() {
            let lr = Git.run(["rev-list", "--left-right", "--count", "@{u}...HEAD"], in: dir, timeout: 10)
            if lr.code == 0 {
                let n = lr.out.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" }).compactMap { Int($0) }
                if n.count == 2 { s.behind = n[0]; s.ahead = n[1] }
            }
        }
        counts()
        // Automatisch aktuell halten: nur wenn es gefahrlos geht (nichts Eigenes, das kollidieren könnte)
        if GitSync.autoPull, s.behind > 0, s.ahead == 0, s.dirty == 0,
           Git.run(["pull", "--ff-only", "--quiet"], in: dir, timeout: 120).code == 0 {
            s.pulled = s.behind
            s.behind = 0
            counts()
        }
        let logRun = Git.run(["log", "-1", "--format=%s\t%cr"], in: dir, timeout: 10)
        let log = logRun.code == 0 ? logRun.out.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let parts = log.components(separatedBy: "\t")
        s.lastCommit = parts.first ?? ""
        s.lastCommitAge = parts.count > 1 ? parts[1] : ""
        let remote = Git.run(["remote", "get-url", "origin"], in: dir, timeout: 5).out
        if remote.contains("github.com"), Detection.which("gh") != nil {
            let pr = Proc.zsh("gh pr list --limit 8 --json number,title,url,isDraft,statusCheckRollup,mergeable", in: dir, timeout: 25)
            if pr.code == 0, let st = pr.out.firstIndex(of: "["), let en = pr.out.lastIndex(of: "]"),
               let arr = try? JSONSerialization.jsonObject(with: Data(pr.out[st...en].utf8)) as? [[String: Any]] {
                s.prs = arr.map { p in
                    let checks = (p["statusCheckRollup"] as? [[String: Any]] ?? []).compactMap { ($0["conclusion"] as? String) ?? ($0["status"] as? String) }
                    let summary: String? = checks.isEmpty ? nil : checks.contains(where: { $0.uppercased() == "FAILURE" }) ? "failure"
                        : checks.allSatisfy({ $0.uppercased() == "SUCCESS" || $0.uppercased() == "SKIPPED" || $0.uppercased() == "NEUTRAL" }) ? "success" : "pending"
                    return ProjectStatus.PR(number: p["number"] as? Int ?? 0, title: p["title"] as? String ?? "",
                                            url: p["url"] as? String ?? "", draft: p["isDraft"] as? Bool ?? false, checks: summary,
                                            mergeable: (p["mergeable"] as? String ?? "").uppercased())
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
                        Text("Wo es brennt, was offen ist, was die Agents gerade tun – pro Repo.").foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if board.loading { ProgressView().controlSize(.small) }
                    ViewThatFits(in: .horizontal) {
                        projectActions(small: false)
                        projectActions(small: true)
                    }
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
        .task {
            refresh()
            // Alle 5 Minuten neu holen, solange die Seite offen ist
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                if !Task.isCancelled, !Energy.saving { refresh() }
            }
        }
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

    @ViewBuilder private func projectActions(small: Bool) -> some View {
        HStack(spacing: Grid.s) {
            if !board.hidden.isEmpty {
                Button { board.showHidden.toggle(); refresh() } label: {
                    if small { Image(systemName: board.showHidden ? "eye.slash" : "eye") }
                    else { Label(board.showHidden ? L("Ausgeblendete verbergen") : String(format: L("Ausgeblendete zeigen (%d)"), board.hidden.count),
                                 systemImage: board.showHidden ? "eye.slash" : "eye") }
                }
                .help(L("Ausgeblendete Projekte anzeigen, um sie wieder einzublenden"))
            }
            Button { globalRules = true } label: {
                if small { Image(systemName: "shield.lefthalf.filled") } else { Label("Regeln für alle", systemImage: "shield.lefthalf.filled") }
            }.help(L("Regeln für alle"))
            Button { adding = true } label: {
                if small { Image(systemName: "plus") } else { Label("Projekt hinzufügen", systemImage: "plus") }
            }
            .buttonStyle(.borderedProminent).help(L("Projekt hinzufügen"))
        }
        .lineLimit(1).fixedSize()
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
        let name: String = p.name.lowercased()
        func terms(_ c: Company) -> [String] { ([c.title, c.rawValue] + c.tags + c.keywords).map { $0.lowercased() } }
        let match: Company? = Company.allCases.first { c in terms(c).contains { $0.count >= 3 && name.contains($0) } }
        let all: [String] = [name] + (match.map(terms) ?? [])
        let words: Set<String> = Set(all.filter { $0.count >= 4 })
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
        for pr in p.prs where pr.ready {
            out.append(Issue(color: .green, symbol: "checkmark.seal.fill",
                text: String(format: L("Pull Request #%d „%@“ ist bereit: alle Prüfungen grün, keine Konflikte."), pr.number, pr.title),
                actions: [(L("Mergen"), "arrow.triangle.merge", { merge(p, pr) }),
                          (L("PR ansehen"), "safari", { if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) } })]))
        }
        for pr in p.prs where pr.mergeable == "CONFLICTING" && !pr.draft {
            out.append(Issue(color: .orange, symbol: "exclamationmark.triangle.fill",
                text: String(format: L("Pull Request #%d „%@“ hat Konflikte mit dem aktuellen Stand."), pr.number, pr.title),
                actions: [(L("Konflikte lösen lassen"), "wrench.and.screwdriver", { fix("Der Pull Request #\(pr.number) („\(pr.title)“) hat Merge-Konflikte. Hol dir den Branch (gh pr checkout \(pr.number)), bring ihn auf den neuesten Stand des Ziel-Branches, löse die Konflikte sorgfältig, prüfe Build und Tests und pushe den Branch.") })]))
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
        if p.ahead > 0 && p.behind > 0 {
            out.append(Issue(color: .orange, symbol: "arrow.triangle.2.circlepath",
                text: String(format: L("%d Commit(s) nur auf deinem Mac und %d neue auf GitHub – erst zusammenführen, dann hochladen."), p.ahead, p.behind),
                actions: [(L("Synchronisieren"), "arrow.triangle.2.circlepath", { upload(p) })]))
        } else if p.ahead > 0 {
            out.append(Issue(color: .orange, symbol: "arrow.up.circle.fill",
                text: String(format: L("%d Commit(s) sind nur auf deinem Mac, noch nicht auf GitHub."), p.ahead),
                actions: [(L("Hochladen"), "arrow.up", { upload(p) })]))
        } else if p.behind > 0 {
            out.append(Issue(color: .secondary, symbol: "arrow.down.circle",
                text: String(format: L("Auf GitHub gibt es %d neuere Commit(s)."), p.behind)
                    + (p.dirty > 0 ? " " + L("Automatisch holen geht nicht, weil lokale Änderungen offen sind.") : ""),
                actions: [(L("Holen (Pull)"), "arrow.down", { update(p) })]))
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
                // Gleich heißende Projekte unterscheidbar machen: Ordner dahinter zeigen
                if board.items.filter({ $0.name == p.name }).count > 1 {
                    Text(((p.path as NSString).deletingLastPathComponent).replacingOccurrences(of: Paths.home.path, with: "~"))
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                        .help(p.path)
                }
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
                    Button { upload(p) } label: {
                        Label("\(p.ahead)", systemImage: "arrow.up.circle.fill").font(.caption)
                    }
                    .buttonStyle(.plain).foregroundStyle(.blue)
                    .help(L("Nicht auf GitHub – klicken zum Hochladen (Push)"))
                }
                if p.behind > 0 {
                    Button { update(p) } label: { Label("\(p.behind)", systemImage: "arrow.down.circle").font(.caption) }
                        .buttonStyle(.plain).help(L("Neue Commits auf GitHub – klicken zum Holen (Pull)"))
                }
                if p.pulled > 0 {
                    Label("\(p.pulled)", systemImage: "arrow.down.circle.fill").font(.caption).foregroundStyle(.green)
                        .help(String(format: L("%d neue Commits automatisch von GitHub geholt"), p.pulled))
                }
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
                        .overlay(alignment: .trailing) {
                            if pr.ready {
                                Button(L("Mergen")) { merge(p, pr) }.controlSize(.mini).buttonStyle(.borderedProminent).tint(.green)
                                    .help(L("Alle Prüfungen grün – in den Ziel-Branch übernehmen (Squash) und den PR-Branch löschen"))
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        if p.prs.count > 2 { Text("+ \(p.prs.count - 2) " + L("weitere Pull Requests")).font(.caption2).foregroundStyle(.tertiary) }
                        Spacer()
                        Button { PRTriage.shared.open(p.path) } label: { Label(L("Alle prüfen …"), systemImage: "checklist") }
                            .controlSize(.mini)
                            .help(L("Alle offenen Pull Requests prüfen: noch nötig, schon eingebaut, veraltet, Konflikte? Dann mit einem Klick mergen, nachbessern lassen oder schließen."))
                    }
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
                } label: {
                    // ausgeschrieben, wenn Platz ist – sonst nur das Symbol (nie abgeschnitten)
                    ViewThatFits(in: .horizontal) {
                        Label("Weiterarbeiten", systemImage: "play.fill").lineLimit(1).fixedSize()
                        Label("Weiter", systemImage: "play.fill").lineLimit(1).fixedSize()
                        Image(systemName: "play.fill")
                    }
                }
                    .buttonStyle(.borderedProminent).help(L("Weiterarbeiten"))
                Button {
                    PreviewServer.shared.start(id: "proj:" + p.path, dir: p.path) { u in if u == nil { app.show(L("Kein Dev-Server gefunden – \"dev\" in .salenta-os.json eintragen")) } }
                    previewFor = p.path
                } label: { Image(systemName: "play.display") }.help(L("Live-Vorschau der App"))
                Button { _ = agents.start(.shell, in: p.path); app.page = .agents } label: { Image(systemName: "terminal") }.help(L("Terminal im Projekt"))
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: p.path)) } label: { Image(systemName: "folder") }.help(L("Im Finder"))
                // Seltener Gebrauchtes im Menü – so passt die Leiste in jede Kartenbreite
                Menu {
                    Button { rulesFor = p.path } label: { Label(L("Regeln und Prüfbefehle"), systemImage: "shield.lefthalf.filled") }
                    Button { memoryFor = p.path } label: { Label(L("Projektwissen"), systemImage: "brain.head.profile") }
                    Divider()
                    Toggle(isOn: Binding(get: { Delegation.autoApply(p.path) }, set: { Delegation.set(p.path, apply: $0); refresh() })) {
                        Text(String(format: L("Kleine Änderungen selbst übernehmen (ab %d grünen Runden)"), Delegation.threshold))
                    }
                    Toggle(isOn: Binding(get: { Delegation.autoPush(p.path) }, set: { Delegation.set(p.path, push: $0); refresh() })) {
                        Text(L("… und danach auf GitHub hochladen"))
                    }.disabled(!Delegation.autoApply(p.path))
                    Divider()
                    Button { app.page = .steward(Steward.shared.adopt(p.path)) } label: {
                        Label(Steward.shared.projects.contains(where: { p.path.hasPrefix($0.id) }) ? L("Projekt-Betreuer öffnen") : L("In Betreuung geben"), systemImage: "safari")
                    }
                    if p.vercel != nil {
                        Button { if let u = URL(string: "https://vercel.com/dashboard") { NSWorkspace.shared.open(u) } } label: { Label("Vercel", systemImage: "triangle.fill") }
                    }
                    if p.sentry {
                        Button { if let u = URL(string: "https://sentry.io/issues/") { NSWorkspace.shared.open(u) } } label: { Label(L("Sentry-Fehler ansehen"), systemImage: "ant") }
                    }
                    Divider()
                    Button { catalog.remove(p.path) } label: { Label(L("Aus der Liste nehmen (Ordner bleibt)"), systemImage: "minus.circle") }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(L("Mehr: Regeln, Projektwissen, Betreuer, Vercel, Sentry, aus der Liste nehmen"))
                Spacer()
                Button { board.toggleHidden(p.path); refresh() } label: { Image(systemName: board.hidden.contains(p.path) ? "eye" : "eye.slash") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(board.hidden.contains(p.path) ? L("Wieder einblenden") : L("Ausblenden – das Projekt bleibt, wo es ist, und lässt sich oben wieder einblenden"))
                Button { board.togglePin(p.path); refresh() } label: { Image(systemName: board.pinned.contains(p.path) ? "pin.slash" : "pin") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Anheften"))
            }
        }
        .padding(Grid.l)
        // Alle Karten gleich hoch und nie breiter als ihre Spalte – egal wie viel los ist
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 360, maxHeight: 360, alignment: .topLeading)
        .clipped()
        .opacity(board.hidden.contains(p.path) ? 0.55 : 1)
        .frame(maxWidth: .infinity)
        .background(ModernCardBackground(radius: 16))
    }

    // MARK: Hochladen, Holen, Mergen – mit klarer Rückmeldung statt stillem Nichts

    private func upload(_ p: ProjectStatus) {
        let a = NSAlert()
        a.messageText = L("Auf GitHub hochladen?")
        a.informativeText = String(format: L("%d Commit(s) aus „%@“ (%@) werden auf GitHub hochgeladen. Neue Änderungen von GitHub werden vorher automatisch eingearbeitet."),
                                   p.ahead, p.name, p.branch)
        a.addButton(withTitle: L("Hochladen")); a.addButton(withTitle: L("Abbrechen"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        app.show(L("Lädt hoch …"))
        DispatchQueue.global(qos: .userInitiated).async {
            let (ok, msg) = GitSync.upload(repo: p.path)
            DispatchQueue.main.async {
                if ok { Celebration.shared.fire(L("Auf GitHub hochgeladen"), p.name, symbol: "arrow.up", tint: .blue) } else { app.show(msg) }
                refresh()
            }
        }
    }

    private func update(_ p: ProjectStatus) {
        app.show(L("Holt den neuen Stand …"))
        DispatchQueue.global(qos: .userInitiated).async {
            let (ok, msg) = GitSync.update(repo: p.path)
            DispatchQueue.main.async { app.show(ok ? "✓ " + msg : msg); refresh() }
        }
    }

    private func merge(_ p: ProjectStatus, _ pr: ProjectStatus.PR) {
        let a = NSAlert()
        a.messageText = String(format: L("Pull Request #%d mergen?"), pr.number)
        a.informativeText = "„\(pr.title)“\n\n" + L("Alle Prüfungen sind grün. Die Änderungen kommen als ein Commit (Squash) in den Ziel-Branch, der PR-Branch wird gelöscht. Danach holt Salenta Code den neuen Stand.")
        a.addButton(withTitle: L("Mergen")); a.addButton(withTitle: L("Abbrechen"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        app.show(L("Merged …"))
        DispatchQueue.global(qos: .userInitiated).async {
            let (ok, msg) = GitSync.mergePR(repo: p.path, number: pr.number)
            DispatchQueue.main.async {
                if ok { Celebration.shared.fire(String(format: L("PR #%d gemergt"), pr.number), pr.title, symbol: "arrow.triangle.merge", tint: .purple) } else { app.show(msg) }
                refresh()
            }
        }
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


/// Git-Abgleich mit GitHub: hochladen, holen, mergen – jeweils mit verständlicher Meldung.
enum GitSync {
    /// Projekte automatisch auf den neuesten Stand bringen (nur wenn gefahrlos möglich)
    static var autoPull: Bool { UserDefaults.standard.object(forKey: "projects.autoPull") as? Bool ?? true }

    private static func hasUpstream(_ repo: String) -> Bool {
        Git.run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: repo, timeout: 5).code == 0
    }

    /// Hochladen: neue Änderungen von GitHub vorher einarbeiten (rebase), dann pushen. Kein Branch-Raten mehr.
    static func upload(repo: String) -> (Bool, String) {
        guard Git.run(["remote", "get-url", "origin"], in: repo, timeout: 5).code == 0 else {
            return (false, L("Dieses Projekt hat kein GitHub-Repo (kein „origin“)."))
        }
        let branch = Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo, timeout: 5).out.trimmingCharacters(in: .whitespacesAndNewlines)
        if branch == "HEAD" { return (false, L("Kein Branch ausgecheckt (detached HEAD) – bitte zuerst einen Branch wählen.")) }
        if hasUpstream(repo) {
            Git.run(["fetch", "--quiet", "origin"], in: repo, timeout: 60)
            let behind = Int(Git.run(["rev-list", "--count", "HEAD..@{u}"], in: repo, timeout: 10).out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            if behind > 0 {
                let r = Git.run(["pull", "--rebase", "--autostash", "--quiet"], in: repo, timeout: 180)
                if r.code != 0 {
                    Git.run(["rebase", "--abort"], in: repo, timeout: 30)
                    return (false, L("Konflikt mit den neuen Änderungen auf GitHub – nichts hochgeladen. Lass einen Agent die Konflikte lösen."))
                }
            }
            let push = Git.run(["push", "--quiet"], in: repo, timeout: 180)
            if push.code == 0 { return (true, String(format: L("Auf GitHub hochgeladen (%@)"), branch)) }
            return (false, explain(push.out))
        }
        let push = Git.run(["push", "--quiet", "-u", "origin", "HEAD"], in: repo, timeout: 180)
        if push.code == 0 { return (true, String(format: L("Branch „%@“ neu auf GitHub angelegt und hochgeladen"), branch)) }
        return (false, explain(push.out))
    }

    /// Holen: erst gefahrlos vorspulen, sonst eigene Commits obendrauf setzen (rebase) – lokale Änderungen bleiben erhalten.
    static func update(repo: String) -> (Bool, String) {
        Git.run(["fetch", "--quiet", "--prune", "origin"], in: repo, timeout: 60)
        if Git.run(["pull", "--ff-only", "--autostash", "--quiet"], in: repo, timeout: 180).code == 0 { return (true, L("Auf dem neuesten Stand")) }
        let r = Git.run(["pull", "--rebase", "--autostash", "--quiet"], in: repo, timeout: 180)
        if r.code == 0 { return (true, L("Neuer Stand geholt – deine Commits liegen jetzt obendrauf")) }
        Git.run(["rebase", "--abort"], in: repo, timeout: 30)
        return (false, L("Holen ging nicht automatisch: Konflikt mit deinen lokalen Änderungen. Nichts verändert."))
    }

    /// PR mergen (Squash, Branch löschen) und danach den lokalen Stand holen.
    static func mergePR(repo: String, number: Int) -> (Bool, String) {
        // Merge-Nachricht ohne Agenten-Vermerke (z. B. „Co-authored-by: <KI-Agent>“, „Generated with …“) – menschliche Co-Autoren bleiben
        let info = Proc.zsh("gh pr view \(number) --json body,baseRefName", in: repo, timeout: 60)
        var base = ""
        var bodyArg = ""
        if info.code == 0, let a = info.out.firstIndex(of: "{"),
           let j = try? JSONSerialization.jsonObject(with: Data(info.out[a...].utf8)) as? [String: Any] {
            base = j["baseRefName"] as? String ?? ""
            let cleaned = cleanCredits(j["body"] as? String ?? "")
            let f = FileManager.default.temporaryDirectory.appendingPathComponent("aos-merge-\(number).md")
            if (try? cleaned.write(to: f, atomically: true, encoding: .utf8)) != nil { bodyArg = " --body-file " + Shell.quote(f.path) }
        }
        let r = Proc.zsh("gh pr merge \(number) --squash --delete-branch" + bodyArg, in: repo, timeout: 120)
        guard r.code == 0 else {
            let o = r.out.lowercased()
            if o.contains("not mergeable") || o.contains("conflict") { return (false, L("GitHub lässt den Merge nicht zu: Konflikte oder fehlende Prüfungen.")) }
            if o.contains("review") { return (false, L("Für diesen Branch ist ein Review vorgeschrieben – bitte auf GitHub freigeben.")) }
            return (false, GitError.explain(r.out))
        }
        refreshBase(repo: repo, base: base)
        return (true, String(format: L("Pull Request #%d gemergt – neuer Stand ist geholt"), number))
    }

    /// Agenten-Vermerke aus Commit-/Merge-Texten entfernen (Co-authored-by eines KI-Agents, „Generated with …“-Zeilen).
    static func cleanCredits(_ text: String) -> String {
        let agents = ["codex", "claude", "cursor", "copilot", "openai", "anthropic", "gemini", "junie", "kimi", "grok", "devin", "aider", "salenta code"]
        let lines = text.components(separatedBy: "\n").filter { line in
            let l = line.lowercased().trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("co-authored-by:"), agents.contains(where: { l.contains($0) }) { return false }
            if l.contains("generated with") && agents.contains(where: { l.contains($0) }) { return false }
            if l.hasPrefix("claude-session:") || l.hasPrefix("🤖") { return false }
            return true
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nur den Haupt-Branch auffrischen (vorspulen, nie umschreiben). Dein gerade ausgecheckter Arbeits-Branch bleibt unberührt.
    static func refreshBase(repo: String, base: String) {
        Git.run(["fetch", "--quiet", "--prune", "origin"], in: repo, timeout: 60)
        let b = base.isEmpty ? (Git.run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repo, timeout: 10).out
            .trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "origin/", with: "")) : base
        guard !b.isEmpty else { return }
        let current = Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo, timeout: 10).out.trimmingCharacters(in: .whitespacesAndNewlines)
        if current == b {
            // ausgecheckt: nur ohne eigene Änderungen und nur vorspulen
            if Git.run(["status", "--porcelain", "--untracked-files=no"], in: repo, timeout: 20).out.isEmpty {
                Git.run(["merge", "--ff-only", "--quiet", "origin/" + b], in: repo, timeout: 60)
                deliverLocalCommits(repo: repo, base: b)
            }
        } else {
            // nicht ausgecheckt: lokalen Branch-Zeiger vorspulen (schlägt still fehl, wenn er eigene Commits hat)
            Git.run(["fetch", "--quiet", "origin", b + ":" + b], in: repo, timeout: 60)
        }
    }

    /// Lokal übernommene Ergebnisse (Merge in den Haupt-Branch, ohne Pull Request – z. B. weil gh gerade nicht geprüft war)
    /// nachträglich als Pull Request liefern: die Commits wandern auf einen eigenen Branch, der Haupt-Branch geht zurück auf GitHub-Stand.
    /// So landet nichts still am Review und der CI vorbei und spätere Helfer bauen nicht auf Unveröffentlichtem auf.
    static func deliverLocalCommits(repo: String, base: String) {
        guard GH.ready else { return }
        let ahead = Git.run(["rev-list", "--count", "origin/\(base)..\(base)"], in: repo, timeout: 20).out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let n = Int(ahead), n > 0, n <= 20 else { return }
        // nur Commits, die Salenta Code selbst übernommen hat (Nachricht = Aufgabentitel aus dem Betreuer)
        let titles = Set(Steward.shared.projects.first { $0.id == repo }?.tasks.filter { $0.state == .done }.map(\.title) ?? [])
        let subjects = Git.run(["log", "--format=%s", "origin/\(base)..\(base)"], in: repo, timeout: 20).out.split(separator: "\n").map(String.init)
        guard !subjects.isEmpty, subjects.allSatisfy({ titles.contains($0) || $0.hasPrefix("Merge") || $0.hasPrefix("Checkpoint:") }) else { return }
        let short = String(UUID().uuidString.prefix(8)).lowercased()
        let branch = "aos/nachlieferung-\(short)"
        guard Git.run(["push", "origin", "\(base):refs/heads/\(branch)"], in: repo, timeout: 120).code == 0 else { return }
        let body = L("Lokal geprüfte und übernommene Ergebnisse des Projekt-Betreuers, nachträglich als Pull Request:") + "\n\n" + subjects.map { "- " + $0 }.joined(separator: "\n")
        let bf = FileManager.default.temporaryDirectory.appendingPathComponent("aos-nachlieferung-\(short).md")
        try? body.write(to: bf, atomically: true, encoding: .utf8)
        let r = Proc.zsh("gh pr create --head \(Shell.quote(branch)) --base \(Shell.quote(base)) --title \(Shell.quote(subjects.count == 1 ? subjects[0] : String(format: L("%d übernommene Ergebnisse"), subjects.count))) --body-file \(Shell.quote(bf.path))", in: repo, timeout: 90)
        try? FileManager.default.removeItem(at: bf)
        guard r.code == 0 else { return }
        Git.run(["reset", "--hard", "--quiet", "origin/" + base], in: repo, timeout: 30)
        CrashLog.mark("Nachlieferung als PR: \(branch) (\(n) Commits)")
    }

    private static func explain(_ out: String) -> String {
        let o = out.lowercased()
        if o.contains("protected") { return L("Branch ist auf GitHub geschützt – bitte als Pull Request übernehmen.") }
        if o.contains("permission") || o.contains("403") || o.contains("denied") { return L("Keine Schreibrechte für dieses Repo auf GitHub (Anmeldung prüfen: gh auth status).") }
        if o.contains("rejected") { return L("GitHub hat neuere Änderungen – bitte erst holen (Pull).") }
        return GitError.explain(out)
    }
}
