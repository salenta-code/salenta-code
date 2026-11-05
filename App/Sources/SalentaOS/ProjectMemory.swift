import AgenticOSKit
import SwiftUI

// Ein Gedächtnis für alle Agents: Was ein Agent über ein Projekt gelernt hat (Entscheidungen, Stolperfallen,
// richtige Befehle, Regeln), landet im Projektwissen – und jeder Agent (Claude, Codex, Kimi, Cursor …) bekommt es
// beim nächsten Auftrag in diesem Projekt automatisch mit. Liegt lokal bei Salenta Code, nicht im Repo.

struct MemoryEntry: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var text: String
    var kind: String = "lernen"      // entscheidung, stolperfalle, befehl, regel, lernen
    var source: String = ""           // Agent / Auftrag
    var date = Date()
    var pinned = false
}

enum ProjectMemory {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "memory.on") as? Bool ?? true }
    private static let maxEntries = 60
    private static let maxPromptChars = 2800

    /// Hauptordner des Repos – auch für Arbeitskopien (git worktree) derselbe Schlüssel.
    static func root(of dir: String) -> String {
        let r = Git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: dir, timeout: 10)
        let common = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.code == 0, common.hasSuffix("/.git") { return String(common.dropLast(5)) }
        return dir
    }

    /// Stabiler Hash (hashValue ändert sich bei jedem Start)
    private static func stableHash(_ s: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 36)
    }

    static func load(_ dir: String) -> [MemoryEntry] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let d = try? Data(contentsOf: url(for: root(of: dir))), let e = try? dec.decode([MemoryEntry].self, from: d) else { return [] }
        return e
    }

    static func url(for root: String) -> URL {
        let name = (root as NSString).lastPathComponent.replacingOccurrences(of: " ", with: "-")
        let d = Paths.data.appendingPathComponent("memory", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("\(name)-\(stableHash(root)).json")
    }

    static func save(_ dir: String, _ entries: [MemoryEntry]) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        if let d = try? enc.encode(entries) { try? d.write(to: url(for: root(of: dir)), options: .atomic) }
    }

    /// Neue Erkenntnisse übernehmen – ohne Dubletten, älteste ungepinnte fallen bei Platzmangel raus.
    static func add(_ dir: String, _ new: [(text: String, kind: String)], source: String) {
        guard enabled, !new.isEmpty else { return }
        var e = load(dir)
        for n in new {
            let t = n.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count > 8, t.count < 400 else { continue }
            if e.contains(where: { similar($0.text, t) }) { continue }
            e.append(MemoryEntry(text: t, kind: n.kind, source: source))
        }
        while e.count > maxEntries, let i = e.firstIndex(where: { !$0.pinned }) { e.remove(at: i) }
        save(dir, e)
    }

    private static func similar(_ a: String, _ b: String) -> Bool {
        let wa = Set(a.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 3 })
        let wb = Set(b.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 3 })
        guard !wa.isEmpty, !wb.isEmpty else { return a == b }
        return Double(wa.intersection(wb).count) / Double(min(wa.count, wb.count)) > 0.7
    }

    /// Block für den Auftrag: gepinnte zuerst, dann die neuesten.
    static func promptBlock(_ dir: String) -> (text: String, count: Int)? {
        guard enabled else { return nil }
        let e = load(dir)
        guard !e.isEmpty else { return nil }
        let order = e.filter(\.pinned) + e.filter { !$0.pinned }.reversed()
        var lines: [String] = []
        var size = 0
        for x in order {
            let line = "- [\(x.kind)] \(x.text)"
            if size + line.count > maxPromptChars { break }
            lines.append(line); size += line.count
        }
        let text = L("Projektwissen (von früheren Aufträgen in diesem Projekt – gilt für alle Agents; beachte es, widersprich nur mit gutem Grund):")
            + "\n" + lines.joined(separator: "\n")
        return (text, lines.count)
    }
}

/// Projektwissen ansehen und bearbeiten (aus der Projektübersicht).
struct ProjectMemorySheet: View {
    let directory: String
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [MemoryEntry] = []
    @State private var newText = ""
    @State private var newKind = "regel"
    @State private var repoName = ""
    private let kinds = ["regel", "entscheidung", "stolperfalle", "befehl", "lernen"]

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.m) {
            HStack {
                Image(systemName: "brain.head.profile").foregroundStyle(Color.accentColor)
                Text(L("Projektwissen: ") + repoName).font(.headline)
                Spacer()
                Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Das lernen die Agents automatisch aus ihren Aufträgen – und jeder Agent bekommt es beim nächsten Auftrag in diesem Projekt mit. Gepinnte Einträge bleiben immer.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach($entries) { $e in
                    HStack(alignment: .top) {
                        Text(e.kind).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
                        TextField("", text: $e.text, axis: .vertical).textFieldStyle(.plain)
                        Button { e.pinned.toggle() } label: { Image(systemName: e.pinned ? "pin.fill" : "pin") }.buttonStyle(.borderless).help(L("Anheften – wird jedem Agent immer mitgegeben"))
                        Button { entries.removeAll { $0.id == e.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help(L("Eintrag löschen"))
                    }
                }
            }
            .listStyle(.inset)
            HStack {
                Picker("", selection: $newKind) { ForEach(kinds, id: \.self) { Text($0).tag($0) } }.labelsHidden().fixedSize()
                TextField("Neue Regel oder Erkenntnis, z. B. „Tests immer mit npm run test:ci“", text: $newText)
                Button("Hinzufügen") {
                    entries.append(MemoryEntry(text: newText, kind: newKind, source: L("du"), pinned: newKind == "regel"))
                    newText = ""
                }
                .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Grid.l)
        .frame(width: 720, height: 520)
        .task {
            // git nie auf dem Hauptthread
            let dir = directory
            let (e, name) = await Task.detached { (ProjectMemory.load(dir), (ProjectMemory.root(of: dir) as NSString).lastPathComponent) }.value
            entries = e; repoName = name
        }
        .onDisappear { ProjectMemory.save(directory, entries) }
    }
}
