import AgenticOSKit
import AppKit
import SwiftUI
import WebKit

// Arbeitsbereich rechts im Auftrag: was der Agent geändert oder erstellt hat (mit Vorschau und Diff),
// der Verlauf als Zeitleiste und unten eine Live-Leiste mit Schritten, Aufrufen und Laufzeit.

// MARK: - Dateien

struct WorkspaceFile: Identifiable, Hashable {
    var id: String { path }
    let path: String          // relativ zum Projekt
    let added: Int
    let removed: Int
    let isNew: Bool
}

enum WorkspaceFiles {
    /// Geänderte und neue Dateien – in der Arbeitskopie gegen ihren Ausgangspunkt, sonst gegen den letzten Commit.
    static func list(_ rec: MissionRecord) -> (root: String, files: [WorkspaceFile]) {
        if let wt = rec.worktree, FileManager.default.fileExists(atPath: wt.path) {
            let root = Worktrees.top(wt)
            let status = Git.run(["status", "--porcelain"], in: root, timeout: 20).out
            let untracked = Set(status.split(separator: "\n").filter { $0.hasPrefix("??") || $0.hasPrefix("A ") }.map { String($0.dropFirst(3)) })
            let files = Worktrees.changes(wt).map { WorkspaceFile(path: $0.path, added: $0.added, removed: $0.removed, isNew: untracked.contains($0.path) || $0.removed == 0 && $0.added > 0) }
            return (root, files)
        }
        let root = Git.root(of: rec.directory) ?? rec.directory
        guard FileManager.default.fileExists(atPath: root + "/.git") || Git.root(of: root) != nil else { return (root, []) }
        let num = Git.run(["diff", "--numstat", "HEAD", "--"], in: root, timeout: 20).out
        var out: [WorkspaceFile] = num.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard p.count == 3 else { return nil }
            return WorkspaceFile(path: p[2], added: Int(p[0]) ?? 0, removed: Int(p[1]) ?? 0, isNew: false)
        }
        let untracked = Git.run(["ls-files", "--others", "--exclude-standard"], in: root, timeout: 20).out
        out += untracked.split(separator: "\n").prefix(200).map { WorkspaceFile(path: String($0), added: 0, removed: 0, isNew: true) }
        return (root, out)
    }

    static func diff(_ rec: MissionRecord, root: String, file: WorkspaceFile) -> String {
        if file.isNew { return (try? String(contentsOfFile: root + "/" + file.path, encoding: .utf8)).map { String($0.prefix(60_000)) } ?? "" }
        if let wt = rec.worktree { return String(Worktrees.diff(wt, file: file.path).prefix(80_000)) }
        return String(Git.run(["diff", "--no-color", "HEAD", "--", file.path], in: root, timeout: 20).out.prefix(80_000))
    }

    static let previewable: Set<String> = ["html", "htm", "svg", "png", "jpg", "jpeg", "gif", "webp", "pdf", "md", "txt", "json", "csv"]
}

struct WorkspacePanel: View {
    let rec: MissionRecord
    let running: Bool
    let blocks: [ChatBlock]
    @State private var tab = 0
    @State private var root = ""
    @State private var files: [WorkspaceFile] = []
    @State private var selected: WorkspaceFile?
    @State private var showDiff = false
    @State private var diffText = ""
    @State private var loading = false
    @State private var fullScreen = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text(L("Dateien") + (files.isEmpty ? "" : " (\(files.count))")).tag(0)
                Text(L("Verlauf")).tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().padding(Grid.s)
            .help(L("Dateien: was der Agent geändert oder erstellt hat · Verlauf: jeder Schritt mit Dauer"))
            Divider()
            if tab == 0 { filesView } else { StepTimeline(blocks: blocks, running: running) }
        }
        .background(Color.secondary.opacity(0.04))
        .task(id: "\(rec.id)-\(running)") { await refreshLoop() }
        .sheet(isPresented: $fullScreen) {
            if let f = selected {
                VStack(spacing: 0) {
                    HStack { Text(f.path).font(.headline).lineLimit(1); Spacer(); Button(L("Schließen")) { fullScreen = false }.keyboardShortcut(.cancelAction) }.padding(Grid.m)
                    Divider()
                    preview(f)
                }
                .frame(minWidth: 900, minHeight: 640)
            }
        }
    }

    private var filesView: some View {
        VStack(spacing: 0) {
            if files.isEmpty {
                VStack(spacing: Grid.s) {
                    Image(systemName: "doc.on.doc").font(.title2).foregroundStyle(.tertiary)
                    Text(loading ? L("Wird geladen …") : running ? L("Noch nichts geändert – sobald der Agent Dateien schreibt, erscheinen sie hier.") : L("Keine geänderten Dateien."))
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(Grid.l)
            } else {
                List(selection: Binding(get: { selected?.id }, set: { id in selected = files.first { $0.id == id }; loadDiff() })) {
                    ForEach(files) { f in
                        HStack(spacing: 6) {
                            Image(systemName: f.isNew ? "doc.badge.plus" : "doc.badge.ellipsis").foregroundStyle(f.isNew ? .green : .orange)
                            VStack(alignment: .leading, spacing: 0) {
                                Text((f.path as NSString).lastPathComponent).lineLimit(1)
                                Text((f.path as NSString).deletingLastPathComponent).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                            }
                            Spacer()
                            if !f.isNew { Text("+\(f.added) −\(f.removed)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                        }
                        .tag(f.id)
                    }
                }
                .listStyle(.sidebar)
                .frame(minHeight: 120, idealHeight: 200, maxHeight: selected == nil ? .infinity : 220)
                if let f = selected {
                    Divider()
                    HStack(spacing: Grid.s) {
                        Text((f.path as NSString).lastPathComponent).font(.caption.weight(.semibold)).lineLimit(1)
                        Spacer()
                        if !f.isNew {
                            Picker("", selection: $showDiff) { Text(L("Vorschau")).tag(false); Text(L("Diff")).tag(true) }
                                .pickerStyle(.segmented).labelsHidden().fixedSize()
                                .help(L("Vorschau der Datei oder nur die Änderungen"))
                        }
                        Button { fullScreen = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.buttonStyle(.plain)
                            .help(L("Groß anzeigen"))
                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: root + "/" + f.path)) } label: { Image(systemName: "arrow.up.forward.app") }.buttonStyle(.plain)
                            .help(L("Mit der passenden App öffnen"))
                        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root + "/" + f.path)]) } label: { Image(systemName: "folder") }.buttonStyle(.plain)
                            .help(L("Im Finder zeigen"))
                    }
                    .padding(.horizontal, Grid.s).padding(.vertical, 6)
                    if showDiff && !f.isNew { WorkspaceDiffText(text: diffText) } else { preview(f) }
                }
            }
        }
    }

    @ViewBuilder private func preview(_ f: WorkspaceFile) -> some View {
        let url = URL(fileURLWithPath: root + "/" + f.path)
        let ext = url.pathExtension.lowercased()
        if ["html", "htm", "svg", "pdf"].contains(ext) {
            FilePreviewWeb(url: url, root: URL(fileURLWithPath: root))
        } else if ["png", "jpg", "jpeg", "gif", "webp"].contains(ext), let img = NSImage(contentsOf: url) {
            ScrollView { Image(nsImage: img).resizable().scaledToFit().padding(Grid.s) }
        } else if ext == "md", let s = try? String(contentsOf: url, encoding: .utf8) {
            ScrollView { Text((try? AttributedString(markdown: String(s.prefix(40_000)), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s))
                .font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(Grid.m) }
        } else if let s = try? String(contentsOf: url, encoding: .utf8) {
            ScrollView([.vertical, .horizontal]) { Text(String(s.prefix(40_000))).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(Grid.s) }
        } else {
            Text(L("Keine Vorschau – mit der passenden App öffnen.")).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadDiff() {
        guard let f = selected else { return }
        showDiff = !f.isNew && !WorkspaceFiles.previewable.contains((f.path as NSString).pathExtension.lowercased())
        let r = rec, root = root
        DispatchQueue.global(qos: .userInitiated).async {
            let d = WorkspaceFiles.diff(r, root: root, file: f)
            DispatchQueue.main.async { if selected == f { diffText = d } }
        }
    }

    /// Während der Agent arbeitet alle 6 s neu einlesen, sonst einmal.
    private func refreshLoop() async {
        loading = files.isEmpty
        repeat {
            let r = rec
            let result = await Task.detached(priority: .utility) { WorkspaceFiles.list(r) }.value
            root = result.root
            if result.files != files { files = result.files }
            loading = false
            if !running { break }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
        } while !Task.isCancelled
    }
}

struct WorkspaceDiffText: View {
    let text: String
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).prefix(4000).enumerated()), id: \.offset) { _, line in
                    let l = String(line)
                    Text(l.isEmpty ? " " : l)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(l.hasPrefix("+") && !l.hasPrefix("+++") ? Color.green : l.hasPrefix("-") && !l.hasPrefix("---") ? Color.red : l.hasPrefix("@@") ? Color.accentColor : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(l.hasPrefix("+") && !l.hasPrefix("+++") ? Color.green.opacity(0.08) : l.hasPrefix("-") && !l.hasPrefix("---") ? Color.red.opacity(0.08) : .clear)
                }
            }
            .textSelection(.enabled).padding(Grid.s)
        }
    }
}

/// Lokale Datei (HTML, SVG, PDF) anzeigen – Zugriff nur auf den Projektordner.
struct FilePreviewWeb: NSViewRepresentable {
    let url: URL
    let root: URL
    func makeNSView(context: Context) -> WKWebView {
        let v = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        v.loadFileURL(url, allowingReadAccessTo: root)
        return v
    }
    func updateNSView(_ v: WKWebView, context: Context) {
        if v.url != url { v.loadFileURL(url, allowingReadAccessTo: root) }
    }
}

// MARK: - Verlauf als Zeitleiste

struct StepTimeline: View {
    let blocks: [ChatBlock]
    let running: Bool
    @State private var open: Int?

    private struct Item: Identifiable { let id: Int; let kind: StepKind; let time: String; let text: String; let seconds: Int? }

    private var items: [Item] {
        var steps: [(Int, StepKind, String, String)] = []
        for b in blocks { if case .step(let i, let k, let t, let s) = b, !t.isEmpty { steps.append((i, k, t, s)) } }
        // Zeitstempel im Protokoll = verstrichene Zeit seit Start (mm:ss)
        func secs(_ t: String) -> Int? { let p = t.split(separator: ":").compactMap { Int($0) }; return p.count == 2 ? p[0] * 60 + p[1] : nil }
        return steps.enumerated().map { n, s in
            let next = n + 1 < steps.count ? secs(steps[n + 1].2) : nil
            let d = zip2(secs(s.2), next).map { max(0, $1 - $0) }
            return Item(id: s.0, kind: s.1, time: s.2, text: s.3, seconds: d)
        }
    }
    private func zip2(_ a: Int?, _ b: Int?) -> (Int, Int)? { if let a, let b { return (a, b) }; return nil }

    var body: some View {
        let list = items
        if list.isEmpty {
            Text(running ? L("Die ersten Schritte erscheinen gleich …") : L("Keine Schritte aufgezeichnet."))
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).padding(Grid.l)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(list) { it in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(spacing: 0) {
                                    Image(systemName: Self.symbol(it.kind)).font(.caption).foregroundStyle(Self.color(it.kind)).frame(width: 18, height: 18)
                                    Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1).frame(maxHeight: .infinity)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(it.time).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                                        if let d = it.seconds, d > 0 {
                                            Text("· " + (d >= 60 ? "\(d / 60) min \(d % 60) s" : "\(d) s")).font(.caption2)
                                                .foregroundStyle(d >= 300 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                                        }
                                    }
                                    Text(it.text).font(.caption).lineLimit(open == it.id ? nil : 2).textSelection(.enabled)
                                }
                                .padding(.bottom, 8)
                                .contentShape(Rectangle())
                                .onTapGesture { open = open == it.id ? nil : it.id }
                            }
                            .padding(.horizontal, Grid.s)
                            .id(it.id)
                        }
                    }
                    .padding(.vertical, Grid.s)
                }
                .onChange(of: list.count) { _, _ in if running, let last = list.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    static func symbol(_ k: StepKind) -> String {
        switch k {
        case .read: "doc.text.magnifyingglass"
        case .write: "pencil"
        case .run: "terminal"
        case .search: "magnifyingglass"
        case .web: "globe"
        case .tool: "wrench.and.screwdriver"
        case .plan: "list.bullet"
        case .think: "brain"
        case .error: "exclamationmark.triangle"
        case .done: "checkmark.circle"
        case .info: "info.circle"
        }
    }
    static func color(_ k: StepKind) -> Color {
        switch k {
        case .error: .red
        case .done: .green
        case .write: .orange
        case .run: .purple
        default: .secondary
        }
    }
}

// MARK: - Live-Leiste

struct LiveStatsBar: View {
    let rec: MissionRecord
    let session: AgentSession?
    let blocks: [ChatBlock]
    @ObservedObject private var store = MissionStore.shared
    @EnvironmentObject private var agents: AgentManager

    var body: some View {
        let steps = blocks.compactMap { b -> StepKind? in if case .step(_, let k, let t, _) = b, !t.isEmpty { return k }; return nil }
        let tools = steps.filter { [.read, .write, .run, .search, .web, .tool].contains($0) }.count
        let edits = steps.filter { $0 == .write }.count
        let errors = steps.filter { $0 == .error }.count
        let helpers = store.missions.filter { $0.parent == rec.id && $0.ended == nil }
        let helpersRunning = helpers.filter { h in agents.sessions.contains { $0.id.uuidString == h.id && $0.running } }
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            // Ruhige Zeile unter der Eingabe, mittig; wird es eng, fallen erst Symbole, dann Nebensachen weg
            ViewThatFits(in: .horizontal) {
                statsRow(steps: steps.count, tools: tools, edits: edits, errors: errors, helpers: helpersRunning, now: ctx.date, icons: true, full: true)
                statsRow(steps: steps.count, tools: tools, edits: edits, errors: errors, helpers: helpersRunning, now: ctx.date, icons: false, full: true)
                statsRow(steps: steps.count, tools: tools, edits: edits, errors: errors, helpers: helpersRunning, now: ctx.date, icons: false, full: false)
            }
            .font(.caption2).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 2).padding(.bottom, 6)
        }
    }

    @ViewBuilder private func statsRow(steps: Int, tools: Int, edits: Int, errors: Int, helpers: [MissionRecord], now: Date, icons: Bool, full: Bool) -> some View {
        HStack(spacing: Grid.m) {
            if session?.running == true { Circle().fill(Color.green).frame(width: 6, height: 6).help(L("arbeitet")) }
            item("\(steps) " + L("Schritte"), "list.number", icons)
            item("\(tools) " + L("Werkzeugaufrufe"), "wrench.and.screwdriver", icons)
            if full, edits > 0 { item("\(edits) " + L("Änderungen"), "pencil", icons) }
            if errors > 0 { item("\(errors) " + L("Fehler"), "exclamationmark.triangle", icons).foregroundStyle(.orange) }
            item(Self.duration(from: rec.started, to: rec.ended ?? now), "clock", icons)
            if full, !helpers.isEmpty {
                Menu {
                    ForEach(helpers, id: \.id) { h in Text("\(h.agentTitle): \(h.title)") }
                } label: { item("\(helpers.count) " + L("Helfer laufen"), "person.2", icons) }
                .menuStyle(.borderlessButton).fixedSize()
                .help(L("Unteraufträge, die gerade für diesen Auftrag arbeiten"))
            }
        }
        .lineLimit(1).fixedSize()
    }

    @ViewBuilder private func item(_ text: String, _ symbol: String, _ icon: Bool) -> some View {
        if icon { Label(text, systemImage: symbol) } else { Text(text) }
    }

    static func duration(from a: Date, to b: Date) -> String {
        let s = Int(max(0, b.timeIntervalSince(a)))
        return s >= 3600 ? String(format: "%d:%02d h", s / 3600, (s % 3600) / 60) : String(format: "%d:%02d min", s / 60, s % 60)
    }
}
