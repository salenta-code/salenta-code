import AgenticOSKit
import Foundation

// Automatisch die richtigen Skills und Erweiterungen mitgeben – je nachdem, was installiert ist:
//  • Immer mit: Token-Sparer (z. B. Caveman, Serena) und Doku-Helfer (Context7), sobald sie installiert sind
//  • Passend zum Auftrag: Skills und Erweiterungen, deren Stichwörter im Auftrag vorkommen (auch bei Folgeaufträgen)
// Gilt für jeden Start eines Agents – neuer Auftrag, Weitermachen, Übergabe, Helfer, Umsetzen aus der Ergebnis-Karte.

enum AutoSkills {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "auto.skills") as? Bool ?? true }

    /// Diese Erweiterungen sind fast immer sinnvoll, wenn sie installiert sind.
    static let alwaysIDs: Set<String> = ["serena", "context7"]   // kein „caveman“: verkürzte Antworten kosten Qualität
    static let tokenWords = ["token", "compress", "komprim", "terse", "concise", "caveman", "knapp", "spar", "context window", "kontext"]

    /// Selbst hinzugefügtes Repo, das laut Name, Beschreibung oder Themen Tokens spart – läuft dann wie die kuratierten Token-Sparer immer mit.
    static func savesTokens(_ e: Extension) -> Bool {
        guard e.id.hasPrefix("custom:") else { return false }
        let t = (e.name + " " + e.purpose + " " + e.when.joined(separator: " ")).lowercased()
        return ["token sav", "save token", "saves token", "saving token", "token-sav", "token spar", "tokens spar", "token usage", "token cost", "token-eff",
                "token eff", "token optim", "token reduc", "reduce token", "fewer tokens", "less tokens", "compress", "caveman", "context window"].contains { t.contains($0) }
    }

    /// Wörter, die in fast jedem Repo-Thema und fast jedem Auftrag stehen – sie sagen nichts darüber, ob ein Repo zum Auftrag passt.
    static let genericWords: Set<String> = ["claude", "code", "coding", "skill", "skills", "agent", "agents", "plugin", "plugins", "server", "tool", "tools",
                                            "anthropic", "openai", "codex", "awesome", "apps", "pack", "official", "community", "collection", "list", "best",
                                            "prompt", "prompts", "automation", "workflow", "workflows", "assistant", "chatgpt", "gemini", "cursor", "model",
                                            "models", "main", "with", "open", "source", "opensource", "free", "your", "help", "helper", "project", "projects"]

    /// Passt ein selbst hinzugefügtes Repo dem Wortlaut nach zum Auftrag? Ein eindeutiges Stichwort muss als ganzes Wort vorkommen.
    static func customMatch(_ keywords: [String], _ lower: String) -> Bool {
        keywords.contains { k in
            let w = k.lowercased()
            return w.count >= 4 && !genericWords.contains(w) && Router.mentions(lower, w)
        }
    }

    /// Welche Agents Skills/Plugins/MCP überhaupt nutzen können.
    static func supports(_ kind: AgentKind, osAgent: Bool) -> Bool {
        osAgent || kind.harness == .claude || kind == .codex
    }

    struct Pick {
        var lines: [String] = []      // Text für den Auftrag
        var names: [String] = []      // für die Anzeige im Auftrag
    }

    /// Was zu diesem Auftrag automatisch mitgegeben wird.
    static func pick(prompt: String, kind: AgentKind, osAgent: Bool, directory: String? = nil, onlyIntegrations: Bool = false) -> Pick {
        var p = Pick()
        guard enabled, supports(kind, osAgent: osAgent) else { return p }
        // Auftrag + Technik des Projekts: so passen Erweiterungen auch, wenn der Auftrag die Technik nicht nennt
        // („Login reparieren“ in einem Supabase-Projekt → Supabase-Helfer)
        let stack = directory.map(stackWords) ?? []
        // Nur der eigentliche Auftrag zählt – nicht Projektname oder Ordnerpfad
        // (sonst bekäme jeder Auftrag in einem gleichnamigen Repo die passende Integration angeboten).
        var body = prompt
        if let re = try? NSRegularExpression(pattern: "^Im Projekt [^:\\n]+:\\s*") {
            body = re.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "")
        }
        if let d = directory, !d.isEmpty { body = body.replacingOccurrences(of: d, with: " ") }
        let lower = body.lowercased() + " " + stack.joined(separator: " ")
        let role = Self.role(of: lower)
        let installed = ExtensionStore.shared.installed
        let harness: AgentKind = osAgent ? .claude : kind.harness

        // 1. Immer mit: installierte Token-Sparer und Doku-Helfer (bei Code-Aufträgen übernimmt das der Phasen-Plan)
        for e in ExtensionCatalog.all where !onlyIntegrations && installed.contains(e.id) && (alwaysIDs.contains(e.id) || e.category == .tokens || savesTokens(e)) {
            guard !lower.contains(e.name.lowercased()) else { continue }
            if harness != .claude && (e.kind == .plugin || e.kind == .skill) { continue }   // Claude-Plugins nur bei Claude
            let line: String
            switch e.id {
            case "caveman": line = L("Antworte und arbeite knapp im Caveman-Stil (Plugin „caveman“ ist installiert, aktiviere es mit /caveman) – spart Tokens, Code und Fakten bleiben exakt.")
            default:
                guard !e.howTo.isEmpty, !prompt.contains(e.howTo) else { continue }
                line = e.howTo
            }
            p.lines.append(line); p.names.append(e.name)
        }
        // installierte Skills, die Tokens sparen (auch selbst angelegte)
        let skills = SkillCatalog.current?.skills(for: harness) ?? []
        for s in skills where !onlyIntegrations && tokenWords.contains(where: { (s.name + " " + s.description).lowercased().contains($0) }) {
            guard !p.names.contains(where: { $0.lowercased() == s.name.lowercased() }), !lower.contains(s.name.lowercased()) else { continue }
            p.lines.append(String(format: L("Nutze den Skill %@, um Tokens zu sparen."), harness == .claude ? "/" + s.name : s.name))
            p.names.append(s.name)
            if p.names.count >= 5 { break }
        }

        // 2. Passend zum Auftrag: Erweiterungen mit passenden Stichwörtern
        for e in ExtensionCatalog.all where !onlyIntegrations && installed.contains(e.id) && !alwaysIDs.contains(e.id) && e.category != .tokens && !e.howTo.isEmpty {
            // Selbst hinzugefügte Repos: nur eindeutige Stichwörter als ganzes Wort (Themen wie „code“ oder „agent“ passen auf alles)
            let hit = e.id.hasPrefix("custom:") ? customMatch(e.when, lower) : e.when.contains(where: { lower.contains($0) })
            guard hit, !p.names.contains(e.name), !prompt.contains(e.howTo) else { continue }
            if harness != .claude && (e.kind == .plugin || e.kind == .skill) { continue }
            p.lines.append(e.howTo); p.names.append(e.name)
        }
        // 2a. Sicherheit und Prüfen: Prüf-Helfer und heikle Aufträge (Login, Zahlungen, Schlüssel, Deploy …)
        //     bekommen die installierten Sicherheits- und Review-Werkzeuge – auch ohne passendes Stichwort.
        if !onlyIntegrations && (role.review || role.sensitive) {
            let cats: Set<Extension.Category> = role.review ? [.security, .quality] : [.security]
            for e in ExtensionCatalog.all where installed.contains(e.id) && cats.contains(e.category) && !e.usage.isEmpty && !p.names.contains(e.name) {
                if harness != .claude && (e.kind == .plugin || e.kind == .skill) { continue }
                p.lines.append(e.usage); p.names.append(e.name)
                if p.names.count >= 8 { break }
            }
            let secWords = role.review ? ["review", "security", "sicherheit", "audit", "verify", "prüf"] : ["security", "sicherheit", "audit"]
            for sk in skills where secWords.contains(where: { (sk.name + " " + sk.description).lowercased().contains($0) }) {
                guard !p.names.contains(where: { $0.lowercased() == sk.name.lowercased() }) else { continue }
                p.lines.append(String(format: L("Für Sicherheit/Prüfung: nutze den Skill %@."), harness == .claude ? "/" + sk.name : sk.name))
                p.names.append(sk.name)
                if p.names.count >= 9 { break }
            }
        }
        // 2b. Verbundene Integrationen (MCP), die zum Auftrag passen – der Agent soll sie nutzen statt Umwegen
        if let hub = MCPHub.current {
            let agentOrigin = osAgent ? "Salenta OS" : (harness == .claude ? "Claude Code" : kind == .codex ? "Codex" : "")
            for s in hub.all where hub.connections[s.id]?.state == .connected {
                let origins = hub.origins(of: s)
                guard osAgent || origins.contains(agentOrigin) else { continue }
                let name = ServerRow.friendly(s.name)
                let words = Set(name.lowercased().split(separator: " ").map(String.init).filter { $0.count >= 4 })
                guard words.contains(where: { lower.contains($0) }), !p.names.contains(name) else { continue }
                p.lines.append(String(format: L("Die Integration „%@“ ist verbunden (MCP-Server %@) – nutze ihre Werkzeuge für diesen Teil, statt es von Hand zu machen."), name, s.name))
                p.names.append(name)
                if p.names.count >= 9 { break }
            }
        }
        // 3. Passend zum Auftrag: Skills (nur, wenn der Auftrag sie nicht schon nennt)
        if !onlyIntegrations && !lower.contains("nutze dafür diese skills") {
            for s in Router.suggestSkills(body, skills: skills).prefix(2) where !p.names.contains(s.name) {
                p.lines.append(String(format: L("Passender Skill für diese Aufgabe (nutze ihn, wenn er hilft): %@"), harness == .claude ? "/" + s.name : s.name))
                p.names.append(s.name)
            }
        }
        return p
    }

    /// Art des Auftrags: reiner Prüf-Auftrag (Helfer „nur prüfen“, Review, Sicherheits-Check) und/oder heikles Thema.
    static func role(of text: String) -> (review: Bool, sensitive: Bool) {
        let reviewWords = ["nur prüfen", "nichts ändern", "review", "prüfe", "überprüf", "sicherheits-check", "sicherheitscheck", "audit", "code-review", "verifiz"]
        let sensitiveWords = ["login", "auth", "passw", "secret", "geheim", "api-key", "api key", "schlüssel", "zahlung", "payment", "stripe", "checkout",
                              "rls", "policy", "berechtig", "permission", "sicherheit", "security", "webhook", "upload", "injection", "xss", "cors", "deploy", "produktion", "production"]
        return (reviewWords.contains { text.contains($0) }, sensitiveWords.contains { text.contains($0) })
    }

    private static var stackCache: [String: [String]] = [:]
    private static let stackLock = NSLock()

    /// Technik des Projekts aus seinen Dateien (ohne git, schnell, zwischengespeichert).
    static func stackWords(_ dir: String) -> [String] {
        stackLock.lock(); if let c = stackCache[dir] { stackLock.unlock(); return c }; stackLock.unlock()
        var out: [String] = []
        let fm = FileManager.default
        func has(_ f: String) -> Bool { fm.fileExists(atPath: (dir as NSString).appendingPathComponent(f)) }
        if let d = fm.contents(atPath: (dir as NSString).appendingPathComponent("package.json")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            let deps = Array(((j["dependencies"] as? [String: Any]) ?? [:]).keys) + Array(((j["devDependencies"] as? [String: Any]) ?? [:]).keys)
            for (k, w) in [("next", "nextjs"), ("react", "react"), ("vue", "vue"), ("svelte", "svelte"), ("@supabase/supabase-js", "supabase"),
                           ("stripe", "stripe"), ("tailwindcss", "tailwind"), ("vitest", "vitest test"), ("playwright", "playwright browser"),
                           ("@sentry", "sentry"), ("prisma", "prisma database"), ("@shopify", "shopify")] where deps.contains(where: { $0.hasPrefix(k) }) {
                out.append(w)
            }
        }
        if has("supabase") { out.append("supabase") }
        if has("vercel.json") || has(".vercel") { out.append("vercel deploy") }
        if has("Package.swift") { out.append("swift") }
        if has("shopify.theme.toml") || has("config/settings_schema.json") { out.append("shopify liquid theme") }
        if has(".github/workflows") { out.append("github ci") }
        stackLock.lock(); stackCache[dir] = out; stackLock.unlock()
        return out
    }

    /// Fertiger Textblock für den Auftrag.
    static func block(_ p: Pick) -> String? {
        guard !p.lines.isEmpty else { return nil }
        return L("Automatisch von Salenta Code (installierte Erweiterungen und Skills):") + "\n" + p.lines.map { "- " + $0 }.joined(separator: "\n")
    }
}
