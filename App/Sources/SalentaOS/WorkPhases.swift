import AgenticOSKit
import Foundation

// Arbeitsplan in Phasen für Code-Aufträge.
// Statt einer langen Liste „nutze X, Y, Z“ bekommt der Agent einen Ablauf – und in jeder Phase genau die installierten
// Erweiterungen und Skills, die dort helfen: planen → umsetzen → aufräumen → prüfen wie die CI → Sicherheit → Review → abschließen.
// Ziel: ein Ergebnis, das beim Übernehmen und auf GitHub gleich grün ist.

enum WorkPhases {
    struct Plan { var text: String; var names: [String] }

    /// Nur für Coding-Agents, die allein arbeiten. Nil = nichts beizutragen.
    static func plan(prompt: String, kind: AgentKind, directory: String?) -> Plan? {
        guard AutoSkills.enabled, AgentKind.coders.contains(kind), kind != .ollama || LocalFirst.shared.localOnly else { return nil }
        let harness = kind.harness
        let installed = ExtensionStore.shared.installed
        var body = prompt
        if let re = try? NSRegularExpression(pattern: "^Im Projekt [^:\\n]+:\\s*") {
            body = re.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "")
        }
        let stack = directory.map(AutoSkills.stackWords) ?? []
        let lower = body.lowercased() + " " + stack.joined(separator: " ")
        let role = AutoSkills.role(of: lower)
        let small = LocalFirst.isSmall(body)
        let ui = isUI(lower)
        let readOnly = lower.contains("nichts ändern") || lower.contains("nur prüfen") || lower.contains("nur analys") || lower.contains("read-only")
        var names: [String] = []

        /// Installierte Erweiterungen nach ID, mit ihrer Nutzungsanweisung (Claude-Plugins nur bei Claude).
        func ext(_ ids: [String]) -> [String] {
            ids.compactMap { id in
                guard installed.contains(id), let e = ExtensionCatalog.find(id), !e.usage.isEmpty else { return nil }
                if harness != .claude && (e.kind == .plugin || e.kind == .skill) { return nil }
                if !names.contains(e.name) { names.append(e.name) }
                return e.usage
            }
        }
        /// Höchstens ein passender eigener Skill pro Phase (ganze Wörter im Namen).
        let skills = SkillCatalog.current?.skills(for: harness) ?? []
        func skill(_ words: [String]) -> [String] {
            guard let s = skills.first(where: { sk in
                let tokens = Set(sk.name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted))
                return words.contains { tokens.contains($0) }
            }) else { return [] }
            if !names.contains(s.name) { names.append(s.name) }
            return [String(format: L("Skill %@ nutzen"), harness == .claude ? "/" + s.name : s.name)]
        }
        func phase(_ n: inout Int, _ title: String, _ what: String, _ tools: [String]) -> String {
            n += 1
            return "\(n). **\(title)** – \(what)" + (tools.isEmpty ? "" : "\n   " + L("Werkzeuge:") + " " + tools.joined(separator: " · "))
        }

        var out: [String] = []
        var n = 0
        // Immer: Token-Sparer
        let savers = ext(["serena"])   // nur Code-Navigation; Antwort-Kürzer (caveman) und Kosten-Zähler gehören nicht in den Auftrag

        out.append(phase(&n, L("Verstehen & planen"),
                         L("Lies CLAUDE.md/AGENTS.md und den betroffenen Code. Schreib einen kurzen Plan: Schritte und je Schritt das Werkzeug von unten.")
                            + (small ? "" : " " + L("Bei Unklarheiten triff die sinnvollste Annahme und nenne sie.")),
                         small ? [] : ext(["superpowers", "feature-dev"]) + skill(["plan", "planning", "brainstorm", "spec"])))
        if !readOnly {
            var build = ext(["context7"])
            if ui { build += ext(["frontend-design"]) + (lower.contains("figma") ? ext(["figma"]) : []) + skill(["design", "frontend", "ui"]) }
            for (id, words) in [("supabase", ["supabase"]), ("stripe", ["stripe", "zahlung", "payment", "checkout"]), ("vercel", ["vercel"]), ("github", ["github actions", "workflow", "ci"])]
                where words.contains(where: { lower.contains($0) }) { build += ext([id]) }
            out.append(phase(&n, L("Umsetzen"),
                             L("Halte dich an Stil und Muster des Projekts. Kleine, nachvollziehbare Schritte; aktuelle Doku statt Vermutungen."), build))
            out.append(phase(&n, L("Aufräumen"),
                             L("Vereinfache, was du geändert hast, ohne das Verhalten zu ändern: keine Debug-Ausgaben, kein toter Code, keine Doppelungen."),
                             ext(["code-simplifier"]) + skill(["simplify", "simplifier", "refactor", "clean"])))
        }
        // Prüfen genau wie die CI auf GitHub
        let checks = directory.map { Verifier.checks(for: $0).map(\.command) } ?? []
        var checkText = checks.isEmpty
            ? L("Führe die Tests, den Lint und den Build des Projekts aus.")
            : L("Führe genau diese Prüfungen aus – dieselben laufen danach auch automatisch und auf GitHub:") + " " + checks.map { "`\($0)`" }.joined(separator: ", ") + "."
        checkText += " " + (readOnly ? L("Berichte, was rot ist.") : L("Alles muss grün sein – sonst Ursache finden und beheben, nicht Tests abschwächen."))
        var testTools = skill(["test", "tdd", "testing"])
        if ui { testTools += ext(["playwright", "chrome-devtools"]); checkText += " " + L("Öffne die geänderte Seite im Browser und prüfe Darstellung, Klicks und Konsole.") }
        out.append(phase(&n, L("Prüfen wie die CI"), checkText, testTools))

        if role.sensitive || role.review {
            out.append(phase(&n, L("Sicherheit"), L("Prüfe die Änderungen auf Lücken (Eingaben, Rechte, Schlüssel, Abhängigkeiten) und behebe Gefundenes."),
                             ext(["security-review", "security-guidance"] + (lower.contains("cloudflare") || lower.contains("worker") ? ["cloudflare-security"] : []))
                                + skill(["security", "sicherheit", "audit"])))
        }
        if !small && !readOnly {
            let review = ext(["code-review"])
            if !review.isEmpty { out.append(phase(&n, L("Selbst-Review"), L("Lies deinen Diff wie ein strenger Kollege und behebe, was auffällt."), review)) }
        }
        out.append(phase(&n, L("Abschließen"),
                         readOnly ? L("Kurzer Bericht: Befund, Ursachen, Empfehlung – nichts ändern.")
                                  : L("Committe in sinnvollen Schritten mit klaren Nachrichten (feat:, fix:, refactor: …). Zum Schluss: was geändert, wie geprüft, was offen.")
                                    + (ext(["claude-md"]).isEmpty ? "" : " " + L("Neue Projekt-Regeln, die du gelernt hast, in CLAUDE.md festhalten.")),
                         []))

        var text = L("Arbeitsplan von Salenta Code – arbeite diese Phasen der Reihe nach ab:") + "\n" + out.joined(separator: "\n")
        if !savers.isEmpty { text += "\n" + L("Die ganze Zeit:") + " " + savers.joined(separator: " · ") }
        return Plan(text: text, names: names)
    }

    static func isUI(_ t: String) -> Bool {
        ["ui", "ux", "design", "seite", "page", "button", "knopf", "layout", "css", "tailwind", "frontend", "komponente", "component",
         "styling", "responsive", "landing", "darstellung", "aussehen", "animation", "dark mode", "formular", "form"].contains { w in
            w.count <= 3 ? t.split(whereSeparator: { !$0.isLetter }).contains { $0 == Substring(w) } : t.contains(w)
        }
    }
}

// Prüfungen wie die CI: aus .github/workflows die Befehle übernehmen, die sich lokal sicher ausführen lassen.
enum CIParity {
    static func commands(_ dir: String) -> [String] {
        let wf = (dir as NSString).appendingPathComponent(".github/workflows")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: wf) else { return [] }
        var out: [String] = []
        for f in files where f.hasSuffix(".yml") || f.hasSuffix(".yaml") {
            guard let text = try? String(contentsOfFile: (wf as NSString).appendingPathComponent(f), encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: "\n")
            var i = 0
            while i < lines.count {
                let l = lines[i].trimmingCharacters(in: .whitespaces)
                let stripped = l.hasPrefix("- ") ? String(l.dropFirst(2)) : l
                if stripped.hasPrefix("run:") {
                    let v = stripped.dropFirst(4).trimmingCharacters(in: .whitespaces)
                    if v == "|" || v == ">" || v.isEmpty {
                        let indent = lines[i].prefix { $0 == " " }.count
                        var j = i + 1
                        while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty || lines[j].prefix(while: { $0 == " " }).count > indent {
                            let c = lines[j].trimmingCharacters(in: .whitespaces); if !c.isEmpty { out.append(c) }
                            j += 1
                        }
                        i = j; continue
                    } else { out.append(v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))) }
                }
                i += 1
            }
        }
        var seen = Set<String>()
        return out.filter { safe($0) && seen.insert($0).inserted }
    }

    /// Nur reine Prüfbefehle ohne Geheimnisse, Netz-Dienste oder Veröffentlichung.
    static func safe(_ c: String) -> Bool {
        let t = c.lowercased()
        let bad = ["${{", "secrets", "deploy", "publish", "release", "upload", "docker", "gh ", "curl", "wget", "supabase db", "vercel",
                   "e2e", "integration", "playwright", "cypress", "sudo", "apt", "brew", "&&", "||", ";", "|", ">", "export ", "cd "]
        guard !bad.contains(where: { t.contains($0) }) else { return false }
        let good = ["npm run ", "pnpm ", "yarn ", "bun run ", "npx tsc", "npx eslint", "npx prettier --check", "npx vitest run", "deno check", "deno lint",
                    "deno fmt --check", "deno test", "swift build", "swift test", "cargo test", "cargo clippy", "cargo build", "go test", "go vet",
                    "ruff", "pytest", "mypy"]
        guard good.contains(where: { t.hasPrefix($0) }) else { return false }
        return ["test", "lint", "check", "typecheck", "tsc", "build", "vet", "clippy", "ruff", "mypy", "pytest", "fmt"].contains { t.contains($0) }
            && !t.contains("install") && !t.contains("--watch")
    }
}
