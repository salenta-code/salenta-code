import AgenticOSKit
import AppKit
import SwiftUI

// MARK: - Jede MCP-Anbindung bekommt automatisch eine eigene Seite

struct MCPAppPage: View {
    @ObservedObject var connection: MCPConnection
    @State private var results: [String: MCPResult] = [:]
    @State private var runner: MCPTool?

    /// Lesende Tools ohne Pflichtfelder: laufen automatisch als Übersicht.
    private var overviewTools: [MCPTool] {
        let auto = connection.tools.filter { t in !t.params.contains(where: \.required) && (t.readOnly || isReadName(t.name)) }
        return Array(auto.prefix(6))
    }

    private var actionTools: [MCPTool] { connection.tools.filter { t in !overviewTools.contains(t) } }

    private func isReadName(_ n: String) -> Bool {
        let l = n.lowercased()
        return ["list", "get", "liste", "status", "ueberblick", "overview", "summary", "search", "kennzahlen", "whoami"].contains { l.contains($0) }
            && !["delete", "loeschen", "send", "senden", "create", "anlegen"].contains { l.contains($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Grid.l) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connection.serverName.isEmpty ? connection.spec.name : connection.serverName).font(.largeTitle.weight(.bold))
                        Text("\(connection.tools.count) Werkzeuge · \(connection.spec.origin)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if connection.state != .connected {
                        Button("Verbinden") { Task { await connection.connect() } }.buttonStyle(.borderedProminent)
                    }
                }
                if connection.state == .connected {
                    ForEach(overviewTools) { t in
                        SCard(title: t.title == t.name ? keyLabel(t.name) : t.title, symbol: "rectangle.grid.1x2", tint: .accentColor) {
                            if let r = results[t.name] { JSONOrText(result: r) } else { ProgressView() }
                        }
                        .task { if results[t.name] == nil { results[t.name] = try? await connection.callTool(t.name, arguments: [:]) } }
                    }
                    Text("Aktionen").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Grid.s)], spacing: Grid.s) {
                        ForEach(actionTools) { t in
                            Button { runner = t } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.title == t.name ? keyLabel(t.name) : t.title).font(.callout.weight(.medium)).lineLimit(1)
                                    Text(t.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                .padding(Grid.m)
                                .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else if connection.state == .connecting {
                    ProgressView()
                }
            }
            .padding(Grid.xl)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(connection.spec.name)
        .task { if connection.state == .idle { await connection.connect(interactiveAuth: false) } }
        .sheet(item: $runner) { t in
            VStack(spacing: 0) {
                ToolRunner(connection: connection, tool: t)
                HStack { Spacer(); Button("Schließen") { runner = nil }.keyboardShortcut(.cancelAction) }.padding(Grid.m)
            }
            .frame(width: 580, height: 640)
        }
    }
}

struct JSONOrText: View {
    let result: MCPResult
    var body: some View {
        if let j = result.json { JSONBlock(value: j) } else { MarkdownText(result.text) }
    }
}

// MARK: - Verlauf: Claude-Code- und Codex-Sitzungen fortsetzen

struct PastSession: Identifiable, Hashable {
    let id: String
    let agent: AgentKind
    let directory: String
    let title: String
    let date: Date
}

final class SessionHistory: ObservableObject {
    @Published var sessions: [PastSession] = []

    func reload() {
        DispatchQueue.global(qos: .utility).async {
            let found = Self.claude() + Self.codex()
            DispatchQueue.main.async { self.sessions = found.sorted { $0.date > $1.date }.prefix(60).map { $0 } }
        }
    }

    private static func firstUserText(_ url: URL, keys: [String]) -> (String?, String?) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return (nil, nil) }
        defer { try? h.close() }
        let data = h.readData(ofLength: 200_000)
        var cwd: String?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(200) {
            guard let d = line.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if cwd == nil { cwd = j["cwd"] as? String ?? (j["payload"] as? [String: Any])?["cwd"] as? String }
            let msg = j["message"] as? [String: Any] ?? (j["payload"] as? [String: Any]) ?? [:]
            let role = msg["role"] as? String ?? j["type"] as? String
            guard role == "user" else { continue }
            if let s = msg["content"] as? String, !s.hasPrefix("<") { return (s, cwd) }
            if let arr = msg["content"] as? [[String: Any]],
               let t = arr.compactMap({ $0["text"] as? String }).first(where: { !$0.hasPrefix("<") }) { return (t, cwd) }
        }
        return (nil, cwd)
    }

    private static func claude() -> [PastSession] {
        let root = Paths.home.appendingPathComponent(".claude/projects")
        let fm = FileManager.default
        var out: [PastSession] = []
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where f.pathExtension == "jsonl" {
                let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                guard date > Date().addingTimeInterval(-30 * 86400) else { continue }
                let (title, cwd) = firstUserText(f, keys: [])
                out.append(PastSession(id: f.deletingPathExtension().lastPathComponent, agent: .claude,
                                       directory: cwd ?? Paths.home.path, title: title.map { String($0.prefix(120)) } ?? "Sitzung", date: date))
            }
        }
        return out
    }

    private static func codex() -> [PastSession] {
        let root = Paths.home.appendingPathComponent(".codex/sessions")
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var out: [PastSession] = []
        while let f = en.nextObject() as? URL {
            guard f.pathExtension == "jsonl" else { continue }
            let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard date > Date().addingTimeInterval(-30 * 86400) else { continue }
            let (title, cwd) = firstUserText(f, keys: [])
            // Dateiname: rollout-<zeit>-<uuid>.jsonl
            let name = f.deletingPathExtension().lastPathComponent
            let uuid = name.count >= 36 ? String(name.suffix(36)) : name
            out.append(PastSession(id: uuid, agent: .codex, directory: cwd ?? Paths.home.path,
                                   title: title.map { String($0.prefix(120)) } ?? "Sitzung", date: date))
        }
        return out
    }
}

struct SessionHistoryList: View {
    @StateObject private var history = SessionHistory()
    @EnvironmentObject private var agents: AgentManager

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.s) {
            HStack {
                Text("Letzte Sitzungen").font(.headline)
                Spacer()
                Button { history.reload() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help(L("Neu laden"))
            }
            if history.sessions.isEmpty { Text("Keine Sitzungen der letzten 30 Tage.").foregroundStyle(.tertiary).font(.callout) }
            ForEach(history.sessions.prefix(25)) { s in
                Button {
                    let cmd = s.agent == .claude ? "claude --resume \(s.id)" : "codex resume \(s.id)"
                    let session = agents.start(.shell, in: s.directory, label: "\(s.agent.title) fortsetzen: \(s.title)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { session.send("exec \(cmd)\n") }
                } label: {
                    HStack(alignment: .top, spacing: Grid.s) {
                        Image(systemName: s.agent.symbol).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title).font(.callout).lineLimit(2)
                            Text("\((s.directory as NSString).lastPathComponent) · \(relativeDay(s.date))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "play.circle").foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Sitzung im Terminal fortsetzen")
            }
        }
        .onAppear { if history.sessions.isEmpty { history.reload() } }
    }
}
