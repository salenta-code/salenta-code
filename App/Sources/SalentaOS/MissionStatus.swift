import AgenticOSKit
import SwiftUI

// Statuszeile für einen Auftrag – wie die Statuszeile in Claude Code:
// in welchem Repo und Branch gearbeitet wird, wie voll der Kontext ist, welche Konnektoren (MCP) dran sind.

struct ConnectorState: Hashable, Identifiable {
    var id: String { name }
    let name: String
    let status: String      // connected, failed, pending, needs-auth, configured
    let source: String      // woher: Sitzung, global, Projekt, Repo

    var ok: Bool { status == "connected" }
    var failed: Bool { status == "failed" }
    var needsAuth: Bool { status == "needs-auth" }
    var problem: Bool { failed || needsAuth }
    /// Anzeigename: „plugin:sales:gmail“ → „gmail“ (Plugin sales)
    var display: String {
        guard name.hasPrefix("plugin:") else { return name }
        let parts = name.split(separator: ":").map(String.init)
        return parts.count >= 3 ? parts[2...].joined(separator: ":") + " · " + parts[1] : name
    }
}

struct MissionStatusInfo: Equatable {
    var repo = ""
    var branch = ""
    var baseBranch = ""
    var isWorktree = false
    var dirty = 0
    var ahead = 0
    var model = ""
    var context = 0
    var window = 0
    var output = 0
    var connectors: [ConnectorState] = []
    var tools = 0
    var live = false        // Konnektor-Status kommt direkt vom Agent (sonst nur aus der Konfiguration)

    var contextShare: Double { window > 0 ? min(1, Double(context) / Double(window)) : 0 }
}

enum MissionStatus {
    /// Statusdatei, die bin/aos-live neben das Lauf-Protokoll schreibt.
    static func statusFile(_ rec: MissionRecord, session: AgentSession?) -> URL? {
        if let s = session {
            let u = URL(fileURLWithPath: s.logFile.path + ".json")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        let dir = Paths.root.appendingPathComponent("logs/runs", isDirectory: true)
        let suffix = "-\(rec.agent)-\(rec.id.prefix(6)).log.json"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(suffix) }.sorted().last.map { dir.appendingPathComponent($0) }
    }

    /// Größe des Kontextfensters je Modell (ohne Angabe vom Agent).
    static func window(model: String, agent: String, used: Int) -> Int {
        let m = model.lowercased()
        if m.contains("1m") { return 1_000_000 }
        if agent == "codex" || m.contains("gpt") || m.contains("codex") { return 272_000 }
        if m.contains("kimi") { return 256_000 }
        if m.contains("gemini") { return 1_000_000 }
        return used > 200_000 ? 1_000_000 : 200_000
    }

    static func load(_ rec: MissionRecord, session: AgentSession?) -> MissionStatusInfo {
        var info = MissionStatusInfo()
        let dir = rec.worktree.map { Worktrees.top($0) } ?? rec.directory
        info.model = rec.model ?? ""

        // Repo und Branch
        let top = Git.run(["rev-parse", "--show-toplevel"], in: dir, timeout: 5)
        if top.code == 0 {
            let root = rec.worktree?.base ?? top.out.trimmingCharacters(in: .whitespacesAndNewlines)
            info.repo = (root as NSString).lastPathComponent
            info.branch = Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: dir, timeout: 5).out.trimmingCharacters(in: .whitespacesAndNewlines)
            info.dirty = Git.run(["status", "--porcelain"], in: dir, timeout: 8).out.split(separator: "\n").count
            if let wt = rec.worktree {
                info.isWorktree = true
                info.baseBranch = wt.baseBranch
                info.ahead = Int(Git.run(["rev-list", "--count", "\(Worktrees.baseRef(wt))..HEAD"], in: dir, timeout: 5).out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            }
        } else {
            info.repo = (dir as NSString).lastPathComponent
        }

        // Live-Status vom Agent (autonome Läufe)
        if let u = statusFile(rec, session: session), let d = try? Data(contentsOf: u),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if let m = j["model"] as? String, !m.isEmpty { info.model = m }
            info.context = j["context"] as? Int ?? 0
            info.output = j["output"] as? Int ?? 0
            info.window = j["window"] as? Int ?? 0
            info.tools = j["tools"] as? Int ?? 0
            let mcp = (j["mcp"] as? [[String: Any]]) ?? []
            if !mcp.isEmpty {
                info.live = true
                info.connectors = mcp.map { ConnectorState(name: $0["name"] as? String ?? "?", status: $0["status"] as? String ?? "", source: L("Sitzung")) }
            }
        } else if let t = rec.transcript {
            // Dialog-Sitzung: letzte Kontextgröße aus dem Verlauf von Claude Code / Codex
            let (c, m) = transcriptUsage(URL(fileURLWithPath: t))
            info.context = c
            if let m, !m.isEmpty { info.model = m }
        }
        if info.window == 0 { info.window = window(model: info.model, agent: rec.agent, used: info.context) }

        // Ohne Live-Status: was laut Konfiguration geladen wird
        if info.connectors.isEmpty { info.connectors = configured(agent: rec.agentKind, dir: dir) }
        return info
    }

    /// Letzte Kontextgröße aus dem Ende einer Verlaufsdatei.
    static func transcriptUsage(_ url: URL) -> (Int, String?) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return (0, nil) }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 300_000 ? size - 300_000 : 0)
        let lines = String(decoding: h.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
        for line in lines.reversed() {
            guard let d = line.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            // Claude Code
            if let msg = j["message"] as? [String: Any], let u = msg["usage"] as? [String: Any], j["isSidechain"] as? Bool != true {
                let c = (u["input_tokens"] as? Int ?? 0) + (u["cache_read_input_tokens"] as? Int ?? 0) + (u["cache_creation_input_tokens"] as? Int ?? 0)
                if c > 0 { return (c, msg["model"] as? String) }
            }
            // Codex
            if let p = j["payload"] as? [String: Any], p["type"] as? String == "token_count",
               let info = p["info"] as? [String: Any], let last = info["last_token_usage"] as? [String: Any] {
                return (last["input_tokens"] as? Int ?? 0, nil)
            }
        }
        return (0, nil)
    }

    /// Konnektoren laut Konfiguration (Claude Code: ~/.claude.json global + Projekt, .mcp.json im Repo; Codex: config.toml).
    static func configured(agent: AgentKind, dir: String) -> [ConnectorState] {
        var out: [ConnectorState] = []
        func add(_ names: [String], _ src: String) {
            for n in names.sorted() where !out.contains(where: { $0.name == n }) { out.append(ConnectorState(name: n, status: "configured", source: src)) }
        }
        let home = Paths.home
        if agent == .codex {
            if let t = try? String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8) {
                let names = t.split(separator: "\n").compactMap { line -> String? in
                    let l = line.trimmingCharacters(in: .whitespaces)
                    guard l.hasPrefix("[mcp_servers."), l.hasSuffix("]") else { return nil }
                    let n = l.dropFirst("[mcp_servers.".count).dropLast()
                    return n.contains(".") ? nil : String(n).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
                add(names, L("Codex-Einstellungen"))
            }
            return out
        }
        if let d = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if let s = j["mcpServers"] as? [String: Any] { add(Array(s.keys), L("global")) }
            if let projects = j["projects"] as? [String: Any] {
                // Projekt-Eintrag des Repos (bei Arbeitskopien auch des Ausgangs-Repos)
                for (path, v) in projects where dir.hasPrefix(path) {
                    if let p = v as? [String: Any], let s = p["mcpServers"] as? [String: Any] { add(Array(s.keys), L("Projekt")) }
                }
            }
        }
        if let d = try? Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(".mcp.json")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let s = j["mcpServers"] as? [String: Any] {
            add(Array(s.keys), L("Repo (.mcp.json)"))
        }
        return out
    }

    /// Gesundheit der Konnektoren direkt beim Agent abfragen (`claude mcp list` prüft jede Verbindung).
    static func health(agent: AgentKind, dir: String) -> [ConnectorState]? {
        let cmd = agent == .codex ? "codex mcp list" : "claude mcp list"
        let r = Proc.zsh(cmd, in: dir, timeout: 90)
        guard r.code == 0 || !r.out.isEmpty else { return nil }
        var out: [ConnectorState] = []
        for raw in r.out.split(separator: "\n").map(String.init) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Claude Code: "name: befehl/url - ✓ Connected" | "- ✗ Failed to connect" | "- ⚠ Needs authentication"
            if let colon = line.firstIndex(of: ":"), let dash = line.range(of: " - ", options: .backwards) {
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !name.contains(" ") || name.count < 40 else { continue }
                let st = line[dash.upperBound...].lowercased()
                let status = st.contains("✓") || st.contains("connected") && !st.contains("fail") ? "connected"
                    : st.contains("auth") ? "needs-auth"
                    : st.contains("✗") || st.contains("fail") ? "failed" : "configured"
                out.append(ConnectorState(name: name, status: status, source: L("geprüft")))
            } else if agent == .codex, let first = line.split(separator: " ").first, !line.hasPrefix("Name"), !line.hasPrefix("-"), !line.isEmpty {
                out.append(ConnectorState(name: String(first), status: "configured", source: L("Codex-Einstellungen")))
            }
        }
        return out
    }

    static func tokens(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1f M", Double(n) / 1_000_000) : n >= 1000 ? "\(n / 1000)k" : "\(n)"
    }
}

/// Die Zeile unter dem Auftragskopf.
struct MissionStatusBar: View {
    let rec: MissionRecord
    let session: AgentSession?
    @State private var info = MissionStatusInfo()
    @State private var showConnectors = false
    @State private var checking = false
    @State private var showAuth = false
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: Grid.m) {
            // Repo und Branch
            HStack(spacing: 4) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(info.repo.isEmpty ? "…" : info.repo).fontWeight(.medium)
                if !info.branch.isEmpty {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                    Text(info.branch).lineLimit(1).truncationMode(.middle)
                    if info.isWorktree {
                        Text("← \(info.baseBranch)").foregroundStyle(.tertiary)
                    }
                }
                if info.dirty > 0 { Text("●\(info.dirty)").foregroundStyle(.orange).help(L("Geänderte, noch nicht gesicherte Dateien")) }
                if info.ahead > 0 { Text("↑\(info.ahead)").foregroundStyle(.secondary).help(L("Eigene Commits in der Arbeitskopie")) }
            }
            .help(info.isWorktree ? L("Gearbeitet wird in einer eigenen Arbeitskopie – dein Repo bleibt unverändert, bis du übernimmst.") : L("Gearbeitet wird direkt in diesem Ordner"))

            divider

            // Kontext
            HStack(spacing: 5) {
                ProgressRing(value: info.contextShare, color: contextColor, lineWidth: 2.5)
                    .frame(width: 12, height: 12)
                Text(info.context > 0
                     ? "\(L("Kontext")) \(MissionStatus.tokens(info.context)) / \(MissionStatus.tokens(info.window)) · \(Int(info.contextShare * 100)) %"
                     : L("Kontext –"))
                    .monospacedDigit()
            }
            .help(info.contextShare > 0.8
                  ? L("Kontext fast voll – der Agent fasst bald automatisch zusammen. Für Neues besser einen frischen Auftrag starten.")
                  : L("So viel vom Kontextfenster des Modells belegt der Auftrag gerade"))

            if !info.model.isEmpty {
                divider
                Text(info.model).lineLimit(1).foregroundStyle(.secondary)
            }

            divider

            // Konnektoren
            Button { showConnectors.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "powerplug")
                    if info.connectors.isEmpty {
                        Text(L("keine Konnektoren"))
                    } else {
                        Text(info.connectors.count == 1 ? L("1 Konnektor") : "\(info.connectors.count) \(L("Konnektoren"))")
                        let failed = info.connectors.filter(\.failed).count
                        let auth = info.connectors.filter(\.needsAuth).count
                        if failed > 0 { Text("· \(failed) \(L("Fehler"))").foregroundStyle(.red) }
                        if auth > 0 { Text("· \(auth) \(L("ohne Anmeldung"))").foregroundStyle(.secondary) }
                    }
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showConnectors, arrowEdge: .bottom) { connectorList }

            Spacer(minLength: 0)
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, Grid.l)
        .padding(.vertical, 6)
        .background(.background.secondary.opacity(0.5))
        .task(id: rec.id) {
            // während der Agent arbeitet alle 8 s, sonst einmal
            repeat {
                let r = rec, s = session
                let i = await Task.detached(priority: .utility) { MissionStatus.load(r, session: s) }.value
                if i != info { withAnimation(.easeOut(duration: 0.3)) { info = i } }
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            } while !Task.isCancelled && session?.running == true
        }
    }

    private var divider: some View { Text("·").foregroundStyle(.tertiary) }

    private var contextColor: Color {
        info.contextShare > 0.85 ? .red : info.contextShare > 0.6 ? .orange : .green
    }

    private var connectorList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(info.live ? L("Konnektoren dieser Sitzung") : L("Konnektoren laut Einstellungen")).font(.headline)
            if !info.live {
                Text("Live-Status gibt es bei selbstständigen Aufträgen. Hier steht, was der Agent beim Start lädt.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if info.connectors.isEmpty { Text("Keine MCP-Konnektoren eingerichtet").foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    group(L("Fehler"), info.connectors.filter(\.failed))
                    group(L("Verbunden"), info.connectors.filter(\.ok))
                    group(L("Eingerichtet"), info.connectors.filter { !$0.ok && !$0.problem })
                    if !info.connectors.filter(\.needsAuth).isEmpty {
                        DisclosureGroup(isExpanded: $showAuth) {
                            VStack(alignment: .leading, spacing: 6) { ForEach(info.connectors.filter(\.needsAuth)) { row($0) } }
                        } label: {
                            Text("\(info.connectors.filter(\.needsAuth).count) \(L("ohne Anmeldung – nur nötig, wenn du sie nutzt"))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(height: min(380, CGFloat(info.connectors.filter { !$0.needsAuth }.count) * 24 + (showAuth ? CGFloat(info.connectors.filter(\.needsAuth).count) * 24 : 0) + 44))
            Divider()
            HStack {
                Button {
                    checking = true
                    let kind = rec.agentKind, dir = rec.worktree.map { Worktrees.top($0) } ?? rec.directory
                    DispatchQueue.global(qos: .userInitiated).async {
                        let h = MissionStatus.health(agent: kind, dir: dir)
                        DispatchQueue.main.async {
                            checking = false
                            if let h, !h.isEmpty {
                                // Live-Status der Sitzung behalten, wo es ihn gibt; sonst Ergebnis der Prüfung
                                var merged = h
                                for c in info.connectors where !merged.contains(where: { $0.name == c.name }) { merged.append(c) }
                                info.connectors = merged
                            } else {
                                app.show(L("Konnektoren konnten nicht geprüft werden"))
                            }
                        }
                    }
                } label: { Label(L("Jetzt prüfen"), systemImage: "stethoscope") }
                .disabled(checking || !(rec.agentKind == .claude || rec.agentKind == .codex))
                if checking { ProgressView().controlSize(.small) }
                Spacer()
                Button(L("Alle verwalten")) { repair(nil) }
                    .disabled(!(rec.agentKind == .claude || rec.agentKind == .codex))
            }
            .font(.caption)
            if info.tools > 0 {
                Divider()
                Text("\(info.tools) \(L("Werkzeuge verfügbar"))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Grid.m)
        .frame(width: 360)
    }

    @ViewBuilder private func group(_ title: String, _ items: [ConnectorState]) -> some View {
        if !items.isEmpty {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2)
            ForEach(items) { row($0) }
        }
    }

    private func row(_ c: ConnectorState) -> some View {
        HStack(spacing: 6) {
            Circle().fill(c.ok ? Color.green : c.failed ? Color.red : c.needsAuth ? Color.orange : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
            Text(c.display).lineLimit(1).truncationMode(.middle).help(c.name)
            Spacer()
            Text(label(c)).font(.caption).foregroundStyle(c.failed ? .red : .secondary)
            if c.problem, c.name != "salenta-os" {
                Button(c.needsAuth ? L("Anmelden") : L("Neu verbinden")) { repair(c) }
                    .controlSize(.small)
            }
        }
    }

    /// Reparieren: Claude Code öffnet in Salenta Code eine Sitzung mit der Konnektor-Verwaltung (/mcp) –
    /// dort Anmelden oder Neu verbinden wählen. Codex meldet sich per `codex mcp login` an.
    private func repair(_ c: ConnectorState?) {
        showConnectors = false
        let dir = rec.worktree.map { Worktrees.top($0) } ?? rec.directory
        if rec.agentKind == .codex {
            if let c, c.status == "needs-auth" { Detection.runInTerminal("cd \(Shell.quote(dir)) && codex mcp login \(Shell.quote(c.name))") }
            else { Detection.runInTerminal("cd \(Shell.quote(dir)) && codex mcp list") }
            return
        }
        let s = agents.start(.claude, in: dir, prompt: nil, mode: .interaktiv,
                             label: c.map { L("Konnektor reparieren: ") + $0.name } ?? L("Konnektoren verwalten"), worktree: false)
        app.page = .chat(s.id.uuidString)
        // sobald Claude Code bereit ist, die Konnektor-Verwaltung öffnen
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { s.view.send(txt: "/mcp\r") }
        app.show(c == nil ? L("Konnektor-Verwaltung öffnet sich …")
                          : L("Wähle „\(c!.name)“ und dann Anmelden bzw. Neu verbinden"))
    }

    private func label(_ c: ConnectorState) -> String {
        switch c.status {
        case "connected": return L("verbunden")
        case "failed": return L("Fehler")
        case "needs-auth": return L("Anmeldung nötig")
        case "pending": return L("verbindet …")
        default: return c.source
        }
    }
}
