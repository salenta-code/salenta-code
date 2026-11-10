import AgenticOSKit
import AppKit
import SwiftUI

// Der eigene Agent im Salenta Code: ein Agent-Loop im Hintergrund mit Werkzeugen.
// Motor: Claude Code ohne Oberfläche (dein Abo, kein API-Key). Werkzeuge:
//  • alle MCP-Anbindungen, die im Salenta Code verbunden sind (z. B. Shopify, Gmail, Notion …)
//  • Salenta Code selbst (Aufgaben, Termine, Mails, Obsidian, andere Agents starten) über bin/aos-mcp
//  • Browser (Playwright): dein Chrome mit deinen Logins (Erweiterung) oder ein eigenes Chrome-Profil
// Alles, was etwas verändert oder verschickt, braucht deine Freigabe im Salenta Code (Freigabe-Leiste oben).

enum OSAgent {
    static var supportDir: URL {
        let d = Paths.support
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// "extension" = dein normales Chrome über die Playwright-Erweiterung, "profil" = eigenes Chrome-Profil für den Agent.
    static var browserMode: String { UserDefaults.standard.string(forKey: "agent.browser") ?? "profil" }

    /// Grundregeln (allgemein) + deine eigenen Regeln aus den Einstellungen.
    static var rules: String {
        let name = Profile.name
        var r = """
        You are \(name)'s agent inside Salenta Code on their Mac. Work autonomously until the task is done, using your tools:
        the connected integrations (MCP), Salenta Code itself (tasks, calendar, mail, Obsidian, other agents) and the browser.
        Rules:
        - Reply in \(Profile.languageName), short and concrete. At the end: what is done, what is still open.
        - Get context first: the Salenta Code tool `lage` and Obsidian (obsidian_suchen / obsidian_lesen) if a vault is connected.
        - Anything that leaves the Mac or changes something (messages, mails, posts, orders, deleting, submitting forms) goes \
        through an approval – the system asks \(name) automatically in the background. If a tool call goes through, it was approved; \
        don't mention the approval. If it is denied, continue without that step and list it at the end.
        - In the browser: no payments, never type passwords, never create accounts. If a login is missing, say so.
        - Never write passwords, tokens or API keys into answers, files or notes.
        - Coding is not your job: hand it off with the tool `delegieren` (ordner = project path) and continue with the result:
          • claude (Claude Code): building new things, features, refactoring, larger changes
          • junie (Junie): debugging – find the cause, fix bugs, including bugs other agents introduced
          • codex (Codex): review and double-checking changes, tests, second opinion
        Pick the model when delegating: `modell` opus for hard work (architecture, multi-file, tricky bugs), sonnet normally, \
        haiku for trivial edits; for codex `denktiefe` high for deep reviews, medium normally.
        For bugs: let junie find and fix it first, then let codex double-check – pass codex the `ordner` from junie's result \
        (coding helpers work in their own copy of the repo; the user reviews and merges the changes afterwards).
        - Find the right project folder and fitting skills with `projekte_und_skills` (keyword from the task). Mention the chosen \
        skills in the delegated task ("Use these skills: /name") and tell \(name) at the end which ones you used.
        - At the end, record the result with obsidian_schreiben (modus journal) if a vault is connected.
        """
        let ext = ExtensionStore.shared.installedList.filter { !$0.usage.isEmpty }
        if !ext.isEmpty {
            r += "\nInstalled extensions you (and delegated Claude Code runs) can use:\n" + ext.map { "- \($0.name): \($0.usage)" }.joined(separator: "\n") + "\n"
        }
        r += "If a task would clearly benefit from a tool that is not installed (e.g. Playwright for UI checks, a security plugin, Junie for debugging), say so at the start and suggest it to \(name) instead of installing it yourself.\n"
        let own = UserDefaults.standard.string(forKey: "agent.rules")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !own.isEmpty { r += "\nRules from \(name) (always follow):\n" + own + "\n" }
        return r
    }

    /// Werkzeuge ohne Rückfrage. Alles andere fragt über mcp__salenta-os__freigabe (die liest-Tools winkt sie selbst durch).
    static let allowedTools = ["Read", "Grep", "Glob", "WebSearch", "WebFetch", "TodoWrite", "Task",
                               "mcp__salenta-os"]   // Browser läuft über die Freigabe (Steuerung mit Zeitlimit)

    /// Baut die MCP-Konfiguration für einen Lauf (Datei nur für dich lesbar, mit frischen Tokens).
    /// Namen der verbundenen Integrationen (für die KI-Wahl der Tools).
    static func toolNames(hub: MCPHub) -> [String] {
        var names = ["browser"]
        for s in hub.all where hub.connections[s.id]?.state == .connected || s.origin == "Salenta OS" {
            let n = safeName(s.name).lowercased()
            if n != "salenta-os", !names.contains(n) { names.append(n) }
        }
        return names
    }

    /// only: nur diese Integrationen (nil = alle verbundenen). browser: Playwright-Browser dazu.
    static func prepareConfig(hub: MCPHub, only: [String]? = nil, browser: Bool = true, source: String = "os-agent") async -> URL {
        var servers: [String: Any] = [:]
        let allow = only.map { Set($0.map { $0.lowercased() }) }
        let py = "/usr/bin/python3"
        servers["salenta-os"] = ["command": py, "args": [Paths.root.appendingPathComponent("bin/aos-mcp").path],
                                 "env": ["AOS_HOME": Paths.root.path, "AOS_SOURCE": source]]
        var browserArgs = ["-y", "@playwright/mcp@latest"]
        if browserMode == "extension" {
            browserArgs.append("--extension")
        } else {
            browserArgs += ["--browser", "chrome", "--user-data-dir", supportDir.appendingPathComponent("browser-profile").path]
        }
        if browser && (allow == nil || allow!.contains("browser")) {
            servers["browser"] = ["command": "/bin/zsh", "args": ["-lc", "npx " + browserArgs.map(Shell.quote).joined(separator: " ")]]
        }

        let specs = await MainActor.run { hub.all }
        for s in specs where servers[safeName(s.name)] == nil && (allow == nil || allow!.contains(safeName(s.name).lowercased())) {
            let connected = await MainActor.run { hub.connections[s.id]?.state == .connected }
            guard connected || s.origin == "Salenta OS" else { continue }
            if let url = s.url {
                var entry: [String: Any] = ["type": "http", "url": url]
                if let token = await OAuthManager.shared.validToken(for: url) {
                    entry["headers"] = ["Authorization": "Bearer \(token)"]
                } else if let h = s.headers, !h.isEmpty {
                    entry["headers"] = h
                }
                servers[safeName(s.name)] = entry
            } else if let cmd = s.command {
                var entry: [String: Any] = ["command": cmd, "args": s.args ?? []]
                if let env = s.env { entry["env"] = env }
                servers[safeName(s.name)] = entry
            }
        }
        let file = supportDir.appendingPathComponent(only == nil && browser ? "agent-mcp.json" : "agent-mcp-\(UUID().uuidString.prefix(8)).json")
        if let d = try? JSONSerialization.data(withJSONObject: ["mcpServers": servers], options: [.prettyPrinted, .withoutEscapingSlashes]) {
            FileManager.default.createFile(atPath: file.path, contents: d, attributes: [.posixPermissions: 0o600])
            try? d.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        return file
    }

    /// Nur Salenta Code als MCP (für Coding-Läufe: Freigaben für Befehle laufen darüber).
    static var aosOnlyConfig: URL {
        let file = supportDir.appendingPathComponent("aos-only-mcp.json")
        let cfg: [String: Any] = ["mcpServers": ["salenta-os": ["command": "/usr/bin/python3",
            "args": [Paths.root.appendingPathComponent("bin/aos-mcp").path],
            "env": ["AOS_HOME": Paths.root.path, "AOS_SOURCE": "claude"]]]]
        if let d = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            try? d.write(to: file, options: .atomic)
        }
        return file
    }

    static func safeName(_ n: String) -> String {
        let s = n.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        return s.isEmpty ? "server" : s
    }

    /// Startet einen Auftrag. Die Sitzung erscheint wie jede andere als Unterhaltung.
    static func start(_ request: String, agents: AgentManager, hub: MCPHub, taskID: String?, label: String,
                      model: String? = nil, tools: [String]? = nil, completion: @escaping (AgentSession) -> Void) {
        Task {
            let cfg = await prepareConfig(hub: hub, only: tools)
            await MainActor.run {
                let s = agents.start(.claude, in: Paths.root.path, prompt: request, taskID: taskID, mode: .autonom,
                                     label: label, osAgentConfig: cfg, model: model)
                if tools != nil { try? FileManager.default.removeItem(at: cfg) }   // Sitzung hat ihre eigene Kopie
                completion(s)
            }
        }
    }
}

// MARK: - Freigaben (der Agent fragt, du entscheidest)

struct ApprovalRequest: Identifiable, Hashable {
    let id: String
    let tool: String
    let input: [String: String]
    let date: Date
    /// "browser" oder "computer": der Agent möchte die Steuerung – du gibst sie für eine Zeit frei.
    var access: String? { input["_zugriff"] }

    /// "mcp__gmail__send_message" → "Gmail: send message"
    var title: String {
        let parts = tool.components(separatedBy: "__")
        if parts.count >= 3 {
            return "\(parts[1].capitalized): \(parts[2...].joined(separator: " ").replacingOccurrences(of: "_", with: " "))"
        }
        switch tool {
        case "Bash": return "Befehl ausführen"
        case "Write": return "Datei schreiben"
        case "Edit", "MultiEdit": return "Datei ändern"
        default: return tool
        }
    }
}

/// Auto-Modus: alle Freigaben automatisch erlauben (dauerhaft oder bis zu einer Uhrzeit).
/// Gespeichert in data/approvals/mode.json – bin/aos-mcp liest das bei jeder Freigabe.
enum ApprovalMode {
    static var file: URL { Paths.data.appendingPathComponent("approvals/mode.json") }

    static var until: Date? {
        guard let d = try? Data(contentsOf: file), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              j["auto"] as? Bool == true else { return nil }
        if let t = j["bis"] as? Double { return Date(timeIntervalSince1970: t) }
        return .distantFuture
    }

    static var isAuto: Bool { (until ?? .distantPast) > Date() }

    static func set(_ until: Date?) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var j: [String: Any] = ["auto": until != nil]
        if let u = until, u != .distantFuture { j["bis"] = u.timeIntervalSince1970 }
        if let d = try? JSONSerialization.data(withJSONObject: j) { try? d.write(to: file, options: .atomic) }
    }
}

struct AutoApproved: Identifiable, Hashable {
    let id = UUID()
    let tool: String
    let detail: String
    let date: Date
}

final class ApprovalCenter: ObservableObject {
    @Published var pending: [ApprovalRequest] = []
    @Published var autoUntil: Date? = ApprovalMode.until
    @Published var log: [AutoApproved] = []

    var isAuto: Bool { (autoUntil ?? .distantPast) > Date() }

    /// nil = immer fragen, .distantFuture = dauerhaft, sonst bis zu dieser Zeit.
    func setAuto(_ until: Date?) {
        ApprovalMode.set(until)
        autoUntil = ApprovalMode.until
        if isAuto { for r in pending { decide(r, allow: true) } }
    }

    /// Protokoll der automatisch erlaubten Aktionen – nur neu lesen, wenn sich die Datei geändert hat, und nur das Ende.
    private var logStamp: (UInt64, Date)?
    private func readLogIfChanged() -> [AutoApproved]? {
        let url = dir.appendingPathComponent("auto.log")
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = a[.size] as? UInt64, let mod = a[.modificationDate] as? Date else { return nil }
        if let s = logStamp, s.0 == size, s.1 == mod { return nil }
        logStamp = (size, mod)
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        try? h.seek(toOffset: size > 120_000 ? size - 120_000 : 0)
        let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        let items: [AutoApproved] = text.split(separator: "\n").suffix(200).compactMap { line in
            guard let d = line.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            return AutoApproved(tool: j["tool"] as? String ?? "?", detail: j["detail"] as? String ?? "",
                                date: Date(timeIntervalSince1970: j["zeit"] as? Double ?? 0))
        }
        return items.reversed()
    }
    private var timer: Timer?
    private var notified: Set<String> = []
    weak var bridge: Bridge?
    private var dir: URL { Paths.data.appendingPathComponent("approvals", isDirectory: true) }

    func start() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Alte Freigabe-Dateien (älter als 1 Tag) aufräumen.
        let old = Date().addingTimeInterval(-86400)
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where f.lastPathComponent.hasPrefix("req-") || f.lastPathComponent.hasPrefix("dec-") {
            if let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, m < old {
                try? FileManager.default.removeItem(at: f)
            }
        }
        timer?.invalidate()
        // Melden statt abfragen: neue Freigabe-Datei → sofort prüfen. Der Takt ist nur noch Rückfallebene.
        watcher = DirectoryWatcher(url: dir) { [weak self] in self?.scan() }
        timer = Timer.scheduledTimer(withTimeInterval: watcher == nil ? 1 : 10, repeats: true) { [weak self] _ in self?.scan() }
        timer?.tolerance = 2
    }
    private var watcher: DirectoryWatcher?

    private let work = DispatchQueue(label: "approvals.scan", qos: .userInitiated)
    private var busy = false

    /// Jede Sekunde nach neuen Freigabe-Wünschen schauen – die Dateiarbeit läuft im Hintergrund, nie auf dem Hauptthread.
    private func scan() {
        guard !busy else { return }
        busy = true
        let dir = self.dir
        work.async {
            let u = ApprovalMode.until
            let newLog = self.readLogIfChanged()
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            let decided = Set(files.filter { $0.lastPathComponent.hasPrefix("dec-") }.map { String($0.deletingPathExtension().lastPathComponent.dropFirst(4)) })
            var list: [ApprovalRequest] = []
            for f in files where f.lastPathComponent.hasPrefix("req-") {
                let id = String(f.deletingPathExtension().lastPathComponent.dropFirst(4))
                guard !decided.contains(id), let d = try? Data(contentsOf: f),
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                let date = (j["zeit"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
                if date < Date().addingTimeInterval(-1800) { continue }
                var input: [String: String] = [:]
                for (k, v) in (j["input"] as? [String: Any]) ?? [:] {
                    let text = (v as? String) ?? ((try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed])).map { String(decoding: $0, as: UTF8.self) } ?? "\(v)")
                    input[k] = text.count > 600 ? String(text.prefix(600)) + "…" : text
                }
                list.append(ApprovalRequest(id: id, tool: j["tool"] as? String ?? "?", input: input, date: date))
            }
            list.sort { $0.date < $1.date }
            DispatchQueue.main.async {
                self.busy = false
                if u != self.autoUntil { self.autoUntil = u }
                if let u, u < Date() { ApprovalMode.set(nil); self.autoUntil = nil }   // abgelaufen → wieder fragen
                if let newLog { self.log = newLog }
                if list != self.pending { self.pending = list }
                for r in list where !self.notified.contains(r.id) {
                    self.notified.insert(r.id)
                    self.bridge?.app?.show("Agent möchte: \(r.title)")
                    NotifyCenter.shared.post(.approval, title: L("Freigabe nötig") + ": " + r.title,
                                             body: r.input.first.map { String($0.value.prefix(200)) } ?? "", route: .approval(r.id), key: r.id)
                }
            }
        }
    }

    func decide(_ r: ApprovalRequest, allow: Bool, message: String = "") {
        let dec: [String: Any] = ["allow": allow, "message": message.isEmpty ? (allow ? "" : "Abgelehnt.") : message]
        if let d = try? JSONSerialization.data(withJSONObject: dec) {
            try? d.write(to: dir.appendingPathComponent("dec-\(r.id).json"), options: .atomic)
        }
        pending.removeAll { $0.id == r.id }
    }
}

/// Leiste oben im Fenster: "Agent möchte … – Erlauben / Ablehnen".
struct ApprovalBar: View {
    @EnvironmentObject private var approvals: ApprovalCenter
    @State private var expanded: String?

    var body: some View {
        if let r = approvals.pending.first, let scope = r.access.flatMap(ControlScope.init(rawValue:)) {
            ControlAccessBar(request: r, scope: scope, more: approvals.pending.count - 1)
        } else if let r = approvals.pending.first {
            VStack(alignment: .leading, spacing: Grid.s) {
                HStack(spacing: Grid.m) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange).font(.title3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Dein Agent möchte: \(r.title)").font(.headline)
                        if approvals.pending.count > 1 {
                            Text("\(approvals.pending.count - 1) weitere warten").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(expanded == r.id ? "Weniger" : "Details") { expanded = expanded == r.id ? nil : r.id }
                        .buttonStyle(.link)
                    Button("Ablehnen") { approvals.decide(r, allow: false) }
                    Menu("Immer erlauben") {
                        Button("Für 1 Stunde alles erlauben") { approvals.setAuto(Date().addingTimeInterval(3600)) }
                        Button("Bis heute Abend alles erlauben") { approvals.setAuto(Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: Date())) }
                        Button("Dauerhaft alles erlauben (Auto-Modus)") { approvals.setAuto(.distantFuture) }
                    }
                    .fixedSize()
                    Button("Erlauben") { approvals.decide(r, allow: true) }
                        .buttonStyle(.borderedProminent).tint(.orange)
                }
                let lines = r.input.sorted { $0.key < $1.key }
                ForEach(lines.prefix(expanded == r.id ? 20 : 3), id: \.key) { k, v in
                    HStack(alignment: .top, spacing: Grid.s) {
                        Text(keyLabel(k)).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                        Text(v).font(.caption).textSelection(.enabled).lineLimit(expanded == r.id ? nil : 2)
                    }
                }
            }
            .padding(Grid.m)
            .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.orange.opacity(0.5)))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .frame(maxWidth: 760)
            .padding(Grid.m)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Einstellungen des Agents (Browser).
struct AgentBrowserSettings: View {
    @AppStorage("agent.browser") private var mode = "profil"
    var body: some View {
        Section("Dein Agent – Browser") {
            Picker("Browser", selection: $mode) {
                Text("Eigenes Chrome-Profil (einmal anmelden)").tag("profil")
                Text("Dein Chrome mit deinen Logins (Erweiterung)").tag("extension")
            }
            if mode == "extension" {
                Text("Dafür in Chrome einmal die Erweiterung „Playwright Extension“ aus dem Chrome Web Store installieren. Der Agent arbeitet dann in deinen offenen Chrome-Tabs mit deinen Logins.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Chrome Web Store öffnen") {
                    Chrome.open(URL(string: "https://chromewebstore.google.com/search/Playwright%20Extension")!)
                }
            } else {
                Text("Der Agent nutzt ein eigenes Chrome-Fenster. Beim ersten Mal meldest du dich dort auf den Seiten an, die er braucht – die Logins bleiben.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}


/// Schalter "Auto-Modus" (unter dem Eingabefeld): fragen oder alles automatisch erlauben.
struct AutoModeButton: View {
    @EnvironmentObject private var approvals: ApprovalCenter
    @State private var showLog = false

    var body: some View {
        Menu {
            Button { approvals.setAuto(nil) } label: { Label("Fragen, bevor etwas verschickt oder geändert wird", systemImage: "hand.raised") }
            Divider()
            Button("Auto-Modus für 1 Stunde") { approvals.setAuto(Date().addingTimeInterval(3600)) }
            Button("Auto-Modus bis heute Abend") { approvals.setAuto(Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: Date())) }
            Button("Auto-Modus dauerhaft") { approvals.setAuto(.distantFuture) }
            Divider()
            Button("Protokoll: automatisch erlaubt (\(approvals.log.count))") { showLog = true }
        } label: {
            if approvals.isAuto {
                Label(autoText, systemImage: "bolt.shield.fill").foregroundStyle(.orange)
            } else {
                Label("Fragt vor dem Senden", systemImage: "hand.raised")
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
        .font(.caption)
        .help("Auto-Modus: alle Agents dürfen alles ohne Rückfrage – Senden, Ändern, Befehle. Jede Aktion steht im Protokoll.")
        .sheet(isPresented: $showLog) { AutoLogSheet() }
    }

    private var autoText: String {
        guard let u = approvals.autoUntil, u != .distantFuture else { return "Auto-Modus an" }
        return "Auto-Modus bis \(u.formatted(date: .omitted, time: .shortened))"
    }
}

struct AutoLogSheet: View {
    @EnvironmentObject private var approvals: ApprovalCenter
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: Grid.m) {
            HStack {
                Text("Automatisch erlaubt").font(.headline)
                Spacer()
                Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            if approvals.log.isEmpty { Text("Noch nichts.").foregroundStyle(.secondary) }
            List(approvals.log) { e in
                VStack(alignment: .leading, spacing: 2) {
                    Text(ApprovalRequest(id: "", tool: e.tool, input: [:], date: e.date).title).font(.callout.weight(.medium))
                    Text(e.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Text(e.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(Grid.l)
        .frame(width: 560, height: 480)
    }
}
