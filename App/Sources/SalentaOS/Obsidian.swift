import AgenticOSKit
import AppKit
import SwiftUI

// Obsidian ist das gemeinsame Gedächtnis: Salenta Code schreibt laufend "Salenta Code/Lage.md" (was gerade los ist)
// und nach jedem Agent-Lauf einen Eintrag ins Journal. Jeder Agent bekommt den Vault als Kontext mit
// und liest/schreibt dort (direkt oder über die MCP-Tools obsidian_* in bin/aos-mcp).

enum Obsidian {
    /// Alle Vaults aus Obsidians eigener Liste (~/Library/Application Support/obsidian/obsidian.json).
    static func vaults() -> [URL] {
        let cfg = Paths.home.appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let d = try? Data(contentsOf: cfg),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let v = j["vaults"] as? [String: Any] else { return [] }
        let list = v.values.compactMap { $0 as? [String: Any] }
        let sorted = list.sorted { (($0["open"] as? Bool) ?? false) && !(($1["open"] as? Bool) ?? false) }
        return sorted.compactMap { ($0["path"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) } }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Gewählter Vault: Einstellung, sonst der zuletzt in Obsidian geöffnete.
    static var vault: URL? {
        if let p = UserDefaults.standard.string(forKey: "obsidian.vault"), !p.isEmpty, FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        let all = vaults()
        return all.first
    }

    static var name: String { vault?.lastPathComponent ?? "Obsidian" }
    static var aosFolder: URL? { vault?.appendingPathComponent("Salenta OS", isDirectory: true) }
    static var lageFile: URL? { aosFolder?.appendingPathComponent("Lage.md") }

    static func journalFile(_ date: Date = Date()) -> URL? {
        aosFolder?.appendingPathComponent("Journal", isDirectory: true).appendingPathComponent("\(DateCoding.day(date)).md")
    }

    static func open(_ file: URL? = nil) {
        var c = URLComponents(string: "obsidian://open")!
        if let file, let v = vault, file.path.hasPrefix(v.path) {
            c.queryItems = [URLQueryItem(name: "vault", value: name),
                            URLQueryItem(name: "file", value: String(file.path.dropFirst(v.path.count + 1)))]
        } else {
            c.queryItems = [URLQueryItem(name: "vault", value: name)]
        }
        if let u = c.url { NSWorkspace.shared.open(u) }
    }

    private static var lastLage = ""

    /// Schreibt die Lage nur, wenn sich inhaltlich etwas geändert hat (schont Obsidian-Sync).
    static func writeLage(_ body: String) {
        guard let file = lageFile, let folder = aosFolder else { return }
        guard body != lastLage else { return }
        lastLage = body
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = """
        ---
        aktualisiert: \(DateCoding.stamp(Date()))
        quelle: Salenta Code
        ---
        # Lage – was gerade los ist

        Automatisch von Salenta Code gepflegt (alle 30 Sekunden bei Änderungen). Nicht von Hand bearbeiten.
        Ergebnisse der Agents stehen im [[Journal/\(DateCoding.day(Date()))|Journal von heute]].

        \(body)
        """
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Hängt einen Eintrag an das Tages-Journal.
    static func journal(agent: String, title: String, text: String, ok: Bool) {
        guard let file = journalFile() else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let time = Date().formatted(date: .omitted, time: .shortened)
        let entry = "\n## \(time) · \(agent) · \(title)\n\(ok ? "✓" : "✗ abgebrochen")\n\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        if FileManager.default.fileExists(atPath: file.path), let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write(Data(entry.utf8))
            try? h.close()
        } else {
            let head = "# Journal \(DateCoding.day(Date()))\n\nWas die Agents heute erledigt haben.\n"
            try? (head + entry).write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// Kontext-Block für jeden Agent-Auftrag.
    static var promptContext: String? {
        guard let v = vault else { return nil }
        return """
        Kontext (Obsidian-Vault \(name), \(v.path)):
        - Lies zuerst \(lageFile?.path ?? "") – dort steht, was bei mir gerade los ist (Aufgaben, Termine, laufende Agents).
        - Nutze die Notizen im Vault für Hintergrund (Firmen, Kunden, Regeln, Entscheidungen) – such gezielt nach Stichworten aus dem Auftrag.
        - Neue Erkenntnisse, Entscheidungen und Ergebnisse trägst du am Ende knapp ins Journal ein: \(journalFile()?.path ?? "") (Abschnitt "## Uhrzeit · Agent · Thema").
        - Keine Passwörter, Tokens oder API-Keys in den Vault schreiben.
        """
    }

    // MARK: Notizen lesen

    struct Note: Identifiable, Hashable {
        var id: String { url.path }
        let url: URL
        let modified: Date
        var title: String { url.deletingPathExtension().lastPathComponent }
        func folder(in vault: URL) -> String {
            let rel = url.deletingLastPathComponent().path.dropFirst(vault.path.count)
            return rel.isEmpty ? "" : String(rel.dropFirst())
        }
    }

    static func notes(limit: Int = 4000) -> [Note] {
        guard let v = vault,
              let e = FileManager.default.enumerator(at: v, includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [Note] = []
        let skip: Set<String> = ["node_modules", "dist", "build", ".venv", "venv", "Pods", "DerivedData"]
        for case let u as URL in e {
            if skip.contains(u.lastPathComponent) { e.skipDescendants(); continue }
            guard u.pathExtension.lowercased() == "md" else { continue }
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            out.append(Note(url: u, modified: d))
            if out.count >= limit { break }
        }
        return out.sorted { $0.modified > $1.modified }
    }
}

/// Gelesener Vault: je Notiz Tags, Links, Eigenschaften und ein Anriss – einmal im Hintergrund aufgebaut.
struct VaultIndex {
    /// „<< [[2026-11-04]] | **fett** >>“ → „2026-11-04 | fett“
    private static let wikiRE = try? NSRegularExpression(pattern: "\\[\\[([^\\]|]+)(?:\\|([^\\]]+))?\\]\\]")
    private static let mdLinkRE = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\([^)]*\\)")
    static func plain(_ line: String) -> String {
        var t = line
        if let re = wikiRE {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "$1")
        }
        if let re = mdLinkRE {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "$1")
        }
        for m in ["**", "__", "`", "<<", ">>", "==", "~~"] { t = t.replacingOccurrences(of: m, with: "") }
        if t.hasPrefix("- [ ] ") || t.hasPrefix("- [x] ") { t.removeFirst(6) } else if t.hasPrefix("- ") || t.hasPrefix("> ") { t.removeFirst(2) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    struct Entry: Identifiable, Hashable {
        var id: String { note.id }
        let note: Obsidian.Note
        let folder: String
        let tags: [String]
        let links: [String]          // [[Ziel]] (ohne Alias/Anker)
        let snippet: String
    }
    var entries: [Entry] = []
    var folders: [String: Int] = [:]
    var tags: [(String, Int)] = []

    /// Sofort-Index ohne Dateien zu lesen (Ordner und Titel) – damit die Liste gleich da ist.
    static func quick(_ vault: URL, notes: [Obsidian.Note]) -> VaultIndex {
        var out = VaultIndex()
        for n in notes {
            let f = n.folder(in: vault)
            out.entries.append(Entry(note: n, folder: f, tags: [], links: [], snippet: ""))
            out.folders[f, default: 0] += 1
        }
        return out
    }

    static func build(_ vault: URL, notes: [Obsidian.Note]) -> VaultIndex {
        var out = VaultIndex()
        let tagRE = try? NSRegularExpression(pattern: #"(?:^|\s)#([\p{L}\d_/-]{2,40})"#)
        let linkRE = try? NSRegularExpression(pattern: #"\[\[([^\]|#]+)"#)
        var tagCount: [String: Int] = [:]
        for n in notes {
            // nur den Anfang lesen (Tags, Links, Anriss) – große Vaults bleiben so schnell
            var text = ""
            if let h = try? FileHandle(forReadingFrom: n.url) {
                text = String(decoding: h.readData(ofLength: 24_000), as: UTF8.self)
                try? h.close()
            }
            let body = text.hasPrefix("---") ? (text.components(separatedBy: "\n---").dropFirst().joined(separator: "\n---")) : text
            let ns = text as NSString
            var tags = Set<String>()
            tagRE?.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                if let m { tags.insert(ns.substring(with: m.range(at: 1)).lowercased()) }
            }
            // tags: [a, b] im Kopf der Notiz
            if text.hasPrefix("---"), let r = text.range(of: #"\ntags:\s*\[?([^\n\]]*)"#, options: .regularExpression) {
                let line = String(text[r]).replacingOccurrences(of: "tags:", with: "")
                for t in line.split(whereSeparator: { ",[] \n#".contains($0) }) where t.count > 1 { tags.insert(t.lowercased()) }
            }
            var links: [String] = []
            linkRE?.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                if let m { links.append(ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)) }
            }
            // Vorschau als Klartext: erste echte Zeile ohne Markdown-/Wiki-Zeichen (keine reine Navigationszeile)
            let snippet = body.split(separator: "\n").lazy.map { VaultIndex.plain(String($0)) }
                .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("---") && $0.rangeOfCharacter(from: .letters) != nil && !$0.allSatisfy({ "<>|-· ".contains($0) || $0.isNumber }) } ?? ""
            let folder = n.folder(in: vault)
            out.entries.append(Entry(note: n, folder: folder, tags: tags.sorted(), links: links, snippet: String(snippet.prefix(160))))
            out.folders[folder, default: 0] += 1
            for t in tags { tagCount[t, default: 0] += 1 }
        }
        out.tags = tagCount.sorted { $0.value > $1.value }.prefix(40).map { ($0.key, $0.value) }
        return out
    }
}

/// Seite „Wissen“: dein Obsidian-Vault, strukturiert – Ordner, Tags, Suche, Lesen und Bearbeiten.
/// Änderungen landen direkt in der Datei; Obsidian (und Obsidian Sync) übernimmt sie automatisch.
struct ObsidianView: View {
    enum Filter: Hashable { case recent, folder(String), tag(String), agents }
    @EnvironmentObject private var app: AppModel
    @State private var notes: [Obsidian.Note] = []
    @State private var index = VaultIndex()
    @State private var filter: Filter = .recent
    @State private var search = ""
    @State private var selected: String?
    @State private var content = ""
    @State private var draft = ""
    @State private var editing = false
    @State private var hits: Set<String>? = nil
    @State private var loading = false
    @AppStorage("obsidian.vault") private var vaultPath = ""

    private var list: [VaultIndex.Entry] {
        var l = index.entries
        switch filter {
        case .recent: break
        case .folder(let f): l = l.filter { $0.folder == f || $0.folder.hasPrefix(f + "/") }
        case .tag(let t): l = l.filter { $0.tags.contains(t) }
        case .agents: l = l.filter { $0.folder.hasPrefix("Salenta OS") }
        }
        if !search.isEmpty { l = l.filter { $0.note.title.localizedCaseInsensitiveContains(search) || (hits?.contains($0.id) ?? false) } }
        return Array(l.sorted { $0.note.modified > $1.note.modified }.prefix(400))
    }

    var body: some View {
        Group {
            if let vault = Obsidian.vault {
                HSplitView {
                    sidebar.frame(minWidth: 190, idealWidth: 220, maxWidth: 280)
                    noteList(vault).frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
                    reader.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView {
                    Label("Kein Obsidian-Vault gefunden", systemImage: "books.vertical")
                } description: {
                    Text("Öffne Obsidian einmal mit deinem Vault oder wähle den Ordner aus.")
                } actions: {
                    Button("Vault-Ordner wählen …", action: chooseVault)
                }
            }
        }
        .navigationTitle("Wissen")
        .navigationSubtitle("Obsidian · \(Obsidian.name) · \(index.entries.count) Notizen")
        .searchable(text: $search, placement: .toolbar, prompt: "Im Vault suchen")
        .onChange(of: search) { _, q in fullText(q) }
        .onChange(of: selected) { _, id in open(id) }
        .toolbar {
            ToolbarItemGroup {
                Button { newNote() } label: { Label("Neue Notiz", systemImage: "square.and.pencil") }
                    .help(L("Neue Notiz im gewählten Ordner"))
                Menu {
                    ForEach(Obsidian.vaults(), id: \.path) { v in
                        Button(v.lastPathComponent) { vaultPath = v.path; reload() }
                    }
                    Divider()
                    Button("Ordner wählen …", action: chooseVault)
                } label: { Label(Obsidian.name, systemImage: "books.vertical") }.help(L("Vault wechseln"))
                Button { reload() } label: { Label("Neu laden", systemImage: "arrow.clockwise") }.help(L("Neu laden"))
            }
        }
        .task { reload() }
    }

    // MARK: Spalte 1 – Ordnung

    private var sidebar: some View {
        List(selection: Binding(get: { filter }, set: { if let f = $0 { filter = f } })) {
            Section("Überblick") {
                Label("Zuletzt geändert", systemImage: "clock").tag(Filter.recent)
                Label("Von den Agents", systemImage: "sparkles").tag(Filter.agents)
                    .badge(index.entries.filter { $0.folder.hasPrefix("Salenta OS") }.count)
                Button { if let f = Obsidian.lageFile { filter = .agents; selected = f.path } } label: { Label("Lage der Agents", systemImage: "scope") }
                    .buttonStyle(.plain)
                Button { if let f = Obsidian.journalFile() { filter = .agents; selected = f.path } } label: { Label("Journal heute", systemImage: "book") }
                    .buttonStyle(.plain)
            }
            Section("Ordner") {
                ForEach(topFolders, id: \.0) { f, n in
                    Label(f.isEmpty ? L("Hauptordner") : f, systemImage: "folder").badge(n).tag(Filter.folder(f))
                }
            }
            if !index.tags.isEmpty {
                Section("Tags") {
                    ForEach(index.tags.prefix(25), id: \.0) { t, n in
                        Label("#" + t, systemImage: "number").badge(n).tag(Filter.tag(t))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay { if loading && index.entries.isEmpty { ProgressView(L("Lese Vault …")) } }
    }

    /// Ordner der ersten Ebene (Unterordner zählen mit)
    private var topFolders: [(String, Int)] {
        var top: [String: Int] = [:]
        for (f, n) in index.folders { top[String(f.split(separator: "/").first ?? ""), default: 0] += n }
        return top.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    // MARK: Spalte 2 – Notizen

    private func noteList(_ vault: URL) -> some View {
        List(selection: $selected) {
            ForEach(list) { e in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(e.note.title).fontWeight(.medium).lineLimit(1)
                        Spacer()
                        Text(relativeDay(e.note.modified)).font(.caption2).foregroundStyle(.tertiary)
                    }
                    if !e.snippet.isEmpty { Text(e.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    HStack(spacing: 4) {
                        if !e.folder.isEmpty { Text(e.folder).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                        ForEach(e.tags.prefix(3), id: \.self) { t in
                            Text("#" + t).font(.caption2).foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .padding(.vertical, 2)
                .tag(e.id)
                .contextMenu {
                    Button(L("In Obsidian öffnen")) { Obsidian.open(e.note.url) }
                    Button(L("Im Finder zeigen")) { NSWorkspace.shared.activateFileViewerSelecting([e.note.url]) }
                    Button(L("Als Auftrag an einen Agent")) { app.page = .home; app.show(L("Notiz kopiert – unten einfügen")); copy(e) }
                    Divider()
                    Button(L("In den Papierkorb"), role: .destructive) { trash(e.note.url) }
                }
            }
        }
        .overlay { if list.isEmpty && !loading { Text(search.isEmpty ? L("Keine Notizen hier") : L("Nichts gefunden")).foregroundStyle(.tertiary) } }
    }

    // MARK: Spalte 3 – Lesen und Bearbeiten

    @ViewBuilder private var reader: some View {
        if let id = selected {
            let url = URL(fileURLWithPath: id)
            let entry = index.entries.first { $0.id == id }
            VStack(spacing: 0) {
                HStack(spacing: Grid.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.deletingPathExtension().lastPathComponent).font(.title2.weight(.semibold)).lineLimit(1)
                        if let e = entry, !e.folder.isEmpty { Text(e.folder).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if editing {
                        Button(L("Abbrechen")) { editing = false; draft = content }
                        Button(L("Sichern")) { save(url) }.buttonStyle(.borderedProminent).keyboardShortcut("s")
                    } else {
                        Button { draft = content; editing = true } label: { Label(L("Bearbeiten"), systemImage: "pencil") }
                            .keyboardShortcut("e")
                        Button { Obsidian.open(url) } label: { Image(systemName: "arrow.up.forward.app") }.help(L("In Obsidian öffnen"))
                    }
                }
                .padding(.horizontal, Grid.l).padding(.vertical, Grid.m)
                if let e = entry, !e.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(e.tags, id: \.self) { t in
                            Button("#" + t) { filter = .tag(t) }.buttonStyle(.plain).font(.caption)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, Grid.l).padding(.bottom, Grid.s)
                }
                Divider()
                if editing {
                    TextEditor(text: $draft)
                        .font(.system(.body, design: .monospaced))
                        .padding(Grid.m)
                        .dictation($draft)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Grid.l) {
                            MarkdownText(Self.withoutFrontmatter(content).isEmpty ? "(leer)" : Self.withoutFrontmatter(content))
                                .textSelection(.enabled)
                            links(entry)
                        }
                        .frame(maxWidth: 820, alignment: .leading)
                        .padding(Grid.xl)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } else {
            ContentUnavailableView("Notiz wählen", systemImage: "doc.text",
                                   description: Text("Alle Agents lesen diesen Vault als Kontext und schreiben ihre Ergebnisse ins Journal."))
        }
    }

    /// Verlinkt: wohin die Notiz zeigt, und wer auf sie zeigt.
    @ViewBuilder private func links(_ e: VaultIndex.Entry?) -> some View {
        if let e {
            let out = e.links.compactMap { l in index.entries.first { $0.note.title.caseInsensitiveCompare(l) == .orderedSame } }
            let back = index.entries.filter { $0.links.contains { $0.caseInsensitiveCompare(e.note.title) == .orderedSame } }
            if !out.isEmpty || !back.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Divider()
                    if !out.isEmpty { linkRow(L("Verweist auf"), out) }
                    if !back.isEmpty { linkRow(L("Wird erwähnt in"), back) }
                }
            }
        }
    }

    private func linkRow(_ title: String, _ items: [VaultIndex.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            FlowRow(items.prefix(20).map { $0 }) { x in
                Button(x.note.title) { selected = x.id }.buttonStyle(.link).font(.callout)
            }
        }
    }

    static func withoutFrontmatter(_ t: String) -> String {
        guard t.hasPrefix("---"), let r = t.range(of: "\n---", range: t.index(t.startIndex, offsetBy: 3)..<t.endIndex) else { return t }
        return String(t[r.upperBound...]).trimmingCharacters(in: .newlines)
    }

    // MARK: Aktionen

    private func open(_ id: String?) {
        editing = false
        guard let id else { content = ""; return }
        DispatchQueue.global(qos: .userInitiated).async {
            let t = (try? String(contentsOfFile: id, encoding: .utf8)) ?? ""
            DispatchQueue.main.async { if selected == id { content = t; draft = t } }
        }
    }

    private func save(_ url: URL) {
        do {
            try draft.write(to: url, atomically: true, encoding: .utf8)
            content = draft
            editing = false
            app.show("✓ " + L("Gesichert – Obsidian übernimmt es automatisch"))
            reload()
        } catch { app.show(L("Nicht gesichert: ") + error.localizedDescription) }
    }

    private func newNote() {
        guard let v = Obsidian.vault else { return }
        var dir = v
        if case .folder(let f) = filter, !f.isEmpty { dir = v.appendingPathComponent(f, isDirectory: true) }
        var name = L("Neue Notiz")
        var url = dir.appendingPathComponent(name + ".md")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) { name = L("Neue Notiz") + " \(i)"; url = dir.appendingPathComponent(name + ".md"); i += 1 }
        try? "# \(name)\n\n".write(to: url, atomically: true, encoding: .utf8)
        reload {
            selected = url.path
            draft = "# \(name)\n\n"; content = draft; editing = true
        }
    }

    private func trash(_ url: URL) {
        NSWorkspace.shared.recycle([url]) { _, err in
            DispatchQueue.main.async {
                app.show(err == nil ? "✓ " + L("In den Papierkorb gelegt") : L("Nicht gelöscht"))
                if selected == url.path { selected = nil }
                reload()
            }
        }
    }

    private func copy(_ e: VaultIndex.Entry) {
        let t = (try? String(contentsOf: e.note.url, encoding: .utf8)) ?? ""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }

    private func reload(then: (() -> Void)? = nil) {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let n = Obsidian.notes()
            guard let v = Obsidian.vault else { DispatchQueue.main.async { loading = false }; return }
            // erst die Liste (sofort), dann Tags/Links/Anriss im Hintergrund nachziehen
            let quick = VaultIndex.quick(v, notes: n)
            DispatchQueue.main.async { notes = n; index = quick; loading = false; then?() }
            let full = VaultIndex.build(v, notes: n)
            DispatchQueue.main.async { if notes.count == n.count { index = full } }
        }
    }

    /// Volltextsuche im Hintergrund (Titel sofort, Inhalt nach kurzer Pause).
    private func fullText(_ q: String) {
        let query = q.trimmingCharacters(in: .whitespaces)
        guard query.count >= 3 else { hits = nil; return }
        let list = notes
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) {
            var found = Set<String>()
            for n in list {
                if let t = try? String(contentsOf: n.url, encoding: .utf8), t.localizedCaseInsensitiveContains(query) { found.insert(n.id) }
            }
            DispatchQueue.main.async { if search.trimmingCharacters(in: .whitespaces) == query { hits = found } }
        }
    }

    private func chooseVault() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "Als Vault nutzen"
        if p.runModal() == .OK, let u = p.url { vaultPath = u.path; reload() }
    }
}

/// Einfache Zeile, die umbricht (für Links und Chips).
struct FlowRow<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content
    init(_ items: [Item], @ViewBuilder content: @escaping (Item) -> Content) { self.items = items; self.content = content }
    var body: some View {
        FlowLayout(spacing: 8) { ForEach(items, id: \.self) { content($0) } }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += sz.width + spacing; row = max(row, sz.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; row = max(row, sz.height)
        }
    }
}
