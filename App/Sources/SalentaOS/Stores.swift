import AgenticOSKit
import Foundation
import SwiftUI

/// Wo alles liegt. Persönliche Daten (Aufgaben, Aufträge, Verläufe, Logs) liegen nie im Quellcode-Ordner,
/// sondern unter ~/Library/Application Support/Salenta Code (Entwickler-Version: „Salenta Code Dev“).
/// Überschreibbar mit AOS_HOME.
enum Paths {
    /// Quellcode-Ordner, aus dem die Entwickler-Version gebaut wurde (build.sh trägt ihn ein) – sonst wie root.
    static var source: URL {
        if let built = Bundle.main.object(forInfoDictionaryKey: "AOSRoot") as? String, !built.isEmpty, !built.hasPrefix("__"),
           FileManager.default.fileExists(atPath: built) {
            return URL(fileURLWithPath: built, isDirectory: true)
        }
        return root
    }

    /// Arbeitsordner mit data/, logs/ und bin/: AOS_HOME, sonst Einstellung, sonst Application Support.
    static var root: URL {
        if let env = ProcessInfo.processInfo.environment["AOS_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        if let saved = UserDefaults.standard.string(forKey: "aos.root"), !saved.isEmpty, !isSourceFolder(saved) {
            return URL(fileURLWithPath: saved, isDirectory: true)
        }
        if isDevBuild {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Salenta Code Dev", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        // Fertige App (Download): Daten getrennt von der App, damit jedes Update sie unangetastet lässt.
        let legacy = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Salenta OS", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacy.appendingPathComponent("data").path) { return legacy }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Salenta Code", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Entwickler-Version (aus dem Quellcode gebaut) oder fertige App?
    static var isDevBuild: Bool {
        if let built = Bundle.main.object(forInfoDictionaryKey: "AOSRoot") as? String, !built.isEmpty, !built.hasPrefix("__") { return true }
        return false
    }

    /// Fertige App: die mitgelieferten Werkzeuge (bin/aos, aos-mcp, aos-live) nach root/bin legen – bei jeder neuen Version.
    /// Die Entwickler-Version hat eine eigene Kennung („…os.dev“). Einmalig deine bisherigen Einstellungen übernehmen,
    /// damit nach der Umbenennung nichts verloren geht. Die veröffentlichte App behält ihre eigenen.
    static func migrateDevDefaults() {
        guard let id = Bundle.main.bundleIdentifier, id.hasSuffix(".dev"), !UserDefaults.standard.bool(forKey: "migrated.fromMain"),
              let old = UserDefaults.standard.persistentDomain(forName: String(id.dropLast(4))) else { return }
        for (k, v) in old where UserDefaults.standard.object(forKey: k) == nil { UserDefaults.standard.set(v, forKey: k) }
        UserDefaults.standard.set(true, forKey: "migrated.fromMain")
    }

    /// Ein Quellcode-Ordner (hat App/build.sh) ist nie der Datenordner.
    static func isSourceFolder(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("App/build.sh"))
    }

    /// Entwickler-Version: Daten, die früher im Quellcode-Ordner lagen, einmalig nach Application Support umziehen
    /// und die Werkzeuge (bin/) aus dem Quellcode verlinken.
    static func moveDevDataOutOfSource() {
        guard isDevBuild else { return }
        let fm = FileManager.default
        let src = source, dst = root
        guard src.standardizedFileURL != dst.standardizedFileURL else { return }
        for d in ["data", "logs"] {
            let from = src.appendingPathComponent(d), to = dst.appendingPathComponent(d)
            guard fm.fileExists(atPath: from.path) else { continue }
            if !fm.fileExists(atPath: to.path) {
                try? fm.moveItem(at: from, to: to)
            } else {
                for f in (try? fm.contentsOfDirectory(atPath: from.path)) ?? [] where d == "data" || f == "runs" {
                    let a = from.appendingPathComponent(f), b = to.appendingPathComponent(f)
                    if !fm.fileExists(atPath: b.path) { try? fm.moveItem(at: a, to: b) }
                }
            }
        }
        // Katalog der Erweiterungen kommt aus dem Repo und bleibt dort
        let catalog = "data/mcp-catalog.json"
        if !fm.fileExists(atPath: dst.appendingPathComponent(catalog).path), fm.fileExists(atPath: src.appendingPathComponent(catalog).path) {
            try? fm.createDirectory(at: dst.appendingPathComponent("data"), withIntermediateDirectories: true)
            try? fm.copyItem(at: src.appendingPathComponent(catalog), to: dst.appendingPathComponent(catalog))
        }
        let bin = dst.appendingPathComponent("bin")
        if (try? fm.destinationOfSymbolicLink(atPath: bin.path)) == nil {
            try? fm.removeItem(at: bin)
            try? fm.createSymbolicLink(at: bin, withDestinationURL: src.appendingPathComponent("bin"))
        }
        if UserDefaults.standard.string(forKey: "aos.root").map(isSourceFolder) == true { UserDefaults.standard.removeObject(forKey: "aos.root") }
    }

    static func prepareRuntime() {
        migrateDevDefaults()
        moveDevDataOutOfSource()
        guard !isDevBuild, let res = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true),
              FileManager.default.fileExists(atPath: res.path) else { return }
        let fm = FileManager.default
        let target = root.appendingPathComponent("bin", isDirectory: true)
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""
        let stamp = target.appendingPathComponent(".version")
        if (try? String(contentsOf: stamp, encoding: .utf8)) == version { return }
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        for f in (try? fm.contentsOfDirectory(at: res, includingPropertiesForKeys: nil)) ?? [] {
            let dst = target.appendingPathComponent(f.lastPathComponent)
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: f, to: dst)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
        }
        for d in ["data", "logs"] { try? fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
        try? version.write(to: stamp, atomically: true, encoding: .utf8)
    }

    /// Private Ablage (Tokens, Browser-Profil des Agents) – nur für deinen Benutzer, nie im Repo.
    static var support: URL {
        // Entwickler-Version („…os.dev“) nutzt denselben Ordner wie bisher – laufende Aufträge, Verläufe und Caches bleiben
        let id = (Bundle.main.bundleIdentifier ?? "AgenticOS").replacingOccurrences(of: ".dev", with: "", options: [.anchored, .backwards])
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    static var data: URL {
        let dir = root.appendingPathComponent("data", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var tasks: URL { data.appendingPathComponent("tasks.json") }
    static var panels: URL { data.appendingPathComponent("panels.json") }
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
}

// MARK: - Aufgaben

/// Liest und schreibt data/tasks.json und lädt neu, sobald ein Agent die Datei ändert.
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [TaskItem] = []
    @Published var lastError: String?

    private var watcher: DirectoryWatcher?
    private var lastWritten: Data?

    init() {
        load()
        watcher = DirectoryWatcher(url: Paths.data) { [weak self] in self?.reloadIfChanged() }
    }

    func load() {
        let url = Paths.tasks
        guard let data = try? Data(contentsOf: url) else {
            tasks = Self.seed
            save()
            return
        }
        do {
            tasks = try TaskFile.decode(data).tasks
            lastWritten = data
            lastError = nil
        } catch {
            lastError = "tasks.json konnte nicht gelesen werden: \(error.localizedDescription)"
        }
    }

    private func reloadIfChanged() {
        guard let data = try? Data(contentsOf: Paths.tasks), data != lastWritten else { return }
        if let file = try? TaskFile.decode(data) {
            tasks = file.tasks
            lastWritten = data
            lastError = nil
        }
    }

    func save() {
        do {
            let data = try TaskFile(tasks: tasks).encoded()
            lastWritten = data
            try data.write(to: Paths.tasks, options: .atomic)
        } catch {
            lastError = "Speichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    // MARK: Ändern

    func add(_ task: TaskItem) {
        tasks.append(task)
        save()
    }

    func update(_ task: TaskItem) {
        guard let i = tasks.firstIndex(where: { $0.id == task.id }) else { return add(task) }
        var t = task
        if t.status == .erledigt, tasks[i].status != .erledigt { Celebration.shared.fire(L("Aufgabe erledigt"), t.title) }
        if t.status == .erledigt, t.doneAt == nil { t.doneAt = Date() }
        if t.status != .erledigt { t.doneAt = nil }
        tasks[i] = t
        save()
    }

    func move(_ id: String, to status: TaskStatus) {
        guard var t = tasks.first(where: { $0.id == id }) else { return }
        t.status = status
        update(t)
    }

    func toggleDone(_ id: String) {
        guard let t = tasks.first(where: { $0.id == id }) else { return }
        move(id, to: t.isDone ? .heute : .erledigt)
    }

    /// Ein Agent-Lauf ist zu Ende: autonom erfolgreich -> erledigt, sonst Notiz und in "Wartet".
    func finish(taskID: String, agent: AgentKind, autonomous: Bool, success: Bool, summary: String?) {
        guard var t = tasks.first(where: { $0.id == taskID }) else { return }
        // Hat der Agent die Aufgabe schon selbst abgeschlossen (aos done), nichts überschreiben.
        if t.status == .erledigt { return }
        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        var note: String
        if autonomous && success {
            t.status = .erledigt
            note = "✓ \(agent.title) fertig (\(stamp))"
        } else if autonomous {
            t.status = .warten
            note = "✗ \(agent.title) abgebrochen (\(stamp))"
        } else {
            note = "\(agent.title)-Sitzung beendet (\(stamp))"
        }
        if let summary, !summary.isEmpty { note += "\n" + summary }
        t.notes = t.notes.isEmpty ? note : t.notes + "\n\n" + note
        update(t)
    }

    func delete(_ id: String) {
        tasks.removeAll { $0.id == id }
        save()
    }

    // MARK: Lesen

    var open: [TaskItem] { tasks.filter { !$0.isDone } }

    func tasks(in status: TaskStatus, company: Company? = nil, search: String = "") -> [TaskItem] {
        var list = tasks.filter { $0.status == status }
        if let company { list = list.filter { $0.company == company } }
        if !search.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.notes.localizedCaseInsensitiveContains(search) }
        }
        if status == .erledigt {
            return Array(list.sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }.prefix(30))
        }
        return list.sorted(by: Self.order)
    }

    /// Fokus: alles in "Heute", alles Überfällige und alles, was heute fällig ist.
    var focus: [TaskItem] {
        open.filter { $0.status == .heute || $0.isOverdue() || $0.isDueToday() }.sorted(by: Self.order)
    }

    static func order(_ a: TaskItem, _ b: TaskItem) -> Bool {
        if a.priority != b.priority { return a.priority > b.priority }
        switch (a.due, b.due) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.createdAt < b.createdAt
        }
    }

    static let seed: [TaskItem] = [
        TaskItem(title: L("Salenta Code einrichten: Kalender- und Mail-Zugriff erlauben"), company: .privat, status: .heute, priority: .hoch),
    ]
}

/// Meldet Änderungen in einem Ordner (atomare Writes ersetzen die Datei, darum der Ordner).
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            self?.pending?.cancel()
            let work = DispatchWorkItem(block: onChange)
            self?.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    deinit { source?.cancel() }
}

// MARK: - Web-Panels

struct WebPanel: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var url: String
    var symbol: String
    var group: String
    /// Pfad zu einer Mac-App (.app) – dann ist es keine Web-App, sondern ein Starter.
    var app: String? = nil
}

final class PanelStore: ObservableObject {
    @Published var panels: [WebPanel] = []

    static let groups = ["Chat & KI", "Kommunikation", "Business", "Agents"]

    init() { load() }

    func load() {
        if let data = try? Data(contentsOf: Paths.panels),
           let file = try? JSONDecoder().decode(PanelFile.self, from: data), !file.panels.isEmpty {
            panels = file.panels
        } else {
            panels = Self.defaults
            save()
        }
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? enc.encode(PanelFile(panels: panels)) {
            try? data.write(to: Paths.panels, options: .atomic)
        }
    }

    func panel(_ id: String) -> WebPanel? { panels.first { $0.id == id } }

    func upsert(_ p: WebPanel) {
        if let i = panels.firstIndex(where: { $0.id == p.id }) { panels[i] = p } else { panels.append(p) }
        save()
    }

    func remove(_ id: String) {
        panels.removeAll { $0.id == id }
        WebPool.shared.forget(id)
        save()
    }

    func move(_ id: String, by delta: Int) {
        guard let i = panels.firstIndex(where: { $0.id == id }) else { return }
        let j = max(0, min(panels.count - 1, i + delta))
        guard i != j else { return }
        panels.swapAt(i, j)
        save()
    }

    func panels(in group: String) -> [WebPanel] { panels.filter { $0.group == group } }

    var allGroups: [String] {
        var seen = Self.groups.filter { g in panels.contains { $0.group == g } }
        for p in panels where !seen.contains(p.group) { seen.append(p.group) }
        return seen
    }

    func resetToDefaults() {
        panels = Self.defaults
        save()
    }

    private struct PanelFile: Codable { var panels: [WebPanel] }

    static let defaults: [WebPanel] = [
        WebPanel(id: "claude", title: "Claude", url: "https://claude.ai/new", symbol: "sparkle", group: "Chat & KI"),
        WebPanel(id: "chatgpt", title: "ChatGPT", url: "https://chatgpt.com/", symbol: "bubble.left.and.bubble.right", group: "Chat & KI"),
        WebPanel(id: "perplexity", title: "Perplexity", url: "https://www.perplexity.ai/", symbol: "magnifyingglass.circle", group: "Chat & KI"),
        WebPanel(id: "gmail", title: "Gmail", url: "https://mail.google.com/mail/u/0/#inbox", symbol: "envelope", group: "Kommunikation"),
        WebPanel(id: "gcal", title: L("Google Kalender"), url: "https://calendar.google.com/calendar/r/week", symbol: "calendar", group: "Kommunikation"),
        WebPanel(id: "outlook", title: "Outlook", url: "https://outlook.office.com/mail/", symbol: "envelope.badge", group: "Kommunikation"),
        WebPanel(id: "whatsapp", title: "WhatsApp", url: "https://web.whatsapp.com/", symbol: "message", group: "Kommunikation"),
        WebPanel(id: "slack", title: "Slack", url: "https://app.slack.com/client", symbol: "number", group: "Kommunikation"),
        WebPanel(id: "github", title: "GitHub", url: "https://github.com/", symbol: "chevron.left.forwardslash.chevron.right", group: "Business"),
    ]
}


/// Wer du bist – Name und Sprache aus den Einstellungen bzw. dem Mac.
enum Profile {
    static var name: String {
        if let n = UserDefaults.standard.string(forKey: "user.name"), !n.trimmingCharacters(in: .whitespaces).isEmpty { return n }
        return NSFullUserName().components(separatedBy: " ").first.flatMap { $0.isEmpty ? nil : $0 } ?? "du"
    }

    /// Sprache für Antworten der Agents (folgt der Sprache des Macs, außer in den Einstellungen anders gewählt).
    static var languageCode: String {
        if let l = UserDefaults.standard.string(forKey: "user.language"), !l.isEmpty { return l }
        return Locale.preferredLanguages.first?.hasPrefix("de") == true ? "de" : "en"
    }

    static var languageName: String { languageCode == "de" ? "German (informal 'du')" : "English" }
}
