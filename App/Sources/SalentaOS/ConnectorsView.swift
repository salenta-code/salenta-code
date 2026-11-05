import AgenticOSKit
import AppKit
import SwiftUI

/// Ein MCP-Server oder Connector, egal aus welchem Agent.
struct Connector: Identifiable, Hashable {
    var id: String { source + "/" + name }
    let name: String
    let source: String
    let detail: String
}

struct ConnectorSource: Identifiable {
    var id: String { title }
    let title: String
    let symbol: String
    let file: URL?
    let note: String
    var items: [Connector]
}

/// Liest die MCP-Konfigurationen von Claude Code, Codex, Cursor und Claude Desktop.
final class ConnectorScanner: ObservableObject {
    @Published var sources: [ConnectorSource] = []
    @Published var scanning = false

    init() { scan() }

    func scan() {
        scanning = true
        DispatchQueue.global(qos: .utility).async {
            let result = Self.collect()
            DispatchQueue.main.async {
                self.sources = result
                self.scanning = false
            }
        }
    }

    private static func collect() -> [ConnectorSource] {
        let home = Paths.home
        var out: [ConnectorSource] = []

        out.append(ConnectorSource(title: L("Claude (claude.ai & Desktop) – Cloud-Connectors"), symbol: "cloud",
                                   file: nil,
                                   note: L("Laufen in deinem Claude-Konto. Verwalten unter claude.ai › Einstellungen › Connectors."),
                                   items: cloudConnectors.map { Connector(name: $0.0, source: "claude.ai", detail: $0.1) }))

        let claudeJSON = home.appendingPathComponent(".claude.json")
        var claudeItems = mcpFromJSON(claudeJSON, source: "Claude Code", projectsKey: true)
        let claudeSettings = home.appendingPathComponent(".claude/settings.json")
        claudeItems += mcpFromJSON(claudeSettings, source: "Claude Code", projectsKey: false)
        out.append(ConnectorSource(title: L("Claude Code – MCP"), symbol: "sparkle", file: claudeJSON,
                                   note: "~/.claude.json (global und pro Projekt). Hinzufügen: claude mcp add …",
                                   items: unique(claudeItems)))

        let codex = home.appendingPathComponent(".codex/config.toml")
        out.append(ConnectorSource(title: L("Codex – MCP"), symbol: "chevron.left.forwardslash.chevron.right", file: codex,
                                   note: "~/.codex/config.toml, Abschnitte [mcp_servers.<name>]. Hinzufügen: codex mcp add …",
                                   items: mcpFromTOML(codex)))

        let junie = home.appendingPathComponent(".junie/mcp/mcp.json")
        out.append(ConnectorSource(title: L("Junie – MCP"), symbol: "j.square", file: junie,
                                   note: "~/.junie/mcp/mcp.json (projektbezogen: .junie/mcp/mcp.json im Repo)",
                                   items: mcpFromJSON(junie, source: "Junie", projectsKey: false)))

        let desktop = home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        var desktopItems = mcpFromJSON(desktop, source: "Claude Desktop", projectsKey: false)
        desktopItems += localDesktopExtras.map { Connector(name: $0, source: "Claude Desktop", detail: L("lokale Erweiterung")) }
        out.append(ConnectorSource(title: L("Claude Desktop – lokal auf dem Mac"), symbol: "desktopcomputer", file: desktop,
                                   note: "claude_desktop_config.json und Desktop-Erweiterungen.",
                                   items: unique(desktopItems)))

        let cursor = home.appendingPathComponent(".cursor/mcp.json")
        out.append(ConnectorSource(title: L("Cursor – MCP"), symbol: "cursorarrow.rays", file: cursor,
                                   note: "~/.cursor/mcp.json",
                                   items: mcpFromJSON(cursor, source: "Cursor", projectsKey: false)))
        return out
    }

    private static func unique(_ list: [Connector]) -> [Connector] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.name.lowercased()).inserted }
    }

    // MARK: Parser

    private static func mcpFromJSON(_ url: URL, source: String, projectsKey: Bool) -> [Connector] {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var list: [Connector] = []
        if let servers = root["mcpServers"] as? [String: Any] {
            for (name, value) in servers { list.append(Connector(name: name, source: source, detail: describe(value) + " · global")) }
        }
        if projectsKey, let projects = root["projects"] as? [String: Any] {
            for (path, value) in projects {
                guard let p = value as? [String: Any], let servers = p["mcpServers"] as? [String: Any] else { continue }
                let short = (path as NSString).lastPathComponent
                for (name, v) in servers { list.append(Connector(name: name, source: source, detail: describe(v) + " · Projekt \(short)")) }
            }
        }
        return list.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private static func describe(_ value: Any) -> String {
        guard let d = value as? [String: Any] else { return "" }
        if let url = d["url"] as? String { return URL(string: url)?.host ?? url }
        if let cmd = d["command"] as? String { return (cmd as NSString).lastPathComponent }
        if let type = d["type"] as? String { return type }
        return ""
    }

    private static func mcpFromTOML(_ url: URL) -> [Connector] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var list: [Connector] = []
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("[mcp_servers."), t.hasSuffix("]") else { continue }
            var name = String(t.dropFirst("[mcp_servers.".count).dropLast())
            if name.contains(".") { continue } // Unterabschnitte wie .env
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            list.append(Connector(name: name, source: "Codex", detail: "config.toml"))
        }
        return list
    }

    private static func mcpFromYAML(_ url: URL) -> [Connector] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var list: [Connector] = []
        var inside = false
        var childIndent: Int?
        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let indent = line.prefix { $0 == " " }.count
            if indent == 0 {
                inside = line.hasPrefix("mcp_servers:")
                childIndent = nil
                continue
            }
            guard inside else { continue }
            if childIndent == nil { childIndent = indent }
            guard indent == childIndent else { continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            if let colon = t.firstIndex(of: ":") {
                let name = String(t[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                if !name.isEmpty, !name.hasPrefix("-") { list.append(Connector(name: name, source: "config.yaml", detail: "config.yaml")) }
            }
        }
        return list
    }

    // claude.ai-Connectors lassen sich lokal nicht auslesen – eigene Einträge in data/cloud-connectors.json (["Name", "Kategorie"]).
    static var cloudConnectors: [(String, String)] {
        guard let d = try? Data(contentsOf: Paths.data.appendingPathComponent("cloud-connectors.json")),
              let list = try? JSONSerialization.jsonObject(with: d) as? [[String]] else { return [] }
        return list.compactMap { $0.count >= 2 ? ($0[0], $0[1]) : nil }
    }

    static let localDesktopExtras = ["Apple Notes", "iMessage", "Filesystem", "browser-use"]
}

struct ConnectorsView: View {
    @StateObject private var scanner = ConnectorScanner()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Grid.xl) {
                Text("Alle Werkzeuge deiner Agents an einem Ort. Jeder Agent hat seine eigene Liste – hier siehst du sie zusammen und springst direkt in die Konfiguration.")
                    .foregroundStyle(.secondary)
                ForEach(scanner.sources) { src in
                    Card(title: "\(src.title)  ·  \(src.items.count)", symbol: src.symbol,
                         trailing: src.file.map { f in AnyView(HStack {
                             Button("Datei öffnen") { NSWorkspace.shared.open(f) }
                                 .buttonStyle(.link)
                                 .disabled(!FileManager.default.fileExists(atPath: f.path))
                             Button("Im Finder") { Launcher.reveal(f) }.buttonStyle(.link)
                         }) }) {
                        Text(src.note).font(.caption).foregroundStyle(.secondary)
                        if src.items.isEmpty {
                            Text("Keine Einträge gefunden.").foregroundStyle(.tertiary)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Grid.s)], alignment: .leading, spacing: Grid.s) {
                                ForEach(src.items) { c in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(c.name).font(.callout.weight(.medium)).lineLimit(1)
                                        if !c.detail.isEmpty {
                                            Text(c.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    .padding(Grid.s)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                    }
                }
            }
            .padding(Grid.xl)
            .frame(maxWidth: 1280, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Connectors")
        .toolbar {
            ToolbarItem {
                Button { scanner.scan() } label: {
                    Label("Neu einlesen", systemImage: scanner.scanning ? "hourglass" : "arrow.clockwise")
                }
            }
        }
    }
}
