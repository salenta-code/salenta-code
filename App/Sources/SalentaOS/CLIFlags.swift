import AgenticOSKit
import Foundation

// Startoptionen der Agent-CLIs nicht fest verdrahten: Salenta Code liest bei jedem Update der CLI deren --help
// und nimmt nur Optionen, die die installierte Version wirklich kennt (z. B. hat Codex --full-auto entfernt).
// Scheitert ein Start trotzdem an einer unbekannten Option, merkt sich Salenta Code das und startet neu ohne sie.

final class CLIFlags {
    static let shared = CLIFlags()

    struct Info: Codable {
        var version = ""
        var helps: [String: String] = [:]      // Unterbefehl ("" = Haupt) → Hilfetext
        var unsupported: [String] = []         // gelernt aus Fehlermeldungen
        var checked = Date.distantPast
    }

    private var info: [String: Info] = [:]
    private let lock = NSLock()
    private let q = DispatchQueue(label: "salenta.cliflags", qos: .utility)
    private var url: URL { Paths.data.appendingPathComponent("cli-flags.json") }
    private var timer: Timer?

    /// Welche Hilfeseiten pro Agent gelesen werden (Unterbefehle mit eigenen Optionen).
    static let helpCommands: [AgentKind: [String: String]] = [
        .claude: ["": "claude --help"],
        .codex: ["": "codex --help", "exec": "codex exec --help"],
        .junie: ["": "junie --help"],
        .cursor: ["": "\(Agents.cursorBin) --help"],
        .opencode: ["": "opencode --help", "run": "opencode run --help"],
        .gemini: ["": "gemini --help"],
        .grok: ["": "grok --help"],
        .kiro: ["chat": "kiro-cli chat --help"],
        .pi: ["": "pi --help"],
        .kimi: ["": "kimi --help"],
    ]

    init() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: url), let j = try? dec.decode([String: Info].self, from: d) { info = j }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.refreshAll() }
        // alle 6 Stunden prüfen, ob sich eine CLI-Version geändert hat
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.refreshAll() }
    }

    func refreshAll(force: Bool = false) {
        for a in Self.helpCommands.keys { refresh(a, force: force) }
    }

    /// Liest Version und Hilfe neu, wenn sich die Version geändert hat (oder erzwungen).
    func refresh(_ agent: AgentKind, force: Bool = false) {
        q.async {
            guard Detection.which(agent.command) != nil || (agent == .cursor && Detection.which("agent") != nil),
                  let cmds = Self.helpCommands[agent] else { return }
            let bin = agent == .cursor ? Agents.cursorBin : agent.command
            let raw = Proc.zsh("\(bin) --version 2>&1 | head -3", in: NSTemporaryDirectory(), timeout: 20).out
            // nur die Versionsnummer (manche CLIs schreiben PID oder Log-Pfad mit dazu)
            let v = raw.range(of: "\\d+\\.\\d+(\\.\\d+)?([.-][0-9A-Za-z]+)?", options: .regularExpression).map { String(raw[$0]) }
                ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let old: Info? = self.lock.withLock { self.info[agent.rawValue] }
            if !force, let o = old, o.version == v, !o.helps.isEmpty { return }
            var n = Info(version: v, checked: Date())
            for (sub, c) in cmds {
                let r = Proc.zsh("\(c) 2>&1", in: NSTemporaryDirectory(), timeout: 25)
                let text = r.out.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
                if text.contains("--") { n.helps[sub] = String(text.prefix(40_000)) }
            }
            // nach einem Update alte „unbekannt“-Einträge verwerfen – die neue Version wird frisch gelesen
            if old?.version == v { n.unsupported = old?.unsupported ?? [] }
            self.lock.withLock { self.info[agent.rawValue] = n }
            self.save()
            if let o = old, !o.version.isEmpty, o.version != v {
                Self.log("\(agent.title): Version \(o.version) → \(v) – Startoptionen neu eingelesen")
                // neue Version bringt oft neue Modelle mit
                DispatchQueue.main.async { ModelCatalog.shared.refresh() }
            }
        }
    }

    /// Kennt die installierte CLI diese Option? nil = (noch) nicht bekannt.
    func supports(_ agent: AgentKind, _ flag: String, sub: String = "") -> Bool? {
        let i: Info? = lock.withLock { info[agent.rawValue] }
        guard let i else { return nil }
        let names = flag.split(separator: " ").map(String.init).filter { $0.hasPrefix("-") }
        if names.contains(where: { i.unsupported.contains($0) }) { return false }
        guard let help = i.helps[sub] ?? i.helps[""] else { return nil }
        return names.allSatisfy { name in
            help.range(of: "(^|[\\s,\\[(|])" + NSRegularExpression.escapedPattern(for: name) + "($|[\\s=,\\])|<])", options: .regularExpression) != nil
        }
    }

    /// Die erste Variante, die die installierte Version kennt. Unbekannte Hilfe → erste Variante (bisheriges Verhalten).
    /// Kennt sie keine davon → fallback (oft: Option weglassen).
    func pick(_ agent: AgentKind, sub: String = "", _ candidates: [String], fallback: String = "") -> String {
        for c in candidates {
            switch supports(agent, c, sub: sub) {
            case .some(true): return " " + c
            case .none: return " " + c
            case .some(false): continue
            }
        }
        return fallback.isEmpty ? "" : " " + fallback
    }

    /// Fehlermeldung „unbekannte Option“ aus der Ausgabe lernen. true = etwas gelernt (Neustart lohnt sich).
    @discardableResult
    func learn(_ agent: AgentKind, from output: String) -> String? {
        let patterns = ["unexpected argument '(-{1,2}[A-Za-z0-9][\\w-]*)'", "unknown (?:option|flag|argument)[:\\s]+'?\"?(-{1,2}[A-Za-z0-9][\\w-]*)",
                        "unrecognized (?:option|arguments?)[:\\s]+'?(-{1,2}[A-Za-z0-9][\\w-]*)", "no such option[:\\s]+(-{1,2}[A-Za-z0-9][\\w-]*)",
                        "invalid option[:\\s]+'?(-{1,2}[A-Za-z0-9][\\w-]*)"]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
                  let r = Range(m.range(at: 1), in: output) else { continue }
            let flag = String(output[r])
            var added = false
            lock.withLock {
                var i = info[agent.rawValue] ?? Info()
                if !i.unsupported.contains(flag) { i.unsupported.append(flag); added = true }
                info[agent.rawValue] = i
            }
            guard added else { return nil }
            save()
            Self.log("\(agent.title) kennt \(flag) nicht (mehr) – wird ab jetzt weggelassen")
            refresh(agent, force: true)
            return flag
        }
        return nil
    }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted]
        let snapshot: [String: Info] = lock.withLock { info }
        if let d = try? enc.encode(snapshot) { try? d.write(to: url, options: .atomic) }
    }

    func version(_ agent: AgentKind) -> String { lock.withLock { info[agent.rawValue]?.version ?? "" } }

    static func log(_ text: String) {
        let f = Paths.root.appendingPathComponent("logs/cli-flags.log")
        let line = "\(Date().formatted(.iso8601)) \(text)\n"
        if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: f, atomically: true, encoding: .utf8) }
    }
}

/// Agent nicht angemeldet / kein Modell eingerichtet: erkennen, nicht mehr automatisch wählen, Hinweis geben.
enum AgentHealth {
    static let loginPatterns = ["no model configured", "use /login", "not logged in", "please log in", "please login", "login required",
                                "authentication required", "not authenticated", "you are not signed in", "sign in to continue",
                                "invalid api key", "no api key", "run `[a-z-]+ (auth )?login`", "credentials not found"]

    private static func key(_ a: AgentKind) -> String { "health.login.\(a.rawValue)" }

    /// Gilt 3 Stunden als „nicht angemeldet“ – oder bis ein Lauf wieder klappt.
    static func needsLogin(_ a: AgentKind) -> Bool {
        let t = UserDefaults.standard.double(forKey: key(a))
        return t > 0 && Date().timeIntervalSince1970 - t < 3 * 3600
    }

    static func clear(_ a: AgentKind) { UserDefaults.standard.removeObject(forKey: key(a)) }

    /// Nur kurze Ausgaben eines gescheiterten Starts prüfen (lange Läufe reden oft selbst über Logins im Code).
    @discardableResult
    static func learn(_ a: AgentKind, from text: String) -> Bool {
        guard text.count < 3000 else { return false }
        let t = text.lowercased()
        guard loginPatterns.contains(where: { t.range(of: $0, options: .regularExpression) != nil }) else { return false }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key(a))
        CLIFlags.log("\(a.title) ist nicht angemeldet – wird vorerst nicht automatisch gewählt")
        return true
    }

    /// Befehl, der im Terminal die Anmeldung startet.
    static func loginCommand(_ a: AgentKind) -> String {
        let h = a.loginHint
        if h.isEmpty || h.contains("→") || h.contains("(") { return a.command == "claude" ? "claude auth login" : a.command }
        return h
    }

    static var flagged: [AgentKind] { AgentKind.coders.filter { needsLogin($0) } }

    static func hint(_ a: AgentKind) -> String {
        a.loginHint.isEmpty ? L("im Terminal anmelden") : a.loginHint
    }
}
