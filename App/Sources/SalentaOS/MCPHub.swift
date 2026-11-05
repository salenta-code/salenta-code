import AgenticOSKit
import AppKit
import Foundation

extension Notification.Name {
    static let mcpServersChanged = Notification.Name("aos.mcpServersChanged")
}

/// Ein Eintrag im Katalog (Katalog + eigene Einträge, data/mcp-catalog.json).
struct CatalogEntry: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let description: String
    let source: String?
    let transport: String
    let auth: String?
    let url: String?
    let command: String?
    let args: [String]?
    let featured: Bool?
    let catalog: String?

    var spec: MCPServerSpec {
        MCPServerSpec(name: name, url: url, command: command, args: args, description: description,
                      origin: "Salenta OS", auth: auth)
    }
}

/// Alle MCP-Server: eigene (data/mcp.json) und die aus Claude Code, Codex, Junie, Claude Desktop, Cursor.
/// Geheimnisse (Header, env) aus fremden Konfigurationen werden nur zur Laufzeit gelesen und nie gespeichert.
final class MCPHub: ObservableObject {
    @Published var own: [MCPServerSpec] = []
    @Published var imported: [MCPServerSpec] = []
    @Published var catalog: [CatalogEntry] = []
    @Published var connections: [String: MCPConnection] = [:]

    private var registryURL: URL { Paths.data.appendingPathComponent("mcp.json") }

    /// Für Stellen ohne Zugriff auf die Umgebung (Agent-Start): der laufende Hub.
    static weak var current: MCPHub?

    init() {
        MCPHub.current = self
        loadOwn()
        loadCatalog()
        reloadImported()
    }

    var all: [MCPServerSpec] {
        var seen = Set<String>()
        var list: [MCPServerSpec] = []
        for s in own + imported {
            let key = (s.url ?? s.name).lowercased()
            if seen.insert(key).inserted { list.append(s) }
        }
        return list
    }

    func server(named name: String) -> MCPServerSpec? { all.first { $0.name == name } }

    /// In welchen Agents (Claude Code, Codex, Cursor …) derselbe Server eingetragen ist.
    func origins(of spec: MCPServerSpec) -> [String] {
        let key = (spec.url ?? spec.name).lowercased()
        var out: [String] = []
        for s in own + imported where (s.url ?? s.name).lowercased() == key && !out.contains(s.origin) { out.append(s.origin) }
        return out
    }

    /// Immer auf dem Hauptthread: `connections` ist @Published und wird von SwiftUI gelesen.
    func connection(for spec: MCPServerSpec) -> MCPConnection {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync { connection(for: spec) }
        }
        if let c = connections[spec.id] { return c }
        let c = MCPConnection(spec: spec)
        connections[spec.id] = c
        return c
    }

    // MARK: Eigene Registry

    private struct Registry: Codable { var servers: [MCPServerSpec] }

    private func loadOwn() {
        guard let d = try? Data(contentsOf: registryURL), let r = try? JSONDecoder().decode(Registry.self, from: d) else { return }
        own = r.servers.map { var s = $0; s.origin = "Salenta Code"; return s }
    }

    private func saveOwn() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let d = try? enc.encode(Registry(servers: own)) { try? d.write(to: registryURL, options: .atomic) }
    }

    func add(_ spec: MCPServerSpec) {
        var s = spec
        s.origin = "Salenta Code"
        own.removeAll { $0.name == s.name }
        own.append(s)
        saveOwn()
    }

    func remove(_ name: String) {
        own.removeAll { $0.name == name }
        connections[name]?.disconnect()
        connections[name] = nil
        saveOwn()
    }

    func isInstalled(_ name: String) -> Bool { all.contains { $0.name == name } }

    private func loadCatalog() {
        let url = Paths.data.appendingPathComponent("mcp-catalog.json")
        struct File: Codable { var servers: [CatalogEntry] }
        if let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d) {
            catalog = f.servers.sorted { ($0.featured ?? false ? 0 : 1, $0.name) < ($1.featured ?? false ? 0 : 1, $1.name) }
        }
    }

    // MARK: Import aus den Agents

    func reloadImported() {
        DispatchQueue.global(qos: .utility).async {
            let found = Self.collectImported()
            DispatchQueue.main.async {
                self.imported = found
                NotificationCenter.default.post(name: .mcpServersChanged, object: nil)
            }
        }
    }

    private static func collectImported() -> [MCPServerSpec] {
        let home = Paths.home
        var out: [MCPServerSpec] = []
        out += fromJSON(home.appendingPathComponent(".claude.json"), origin: "Claude Code", projects: true)
        out += fromJSON(home.appendingPathComponent(".junie/mcp/mcp.json"), origin: "Junie", projects: false)
        out += fromJSON(home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"), origin: "Claude Desktop", projects: false)
        out += fromJSON(home.appendingPathComponent(".cursor/mcp.json"), origin: "Cursor", projects: false)
        out += fromTOML(home.appendingPathComponent(".codex/config.toml"))
        return out
    }

    private static func spec(name: String, _ d: [String: Any], origin: String) -> MCPServerSpec? {
        let url = d["url"] as? String ?? d["serverUrl"] as? String
        let command = d["command"] as? String
        guard url != nil || command != nil else { return nil }
        return MCPServerSpec(name: name, url: url, command: command,
                             args: (d["args"] as? [Any])?.map { "\($0)" },
                             env: d["env"] as? [String: String],
                             headers: d["headers"] as? [String: String],
                             description: nil, origin: origin, auth: nil)
    }

    private static func fromJSON(_ url: URL, origin: String, projects: Bool) -> [MCPServerSpec] {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [MCPServerSpec] = []
        for (name, v) in root["mcpServers"] as? [String: Any] ?? [:] {
            if let d = v as? [String: Any], let s = spec(name: name, d, origin: origin) { out.append(s) }
        }
        if projects {
            for (_, p) in root["projects"] as? [String: Any] ?? [:] {
                for (name, v) in (p as? [String: Any])?["mcpServers"] as? [String: Any] ?? [:] {
                    if let d = v as? [String: Any], let s = spec(name: name, d, origin: origin) { out.append(s) }
                }
            }
        }
        return out
    }

    /// Minimaler TOML-Leser für [mcp_servers.<name>] mit url/command/args.
    private static func fromTOML(_ url: URL) -> [MCPServerSpec] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [MCPServerSpec] = []
        var current: String?
        var dict: [String: Any] = [:]
        func flush() {
            if let n = current, let s = spec(name: n, dict, origin: "Codex") { out.append(s) }
            dict = [:]
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                flush()
                current = nil
                if line.hasPrefix("[mcp_servers."), line.hasSuffix("]") {
                    let n = String(line.dropFirst("[mcp_servers.".count).dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if !n.contains(".") { current = n }
                }
                continue
            }
            guard current != nil, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("[") {
                dict[key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
                    .filter { !$0.isEmpty }
            } else {
                dict[key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        flush()
        return out
    }

    /// Minimaler YAML-Leser für mcp_servers: name: url/command/args.
    private static func fromYAML(_ url: URL) -> [MCPServerSpec] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [MCPServerSpec] = []
        var inside = false
        var childIndent: Int?
        var current: String?
        var dict: [String: Any] = [:]
        var listKey: String?
        func flush() {
            if let n = current, let s = spec(name: n, dict, origin: "config.yaml") { out.append(s) }
            dict = [:]
            listKey = nil
        }
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " }.count
            if indent == 0 {
                flush(); current = nil
                inside = t.hasPrefix("mcp_servers:")
                childIndent = nil
                continue
            }
            guard inside else { continue }
            if childIndent == nil { childIndent = indent }
            if indent == childIndent, t.hasSuffix(":") {
                flush()
                current = String(t.dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                continue
            }
            guard current != nil else { continue }
            if t.hasPrefix("- "), let k = listKey {
                var arr = dict[k] as? [String] ?? []
                arr.append(String(t.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")))
                dict[k] = arr
                continue
            }
            guard let colon = t.firstIndex(of: ":") else { continue }
            let key = String(t[..<colon])
            let value = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                listKey = key
            } else if value.hasPrefix("[") {
                dict[key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }.filter { !$0.isEmpty }
            } else {
                dict[key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        flush()
        return out
    }

    // MARK: In die Agents installieren

    enum Target: String, CaseIterable, Identifiable {
        case claude, codex, junie
        var id: String { rawValue }
        var title: String {
            switch self {
            case .claude: "Claude Code"
            case .codex: "Codex"
            case .junie: "Junie"
            }
        }
    }

    /// Shell-Befehle, die den Server in den gewählten Agents eintragen. Laufen sichtbar im Terminal,
    /// damit Rückfragen (Tool-Auswahl, OAuth) beantwortet werden können.
    func installScript(_ spec: MCPServerSpec, targets: Set<Target>) -> String {
        let n = Shell.quote(spec.name)
        var lines = ["echo '→ MCP-Server \(spec.name) wird eingetragen …'"]
        for t in Target.allCases where targets.contains(t) {
            lines.append("echo; echo '== \(t.title)'")
            switch (t, spec.url) {
            case let (.claude, url?):
                lines.append("claude mcp add --scope user --transport http \(n) \(Shell.quote(url))")
            case (.claude, nil):
                lines.append("claude mcp add --scope user \(n) -- \(cmdLine(spec))")
            case let (.codex, url?):
                lines.append("codex mcp add \(n) --url \(Shell.quote(url))")
            case (.codex, nil):
                lines.append("codex mcp add \(n) -- \(cmdLine(spec))")
            case (.junie, _):
                lines.append("\(Shell.quote(Paths.root.appendingPathComponent("bin/aos").path)) mcp-junie \(n) \(Shell.quote(spec.url ?? "")) \(spec.url == nil ? cmdLine(spec) : "")")
            }
        }
        lines.append("echo; echo '✓ Fertig. Neue Agent-Sitzungen laden den Server automatisch.'")
        return lines.joined(separator: "; ")
    }

    private func cmdLine(_ spec: MCPServerSpec) -> String {
        ([spec.command ?? ""] + (spec.args ?? [])).map(Shell.quote).joined(separator: " ")
    }
}
