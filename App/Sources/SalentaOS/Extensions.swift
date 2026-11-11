import AgenticOSKit
import AppKit
import SwiftUI

// Erweiterungen: kuratierte, kostenlose Plugins, MCP-Server, Skills und CLIs, die Vibe-Coding besser
// und günstiger machen. Mit Erklärung, Repo-Link, Installation per Klick – und die Agentenwahl kennt sie:
// sie nutzt installierte Erweiterungen gezielt und schlägt fehlende vor, wenn ein Auftrag davon profitiert.

struct Extension: Identifiable, Hashable {
    enum Kind: String { case plugin = "Claude-Plugin", mcp = "MCP-Server", skill = "Skill", cli = "CLI-Agent", tool = "Werkzeug" }
    enum Category: String, CaseIterable {
        case essentials = "Empfohlen für den Start"
        case quality = "Qualität & Review"
        case debug = "Debugging & Tests"
        case security = "Sicherheit"
        case tokens = "Tokens sparen"
        case docs = "Doku & Kontext"
        case deploy = "Deploy & Betrieb"
        case design = "Design & Frontend"
        var title: String { L(rawValue) }
    }

    let id: String
    let name: String
    let kind: Kind
    let category: Category
    let repo: String            // Link zum Repo / zur Doku
    let stars: String           // grobe Beliebtheit (Stand Herbst 2026)
    let purpose: String         // was es bringt – in einfachen Worten
    let when: [String]          // Stichwörter: wann die Agentenwahl es vorschlägt
    let install: String         // Befehl
    let usage: String           // wie der Agent es im Auftrag nutzt
    var essential = false

    var pluginKey: String? { kind == .plugin ? (install.components(separatedBy: "plugin install ").last?.components(separatedBy: " ").first) : nil }

    /// Wie ein Agent diese Erweiterung im Auftrag nutzt. Selbst hinzugefügte Repos haben keinen festen Satz – für sie entsteht er
    /// aus Art und Beschreibung, damit Agentenwahl, Betreuer und Automatik sie genauso einplanen wie die kuratierten.
    var howTo: String {
        if !usage.isEmpty { return usage }
        guard id.hasPrefix("custom:") else { return "" }
        let what = purpose.isEmpty || purpose == L("Ohne Beschreibung im Repo.") ? "" : " (" + String(purpose.prefix(140)) + ")"
        switch kind {
        case .plugin: return String(format: L("Das Plugin „%@“ ist installiert%@ – nutze seine Befehle und Skills überall dort, wo sie zu diesem Auftrag passen."), name, what)
        case .skill: return String(format: L("Der Skill /%@ ist installiert%@ – nutze ihn, wo er zu diesem Auftrag passt."), name, what)
        case .mcp: return String(format: L("Der MCP-Server „%@“ ist verbunden%@ – nutze seine Werkzeuge, statt es von Hand zu machen."), name, what)
        case .cli, .tool: return String(format: L("Das Werkzeug „%@“ ist installiert%@ – nutze es, wo es hilft."), name, what)
        }
    }

    /// Plugins und Skills kennt nur Claude Code (und was darauf läuft), MCP-Server und Werkzeuge jeder Agent.
    /// (Ein Werkzeug, das nur ein Befehl von Claude Code oder ein anderer Agent ist, zählt für fremde Agents nicht.)
    func usable(claudeBased: Bool) -> Bool {
        if claudeBased { return true }
        guard kind == .mcp || kind == .tool else { return false }
        let u = usage.lowercased()
        return !(u.contains("/" + id.lowercased()) || u.contains("claude ") || u.contains("junie"))
    }
}

enum ExtensionCatalog {
    /// Kuratiert + selbst hinzugefügte Repos
    static var all: [Extension] { curated + CustomExtensions.shared.extensions }
    static let curated: [Extension] = [
        // Start-Paket: was jeder braucht, der nur Claude Code hat
        Extension(id: "playwright", name: "Playwright", kind: .plugin, category: .essentials,
                  repo: "https://github.com/microsoft/playwright-mcp", stars: "Microsoft · 300k+ Installationen",
                  purpose: "Der Agent kann echte Webseiten öffnen, klicken, ausfüllen und Screenshots machen – er prüft seine eigene UI selbst.",
                  when: ["ui", "seite", "button", "formular", "login", "browser", "klick", "e2e", "frontend", "layout", "responsive", "testen"],
                  install: "claude plugin install playwright@claude-plugins-official",
                  usage: "Prüfe UI-Änderungen selbst mit dem Playwright-Browser (Seite öffnen, durchklicken, Screenshot).", essential: true),
        Extension(id: "context7", name: "Context7", kind: .plugin, category: .essentials,
                  repo: "https://github.com/upstash/context7", stars: "Upstash · 400k+ Installationen",
                  purpose: "Holt die aktuelle Doku genau der Bibliotheks-Version, die du nutzt. Weniger falsche APIs, weniger Nachbessern, weniger Tokens.",
                  when: ["api", "bibliothek", "library", "framework", "next", "react", "supabase", "stripe", "sdk", "version", "upgrade", "migration", "doku"],
                  install: "claude plugin install context7@claude-plugins-official",
                  usage: "Schlage aktuelle Doku über Context7 nach, bevor du Bibliotheks-APIs benutzt.", essential: true),
        Extension(id: "security-guidance", name: "Security Guidance", kind: .plugin, category: .essentials,
                  repo: "https://github.com/anthropics/claude-plugins-official", stars: "Anthropic · 240k+ Installationen",
                  purpose: "Warnt schon beim Schreiben vor riskantem Code (Injection, Secrets, unsichere Auth) und prüft den Diff vor dem Commit.",
                  when: ["sicherheit", "security", "auth", "login", "passwort", "token", "api-key", "rls", "berechtigung", "payment", "zahlung", "upload", "webhook"],
                  install: "claude plugin install security-guidance@claude-plugins-official",
                  usage: "Achte auf die Hinweise von security-guidance und führe am Ende /security-review aus.", essential: true),
        Extension(id: "superpowers", name: "Superpowers", kind: .plugin, category: .essentials,
                  repo: "https://github.com/obra/superpowers", stars: "obra · 1 Mio.+ Installationen",
                  purpose: "Bewährte Arbeitsweisen als Skills: erst planen, Tests zuerst (TDD), sauber debuggen, Teilaufgaben an Subagents.",
                  when: ["feature", "bauen", "plan", "refactor", "umbauen", "neu", "komplex", "architektur", "tdd", "test"],
                  install: "claude plugin install superpowers@claude-plugins-official",
                  usage: "Arbeite nach den Superpowers-Skills: Plan, Tests zuerst, systematisches Debugging.", essential: true),
        Extension(id: "junie", name: "Junie (JetBrains)", kind: .cli, category: .essentials,
                  repo: "https://junie.jetbrains.com/docs/junie-cli.html", stars: "JetBrains",
                  purpose: "Eigener Coding-Agent von JetBrains – stark beim Fehlersuchen: findet die Ursache, behebt sie, lässt Tests laufen. Salenta Code nimmt ihn automatisch für Bugs.",
                  when: ["bug", "fehler", "crash", "kaputt", "funktioniert nicht", "debug", "stacktrace", "exception"],
                  install: "curl -fsSL https://junie.jetbrains.com/install.sh | bash",
                  usage: "", essential: true),

        // Qualität & Review
        Extension(id: "code-review", name: "Code Review", kind: .plugin, category: .quality,
                  repo: "https://github.com/anthropics/claude-plugins-official", stars: "Anthropic · 440k+ Installationen",
                  purpose: "Mehrere Prüf-Agents lesen deinen Pull Request gegen – Bugs, Regeln aus CLAUDE.md, Historie.",
                  when: ["review", "pull request", "pr", "prüf", "gegenlesen", "qualität"],
                  install: "claude plugin install code-review@claude-plugins-official", usage: "Nutze /code-review für die Prüfung."),
        Extension(id: "code-simplifier", name: "Code Simplifier", kind: .plugin, category: .quality,
                  repo: "https://github.com/anthropics/claude-plugins-official", stars: "Anthropic · 370k+ Installationen",
                  purpose: "Räumt frisch geänderten Code auf, ohne das Verhalten zu ändern – lesbarer, weniger doppelt.",
                  when: ["aufräumen", "vereinfachen", "clean", "lesbar", "doppelt", "refactor"],
                  install: "claude plugin install code-simplifier@claude-plugins-official", usage: "Räume am Ende mit code-simplifier auf."),
        Extension(id: "feature-dev", name: "Feature Dev", kind: .plugin, category: .quality,
                  repo: "https://github.com/anthropics/claude-plugins-official", stars: "Anthropic · 270k+ Installationen",
                  purpose: "Geführter Ablauf für größere Features: Code erkunden, Architektur entwerfen, bauen, prüfen.",
                  when: ["feature", "neue funktion", "großes", "modul", "erweiterung"],
                  install: "claude plugin install feature-dev@claude-plugins-official", usage: "Nutze /feature-dev für den Ablauf."),
        Extension(id: "claude-md", name: "CLAUDE.md Management", kind: .plugin, category: .quality,
                  repo: "https://github.com/anthropics/claude-plugins-official", stars: "Anthropic · 310k+ Installationen",
                  purpose: "Hält die Projekt-Notizen (CLAUDE.md) aktuell – jeder Agent kennt dann die Regeln und Eigenheiten des Repos.",
                  when: ["projekt einrichten", "onboarding", "regeln", "claude.md", "agents.md"],
                  install: "claude plugin install claude-md-management@claude-plugins-official", usage: "Aktualisiere am Ende die CLAUDE.md, wenn du etwas Wichtiges gelernt hast."),

        // Debugging & Tests
        Extension(id: "chrome-devtools", name: "Chrome DevTools", kind: .plugin, category: .debug,
                  repo: "https://github.com/ChromeDevTools/chrome-devtools-mcp", stars: "Google",
                  purpose: "Konsole, Netzwerk und Performance-Messungen im echten Chrome – findet JavaScript-Fehler und langsame Seiten.",
                  when: ["langsam", "performance", "ladezeit", "konsole", "console", "netzwerk", "network", "javascript-fehler", "lighthouse"],
                  install: "claude plugin install chrome-devtools-mcp@claude-plugins-official", usage: "Untersuche Konsole, Netzwerk und Performance mit Chrome DevTools."),
        Extension(id: "sentry", name: "Sentry", kind: .plugin, category: .debug,
                  repo: "https://github.com/getsentry/sentry-mcp", stars: "Sentry",
                  purpose: "Der Agent liest echte Fehler aus deiner Live-App (Stacktraces, betroffene Nutzer) und behebt sie gezielt.",
                  when: ["live", "produktion", "production", "sentry", "fehlermeldung", "nutzer melden"],
                  install: "claude plugin install sentry@claude-plugins-official", usage: "Hole dir die Fehlerdetails aus Sentry."),

        // Sicherheit
        Extension(id: "security-review", name: "/security-review (eingebaut)", kind: .tool, category: .security,
                  repo: "https://docs.claude.com/en/docs/claude-code", stars: "Anthropic · in Claude Code enthalten",
                  purpose: "Einmaliger Sicherheits-Check der offenen Änderungen – ohne Installation, direkt in Claude Code.",
                  when: ["sicherheit", "security", "audit", "lücke", "schwachstelle"],
                  install: "", usage: "Führe /security-review auf deine Änderungen aus."),
        Extension(id: "cloudflare-security", name: "Cloudflare Security Skill", kind: .skill, category: .security,
                  repo: "https://github.com/santmun/cloudflare-security-skill", stars: "Community · neu",
                  purpose: "Sichert eine App auf Cloudflare Schritt für Schritt ab (WAF, Rate-Limits, Turnstile, Bot-Schutz) – erklärt jeden Schritt und fragt vorher.",
                  when: ["cloudflare", "waf", "ddos", "bot", "rate limit", "turnstile"],
                  install: "git clone https://github.com/santmun/cloudflare-security-skill.git ~/.claude/skills/cloudflare-security",
                  usage: "Nutze den Skill /cloudflare-security."),

        // Tokens sparen
        Extension(id: "caveman", name: "Caveman", kind: .plugin, category: .tokens,
                  repo: "https://github.com/JuliusBrussee/caveman", stars: "≈ 114k ⭐",
                  purpose: "Lässt den Agent knapp antworten und weniger lesen – spart im Schnitt rund zwei Drittel der Ausgabe-Tokens, Code bleibt exakt.",
                  when: [], install: "claude plugin marketplace add JuliusBrussee/caveman && claude plugin install caveman@caveman", usage: ""),
        Extension(id: "serena", name: "Serena", kind: .mcp, category: .tokens,
                  repo: "https://github.com/oraios/serena", stars: "≈ 31k ⭐",
                  purpose: "Findet Funktionen und Klassen wie eine IDE statt ganze Dateien zu lesen – spart in großen Repos viele Tokens.",
                  when: ["großes repo", "monorepo", "viele dateien", "umbenennen", "refactor"],
                  install: "(command -v uv || brew install uv) && uv tool install -p 3.13 serena-agent && claude mcp add --scope user serena -- serena start-mcp-server --context claude-code --project-from-cwd",
                  usage: "Nutze Serena für die Code-Navigation statt ganze Dateien zu lesen."),
        Extension(id: "codeburn", name: "CodeBurn", kind: .tool, category: .tokens,
                  repo: "https://codeburn.app", stars: "lokal, kostenlos",
                  purpose: "Zeigt Token-Verbrauch und Kosten über 40+ Tools – gut, um zu sehen, wo Tokens verbrannt werden.",
                  when: [], install: "open https://codeburn.app", usage: ""),

        // Doku & Kontext
        Extension(id: "github", name: "GitHub", kind: .plugin, category: .docs,
                  repo: "https://github.com/github/github-mcp-server", stars: "GitHub · 340k+ Installationen",
                  purpose: "Issues, Pull Requests und Code-Suche direkt für den Agent – „schau dir Issue #12 an und behebe es“.",
                  when: ["issue", "pull request", "github", "pr #", "ticket"],
                  install: "claude plugin install github@claude-plugins-official", usage: "Lies Issues und Pull Requests über das GitHub-Plugin."),

        // Deploy & Betrieb
        Extension(id: "vercel", name: "Vercel", kind: .plugin, category: .deploy,
                  repo: "https://vercel.com/docs/mcp", stars: "Vercel · 270k+ Installationen",
                  purpose: "Deploy-Status, Build-Logs und Umgebungsvariablen – der Agent sieht, warum ein Deploy fehlschlägt.",
                  when: ["vercel", "deploy", "build fehlgeschlagen", "preview", "domain"],
                  install: "claude plugin install vercel@claude-plugins-official", usage: "Prüfe Deploys und Build-Logs über das Vercel-Plugin."),
        Extension(id: "supabase", name: "Supabase", kind: .plugin, category: .deploy,
                  repo: "https://github.com/supabase-community/supabase-mcp", stars: "Supabase · 120k+ Installationen",
                  purpose: "Datenbank, Auth, Storage und Edge Functions – Tabellen ansehen, Migrationen, Logs.",
                  when: ["supabase", "datenbank", "tabelle", "migration", "edge function", "rls", "postgres"],
                  install: "claude plugin install supabase@claude-plugins-official", usage: "Nutze das Supabase-Plugin für Datenbank und Logs."),
        Extension(id: "stripe", name: "Stripe", kind: .plugin, category: .deploy,
                  repo: "https://github.com/stripe/agent-toolkit", stars: "Stripe",
                  purpose: "Zahlungen, Abos und Webhooks richtig einbauen – mit Stripes eigenem Wissen.",
                  when: ["stripe", "zahlung", "payment", "abo", "checkout", "subscription"],
                  install: "claude plugin install stripe@claude-plugins-official", usage: "Nutze das Stripe-Plugin."),

        // Design & Frontend
        Extension(id: "frontend-design", name: "Frontend Design", kind: .plugin, category: .design,
                  repo: "https://github.com/anthropics/claude-plugins-official", stars: "Anthropic · 1,2 Mio.+ Installationen",
                  purpose: "Eigenständiges, hochwertiges UI statt Standard-Look – Typografie, Farben, Layout mit Haltung.",
                  when: ["design", "ui", "landing", "seite gestalten", "schöner", "optik", "look", "css", "tailwind"],
                  install: "claude plugin install frontend-design@claude-plugins-official", usage: "Nutze den Skill frontend-design für die Gestaltung.", essential: false),
        Extension(id: "figma", name: "Figma", kind: .plugin, category: .design,
                  repo: "https://help.figma.com/hc/en-us/articles/32132100833559", stars: "Figma · 180k+ Installationen",
                  purpose: "Setzt Figma-Designs direkt in Code um (und zurück).",
                  when: ["figma", "design umsetzen", "mockup"],
                  install: "claude plugin install figma@claude-plugins-official", usage: "Hole das Design über das Figma-Plugin."),
    ]

    static func find(_ id: String) -> Extension? { all.first { $0.id == id } }
}

/// Was ist schon installiert? (Claude-Plugins, MCP-Server, Skills, CLIs)
final class ExtensionStore: ObservableObject {
    static let shared = ExtensionStore()
    @Published private(set) var installed: Set<String> = []
    @Published private(set) var busy: Set<String> = []
    @Published var lastLog: [String: String] = [:]

    init() { refresh() }

    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let home = FileManager.default.homeDirectoryForCurrentUser
            var plugins = Set<String>()
            if let d = try? Data(contentsOf: home.appendingPathComponent(".claude/plugins/installed_plugins.json")),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                let p = (j["plugins"] as? [String: Any]) ?? j
                plugins = Set(p.keys.map { $0.lowercased() })
            }
            var mcps = Set<String>()
            if let d = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                mcps.formUnion(((j["mcpServers"] as? [String: Any]) ?? [:]).keys.map { $0.lowercased() })
                for (_, v) in (j["projects"] as? [String: Any]) ?? [:] {
                    mcps.formUnion((((v as? [String: Any])?["mcpServers"] as? [String: Any]) ?? [:]).keys.map { $0.lowercased() })
                }
            }
            let skills = Set(((try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".claude/skills").path)) ?? []).map { $0.lowercased() })
            var found = Set<String>()
            for e in ExtensionCatalog.all {
                switch e.kind {
                case .plugin:
                    if let key = e.pluginKey?.lowercased(), plugins.contains(key) || plugins.contains(where: { $0.hasPrefix(key.components(separatedBy: "@").first! + "@") }) { found.insert(e.id) }
                case .mcp: if mcps.contains(e.id) || mcps.contains(e.name.lowercased()) { found.insert(e.id) }
                case .skill:
                    if e.id.hasPrefix("custom:") { if skills.contains(e.name.lowercased()) { found.insert(e.id) } }
                    else if skills.contains(where: { $0.contains(e.id.components(separatedBy: "-").first!) }) { found.insert(e.id) }
                case .cli: if Detection.which(e.id) != nil { found.insert(e.id) }
                case .tool: if e.install.isEmpty { found.insert(e.id) }
                }
            }
            DispatchQueue.main.async { self.installed = found }
        }
    }

    func isInstalled(_ e: Extension) -> Bool { installed.contains(e.id) }

    /// Installiert im Hintergrund (Fortschritt im Log). CLI-Agents mit Webseite öffnen die Anleitung.
    func install(_ e: Extension, completion: ((Bool) -> Void)? = nil) {
        if e.install.hasPrefix("open ") {
            if let u = URL(string: String(e.install.dropFirst(5))) { NSWorkspace.shared.open(u) }
            return
        }
        guard !e.install.isEmpty, !busy.contains(e.id) else { return }
        busy.insert(e.id)
        DispatchQueue.global(qos: .userInitiated).async {
            // Offizieller Marktplatz einmalig (wird bei neuen Claude-Code-Versionen automatisch angelegt)
            var cmd = e.install
            if cmd.contains("@claude-plugins-official") {
                cmd = "(claude plugin marketplace list 2>/dev/null | grep -q claude-plugins-official || claude plugin marketplace add anthropics/claude-plugins-official); " + cmd
            }
            // MCP-Server für alle installierten Agents eintragen, nicht nur für Claude Code
            if let m = cmd.range(of: #"claude mcp add --scope user (\S+) -- (.+)$"#, options: .regularExpression) {
                let tail = String(cmd[m])
                let name = tail.components(separatedBy: " ")[5]
                let run = tail.components(separatedBy: " -- ").dropFirst().joined(separator: " -- ")
                cmd += "; (command -v codex >/dev/null && codex mcp add \(name) -- \(run) >/dev/null 2>&1 || true)"
                cmd += "; (command -v gemini >/dev/null && gemini mcp add -s user \(name) \(run) >/dev/null 2>&1 || true)"
            }
            let r = Proc.zsh(cmd, in: FileManager.default.homeDirectoryForCurrentUser.path, timeout: 600)
            let logURL = Paths.root.appendingPathComponent("logs/extensions.log")
            let entry = "\n=== \(Date()) \(e.id) exit \(r.code)\n$ \(cmd)\n\(r.out.suffix(3000))\n"
            if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(Data(entry.utf8)); try? h.close() }
            else { try? entry.write(to: logURL, atomically: true, encoding: .utf8) }
            DispatchQueue.main.async {
                self.busy.remove(e.id)
                self.lastLog[e.id] = String(r.out.suffix(1500))
                self.refresh()
                completion?(r.code == 0)
            }
        }
    }

    /// Für die Agentenwahl: installiert + passend / nicht installiert + passend.
    func matches(_ text: String) -> (use: [Extension], suggest: [Extension]) {
        let t = text.lowercased()
        let hits = ExtensionCatalog.all.filter { e in e.when.contains { t.contains($0) } }
        return (hits.filter { isInstalled($0) && !$0.howTo.isEmpty }, hits.filter { !isInstalled($0) && !$0.install.isEmpty })
    }

    var installedList: [Extension] { ExtensionCatalog.all.filter { isInstalled($0) } }
}

// MARK: - Seite "Erweiterungen"

struct ExtensionsView: View {
    @ObservedObject private var store = ExtensionStore.shared
    @ObservedObject private var custom = CustomExtensions.shared
    @State private var filter = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Grid.xl) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Erweiterungen").font(.largeTitle.weight(.semibold))
                    Text("Kostenlose Plugins, Tools und Skills, die beim Vibe-Coden helfen – geprüft, beliebt, mit einem Klick installiert. Salenta Code nutzt sie automatisch, wenn ein Auftrag davon profitiert, und schlägt fehlende vor.")
                        .foregroundStyle(.secondary)
                    Text("Tipp: 3–6 Erweiterungen reichen. Jede zusätzliche kostet ein wenig Kontext pro Auftrag.")
                        .font(.caption).foregroundStyle(.tertiary)
                    Toggle(isOn: Binding(get: { AutoSkills.enabled }, set: { UserDefaults.standard.set($0, forKey: "auto.skills") })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Automatisch nutzen").font(.callout.weight(.semibold))
                            Text("Serena (Code-Navigation) und Context7 laufen bei jedem Auftrag mit, wenn sie installiert sind; passende Skills und Erweiterungen werden je nach Aufgabe dazugenommen – auch beim Weitermachen und Umsetzen.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch).padding(.top, 6)
                }
                ExtensionSearchBar(filter: $filter)
                if !CustomExtensions.shared.extensions.isEmpty {
                    VStack(alignment: .leading, spacing: Grid.s) {
                        Text("Von dir hinzugefügt").font(.title3.weight(.semibold))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: Grid.m)], spacing: Grid.m) {
                            ForEach(CustomExtensions.shared.extensions.filter { ExtensionSearchBar.matches($0, filter) }) { e in
                                ExtensionCard(ext: e)
                                    .contextMenu { Button(L("Aus „Von dir hinzugefügt“ entfernen")) { CustomExtensions.shared.remove(e.id) } }
                            }
                        }
                    }
                }
                ForEach(Extension.Category.allCases, id: \.self) { cat in
                    let items = ExtensionCatalog.curated.filter { $0.category == cat && ExtensionSearchBar.matches($0, filter) }
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: Grid.s) {
                            Text(cat.title).font(.title3.weight(.semibold))
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: Grid.m)], spacing: Grid.m) {
                                ForEach(items) { e in ExtensionCard(ext: e) }
                            }
                        }
                    }
                }
                Divider()
                DiscoveredSection()
            }
            .padding(Grid.xl)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Erweiterungen")
        .toolbar { ToolbarItem { Button { store.refresh() } label: { Label("Aktualisieren", systemImage: "arrow.clockwise") }.help(L("Aktualisieren")) } }
        .onAppear { store.refresh() }
    }
}

struct ExtensionCard: View {
    let ext: Extension
    var compact = false
    @ObservedObject private var store = ExtensionStore.shared

    var body: some View {
        let ok = store.isInstalled(ext)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Grid.s) {
                Text(ext.name).font(.headline)
                Text(L(ext.kind.rawValue)).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                Spacer()
                if ok {
                    Label("installiert", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                } else if store.busy.contains(ext.id) {
                    ProgressView().controlSize(.small)
                } else if !ext.install.isEmpty {
                    Button(ext.install.hasPrefix("open ") ? L("Anleitung") : L("Installieren")) { store.install(ext) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            Text(L(ext.purpose)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !compact {
                HStack {
                    Text(ext.stars).font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    if let u = URL(string: ext.repo) { Link("Repo / Doku", destination: u).font(.caption) }
                }
                if let log = store.lastLog[ext.id], !ok {
                    Text(log).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
                }
            }
        }
        .padding(Grid.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ModernCardBackground(radius: 12))
    }
}

/// Schritt in der Einrichtung: das Start-Paket mit einem Klick.
struct ExtensionsSetupStep: View {
    @ObservedObject private var store = ExtensionStore.shared
    @State private var chosen: Set<String> = Set(ExtensionCatalog.all.filter(\.essential).map(\.id))

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.m) {
            Text("Empfohlene Erweiterungen").font(.title2.weight(.semibold))
            Text("Damit arbeiten deine Agents von Anfang an besser: Browser zum Selbsttesten, aktuelle Doku, Sicherheits-Hinweise, bewährte Arbeitsweisen. Alles kostenlos, jederzeit unter „Erweiterungen“ änderbar.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(ExtensionCatalog.all.filter { $0.essential || $0.id == "caveman" || $0.id == "frontend-design" }) { e in
                        HStack(alignment: .top) {
                            if store.isInstalled(e) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else if store.busy.contains(e.id) {
                                ProgressView().controlSize(.small)
                            } else {
                                Toggle("", isOn: Binding(get: { chosen.contains(e.id) }, set: { if $0 { chosen.insert(e.id) } else { chosen.remove(e.id) } }))
                                    .toggleStyle(.checkbox).labelsHidden()
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.name).font(.callout.weight(.semibold))
                                Text(L(e.purpose)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
            }
            HStack {
                Button("Ausgewählte installieren") {
                    for e in ExtensionCatalog.all where chosen.contains(e.id) && !store.isInstalled(e) && !e.install.hasPrefix("open ") { store.install(e) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(Detection.which("claude") == nil)
                if Detection.which("claude") == nil {
                    Text("Erst Claude Code installieren (vorheriger Schritt).").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
}

// MARK: - Vorschlag vor dem Start

/// "So würde ich es umsetzen": Agent, Modell, Projekt, Skills, Erweiterungen – ändern, starten oder ablehnen.
struct ProposalCard: View {
    @Binding var decision: AIRouteDecision
    let visible: [MissionTarget]
    var projects: [Project] = []
    let start: (AIRouteDecision) -> Void
    let plain: () -> Void
    let cancel: () -> Void
    @ObservedObject private var ext = ExtensionStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.s) {
            HStack(spacing: Grid.s) {
                Image(systemName: "wand.and.sparkles").foregroundStyle(.orange)
                Text("So würde ich es umsetzen").font(.headline)
                Spacer()
                Button { cancel() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary).help(L("Vorschlag schließen"))
            }
            if !decision.reason.isEmpty { Text(decision.reason).font(.callout).foregroundStyle(.secondary) }

            HStack(spacing: Grid.m) {
                Menu {
                    ForEach(visible.filter { $0 != .auto }) { t in
                        Button { decision.target = t; if !(t == .claude || t == .osAgent) || !["opus", "sonnet", "haiku"].contains(decision.model ?? "") { decision.model = nil } } label: { Label(t.title, systemImage: t.symbol) }
                    }
                } label: { Label(decision.target.title, systemImage: decision.target.symbol).font(.callout.weight(.semibold)) }
                    .menuStyle(.borderlessButton).fixedSize()
                let agent = decision.target == .osAgent ? AgentKind.claude : decision.target.agent
                let chosen = agent.map { ModelCatalog.selected(for: $0) } ?? ""
                Label(chosen.isEmpty ? (decision.model.map { ["opus", "sonnet", "haiku"].contains($0) ? $0.capitalized : $0 } ?? L("Standardmodell")) : chosen, systemImage: "cpu").font(.callout)
                if let e = decision.effort { Label(L("Denktiefe ") + e, systemImage: "brain").font(.callout) }
                if decision.target != .osAgent && decision.target != .chatgpt && decision.target != .claudeWeb {
                    // Projekt sichtbar und änderbar – oder lösen
                    Menu {
                        ForEach(projects) { p in
                            Button { decision.directory = p.path } label: {
                                Label(p.name + "  " + (p.path as NSString).deletingLastPathComponent.replacingOccurrences(of: Paths.home.path, with: "~"),
                                      systemImage: decision.directory == p.path ? "checkmark" : "folder")
                            }
                        }
                        if projects.isEmpty { Text("Noch keine Projekte – unter Projekte hinzufügen") }
                        Divider()
                        Button(L("Ordner wählen …")) {
                            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                            if panel.runModal() == .OK, let u = panel.url { decision.directory = u.path }
                        }
                        if decision.directory != nil { Button(L("Projekt lösen")) { decision.directory = nil } }
                    } label: {
                        Label(decision.directory.map { ($0 as NSString).lastPathComponent } ?? L("Projekt wählen"),
                              systemImage: decision.directory == nil ? "folder.badge.plus" : "folder").font(.callout)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .foregroundStyle(decision.directory == nil ? .orange : .primary)
                }
            }
            .foregroundStyle(.primary)

            chips(L("Skills"), "wand.and.stars", decision.skills) { s in decision.skills.removeAll { $0 == s } }
            chips(L("Erweiterungen"), "puzzlepiece.extension", (decision.extensions ?? []).compactMap { ExtensionCatalog.find($0)?.name }) { name in
                decision.extensions?.removeAll { ExtensionCatalog.find($0)?.name == name }
            }
            if let t = decision.tools, !t.isEmpty {
                chips(L("Tools"), "app.connected.to.app.below.fill", t) { x in decision.tools?.removeAll { $0 == x } }
            }

            let sugg = (decision.suggest ?? []).compactMap(ExtensionCatalog.find).filter { !ext.isInstalled($0) }
            if !sugg.isEmpty {
                Text("Würde hier helfen – noch nicht installiert:").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(sugg) { e in
                    HStack(alignment: .top) {
                        Image(systemName: "lightbulb").foregroundStyle(.yellow)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.name).font(.callout.weight(.semibold))
                            Text(L(e.purpose)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        if ext.busy.contains(e.id) { ProgressView().controlSize(.small) } else {
                            Button(e.install.hasPrefix("open ") ? L("Anleitung") : L("Installieren")) {
                                ext.install(e) { ok in
                                    if ok, !e.howTo.isEmpty { decision.extensions = (decision.extensions ?? []) + [e.id] }
                                }
                            }.controlSize(.small)
                        }
                    }
                }
            }

            HStack {
                Button(AgentManager.claudeOff ? L("Ohne Vorschläge – direkt mit Codex") : L("Ohne Vorschläge – normal mit Claude")) { plain() }
                    .buttonStyle(.link).font(.caption)
                    .help(L("Startet Claude Code im Dialog, ohne Skills, Erweiterungen oder automatische Modellwahl"))
                Spacer()
                Button(L("Abbrechen")) { cancel() }
                Button { start(decision) } label: { Label(L("Starten"), systemImage: "arrow.up") }
                    .buttonStyle(.borderedProminent).tint(.orange)
            }
        }
        .padding(Grid.m)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.orange.opacity(0.3)))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder private func chips(_ title: String, _ symbol: String, _ items: [String], remove: @escaping (String) -> Void) -> some View {
        if !items.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.caption).foregroundStyle(.secondary)
                ForEach(items, id: \.self) { i in
                    HStack(spacing: 3) {
                        Text(i).font(.caption)
                        Button { remove(i) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }.buttonStyle(.plain).help(L("Entfernen"))
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
            }
        }
    }
}

// MARK: - Automatisch neue Erweiterungen finden (täglich, mit Sicherheits-Check)

/// Ein auf GitHub gefundenes, installierbares Claude-Plugin-Repo.
struct DiscoveredExt: Codable, Identifiable, Hashable {
    var id: String { repo }
    let repo: String            // owner/name
    let description: String
    let stars: Int
    let pushed: String
    let license: String
    let marketplace: String     // Name aus .claude-plugin/marketplace.json
    let plugins: [String]
    let checkedFiles: Int
}

final class ExtensionDiscovery: ObservableObject {
    static let shared = ExtensionDiscovery()
    @Published private(set) var items: [DiscoveredExt] = []
    @Published private(set) var excluded: [String: String] = [:]   // Repo → Grund
    @Published private(set) var updated: Date?
    @Published private(set) var running = false
    @Published private(set) var lastError: String?

    static var minStars: Int { UserDefaults.standard.object(forKey: "discover.minStars") as? Int ?? 3000 }
    static let maxItems = 20
    private var url: URL { Paths.data.appendingPathComponent("discovered-extensions.json") }

    init() {
        load()
        if (updated ?? .distantPast) < Date().addingTimeInterval(-86400) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.refresh() }
        }
    }

    private func load() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let d = try? Data(contentsOf: url), let j = try? dec.decode(Saved.self, from: d) else { return }
        items = j.items; excluded = j.excluded; updated = j.updated
    }

    private struct Saved: Codable { let items: [DiscoveredExt]; let excluded: [String: String]; let updated: Date }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        if let d = try? enc.encode(Saved(items: items, excluded: excluded, updated: updated ?? Date())) { try? d.write(to: url, options: .atomic) }
    }

    // MARK: Abrufen

    /// GitHub-API: mit `gh` (angemeldet, hohes Limit) oder ohne Anmeldung.
    private static func api(_ path: String) -> Any? {
        if Detection.which("gh") != nil {
            let r = Proc.zsh("gh api -H 'Accept: application/vnd.github+json' \(Shell.quote(path))", in: NSTemporaryDirectory(), timeout: 30)
            if r.code == 0, let s = r.out.firstIndex(where: { $0 == "{" || $0 == "[" }) {
                return try? JSONSerialization.jsonObject(with: Data(r.out[s...].utf8))
            }
        }
        guard let u = URL(string: "https://api.github.com/" + path) else { return nil }
        return fetch(u).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    private static func fetch(_ u: URL) -> Data? {
        var req = URLRequest(url: u, timeoutInterval: 20)
        req.setValue("Salenta-Code", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var out: Data?
        URLSession.shared.dataTask(with: req) { d, r, _ in
            if (r as? HTTPURLResponse)?.statusCode == 200 { out = d }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 25)
        return out
    }

    private static func raw(_ repo: String, _ branch: String, _ path: String) -> String? {
        let p = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        guard let u = URL(string: "https://raw.githubusercontent.com/\(repo)/\(branch)/\(p)") else { return nil }
        return fetch(u).map { String(decoding: $0, as: UTF8.self) }
    }

    func refresh() {
        guard !running else { return }
        running = true
        lastError = nil
        DispatchQueue.global(qos: .utility).async {
            let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-120 * 86400)).prefix(10)
            let queries = ["topic:claude-code-plugin", "topic:claude-code-plugins", "topic:claude-plugin", "topic:claude-code",
                           "topic:claude-skills", "topic:agent-skills", "claude-code+plugin+in:name,description"]
            var cands: [String: [String: Any]] = [:]
            for q in queries {
                let path = "search/repositories?q=\(q)+stars:>=\(Self.minStars)+archived:false+pushed:>=\(since)&sort=stars&order=desc&per_page=30"
                guard let j = Self.api(path) as? [String: Any], let arr = j["items"] as? [[String: Any]] else { continue }
                for r in arr { if let n = r["full_name"] as? String { cands[n] = r } }
            }
            if cands.isEmpty {
                DispatchQueue.main.async { self.running = false; self.lastError = L("GitHub nicht erreichbar oder Limit erreicht – später erneut.") }
                return
            }
            let curatedRepos = Set(ExtensionCatalog.all.map { $0.repo.lowercased() })
            let sorted = cands.values.sorted { ($0["stargazers_count"] as? Int ?? 0) > ($1["stargazers_count"] as? Int ?? 0) }
            var found: [DiscoveredExt] = []
            var bad: [String: String] = [:]
            for r in sorted.prefix(45) where found.count < Self.maxItems {
                guard let name = r["full_name"] as? String, let branch = r["default_branch"] as? String else { continue }
                if curatedRepos.contains("https://github.com/\(name)".lowercased()) { continue }
                guard (r["license"] as? [String: Any])?["spdx_id"] != nil else { bad[name] = L("keine Lizenz"); continue }
                // Nur, was beim Programmieren hilft
                // Produktnamen (Claude Code, Codex, Cursor …) zählen nicht – sonst passt jedes Plugin
                let topics = ((r["topics"] as? [String]) ?? []).filter { t in !["claude", "codex", "cursor", "copilot", "gemini", "agent", "skill", "plugin"].contains { t.contains($0) } }
                var about = ((r["description"] as? String ?? "") + " " + topics.joined(separator: " ")).lowercased()
                for n in ["claude code", "claude-code", "coding agents", "coding agent", "ai agents", "codex", "opencode"] { about = about.replacingOccurrences(of: n, with: " ") }
                let coding = ["code", "coding", "developer", "programming", "engineer", "engineering", "devtools", "api", "backend", "review", "debug", "test", "security", "token",
                              "context", "refactor", "frontend", "ui/ux", "design system", "mcp", "devops", "deploy", "software", "github", "spec",
                              "tdd", "ide", "compress", "memory", "harness", "senior dev", "diagram"]
                // ganze Wörter (sonst passt „ide“ zu „provide“ oder „test“ zu „latest“)
                guard coding.contains(where: { about.range(of: "\\b" + NSRegularExpression.escapedPattern(for: $0) + "s?\\b", options: .regularExpression) != nil }) else {
                    continue
                }
                // Themen ohne Programmierbezug (Marketing, Texte „vermenschlichen“, SEO …) fliegen raus, auch wenn ein Stichwort passt
                let offTopic = ["marketing", "copywriting", "seo", "humanizer", "humanize", "ai-generated writing", "ai writing", "social media", "sales", "growth hacking", "cro"]
                let fullAbout = (name + " " + (r["description"] as? String ?? "") + " " + ((r["topics"] as? [String]) ?? []).joined(separator: " ")).lowercased()
                if offTopic.contains(where: { fullAbout.range(of: "\\b" + NSRegularExpression.escapedPattern(for: $0) + "s?\\b", options: .regularExpression) != nil }) {
                    continue
                }
                // Nur, was sich wirklich als Plugin installieren lässt
                guard let mj = Self.raw(name, branch, ".claude-plugin/marketplace.json"),
                      let m = try? JSONSerialization.jsonObject(with: Data(mj.utf8)) as? [String: Any],
                      let mname = m["name"] as? String,
                      let plugins = (m["plugins"] as? [[String: Any]])?.compactMap({ $0["name"] as? String }), !plugins.isEmpty else { continue }
                // Sicherheits-Check über alle Anleitungen, Skills, Befehle, Agents und Hooks
                let (files, problem) = Self.scanRepo(name, branch: branch, marketplace: mj)
                if let problem { bad[name] = problem; continue }
                let lic = ((r["license"] as? [String: Any])?["spdx_id"] as? String) ?? ""
                found.append(DiscoveredExt(repo: name, description: (r["description"] as? String ?? "").prefix(220).description,
                                           stars: r["stargazers_count"] as? Int ?? 0, pushed: String((r["pushed_at"] as? String ?? "").prefix(10)),
                                           license: lic, marketplace: mname, plugins: Array(plugins.prefix(12)), checkedFiles: files))
            }
            DispatchQueue.main.async {
                self.items = found
                self.excluded = bad
                self.updated = Date()
                self.running = false
                self.save()
            }
        }
    }

    // MARK: Sicherheits-Check

    static let injection: [(String, String)] = [
        ("ignore (all |any )?(the )?(previous|prior|above|earlier) (instructions|prompts|rules)", "Prompt-Injection („ignore previous instructions“)"),
        ("disregard (all |the )?(system|previous|prior) (prompt|instructions)", "Prompt-Injection („disregard system prompt“)"),
        ("(do not|don't|never) (tell|inform|mention|reveal)[^.\\n]{0,30}(the )?user", "Verschleiern gegenüber dem Nutzer"),
        ("without (asking|telling|informing) the user", "Handeln ohne den Nutzer zu fragen"),
        ("you are now (dan|in developer mode|jailbroken)|jailbreak", "Jailbreak-Anweisung"),
        ("(\\.ssh/|id_rsa|id_ed25519|\\.aws/credentials|security find-(generic|internet)-password|keychain-dump)", "Zugriff auf Schlüssel/Passwörter"),
        ("(curl|wget|fetch)[^\\n]{0,80}\\$\\{?(anthropic|openai|github|gh|aws|stripe|supabase)[a-z_]*(key|token|secret)", "Senden von Schlüsseln an fremde Server"),
        ("base64 (-d|--decode)[^\\n]{0,40}\\|\\s*(ba|z)?sh", "Verschleiertes Skript (base64 | sh)"),
        ("--dangerously-skip-permissions|--yolo\\b|bypass(es)? (all )?permissions", "Hebelt Freigaben aus"),
        ("rm -rf (~|\\$home|/\\s)", "Löscht das Home-Verzeichnis"),
    ]

    /// Verdächtige Unicode-Zeichen (unsichtbar, Richtungswechsel, Tag-Zeichen) – typisch für versteckte Anweisungen.
    static func hiddenChars(_ s: String) -> Bool {
        s.unicodeScalars.contains { u in
            u.value == 0x200B || u.value == 0x200E || u.value == 0x200F || (0x202A...0x202E).contains(u.value) || (0x2066...0x2069).contains(u.value)
                || (0xE0000...0xE007F).contains(u.value)
        }
    }

    static func check(_ text: String, path: String) -> String? {
        let lower = text.lowercased()
        if hiddenChars(text) { return L("Versteckte Unicode-Zeichen in ") + path }
        for (p, why) in injection {
            guard let r = lower.range(of: p, options: .regularExpression) else { continue }
            // In README/Doku sind Installationszeilen normal – dort nur die harten Muster prüfen
            if path.lowercased().hasPrefix("readme"), why.contains("Freigaben") { continue }
            // Warnungen davor ("never follow …", "if a page says …") sind kein Angriff
            let before = lower[lower.index(r.lowerBound, offsetBy: -min(120, lower.distance(from: lower.startIndex, to: r.lowerBound)))..<r.lowerBound]
            let defensive = ["injection", "attack", "malicious", "untrusted", "if a ", "if the ", "e.g.", "such as", "never", "don't", "do not",
                             "dont ", "avoid", "beware", "warn", "example", "like \"", "treat"]
            if defensive.contains(where: { before.contains($0) }) { continue }
            return L(why) + " – " + path
        }
        // Hooks, die Fernskripte laden
        if path.contains("hooks"), lower.range(of: "(curl|wget)[^\\n]{0,120}https?://", options: .regularExpression) != nil {
            return L("Hook lädt Code aus dem Internet – ") + path
        }
        return nil
    }

    /// Prüft README, marketplace.json und bis zu 60 Plugin-Dateien (Skills, Befehle, Agents, Hooks).
    static func scanRepo(_ repo: String, branch: String, marketplace: String) -> (Int, String?) {
        if let p = check(marketplace, path: ".claude-plugin/marketplace.json") { return (1, p) }
        var files = 1
        if let readme = raw(repo, branch, "README.md") {
            files += 1
            if let p = check(readme, path: "README.md") { return (files, p) }
        }
        var paths: [String] = []
        if Detection.which("gh") != nil {
            let r = Proc.zsh("gh api \(Shell.quote("repos/\(repo)/git/trees/\(branch)?recursive=1")) --jq '.tree[].path'", in: NSTemporaryDirectory(), timeout: 40)
            if r.code == 0 { paths = r.out.split(separator: "\n").map(String.init).filter { !$0.contains(" ") || $0.contains("/") } }
        }
        if paths.isEmpty, let u = URL(string: "https://api.github.com/repos/\(repo)/git/trees/\(branch)?recursive=1"),
           let d = fetch(u), let tree = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let entries = tree["tree"] as? [[String: Any]] {
            paths = entries.compactMap { $0["path"] as? String }
        }
        guard !paths.isEmpty else { return (files, L("Dateien konnten nicht geprüft werden")) }
        let interesting = paths.filter { p in
            let l = p.lowercased()
            let ext = (l as NSString).pathExtension
            return ["md", "json", "sh", "py", "js", "ts", "mjs"].contains(ext)
                && (l.contains("skills/") || l.contains("commands/") || l.contains("agents/") || l.contains("hooks") || l.hasSuffix("plugin.json")
                    || l.hasSuffix("claude.md") || l.hasSuffix("agents.md") || l.hasSuffix(".mcp.json"))
                && !l.contains("node_modules/") && !l.contains("test")
        }
        for p in interesting.prefix(60) {
            guard let text = raw(repo, branch, p) else { continue }
            files += 1
            if let problem = check(text, path: p) { return (files, problem) }
        }
        return (files, nil)
    }

    // MARK: Installieren

    func isInstalled(_ e: DiscoveredExt) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let d = try? Data(contentsOf: home.appendingPathComponent(".claude/plugins/installed_plugins.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        let keys = ((j["plugins"] as? [String: Any]) ?? j).keys
        return keys.contains { $0.lowercased().hasSuffix("@" + e.marketplace.lowercased()) }
    }

    func installCommand(_ e: DiscoveredExt, plugin: String) -> String {
        "(claude plugin marketplace list 2>/dev/null | grep -q \(Shell.quote(e.marketplace)) || claude plugin marketplace add \(Shell.quote(e.repo))) && claude plugin install \(Shell.quote(plugin + "@" + e.marketplace))"
    }
}

struct DiscoveredSection: View {
    @ObservedObject private var d = ExtensionDiscovery.shared
    @ObservedObject private var store = ExtensionStore.shared
    @State private var busy: String?
    @State private var showExcluded = false
    @State private var tick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.s) {
            HStack {
                Text("Neu entdeckt – automatisch aktualisiert").font(.title3.weight(.semibold))
                if d.running { ProgressView().controlSize(.small); Text("sucht und prüft …").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let u = d.updated { Text(L("Stand: ") + u.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.tertiary) }
                Button { d.refresh() } label: { Label("Jetzt suchen", systemImage: "arrow.clockwise") }.disabled(d.running)
            }
            HStack(alignment: .top, spacing: Grid.s) {
                Image(systemName: "exclamationmark.shield").foregroundStyle(.orange)
                Text("Täglich auf GitHub gesucht: nur Repos mit mindestens \(ExtensionDiscovery.minStars.formatted()) Sternen, in den letzten 4 Monaten gepflegt, mit Lizenz und als Claude-Plugin installierbar – höchstens die Top \(ExtensionDiscovery.maxItems). Jedes Repo wird automatisch auf Prompt-Injection, versteckte Zeichen, Datenabfluss und Fernskripte in Hooks geprüft; Auffällige werden aussortiert. Der Check ist eine Hilfe, keine Garantie: Die Erweiterungen stammen von Dritten, die Installation erfolgt auf eigene Verantwortung, Salenta Code übernimmt dafür keine Haftung.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(Grid.s)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.07)))
            if let e = d.lastError { Text(e).font(.caption).foregroundStyle(.red) }
            if d.items.isEmpty && !d.running {
                Text("Noch nichts gefunden – „Jetzt suchen“ startet die Suche.").foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: Grid.m)], spacing: Grid.m) {
                ForEach(d.items) { e in card(e) }
            }
            if !d.excluded.isEmpty {
                DisclosureGroup(isExpanded: $showExcluded) {
                    ForEach(d.excluded.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                        HStack { Text(k).font(.caption.monospaced()); Text(v).font(.caption).foregroundStyle(.red) }
                    }
                } label: { Text("\(d.excluded.count) " + L("Repos aussortiert (Sicherheits-Check oder keine Lizenz)")).font(.caption) }
            }
        }
    }

    @ViewBuilder private func card(_ e: DiscoveredExt) -> some View {
        let installed = { _ = tick; return d.isInstalled(e) }()
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(e.repo.components(separatedBy: "/").last ?? e.repo).font(.headline)
                Text("⭐ \(e.stars.formatted())").font(.caption)
                Spacer()
                if installed {
                    Label("installiert", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                } else if busy == e.repo {
                    ProgressView().controlSize(.small)
                } else {
                    Menu(L("Installieren")) {
                        ForEach(e.plugins, id: \.self) { p in Button(p) { install(e, p) } }
                    }
                    .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
                }
            }
            Text(e.description).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            HStack(spacing: Grid.s) {
                Label(L("geprüft: \(e.checkedFiles) Dateien"), systemImage: "checkmark.shield").font(.caption2).foregroundStyle(.green)
                Text("\(e.license) · " + L("aktualisiert ") + e.pushed).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if let u = URL(string: "https://github.com/" + e.repo) { Link("Repo", destination: u).font(.caption) }
            }
        }
        .padding(Grid.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ModernCardBackground(radius: 12))
    }

    private func install(_ e: DiscoveredExt, _ plugin: String) {
        let a = NSAlert()
        a.messageText = L("„\(plugin)“ aus \(e.repo) installieren?")
        a.informativeText = L("Das Plugin stammt von einem Drittanbieter (⭐ \(e.stars.formatted())). Salenta Code hat es automatisch geprüft, kann aber keine Sicherheit garantieren und übernimmt keine Haftung. Fortfahren?")
        a.addButton(withTitle: L("Installieren")); a.addButton(withTitle: L("Abbrechen"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        busy = e.repo
        let cmd = d.installCommand(e, plugin: plugin)
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Proc.zsh(cmd, in: FileManager.default.homeDirectoryForCurrentUser.path, timeout: 600)
            let logURL = Paths.root.appendingPathComponent("logs/extensions.log")
            let entry = "\n=== \(Date()) \(e.repo) \(plugin) exit \(r.code)\n$ \(cmd)\n\(r.out.suffix(3000))\n"
            if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(Data(entry.utf8)); try? h.close() }
            DispatchQueue.main.async { busy = nil; tick += 1; store.refresh() }
        }
    }
}
