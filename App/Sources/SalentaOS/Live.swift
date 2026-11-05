import AgenticOSKit
import AppKit
import SwiftUI

// "Was läuft gerade?" – alles an einer Stelle: Sitzungen im Salenta Code, Claude-Code- und Codex-Sitzungen
// aus anderen Fenstern (über ihre Verlaufsdateien). Ein Klick zeigt die Sitzung live wie
// in Claude Code – als Chat, nicht als Technik.

struct LiveItem: Identifiable, Hashable {
    enum Kind: Hashable { case inApp(UUID), transcript(String), app(String) }
    let id: String
    let kind: Kind
    let agent: String
    let symbol: String
    let title: String
    let project: String
    let since: Date
    let running: Bool
}

/// Eine Verlaufsdatei (Claude Code: ~/.claude/projects, Codex: ~/.codex/sessions).
struct TranscriptFile: Hashable {
    let url: URL
    let agent: AgentKind
    let modified: Date
}

final class LiveMonitor: ObservableObject {
    @Published var transcripts: [TranscriptFile] = []
    @Published var projects: [ProjectActivity] = []
    private var timer: Timer?

    struct ProjectActivity: Identifiable, Hashable {
        var id: String { path }
        let path: String
        let name: String
        let sessions: Int
        let last: Date
        let company: Company?
    }

    func start() {
        guard timer == nil else { return }
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.scan() }
        timer?.tolerance = 5
    }

    /// "Läuft" = in den letzten 3 Minuten geschrieben.
    var active: [TranscriptFile] { transcripts.filter { $0.modified > Date().addingTimeInterval(-180) } }

    // Gemessen: ein Durchgang las früher bei jedem Takt den Anfang jeder Verlaufsdatei der letzten 7 Tage – und
    // Durchgänge stapelten sich (110 % CPU, Speicher wuchs auf GB). Jetzt: nie zwei gleichzeitig, Arbeitsordner je Datei
    // nur einmal lesen (ändert sich nie), und nur veröffentlichen, wenn sich etwas geändert hat.
    private var scanning = false
    private static var cwdCache: [String: String] = [:]
    private static let cacheLock = NSLock()

    private func scan() {
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async {
            let files = Self.recentFiles(days: 30)
            let projects = Self.activity(files.filter { $0.modified > Date().addingTimeInterval(-7 * 86400) })
            DispatchQueue.main.async {
                self.scanning = false
                if files != self.transcripts { self.transcripts = files }
                if projects != self.projects { self.projects = projects }
            }
        }
    }

    static func cachedCwd(_ url: URL) -> String? {
        cacheLock.lock(); let hit = cwdCache[url.path]; cacheLock.unlock()
        if let hit { return hit.isEmpty ? nil : hit }
        let c = Transcript.cwd(of: url)
        cacheLock.lock(); cwdCache[url.path] = c ?? ""; if cwdCache.count > 5000 { cwdCache.removeAll() }; cacheLock.unlock()
        return c
    }

    private static func recentFiles(days: Double) -> [TranscriptFile] {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-days * 86400)
        var out: [TranscriptFile] = []
        let claudeRoot = Paths.home.appendingPathComponent(".claude/projects")
        for dir in (try? fm.contentsOfDirectory(at: claudeRoot, includingPropertiesForKeys: nil)) ?? [] {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where f.pathExtension == "jsonl" {
                let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if d > cutoff { out.append(TranscriptFile(url: f, agent: .claude, modified: d)) }
            }
        }
        // Codex legt Tagesordner an (JJJJ/MM/TT): nur die Tage im Zeitraum ansehen statt den ganzen Baum
        // (gemessen: der ganze Baum war der größte CPU-Posten dieses Scanners).
        let codexRoot = Paths.home.appendingPathComponent(".codex/sessions")
        let cal = Calendar.current
        var day = cutoff
        while day <= Date().addingTimeInterval(86400) {
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = codexRoot.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where f.pathExtension == "jsonl" {
                let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if d > cutoff { out.append(TranscriptFile(url: f, agent: .codex, modified: d)) }
            }
            day = day.addingTimeInterval(86400)
        }
        return out.sorted { $0.modified > $1.modified }
    }

    private static func activity(_ files: [TranscriptFile]) -> [ProjectActivity] {
        var groups: [String: (Int, Date)] = [:]
        for f in files {
            let cwd = cachedCwd(f.url) ?? Paths.home.path
            let cur = groups[cwd] ?? (0, .distantPast)
            groups[cwd] = (cur.0 + 1, max(cur.1, f.modified))
        }
        return groups.map { path, v in
            let name = (path as NSString).lastPathComponent
            return ProjectActivity(path: path, name: path == Paths.home.path ? "Home" : name, sessions: v.0, last: v.1, company: companyFor(path))
        }
        .sorted { $0.last > $1.last }
    }

    static func companyFor(_ path: String) -> Company? { Company.match(in: path) }
}

// MARK: - Verlauf lesen

struct TranscriptEntry: Identifiable, Hashable {
    let id: Int
    enum Role: Hashable { case user, assistant, tool }
    let role: Role
    let text: String
    let date: Date?
}

enum Transcript {
    static func cwd(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let data = h.readData(ofLength: 60_000)
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(60) {
            guard let d = line.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if let c = j["cwd"] as? String { return c }
            if let c = (j["payload"] as? [String: Any])?["cwd"] as? String { return c }
        }
        return nil
    }

    /// Liest die letzten ~400 KB und macht daraus Chat-Einträge.
    static func read(_ url: URL) -> [TranscriptEntry] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > 400_000 ? size - 400_000 : 0
        try? h.seek(toOffset: start)
        let data = h.readDataToEndOfFile()
        var out: [TranscriptEntry] = []
        var n = 0
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let d = line.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let date = (j["timestamp"] as? String).flatMap(parseISO)
            // Claude Code
            if let msg = j["message"] as? [String: Any], let role = msg["role"] as? String {
                for (r, t) in parts(msg["content"], role: role) { n += 1; out.append(TranscriptEntry(id: n, role: r, text: t, date: date)) }
                continue
            }
            // Codex
            if let p = j["payload"] as? [String: Any] {
                let type = p["type"] as? String
                if type == "message", let role = p["role"] as? String, role != "developer" && role != "system" {
                    for (r, t) in parts(p["content"], role: role) { n += 1; out.append(TranscriptEntry(id: n, role: r, text: t, date: date)) }
                } else if type == "function_call" || type == "local_shell_call" || type == "custom_tool_call" {
                    let name = p["name"] as? String ?? "Werkzeug"
                    let args = (p["arguments"] as? String) ?? (p["input"] as? String) ?? ""
                    n += 1
                    out.append(TranscriptEntry(id: n, role: .tool, text: "\(name): \(summarize(args))", date: date))
                }
            }
        }
        return out.filter { !$0.text.isEmpty }
    }

    private static func parts(_ content: Any?, role: String) -> [(TranscriptEntry.Role, String)] {
        let r: TranscriptEntry.Role = role == "user" ? .user : .assistant
        if let s = content as? String { return s.hasPrefix("<") ? [] : [(r, s)] }
        var out: [(TranscriptEntry.Role, String)] = []
        for c in content as? [[String: Any]] ?? [] {
            switch c["type"] as? String {
            case "text", "input_text", "output_text":
                if let t = c["text"] as? String, !t.hasPrefix("<") { out.append((r, t)) }
            case "tool_use":
                let name = c["name"] as? String ?? "Werkzeug"
                let input = c["input"] as? [String: Any] ?? [:]
                let detail = (input["command"] ?? input["file_path"] ?? input["pattern"] ?? input["description"] ?? input["url"]).map { "\($0)" } ?? ""
                out.append((.tool, "\(name)\(detail.isEmpty ? "" : ": " + summarize(detail))"))
            default:
                break
            }
        }
        return out
    }

    private static func summarize(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count > 140 ? String(one.prefix(140)) + "…" : one
    }

    static func title(of url: URL) -> String {
        read(url).first(where: { $0.role == .user })?.text.components(separatedBy: .newlines).first.map { String($0.prefix(100)) } ?? "Sitzung"
    }

    static func sessionID(of file: TranscriptFile) -> String {
        let name = file.url.deletingPathExtension().lastPathComponent
        return file.agent == .codex && name.count >= 36 ? String(name.suffix(36)) : name
    }
}

/// Live-Ansicht einer Claude-Code- oder Codex-Sitzung als Chat.
struct TranscriptView: View {
    let file: TranscriptFile
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var app: AppModel
    @State private var entries: [TranscriptEntry] = []
    @State private var showTools = true
    @State private var cwd: String?
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Grid.m) {
                Image(systemName: file.agent.symbol).font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entries.first(where: { $0.role == .user })?.text.components(separatedBy: .newlines).first ?? file.agent.title)
                        .font(.headline).lineLimit(1)
                    Text("\(file.agent.title) · \(((cwd ?? "") as NSString).lastPathComponent) · \(isLive ? "läuft gerade" : "zuletzt \(relativeDay(file.modified))")")
                        .font(.caption).foregroundStyle(isLive ? Color.green : Color.secondary)
                }
                Spacer()
                Toggle("Werkzeuge zeigen", isOn: $showTools).toggleStyle(.checkbox).controlSize(.small)
                Button {
                    let title = entries.first(where: { $0.role == .user })?.text.components(separatedBy: .newlines).first ?? file.agent.title
                    let s = agents.resume(file, in: cwd ?? Paths.home.path, title: String(title.prefix(90)))
                    app.page = .chat(s.id.uuidString)
                } label: { Label("Hier weiterarbeiten", systemImage: "text.cursor") }
                .buttonStyle(.borderedProminent)
                .help(isLive ? "Läuft noch in einem anderen Fenster – erst dort beenden." : "Sitzung im Salenta Code fortsetzen")
            }
            .padding(Grid.m)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Grid.m) {
                        ForEach(entries.filter { showTools || $0.role != .tool }) { e in
                            TranscriptRow(entry: e).id(e.id)
                        }
                        if isLive {
                            HStack(spacing: Grid.s) { ProgressView().controlSize(.small); Text("arbeitet …").foregroundStyle(.secondary) }.id(-1)
                        }
                    }
                    .padding(Grid.xl)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: entries.count) { _, _ in proxy.scrollTo(isLive ? -1 : (entries.last?.id ?? -1), anchor: .bottom) }
            }
        }
        .onAppear(perform: load)
        .onReceive(timer) { _ in if isLive || entries.isEmpty { load() } }
    }

    private var isLive: Bool {
        let d = (try? file.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? file.modified
        return d > Date().addingTimeInterval(-180)
    }

    private func load() {
        let url = file.url
        DispatchQueue.global(qos: .userInitiated).async {
            let e = Transcript.read(url)
            let c = Transcript.cwd(of: url)
            DispatchQueue.main.async {
                if e.count != entries.count { entries = e }
                cwd = c
            }
        }
    }
}

struct TranscriptRow: View {
    let entry: TranscriptEntry

    var body: some View {
        switch entry.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(entry.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.accentColor.opacity(0.85)))
                    .foregroundStyle(.white)
            }
        case .assistant:
            MarkdownText(entry.text).frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            Label(entry.text, systemImage: "wrench.and.screwdriver")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        }
    }
}

// MARK: - "Läuft gerade"-Knopf mit Liste

struct RunningButton: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var live: LiveMonitor
    @EnvironmentObject private var app: AppModel
    @State private var open = false

    private var count: Int {
        let inApp = agents.sessions.filter(\.running).count
        return inApp + live.active.count
    }

    var body: some View {
        HStack(spacing: 4) {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Circle().fill(count > 0 ? Color.green : Color.secondary.opacity(0.5)).frame(width: 9, height: 9)
                Text(count == 0 ? "Nichts läuft" : "\(count) läuft gerade").font(.callout.weight(.semibold))
                Image(systemName: "chevron.down").font(.caption2)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(count > 0 ? Color.green.opacity(0.15) : Color.secondary.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            RunningList { open = false }.frame(width: 420)
        }
        Button { openWindow(id: "live") } label: { Image(systemName: "macwindow.on.rectangle") }
            .buttonStyle(.borderless)
            .help("Live-Fenster: alles, was gerade arbeitet, groß und in Echtzeit (⌘L)")
        }
    }
}

struct RunningList: View {
    var onSelect: () -> Void
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var live: LiveMonitor
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.s) {
            Text("Läuft gerade").font(.headline)
            let inApp = agents.sessions.filter(\.running)
            if inApp.isEmpty && live.active.isEmpty {
                Text("Gerade arbeitet kein Agent.").foregroundStyle(.secondary)
            }
            ForEach(inApp) { s in
                row(symbol: s.kind.symbol, title: s.label, detail: "\(s.kind.title) · \(s.directory.lastPathComponent) · im Salenta Code") {
                    agents.selected = s.id
                    app.page = .agents
                }
            }
            ForEach(live.active, id: \.url) { f in
                row(symbol: f.agent.symbol, title: Transcript.title(of: f.url),
                    detail: "\(f.agent.title) · \((Transcript.cwd(of: f.url).map { ($0 as NSString).lastPathComponent }) ?? "") · anderes Fenster") {
                    app.page = .live(f.url.path)
                }
            }
            Divider()
            Button("Alles in Mission Control") { app.page = .mission; onSelect() }.buttonStyle(.link)
        }
        .padding(Grid.l)
    }

    private func row(symbol: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            onSelect()
        } label: {
            HStack(spacing: Grid.m) {
                ZStack {
                    Circle().fill(Color.green.opacity(0.15))
                    Image(systemName: symbol).foregroundStyle(.green)
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.medium)).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Projekte & Verlauf (Cockpit)

struct ProjectsCard: View {
    @EnvironmentObject private var live: LiveMonitor
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Card(title: "Woran du gerade arbeitest", symbol: "folder.badge.gearshape",
             trailing: AnyView(Button("Verlauf") { app.page = .history }.buttonStyle(.link))) {
            if live.projects.isEmpty { Text("Keine Claude-Code- oder Codex-Sitzungen in den letzten 7 Tagen.").foregroundStyle(.secondary) }
            ForEach(live.projects.prefix(6)) { p in
                Button { app.page = .history } label: {
                    HStack(spacing: Grid.s) {
                        Circle().fill(p.company?.color ?? Color.secondary).frame(width: 8, height: 8)
                        Text(p.name).font(.callout.weight(.medium))
                        if let c = p.company { Text(c.title).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text("\(p.sessions) Sitzung\(p.sessions == 1 ? "" : "en")").font(.caption).foregroundStyle(.secondary)
                        Text(relativeDay(p.last)).font(.caption).foregroundStyle(.tertiary).frame(width: 56, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Alle Sitzungen der letzten 30 Tage, nach Projekt – ein Klick zeigt den Verlauf wie in Claude Code.
struct HistoryView: View {
    @EnvironmentObject private var live: LiveMonitor
    @State private var selected: String?
    @State private var titles: [String: String] = [:]

    var body: some View {
        HSplitView {
            List(selection: $selected) {
                ForEach(live.projects) { p in
                    Section(p.name) {
                        ForEach(live.transcripts.filter { (Transcript.cwdCache[$0.url.path] ?? "") == p.path }, id: \.url.path) { f in
                            HStack(spacing: Grid.s) {
                                Image(systemName: f.agent.symbol).frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(titles[f.url.path] ?? "…").lineLimit(2)
                                    Text("\(f.agent.title) · \(relativeDay(f.modified))").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if f.modified > Date().addingTimeInterval(-180) { Circle().fill(Color.green).frame(width: 7, height: 7) }
                            }
                            .tag(f.url.path)
                            .task { if titles[f.url.path] == nil { titles[f.url.path] = Transcript.title(of: f.url) } }
                        }
                    }
                }
            }
            .frame(minWidth: 280, idealWidth: 340, maxWidth: 420)
            Group {
                if let path = selected, let f = live.transcripts.first(where: { $0.url.path == path }) {
                    TranscriptView(file: f).id(path)
                } else {
                    ContentUnavailableView("Sitzung wählen", systemImage: "text.bubble",
                                           description: Text("Claude Code und Codex – auch aus anderen Fenstern – als Chat-Verlauf, live."))
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Verlauf")
        .onAppear { Transcript.warmCache(live.transcripts) }
        .onChange(of: live.transcripts.count) { _, _ in Transcript.warmCache(live.transcripts) }
    }
}

extension Transcript {
    /// Ordner je Datei (für die Gruppierung), einmal gelesen.
    static var cwdCache: [String: String] = [:]

    static func warmCache(_ files: [TranscriptFile]) {
        for f in files where cwdCache[f.url.path] == nil {
            cwdCache[f.url.path] = cwd(of: f.url) ?? Paths.home.path
        }
    }
}

/// Seite für eine einzelne Live-Sitzung (aus "Läuft gerade").
struct LiveTranscriptPage: View {
    let path: String
    @EnvironmentObject private var live: LiveMonitor

    var body: some View {
        if let f = live.transcripts.first(where: { $0.url.path == path }) {
            TranscriptView(file: f).navigationTitle(f.agent.title)
        } else {
            TranscriptView(file: TranscriptFile(url: URL(fileURLWithPath: path),
                                                agent: path.contains("/.codex/") ? .codex : .claude, modified: Date()))
        }
    }
}
