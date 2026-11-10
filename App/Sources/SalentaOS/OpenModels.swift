import AgenticOSKit
import AppKit
import SwiftUI

// Open-Source-Modelle und API-Schlüssel.
//  • OpenRouter: Claude Code als Werkzeug, aber mit Qwen, DeepSeek, Kimi, GLM … (Bezahlung pro Nutzung, viele Modelle kostenlos)
//  • Ollama: dasselbe mit einem Modell lokal auf dem Mac – kostenlos und privat
//  • API-Schlüssel statt Abo für Claude Code und Codex (für Teams und Firmen)
// Schlüssel liegen nur im macOS-Schlüsselbund – nie in Dateien, Repos oder Logs.

enum Secrets {
    static let service = "Salenta OS"   // Schlüsselbund-Eintrag – bleibt, sonst gingen gespeicherte Schlüssel verloren

    /// Liest einen Schlüssel (nur die Shell-Werkzeuge der App, kein Dialog).
    static func get(_ account: String) -> String? {
        let r = Proc.zsh("/usr/bin/security find-generic-password -s \(Shell.quote(service)) -a \(Shell.quote(account)) -w 2>/dev/null",
                         in: NSTemporaryDirectory(), timeout: 10)
        let v = r.out.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return r.code == 0 && !v.isEmpty ? v : nil
    }

    /// Ob ein Schlüssel da ist. Blockiert nie den Main-Thread (SwiftUI darf beim Zeichnen keinen Prozess abwarten –
    /// das hat beim Start zum Absturz geführt). Auf dem Main-Thread kommt der zwischengespeicherte Wert, aktualisiert wird im Hintergrund.
    static func has(_ account: String) -> Bool {
        let cached: (Bool, Date)? = lock.withLock { cache[account] }
        if let c = cached, c.1 > Date().addingTimeInterval(-300) { return c.0 }
        if Thread.isMainThread {
            refresh(account)
            return cached?.0 ?? false
        }
        let v = get(account) != nil
        lock.withLock { cache[account] = (v, Date()) }
        return v
    }
    private static var cache: [String: (Bool, Date)] = [:]
    private static var pending: Set<String> = []
    private static let lock = NSLock()
    static let changed = Notification.Name("SalentaSecretsChanged")

    /// Im Hintergrund nachsehen; bei Änderung wird die Oberfläche benachrichtigt.
    static func refresh(_ account: String) {
        let start: Bool = lock.withLock { pending.insert(account).inserted }
        guard start else { return }
        DispatchQueue.global(qos: .utility).async {
            let v = get(account) != nil
            let old: Bool? = lock.withLock { let o = cache[account]?.0; cache[account] = (v, Date()); pending.remove(account); return o }
            if old != v { DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: account) } }
        }
    }

    /// Beim App-Start einmal alle bekannten Schlüssel prüfen.
    static func prime() { for a in ["openrouter", "anthropic", "openai", "deepseek"] { refresh(a) } }

    /// Speichert (oder löscht bei leerem Wert) im Hintergrund. Lesbar für /usr/bin/security, damit Agents ihn zur Laufzeit holen können.
    static func set(_ account: String, _ value: String, done: (() -> Void)? = nil) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock { cache[account] = (!v.isEmpty, Date()) }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Proc.zsh("/usr/bin/security delete-generic-password -s \(Shell.quote(service)) -a \(Shell.quote(account)) >/dev/null 2>&1", in: NSTemporaryDirectory(), timeout: 10)
            if !v.isEmpty {
                _ = Proc.zsh("/usr/bin/security add-generic-password -U -s \(Shell.quote(service)) -a \(Shell.quote(account)) -T /usr/bin/security -w \(Shell.quote(v))",
                             in: NSTemporaryDirectory(), timeout: 10)
            }
            DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: account); done?() }
        }
    }

    /// Shell-Ausdruck, der den Schlüssel erst beim Start des Agents aus dem Schlüsselbund holt (steht so nie im Klartext in einer Datei).
    static func shellValue(_ account: String) -> String {
        "\"$(/usr/bin/security find-generic-password -s \(Shell.quote(service)) -a \(Shell.quote(account)) -w 2>/dev/null)\""
    }
}

enum OpenModels {
    /// Ist der Agent wirklich nutzbar (CLI da, bei OpenRouter auch ein Schlüssel)?
    static func available(_ k: AgentKind) -> Bool {
        if AgentOff.isOff(k) { return false }        // von dir abgeschaltet (z. B. Abo gekündigt)
        if AgentHealth.needsLogin(k) { return false }   // gerade nicht angemeldet → nicht automatisch wählen
        switch k {
        case .openrouter: return Detection.which("claude") != nil && hasOpenRouter
        case .ollama: return Detection.which("claude") != nil && OllamaApp.installed
        case .harness: return HarnessSetup.ready
        default: return Detection.which(k.command) != nil
        }
    }

    static var hasOpenRouter: Bool { Secrets.has("openrouter") }
    static var claudeUsesAPIKey: Bool { UserDefaults.standard.bool(forKey: "auth.claude.apikey") && Secrets.has("anthropic") }
    static var codexUsesAPIKey: Bool { UserDefaults.standard.bool(forKey: "auth.codex.apikey") && Secrets.has("openai") }

    /// Eigener Claude-Code-Konfigordner für OpenRouter/Ollama – dein normaler Claude-Login bleibt unberührt.
    static func configDir(_ kind: AgentKind) -> String {
        let d = Paths.support.appendingPathComponent("claude-\(kind.rawValue)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.path
    }

    static var defaultModel: [AgentKind: String] { [.openrouter: "qwen/qwen3-coder", .ollama: LocalFirst.shared.model ?? "qwen3-coder"] }

    /// Umgebung als Shell-Exports (vor dem eigentlichen Befehl).
    static func exports(for kind: AgentKind, model: String?) -> String {
        switch kind {
        case .openrouter:
            let m = Shell.quote(model ?? defaultModel[.openrouter]!)
            return "export CLAUDE_CONFIG_DIR=\(Shell.quote(configDir(.openrouter))) ANTHROPIC_BASE_URL=https://openrouter.ai/api ANTHROPIC_API_KEY='' "
                + "ANTHROPIC_AUTH_TOKEN=\(Secrets.shellValue("openrouter")) ANTHROPIC_MODEL=\(m) ANTHROPIC_DEFAULT_OPUS_MODEL=\(m) "
                + "ANTHROPIC_DEFAULT_SONNET_MODEL=\(m) ANTHROPIC_DEFAULT_HAIKU_MODEL=\(m) ANTHROPIC_SMALL_FAST_MODEL=\(m) CLAUDE_CODE_SUBAGENT_MODEL=\(m); "
        case .ollama:
            // Variante mit genug Kontext – unabhängig davon, wie der Ollama-Server gestartet wurde
            let m = Shell.quote(LocalFirst.contextVariant(model ?? defaultModel[.ollama]!))
            // Claude Code braucht viel Kontext – Ollamas Standard (4–8k) reicht nicht für Agent-Arbeit
            return "(pgrep -x ollama >/dev/null || (open -ga Ollama 2>/dev/null || (OLLAMA_CONTEXT_LENGTH=65536 ollama serve >/dev/null 2>&1 &)); sleep 2); "
                + "export CLAUDE_CONFIG_DIR=\(Shell.quote(configDir(.ollama))) ANTHROPIC_BASE_URL=http://localhost:11434 ANTHROPIC_API_KEY='' "
                + "ANTHROPIC_AUTH_TOKEN=ollama ANTHROPIC_MODEL=\(m) ANTHROPIC_DEFAULT_OPUS_MODEL=\(m) ANTHROPIC_DEFAULT_SONNET_MODEL=\(m) "
                + "ANTHROPIC_DEFAULT_HAIKU_MODEL=\(m) ANTHROPIC_SMALL_FAST_MODEL=\(m) CLAUDE_CODE_SUBAGENT_MODEL=\(m); "
        case .claude:
            return claudeUsesAPIKey ? "export ANTHROPIC_API_KEY=\(Secrets.shellValue("anthropic")); " : ""
        case .codex:
            return codexUsesAPIKey ? "export OPENAI_API_KEY=\(Secrets.shellValue("openai")); " : ""
        default:
            return ""
        }
    }

    // MARK: Modelle

    /// Aktuelle Open-Source-Coding-Modelle von OpenRouter (öffentliche Liste, kein Schlüssel nötig).
    static func fetchOpenRouter() -> [String] {
        guard let u = URL(string: "https://openrouter.ai/api/v1/models") else { return [] }
        var req = URLRequest(url: u, timeoutInterval: 20)
        req.setValue("Salenta-Code", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var data: Data?
        URLSession.shared.dataTask(with: req) { d, _, _ in data = d; sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 25)
        guard let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = j["data"] as? [[String: Any]] else { return [] }
        let providers = ["qwen/", "deepseek/", "moonshotai/", "z-ai/", "mistralai/", "minimax/", "meta-llama/", "openai/gpt-oss", "x-ai/grok-code"]
        let models = arr.compactMap { m -> (String, Double)? in
            guard let id = m["id"] as? String, providers.contains(where: { id.hasPrefix($0) }) else { return nil }
            let created = (m["created"] as? Double) ?? Double(m["created"] as? Int ?? 0)
            return (id, created)
        }.sorted { $0.1 > $1.1 }.map(\.0)
        return models
    }

    /// Lokal installierte Ollama-Modelle.
    static func ollamaModels() -> [String] {
        guard OllamaApp.installed else { return [] }
        return OllamaApp.models()
    }
}

// MARK: - Einstellungen

struct ModelAccessSettings: View {
    @State private var openrouter = ""
    @State private var anthropic = ""
    @State private var openai = ""
    @State private var saved: String?
    @AppStorage("auth.claude.apikey") private var claudeAPI = false
    @AppStorage("auth.codex.apikey") private var codexAPI = false
    @State private var hasOR = OpenModels.hasOpenRouter
    @State private var hasAN = Secrets.has("anthropic")
    @State private var hasOA = Secrets.has("openai")
    @State private var deepseek = ""
    @State private var hasDS = Secrets.has("deepseek")

    var body: some View {
        Form {
            Section("Open-Source-Modelle über OpenRouter") {
                Text("Qwen, DeepSeek, Kimi, GLM, Mistral & Co. – mit Claude Code als Werkzeug. Bezahlt wird pro Nutzung direkt bei OpenRouter (viele Modelle kostenlos). Gut, wenn dein Abo am Limit ist oder für einfache Aufgaben günstiger.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    SecureField(hasOR ? L("Schlüssel gespeichert – zum Ändern neu eingeben") : "sk-or-…", text: $openrouter)
                    Button("Speichern") { Secrets.set("openrouter", openrouter) { ModelCatalog.shared.refresh() }; openrouter = ""; hasOR = true }
                        .disabled(openrouter.isEmpty)
                    if hasOR { Button("Entfernen", role: .destructive) { Secrets.set("openrouter", ""); hasOR = false } }
                }
                Link("Schlüssel erstellen: openrouter.ai/keys", destination: URL(string: "https://openrouter.ai/keys")!).font(.caption)
            }
            Section("Salenta Harness – unser eigener Agent") {
                Text("Läuft mit DeepSeek, Claude, OpenAI, OpenRouter oder lokal (Ollama) – der erste vorhandene Schlüssel wird genutzt. DeepSeek ist sehr günstig und stark beim Programmieren.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    SecureField(hasDS ? L("DeepSeek-Schlüssel gespeichert") : "DeepSeek: sk-…", text: $deepseek)
                    Button("Speichern") { Secrets.set("deepseek", deepseek); deepseek = ""; hasDS = true }.disabled(deepseek.isEmpty)
                    if hasDS { Button("Entfernen", role: .destructive) { Secrets.set("deepseek", ""); hasDS = false } }
                }
                Link("Schlüssel erstellen: platform.deepseek.com", destination: URL(string: "https://platform.deepseek.com/api_keys")!).font(.caption)
                Text(HarnessSetup.status).font(.caption).foregroundStyle(HarnessSetup.ready ? .green : .orange)
            }
            Section("Lokal mit Ollama (kostenlos, privat)") {
                LocalSetupRow()
                Text("Läuft komplett auf deinem Mac. Für kleine, klare Aufgaben – für große Umbauten sind die Cloud-Modelle deutlich besser.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LocalFirstSettings()
            UpdateSettings()
            Section("API-Schlüssel statt Abo (für Teams und Firmen)") {
                Toggle("Claude Code mit Anthropic-API-Schlüssel", isOn: $claudeAPI)
                HStack {
                    SecureField(hasAN ? L("Schlüssel gespeichert") : "sk-ant-…", text: $anthropic)
                    Button("Speichern") { Secrets.set("anthropic", anthropic); anthropic = ""; hasAN = true }.disabled(anthropic.isEmpty)
                }
                Toggle("Codex mit OpenAI-API-Schlüssel", isOn: $codexAPI)
                HStack {
                    SecureField(hasOA ? L("Schlüssel gespeichert") : "sk-…", text: $openai)
                    Button("Speichern") { Secrets.set("openai", openai); openai = ""; hasOA = true }.disabled(openai.isEmpty)
                }
                Text("Ohne Schlüssel nutzen die Agents deinen eigenen Login in der jeweiligen CLI. Mit Schlüssel rechnet der Anbieter direkt mit dir ab. Schlüssel liegen nur im macOS-Schlüsselbund.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: Secrets.changed)) { _ in
            hasOR = OpenModels.hasOpenRouter; hasAN = Secrets.has("anthropic"); hasOA = Secrets.has("openai"); hasDS = Secrets.has("deepseek")
        }
    }
}
