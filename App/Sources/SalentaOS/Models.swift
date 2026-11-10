import AgenticOSKit
import AppKit
import SwiftUI

// Modelle pro Agent: Salenta Code fragt die CLIs selbst, welche Modelle es gibt (cursor-agent --list-models,
// opencode models, pi --list-models …), ergänzt die Modelle, die du zuletzt wirklich benutzt hast
// (aus den Verlaufsdateien), und merkt sich deine Wahl pro Agent.

struct ModelOption: Hashable, Identifiable {
    var id: String { value }
    let value: String     // was an --model übergeben wird
    let label: String
    var hint: String = ""
}

final class ModelCatalog: ObservableObject {
    static let shared = ModelCatalog()
    @Published private(set) var discovered: [String: [String]] = [:]
    @Published private(set) var refreshing = false
    private var url: URL { Paths.data.appendingPathComponent("models.json") }

    init() {
        if let d = try? Data(contentsOf: url), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let m = j["models"] as? [String: [String]] {
            discovered = m
            let t = j["updated"] as? Double ?? 0
            if Date().timeIntervalSince1970 - t > 86400 { DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.refresh() } }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.refresh() }
        }
    }

    /// Befehle, mit denen die CLIs ihre Modelle auflisten.
    static let listCommands: [AgentKind: [String]] = [
        .cursor: ["cursor-agent --list-models", "cursor-agent models", "agent --list-models"],
        .opencode: ["opencode models"],
        .pi: ["pi --list-models"],
        .kimi: ["kimi provider list --json"],
        .grok: ["grok models", "grok --list-models"],
        .kiro: ["kiro-cli chat --list-models", "kiro-cli models"],
        .gemini: [],
    ]

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async {
            var out: [String: [String]] = [:]
            for (agent, cmds) in Self.listCommands where Detection.which(agent.command) != nil || (agent == .cursor && Detection.which("agent") != nil) {
                for c in cmds {
                    let r = Proc.zsh(c, in: NSTemporaryDirectory(), timeout: 25)
                    let ids = agent == .kimi ? Self.parseKimi(r.out) : Self.parse(r.out)
                    if r.code == 0, ids.count >= (agent == .kimi ? 1 : 2) { out[agent.rawValue] = ids; break }
                }
            }
            let or = OpenModels.fetchOpenRouter()
            if !or.isEmpty { out[AgentKind.openrouter.rawValue] = or }
            let ol = OpenModels.ollamaModels()
            if !ol.isEmpty { out[AgentKind.ollama.rawValue] = ol }
            DispatchQueue.main.async {
                for (k, v) in out { self.discovered[k] = v }
                self.refreshing = false
                let j: [String: Any] = ["models": self.discovered, "updated": Date().timeIntervalSince1970]
                if let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted]) { try? d.write(to: self.url, options: .atomic) }
            }
        }
    }

    /// Modell-IDs aus einer CLI-Liste lesen (eine pro Zeile, Spiegelstriche/Tabellen/Beschreibungen werden ignoriert).
    static func parse(_ text: String) -> [String] {
        var ids: [String] = []
        let clean = text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        for raw in clean.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "-*•│|> \t"))
            guard let first = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "|" || $0 == "(" || $0 == "," }).first else { continue }
            let id = String(first).trimmingCharacters(in: CharacterSet(charactersIn: ":`'\""))
            guard id.count >= 3, id.count <= 80, id.range(of: "^[A-Za-z0-9][A-Za-z0-9._/:-]*$", options: .regularExpression) != nil,
                  id.rangeOfCharacter(from: .decimalDigits) != nil || id.contains("-") || id.contains("/"),
                  !["available", "models", "model", "usage", "loading", "current"].contains(id.lowercased()) else { continue }
            if !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    /// `kimi provider list --json`: Anbieter mit ihren Modellen → „anbieter/modell“, wie Kimi sie bei -m erwartet.
    static func parseKimi(_ text: String) -> [String] {
        guard let start = text.firstIndex(where: { $0 == "[" || $0 == "{" }),
              let j = try? JSONSerialization.jsonObject(with: Data(text[start...].utf8)) else { return [] }
        var ids: [String] = []
        func modelName(_ m: Any) -> String? {
            if let s = m as? String { return s }
            if let d = m as? [String: Any] { return (d["id"] ?? d["model"] ?? d["name"]) as? String }
            return nil
        }
        func walk(_ v: Any, provider: String?) {
            if let arr = v as? [Any] { arr.forEach { walk($0, provider: provider) }; return }
            guard let d = v as? [String: Any] else { return }
            let pid = (d["id"] ?? d["provider"] ?? d["providerId"] ?? d["name"]) as? String ?? provider
            if let models = d["models"] {
                let list: [Any] = (models as? [Any]) ?? ((models as? [String: Any]).map { Array($0.keys) } ?? [])
                for m in list {
                    guard let n = modelName(m) else { continue }
                    let full = n.contains("/") || pid == nil ? n : "\(pid!)/\(n)"
                    if !ids.contains(full) { ids.append(full) }
                }
            }
            for (k, sub) in d where k != "models" && (sub is [Any] || sub is [String: Any]) { walk(sub, provider: pid) }
        }
        walk(j, provider: nil)
        return ids
    }

    /// Modelle, die du zuletzt wirklich benutzt hast (aus den Verlaufsdateien), neueste zuerst.
    private func observed(_ prefix: (String) -> Bool, from points: [UsagePoint]) -> [String] {
        var seen: [String] = []
        for p in points.reversed() where prefix(p.model) && !seen.contains(p.model) { seen.append(p.model) }
        return Array(seen.prefix(8))
    }

    /// Auswahl für einen Agent.
    func options(for agent: AgentKind) -> [ModelOption] {
        switch agent {
        case .claude:
            var o = [ModelOption(value: "opus", label: "Opus", hint: L("schwierig, Architektur, wichtige Texte")),
                     ModelOption(value: "sonnet", label: "Sonnet", hint: L("normale Aufgaben")),
                     ModelOption(value: "haiku", label: "Haiku", hint: L("kurz und schnell"))]
            o += observed({ $0.hasPrefix("claude-") }, from: Usage.shared.claude).map { ModelOption(value: $0, label: $0, hint: L("zuletzt genutzt")) }
            return o
        case .codex:
            var o = observed({ !$0.isEmpty && $0 != "codex" }, from: Usage.shared.codex).map { ModelOption(value: $0, label: $0, hint: L("zuletzt genutzt")) }
            if let cfg = try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml"), encoding: .utf8),
               let r = cfg.range(of: "(?m)^model\\s*=\\s*\"([^\"]+)\"", options: .regularExpression) {
                let m = String(cfg[r]).components(separatedBy: "\"").dropFirst().first ?? ""
                if !m.isEmpty, !o.contains(where: { $0.value == m }) { o.insert(ModelOption(value: m, label: m, hint: L("Standard aus config.toml")), at: 0) }
            }
            return o
        case .gemini:
            let base = discovered[agent.rawValue] ?? []
            let defaults = ["gemini-3-pro-preview", "gemini-3-flash-preview", "gemini-2.5-pro", "gemini-2.5-flash"]
            return (base + defaults.filter { !base.contains($0) }).map { ModelOption(value: $0, label: $0) }
        case .grok:
            let base = discovered[agent.rawValue] ?? ["grok-build"]
            return base.map { ModelOption(value: $0, label: $0) }
        case .kimi:
            let base = discovered[agent.rawValue] ?? []
            let defaults = ["kimi-code/kimi-for-coding"]
            return (base + defaults.filter { !base.contains($0) }).map { ModelOption(value: $0, label: $0, hint: $0 == "kimi-code/kimi-for-coding" ? L("Kimi-Abo (Standard)") : "") }
        case .cursor, .opencode, .kiro, .pi, .openrouter, .deepseek, .harness:
            return (discovered[agent.rawValue] ?? []).map { ModelOption(value: $0, label: $0, hint: $0.hasSuffix(":free") ? L("kostenlos") : "") }
        case .ollama:
            let local = discovered[agent.rawValue] ?? []
            return (local.isEmpty ? ["qwen3-coder"] : local).map { ModelOption(value: $0, label: $0, hint: local.isEmpty ? L("wird automatisch eingerichtet (Einstellungen › Modelle)") : L("lokal")) }
        case .junie, .shell:
            return []
        }
    }

    /// Nur die aktuellsten Modelle: pro Familie (z. B. gpt-codex, claude-opus, qwen-coder) die höchste Version,
    /// ohne Varianten wie -fast, -high, -thinking, -preview. Die vollständige Liste gibt es unter „Alle Modelle“.
    func latest(for agent: AgentKind, limit: Int = 12) -> [ModelOption] {
        let all = options(for: agent)
        guard all.count > limit else { return all }
        let variants: Set<String> = ["fast", "low", "medium", "high", "xhigh", "max", "thinking", "preview", "latest", "exp", "beta", "free", "instruct", "turbo", "nitro"]
        var best: [String: (version: [Int], opt: ModelOption)] = [:]
        var order: [String] = []
        for o in all {
            let base = (o.value.components(separatedBy: "/").last ?? o.value).lowercased().replacingOccurrences(of: ":", with: "-")
            var tokens = base.split(separator: "-").map(String.init)
            while let last = tokens.last, variants.contains(last) || (last.count == 8 && Int(last) != nil) || (last.count == 4 && Int(last) != nil && tokens.count > 2) { tokens.removeLast() }
            let provider = o.value.contains("/") ? (o.value.components(separatedBy: "/").first ?? "") + "/" : ""
            let family = provider + tokens.filter { $0.rangeOfCharacter(from: .decimalDigits) == nil }.joined(separator: "-")
            let version = tokens.joined(separator: ".").components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
            // bevorzugt die Grundvariante (ohne Suffix), sonst die mit höchster Version
            let isBase = base == tokens.joined(separator: "-")
            if let cur = best[family] {
                if version.lexicographicallyPrecedes(cur.version) { continue }
                if version == cur.version && !isBase { continue }
            } else { order.append(family) }
            best[family] = (version, o)
        }
        // Agent-Reihenfolge der CLI beibehalten (meist sinnvoll sortiert), höchstens limit
        return Array(order.compactMap { best[$0]?.opt }.prefix(limit))
    }

    /// Lange Listen (Cursor kennt ~190 Modelle) nach Anbieter/Familie gruppieren.
    func grouped(for agent: AgentKind) -> [(String, [ModelOption])] {
        let opts = options(for: agent)
        guard opts.count > 14 else { return [("", opts)] }
        let groups = Dictionary(grouping: opts) { o -> String in
            if o.value.contains("/") { return String(o.value.split(separator: "/").first ?? "") }
            let v = o.value.lowercased()
            for fam in ["claude", "gpt", "gemini", "grok", "composer", "o3", "o4", "deepseek", "kimi", "qwen", "llama", "mistral", "glm"] where v.hasPrefix(fam) { return fam }
            return L("Weitere")
        }
        return groups.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }

    // MARK: Gewählt pro Agent

    static func selected(for agent: AgentKind) -> String {
        let v = UserDefaults.standard.string(forKey: "mission.model.\(agent.rawValue)") ?? ""
        return fits(v, agent) ? v : ""   // falsch abgelegte Wahl (z. B. GPT unter Claude Code) gilt nicht
    }

    static func select(_ value: String, for agent: AgentKind) {
        UserDefaults.standard.set(value, forKey: "mission.model.\(agent.rawValue)")
    }

    /// Passt die Modell-ID zum Agent? (Nach einem Agent-Wechsel darf z. B. Codex nie „opus“ bekommen
    /// und Claude Code nie ein GPT- oder Kimi-Modell – sonst läuft still ein anderes Modell als gedacht.)
    static func fits(_ model: String, _ agent: AgentKind) -> Bool {
        let m = model.lowercased()
        if m.isEmpty { return true }
        let claudeAlias = ["opus", "sonnet", "haiku"].contains(m)
        let claudeID = m.hasPrefix("claude-") || claudeAlias
        let openAI = m.hasPrefix("gpt-") || m.hasPrefix("o3") || m.hasPrefix("o4") || m.contains("codex")
        switch agent {
        case .claude: return claudeID
        case .codex: return openAI
        case .cursor: return !claudeAlias
        default: return !claudeAlias && !(m.hasPrefix("claude-") && agent != .opencode && agent != .openrouter)
        }
    }

    /// Kann der Agent ein Modell per Parameter bekommen?
    static func supportsModel(_ a: AgentKind) -> Bool { ![.junie, .shell].contains(a) }
}

/// Eigenes Modell eintippen (z. B. eine neue Modell-ID, die noch nicht in der Liste steht).
enum ModelPrompt {
    static func ask(agent: AgentKind, current: String) -> String? {
        let a = NSAlert()
        a.messageText = L("Modell für ") + agent.title
        a.informativeText = L("Modell-ID genau so, wie die CLI sie bei --model erwartet.")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        f.stringValue = current
        f.placeholderString = agent == .opencode ? "anthropic/claude-sonnet-…" : "z. B. gpt-…"
        a.accessoryView = f
        a.addButton(withTitle: L("Übernehmen")); a.addButton(withTitle: L("Abbrechen"))
        return a.runModal() == .alertFirstButtonReturn ? f.stringValue.trimmingCharacters(in: .whitespaces) : nil
    }
}
