import AgenticOSKit
import Foundation
import Network
import SwiftUI

// Lokal zuerst (Ollama):
//  • Fällt das Internet weg, übernimmt automatisch das lokale Modell – Aufträge laufen weiter statt zu scheitern.
//  • Kleine Aufgaben (Tippfehler, Umbenennen, Kommentare, Formatieren, Übersetzen …) gehen automatisch an das lokale
//    Modell – das spart Abo-Kontingent und API-Kosten. Große oder heikle Aufgaben bleiben bei Claude, Codex & Co.

final class LocalFirst: ObservableObject {
    static let shared = LocalFirst()
    @Published private(set) var online = true
    @Published private(set) var models: [String] = []

    var onOffline: Bool { UserDefaults.standard.object(forKey: "local.offline") as? Bool ?? true }
    var forSmall: Bool { UserDefaults.standard.object(forKey: "local.small") as? Bool ?? true }
    /// „Nur lokal“: kein Auftrag und keine Hilfsabfrage geht an ein Cloud-Modell – alles läuft über Ollama.
    var localOnly: Bool { UserDefaults.standard.bool(forKey: "local.only") }
    /// Sollen Modell-Aufrufe gerade lokal laufen? (Nur-lokal an, oder offline mit Umschalten)
    var useLocal: Bool { ready && (localOnly || (onOffline && !isOnline)) }
    /// Gewähltes lokales Modell (leer = automatisch das beste Code-Modell)
    var chosen: String { UserDefaults.standard.string(forKey: "local.model") ?? "" }

    private let monitor = NWPathMonitor()
    private var timer: Timer?
    private let lock = NSLock()
    private var onlineSnap = true

    /// Gibt es überhaupt ein lokales Modell?
    /// Thread-sicher: Agent-Starts und Hilfsabfragen fragen das auch aus dem Hintergrund.
    var ready: Bool { OllamaApp.installed && Detection.which("claude") != nil && !installedModels.isEmpty }
    private var modelsSnap: [String] = []
    var installedModels: [String] { lock.lock(); defer { lock.unlock() }; return modelsSnap }

    /// Bestes Code-Modell unter den geladenen.
    var model: String? {
        // Nur Modelle, die bequem in den Speicher passen – ein 30B-Modell (22 GB) auf einem 24-GB-Mac ließ alles auslagern und hängen
        let models = installedModels.filter { Self.fitsComfortably($0) }
        if !chosen.isEmpty, installedModels.contains(chosen) { return chosen }
        // das beste geladene laut Katalog (aktualisiert sich täglich)
        for c in LocalCatalog.shared.models.sorted(by: { $0.rank > $1.rank }) where LocalCatalog.comfortable(c) {
            let base = c.pull.split(separator: ":").first.map(String.init) ?? c.pull
            if let m = models.first(where: { $0 == c.pull || $0.hasPrefix(base + ":") || $0 == base }) { return m }
        }
        // Reihenfolge: stärkste lokale Code-/Agent-Modelle zuerst (Stand Herbst 2026)
        let pref = ["qwen3-coder-next", "laguna", "qwen3.8", "devstral-small-2", "devstral", "qwen3-coder", "qwen3.6", "gemma4",
                    "qwen2.5-coder", "codestral", "gpt-oss", "deepseek-coder", "qwen3", "llama3"]
        for p in pref { if let m = models.first(where: { $0.lowercased().hasPrefix(p) }) { return m } }
        return models.first
    }

    /// Passt das Modell bequem (≤ 75 % des Grafikspeichers)? Größe aus dem Katalog, sonst aus „…14b“ im Namen geschätzt.
    static func fitsComfortably(_ name: String) -> Bool {
        let base = name.split(separator: ":").first.map(String.init) ?? name
        if let c = LocalCatalog.shared.models.first(where: { $0.pull == name || $0.pull == base || $0.pull.hasPrefix(base + ":") }) {
            return LocalCatalog.comfortable(c)
        }
        if let r = name.range(of: #"(\d+(\.\d+)?)b"#, options: [.regularExpression, .caseInsensitive]), let b = Double(name[r].dropLast()) {
            return b * 0.65 <= OllamaApp.gpuGB * 0.75   // ~0,65 GB je Milliarde Parameter (Q4)
        }
        return name.lowercased().hasPrefix("qwen3-coder") ? 19 <= OllamaApp.gpuGB * 0.75 : true
    }

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            if path.status == .satisfied { self.probe() } else { self.set(false) }
        }
        monitor.start(queue: DispatchQueue(label: "local.net"))
        loadModels()
        timer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in self?.probe() }
        timer?.tolerance = 15
    }

    /// Thread-sicher für Agent-Start und Hintergrund.
    var isOnline: Bool { lock.lock(); defer { lock.unlock() }; return onlineSnap }

    private func set(_ v: Bool) {
        lock.lock(); let changed = onlineSnap != v; onlineSnap = v; lock.unlock()
        DispatchQueue.main.async {
            if self.online != v { self.online = v }
            if changed {
                CrashLog.mark(v ? "Internet wieder da" : "Internet weg – lokales Modell übernimmt")
                if !v, self.ready { Notifier.push("Salenta Code", L("Offline – Aufträge laufen jetzt mit dem lokalen Modell weiter."), priority: 3, tags: "satellite") }
            }
        }
    }

    /// Echte Erreichbarkeit prüfen (WLAN ohne Internet zählt als offline).
    func probe() {
        guard Energy.due("probe", every: 300) else { return }
        var r = URLRequest(url: URL(string: "https://api.anthropic.com")!, timeoutInterval: 6)
        r.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: r) { [weak self] _, resp, err in
            self?.set(resp != nil && err == nil)
        }.resume()
    }

    func loadModels() {
        DispatchQueue.global(qos: .utility).async {
            let m = OpenModels.ollamaModels().filter { !$0.contains("-sc:") }
            self.lock.lock(); self.modelsSnap = m; self.lock.unlock()
            DispatchQueue.main.async {
                self.models = m
                if let best = self.model { Self.prepareVariant(best) }   // gleich vorbereiten, damit der erste Auftrag sie schon hat
            }
        }
    }

    /// Empfehlung passend zum Arbeitsspeicher dieses Macs (Name zum Laden, Beschreibung).
    static var recommended: (pull: String, why: String) {
        let gb = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        switch gb {
        case 96...: return ("qwen3-coder-next", L("stärkstes lokales Code-Modell für große Macs (≈52 GB)"))
        case 48...: return ("laguna-xs-2.1", L("stark bei langen Agent-Aufgaben, schnell dank MoE (≈20 GB)"))
        case 32...: return ("qwen3.8:27b", L("bester Allrounder für Code mit Werkzeugen (≈18 GB)"))
        case 16...: return ("devstral-small-2", L("für Agent-Arbeit gebaut, passt auf 16 GB (≈15 GB)"))
        default: return ("qwen3:8b", L("klein und schnell für einfache Aufgaben (≈5 GB)"))
        }
    }

    // MARK: Entscheidungen

    static let cloudKinds: Set<AgentKind> = [.claude, .codex, .gemini, .cursor, .kimi, .deepseek, .harness, .openrouter, .grok, .kiro, .opencode, .pi, .junie]

    /// Offline? Dann diesen Agent gegen den lokalen tauschen.
    func offlineSwap(_ kind: AgentKind) -> (AgentKind, String)? {
        guard useLocal, Self.cloudKinds.contains(kind), let m = model else { return nil }
        return (.ollama, m)
    }

    /// Umgebung für kurze `claude -p`-Hilfsaufrufe (Agent-Wahl, Zusammenfassungen, Review, Planung):
    /// bei „Nur lokal“ oder offline über das lokale Modell, sonst leer (= wie gewohnt).
    static func cliEnv() -> String {
        let l = LocalFirst.shared
        if l.localOnlyBlocked { return "echo 'Nur lokal: kein lokales Modell bereit' >&2; exit 3; " }   // nie still in die Cloud
        guard l.useLocal, let m = l.model else { return "" }
        return OpenModels.exports(for: .ollama, model: m)
    }

    /// Nur lokal an, aber nichts Lokales da → Cloud bleibt gesperrt, statt still doch die Cloud zu nehmen.
    var localOnlyBlocked: Bool { localOnly && !ready }

    /// Claude Code schickt allein als Anweisungen ~20.000 Tokens. Ollama schneidet sonst je nach Start bei 4–8k ab –
    /// das Modell sieht dann seine Werkzeuge nicht und liefert Unsinn. Darum eine eigene Variante „<modell>-sc“ mit festem
    /// Kontext anlegen (kostet keinen Speicher, nutzt dieselben Gewichte). Größe passend zum Arbeitsspeicher.
    // Kontext kostet Arbeitsspeicher (bei 8B-Modellen ~4–5 GB pro 32k). Auf 16/24-GB-Macs blieb mit 32k zu wenig für den Rest –
    // macOS lagerte aus und alles wurde zäh. Daher eine Stufe kleiner.
    static var contextSize: Int { LocalCatalog.ramGB >= 64 ? 65536 : LocalCatalog.ramGB >= 32 ? 32768 : 16384 }
    private static var variants: [String: String] = [:]
    private static let variantLock = NSLock()

    /// Liefert sofort (nie blockierend): die fertige Variante, sonst das Basismodell – und legt die Variante im Hintergrund an.
    static func contextVariant(_ model: String) -> String {
        if model.contains("-sc:") { return model }
        variantLock.lock(); let v = variants[model]; variantLock.unlock()
        if let v { return v }
        prepareVariant(model)
        return model
    }

    /// Im Hintergrund anlegen (beim Start, nach jedem Download). Fehlschläge werden nicht gemerkt – nächstes Mal neu versuchen.
    static func prepareVariant(_ model: String) {
        variantLock.lock(); let busy = variants[model] != nil || preparing.contains(model); if !busy { preparing.insert(model) }; variantLock.unlock()
        guard !busy else { return }
        DispatchQueue.global(qos: .utility).async {
            let parts: [String] = model.split(separator: ":").map(String.init)
            let base: String = parts.first ?? model
            let tag: String = parts.count > 1 ? parts[1] : "latest"
            let name: String = base + "-sc:" + tag
            OllamaApp.startServer()
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sc-modelfile-\(UUID().uuidString.prefix(6))")
            try? "FROM \(model)\nPARAMETER num_ctx \(contextSize)\n".write(to: tmp, atomically: true, encoding: .utf8)
            let have = Proc.zsh("\(OllamaApp.cli) show \(Shell.quote(name)) --parameters 2>/dev/null | grep -q 'num_ctx.*\(contextSize)'", in: NSTemporaryDirectory(), timeout: 20).code == 0
            let ok = have || Proc.zsh("\(OllamaApp.cli) create \(Shell.quote(name)) -f \(Shell.quote(tmp.path))", in: NSTemporaryDirectory(), timeout: 180).code == 0
            try? FileManager.default.removeItem(at: tmp)
            variantLock.lock(); preparing.remove(model); if ok { variants[model] = name }; variantLock.unlock()
            if ok { CrashLog.mark("Lokales Modell \(model) → \(name) (Kontext \(contextSize))") }
        }
    }
    private static var preparing = Set<String>()

    /// Kleine, risikoarme Aufgabe – lohnt kein großes Modell.
    static func isSmall(_ text: String) -> Bool {
        let t = text.lowercased()
        guard t.count <= 320, t.split(separator: "\n").count <= 4 else { return false }
        let small = ["tippfehler", "typo", "rechtschreib", "umbenenn", "rename", "kommentar", "comment", "formatier", "format ",
                     "lint", "readme", "übersetz", "translate", "changelog", "commit-nachricht", "commit message", "docstring",
                     "jsdoc", "console.log", "print-ausgabe", "import sortier", "sort imports", "kleine änderung", "kleinigkeit",
                     "text ändern", "button-text", "buttontext", "überschrift", "farbe ändern", "abstand", "padding", "label ändern",
                     "beschriftung", "platzhalter", "placeholder", "emoji", "zusammenfass", "erkläre", "explain", "was macht"]
        let big = ["architektur", "refactor", "umbau", "neu bauen", "feature", "migration", "sicherheit", "security", "datenbank",
                   "database", "auth", "login", "zahlung", "payment", "stripe", "performance", "deploy", "produktion", "production",
                   "alle dateien", "ganze", "komplett", "mehrere", "tests schreiben", "bug", "fehler finden", "debug", "absturz", "crash"]
        return small.contains(where: { t.contains($0) }) && !big.contains(where: { t.contains($0) })
    }

    /// Für die automatische Agentenwahl: offline oder kleine Aufgabe → lokales Modell.
    func adjust(_ d: AIRouteDecision, text: String) -> AIRouteDecision {
        guard ready, let m = model, let a = d.target.agent, Self.cloudKinds.contains(a) || d.target == .osAgent else { return d }
        var d = d
        if localOnly && d.target != .osAgent {
            d.target = .ollama; d.model = m
            d.reason = L("Nur lokal – das lokale Modell arbeitet") + " (\(m))"
        } else if localOnly {
            d.reason = L("Nur lokal – dein Agent läuft mit dem lokalen Modell") + " (\(m))"
        } else if onOffline && !isOnline && d.target != .osAgent {
            d.target = .ollama; d.model = m
            d.reason = L("Offline – das lokale Modell übernimmt") + " (\(m))"
        } else if forSmall && !Energy.saving && d.target != .osAgent && AgentKind.coders.contains(a) {   // am Akku: lokal kostet zu viel Strom
            if let why = localMisfit(d, text: text) {
                // bleibt in der Cloud – und du siehst, warum (nur wenn es sonst lokal gegangen wäre)
                if d.localOK == true || Self.isSmall(text) { d.reason += " · " + L("nicht lokal: ") + why }
            } else {
                d.target = .ollama; d.model = m
                d.reason = L("Kleine Aufgabe – lokal erledigt, spart Kosten") + " (\(m))"
            }
        }
        return d
    }

    /// Warum das lokale Modell diesen Auftrag NICHT bekommen soll – nil heißt: passt.
    /// Zusammen entscheiden: Einschätzung der KI-Agentenwahl, Stichwörter, Stärke des lokalen Modells und was zuletzt geklappt hat.
    func localMisfit(_ d: AIRouteDecision, text: String) -> String? {
        if d.localOK == false { return L("die Agentenwahl hält ihn für zu anspruchsvoll") }
        if let c = d.complexity, c == "medium" || c == "large" { return L("zu umfangreich") }
        if d.localOK == nil && !Self.isSmall(text) { return L("nicht eindeutig klein") }
        if Self.isHeavy(text) { return L("heikles Thema (Sicherheit, Daten, Deploy …)") }
        let rank = Self.rank(of: model ?? "")
        if rank < 75 && !Self.isTextOnly(text) { return L("das lokale Modell ist für Code-Änderungen zu klein") }
        let stats = LocalStats.current
        if let dir = d.directory, let f = stats.failed?[dir], f.filter({ $0 > Date().addingTimeInterval(-14 * 86400) }).count >= 2 {
            return L("hat in diesem Projekt zuletzt nicht geklappt")
        }
        if stats.runs >= 4, Double(stats.ok) / Double(stats.runs) < 0.5 { return L("lokale Läufe scheitern zuletzt zu oft") }
        return nil
    }

    /// Stärke eines geladenen Modells laut Katalog (0 = unbekannt → wie ein kleines Modell behandeln).
    static func rank(of model: String) -> Int {
        let base = model.split(separator: ":").first.map(String.init) ?? model
        return LocalCatalog.shared.models.first { m in
            let mb = m.pull.split(separator: ":").first.map(String.init) ?? m.pull
            return m.pull == model || mb == base
        }?.rank ?? 0
    }

    /// Reine Text-Aufgaben (erklären, übersetzen, Commit-Nachricht …) – die schafft auch ein kleines Modell.
    static func isTextOnly(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["erkläre", "explain", "was macht", "übersetz", "translate", "zusammenfass", "summar", "commit-nachricht", "commit message", "changelog"]
            .contains { t.contains($0) }
    }

    static func isHeavy(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["sicherheit", "security", "auth", "login", "passw", "zahlung", "payment", "stripe", "datenbank", "database", "migration",
                "deploy", "produktion", "production", "debug", "absturz", "crash", "refactor", "architektur"].contains { t.contains($0) }
    }

    /// Für die KI-Agentenwahl: welches lokale Modell da ist und was es kann.
    var routerHint: String {
        guard ready, forSmall || localOnly, let m = model else { return "" }
        let r = Self.rank(of: m)
        return "Local model available: \(m) (\(r >= 85 ? "strong" : r >= 75 ? "medium" : "small") local model). It is free but much weaker than cloud models – " +
            "only trivial/small, clearly specified tasks should go to it (set localOK accordingly)."
    }
}

// MARK: - Zählung: wie viel lief lokal statt in der Cloud

struct LocalStats: Codable {
    var runs = 0, ok = 0, fallbacks = 0, tokens = 0
    var since = Date()
    /// Fehlgeschlagene lokale Läufe pro Projekt – daraus lernt die Agentenwahl
    var failed: [String: [Date]]? = nil

    private static var url: URL { Paths.data.appendingPathComponent("local-stats.json") }
    private static let lock = NSLock()
    static var current: LocalStats {
        lock.lock(); defer { lock.unlock() }
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(LocalStats.self, from: $0) } ?? LocalStats()
    }
    private static func update(_ f: (inout LocalStats) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var s = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(LocalStats.self, from: $0) } ?? LocalStats()
        f(&s)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: url, options: .atomic) }
    }

    /// Nach jedem lokalen Lauf: Ergebnis und Tokens (mindestens Kontext + Ausgabe aus der Live-Anzeige).
    static func record(_ s: AgentSession) {
        let statusURL = URL(fileURLWithPath: s.logFile.path + ".json")
        var tok = 0
        if let d = try? Data(contentsOf: statusURL), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            tok = ((j["context"] as? Int) ?? 0) + ((j["output"] as? Int) ?? 0)
        }
        let ok = s.succeeded
        let project = s.worktree?.base ?? s.directory.path
        DispatchQueue.global(qos: .utility).async {
            update {
                $0.runs += 1; if ok { $0.ok += 1 }; $0.tokens += tok
                if !ok {
                    var f = $0.failed ?? [:]
                    f[project, default: []] = (f[project, default: []] + [Date()]).suffix(10)
                    $0.failed = f
                }
            }
        }
    }
    static func recordFallback() { DispatchQueue.global(qos: .utility).async { update { $0.fallbacks += 1 } } }
    static func reset() { DispatchQueue.global(qos: .utility).async { update { $0 = LocalStats() } } }
}

// MARK: - Katalog lokaler Modelle (aktualisiert sich selbst)

/// Ein empfehlenswertes lokales Modell. `rank`: höher = besser. `ram`: so viel Arbeitsspeicher braucht der Mac mindestens.
struct LocalModelInfo: Codable, Hashable, Identifiable {
    var id: String { pull }
    var pull: String
    var name: String
    var ram: Int
    var size: Int
    var rank: Int
    var note: String
    var macIssue: Bool? = nil      // bekanntes Problem auf dem Mac → nie automatisch empfehlen
}

final class LocalCatalog: ObservableObject {
    static let shared = LocalCatalog()
    @Published private(set) var models: [LocalModelInfo] = LocalCatalog.builtIn
    @Published private(set) var pulling: [String: Double] = [:]      // Modell → Fortschritt 0…1
    @Published private(set) var pullError: [String: String] = [:]
    @Published private(set) var updated: Date?

    /// Stand der App (Herbst 2026). Wird durch die Online-Liste ersetzt, sobald es eine neuere gibt.
    static let builtIn: [LocalModelInfo] = [
        LocalModelInfo(pull: "qwen3-coder-next", name: "Qwen3-Coder-Next", ram: 64, size: 52, rank: 95, note: "Stärkstes lokales Code-Modell (MoE, 256k Kontext)"),
        LocalModelInfo(pull: "qwen3.8:27b", name: "Qwen3.8 27B", ram: 32, size: 18, rank: 88, note: "Bester Allrounder für Code mit Werkzeugen"),
        LocalModelInfo(pull: "flint", name: "Flint 40B", ram: 32, size: 23, rank: 87, note: "Für Coding-Agents gebaut (MoE, 256k Kontext)"),
        LocalModelInfo(pull: "devstral-small-2", name: "Devstral Small 2", ram: 24, size: 15, rank: 84, note: "Für Agent-Arbeit gebaut, findet sich in großen Repos zurecht"),
        LocalModelInfo(pull: "qwen3-coder:30b", name: "Qwen3-Coder 30B", ram: 32, size: 19, rank: 80, note: "Bewährt, ganze Repos im Blick"),
        LocalModelInfo(pull: "gemma4:31b", name: "Gemma 4 31B", ram: 32, size: 19, rank: 78, note: "Stark bei Text und Erklärungen"),
        LocalModelInfo(pull: "mimo-v2.6", name: "MiMo V2.6 9B", ram: 16, size: 8, rank: 74, note: "Klein, aber stark bei Code und Werkzeugen – läuft kühl"),
        LocalModelInfo(pull: "gemma4:12b", name: "Gemma 4 12B", ram: 16, size: 8, rank: 66, note: "Solide und sparsam, 256k Kontext"),
        LocalModelInfo(pull: "laguna-xs-2.1", name: "Laguna XS 2.1", ram: 32, size: 20, rank: 60, note: "Lange Agent-Aufgaben – liefert auf dem Mac derzeit teils leere Antworten", macIssue: true),
        LocalModelInfo(pull: "qwen3:8b", name: "Qwen3 8B", ram: 8, size: 5, rank: 55, note: "Klein und schnell für einfache Aufgaben"),
    ]

    /// Woher neue Empfehlungen kommen (eine kleine JSON-Liste). Leer = nur die Liste in der App.
    static var sourceURL: String {
        UserDefaults.standard.string(forKey: "local.catalogURL")
            ?? (Updater.repo.isEmpty ? "" : "https://raw.githubusercontent.com/\(Updater.repo)/main/models.json")
    }

    static var ramGB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) }

    /// Was auf diesen Mac passt, bestes zuerst.
    var fitting: [LocalModelInfo] { models.filter { Self.fitsGPU($0) }.sorted { ($0.macIssue == true ? 0 : 1, $0.rank) > ($1.macIssue == true ? 0 : 1, $1.rank) } }

    /// Gibt es ein besseres passendes Modell als das beste geladene?
    var better: LocalModelInfo? {
        let installed = LocalFirst.shared.models
        let bestInstalled = models.filter { m in installed.contains { $0.hasPrefix(m.pull.split(separator: ":").first.map(String.init) ?? m.pull) } }.map(\.rank).max() ?? 0
        return fitting.first { $0.macIssue != true && Self.comfortable($0) && $0.rank > bestInstalled && !installed.contains($0.pull) }
    }

    private var timer: Timer?

    init() {
        if let d = try? Data(contentsOf: Paths.data.appendingPathComponent("local-models.json")),
           let m = try? JSONDecoder().decode([LocalModelInfo].self, from: d), !m.isEmpty { models = m }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in self?.refresh() }
    }

    /// Neue Empfehlungen holen (einmal täglich). Bei einem neuen, besseren Modell kommt eine Mitteilung.
    func refresh() {
        guard LocalFirst.shared.isOnline, let url = URL(string: Self.sourceURL), !Self.sourceURL.isEmpty else { return }
        URLSession.shared.dataTask(with: url) { [weak self] d, resp, _ in
            guard let self, let d, (resp as? HTTPURLResponse)?.statusCode == 200,
                  let list = try? JSONDecoder().decode([LocalModelInfo].self, from: d), !list.isEmpty else { return }
            try? d.write(to: Paths.data.appendingPathComponent("local-models.json"), options: .atomic)
            DispatchQueue.main.async {
                let oldBest = self.fitting.first?.pull
                self.models = list
                self.updated = Date()
                if let b = self.better, b.pull != oldBest {
                    Notifier.push("Salenta Code", L("Neues lokales Modell verfügbar: ") + b.name + " – " + b.note, priority: 3, tags: "sparkles")
                    CrashLog.mark("Neues lokales Modell empfohlen: \(b.pull)")
                }
            }
        }.resume()
    }

    /// Herunterladen über Ollama (mit Fortschritt) – danach automatisch als lokales Modell aktiv und vorgewärmt.
    func pull(_ name: String) {
        guard pulling[name] == nil else { return }
        pulling[name] = 0
        pullError[name] = nil
        ensureOllamaRunning {
            var r = URLRequest(url: URL(string: "http://localhost:11434/api/pull")!, timeoutInterval: 24 * 3600)
            r.httpMethod = "POST"
            r.httpBody = try? JSONSerialization.data(withJSONObject: ["model": name, "stream": true])
            // Fortschritt über den Stream-Delegate
            let session = URLSession(configuration: .default, delegate: PullDelegate(name: name, catalog: self), delegateQueue: nil)
            session.dataTask(with: r).resume()
        }
    }

    fileprivate func progress(_ name: String, _ p: Double) { DispatchQueue.main.async { if self.pulling[name] != nil { self.pulling[name] = p } } }

    fileprivate func finished(_ name: String, error: String?) {
        DispatchQueue.main.async {
            self.pulling[name] = nil
            self.notifySetup(ok: error == nil, error: error)
            if let error { self.pullError[name] = error; return }
            UserDefaults.standard.set(name, forKey: "local.model")   // gleich nutzen
            LocalFirst.shared.loadModels()
            self.warmUp(name)
            Notifier.push("Salenta Code", "✓ " + name + " " + L("ist geladen und aktiv – läuft auch offline."), priority: 3, tags: "white_check_mark")
        }
    }

    /// Modell einmal in den Speicher laden, damit der erste Auftrag nicht wartet.
    func warmUp(_ name: String) {
        var r = URLRequest(url: URL(string: "http://localhost:11434/api/generate")!, timeoutInterval: 300)
        r.httpMethod = "POST"
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["model": LocalFirst.contextVariant(name), "prompt": "", "keep_alive": "5m"])
        URLSession.shared.dataTask(with: r).resume()
    }

    /// Ollama starten, falls es nicht läuft (App oder Dienst), dann weiter.
    func ensureOllamaRunning(_ then: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            OllamaApp.startServer()
            then()
        }
    }
}

/// Liest den Fortschritt aus Ollamas Antwort-Strom ({"total":…, "completed":…} je Zeile).
private final class PullDelegate: NSObject, URLSessionDataDelegate {
    let name: String
    weak var catalog: LocalCatalog?
    private var buffer = Data()
    private var lastError: String?
    init(name: String, catalog: LocalCatalog) { self.name = name; self.catalog = catalog }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer = Data(buffer[buffer.index(after: nl)...])
            guard let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let e = j["error"] as? String { lastError = e }
            if let t = j["total"] as? Double, t > 0, let c = j["completed"] as? Double { catalog?.progress(name, min(1, c / t)) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        catalog?.finished(name, error: error?.localizedDescription ?? lastError)
        session.finishTasksAndInvalidate()
    }
}

/// Einstellungen: Lokal zuerst.
struct LocalFirstSettings: View {
    @ObservedObject private var local = LocalFirst.shared
    @ObservedObject private var catalog = LocalCatalog.shared
    @AppStorage("local.offline") private var offline = true
    @AppStorage("local.small") private var small = true
    @AppStorage("local.only") private var only = false
    @AppStorage("local.model") private var model = ""

    var body: some View {
        Section("Lokal zuerst (Ollama)") {
            HStack {
                Circle().fill(local.online ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(local.online ? L("Internet da") : L("Offline – lokales Modell arbeitet"))
                Spacer()
                Text(local.ready ? (local.model.map { L("lokal bereit: ") + $0 } ?? "") : L("kein lokales Modell geladen")).foregroundStyle(.secondary)
            }
            Toggle(isOn: $only) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Nur lokal arbeiten (Offline-Modus)"))
                    Text(L("Alle Agents, Helfer, Mods und Hilfsabfragen nutzen nur das lokale Modell – nichts geht an eine Cloud-KI."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!local.ready && !only)
            .help(local.ready ? L("Schaltet alle Cloud-Modelle ab") : L("Erst ein lokales Modell laden (unten)"))
            if only && !local.ready {
                Label(L("Nur lokal ist an, aber kein lokales Modell ist bereit – Aufträge starten nicht, bis eins geladen ist."), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
            }
            Toggle(L("Bei Internet-Ausfall automatisch aufs lokale Modell umschalten"), isOn: $offline)
            Toggle(L("Kleine Aufgaben automatisch lokal erledigen (spart Kosten)"), isOn: $small)
            Picker(L("Lokales Modell"), selection: $model) {
                Text(L("Automatisch (bestes Code-Modell)")).tag("")
                ForEach(local.models, id: \.self) { Text($0).tag($0) }
            }
            // Empfehlungen für diesen Mac – laden per Klick, danach automatisch aktiv
            if let b = catalog.better {
                Label(L("Besseres Modell verfügbar: ") + b.name, systemImage: "sparkles").foregroundStyle(Color.accentColor)
            }
            ForEach(catalog.fitting.prefix(5)) { m in
                HStack(spacing: Grid.s) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(m.name).fontWeight(.medium)
                            Text("≈\(m.size) GB").font(.caption).foregroundStyle(.tertiary)
                            if !LocalCatalog.comfortable(m) { Text(L("passt knapp – wärmer, langsamer")).font(.caption2).foregroundStyle(.orange) }
                            if m.pull == catalog.recommendedForThisMac?.pull { Text(L("empfohlen")).font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor) }
                            if local.model?.hasPrefix(m.pull.split(separator: ":").first.map(String.init) ?? m.pull) == true {
                                Text(L("aktiv")).font(.caption2.weight(.semibold)).foregroundStyle(.green)
                            }
                        }
                        Text(m.note).font(.caption).foregroundStyle(.secondary)
                        if let e = catalog.pullError[m.pull] { Text(e).font(.caption).foregroundStyle(.red) }
                    }
                    Spacer()
                    if let p = catalog.pulling[m.pull] {
                        ProgressView(value: p).frame(width: 90)
                        Text("\(Int(p * 100)) %").font(.caption.monospacedDigit()).frame(width: 36)
                    } else if local.models.contains(where: { $0 == m.pull || $0.hasPrefix(m.pull + ":") || m.pull.hasPrefix($0) }) {
                        Button(L("Nutzen")) { model = local.models.first { $0 == m.pull || $0.hasPrefix(m.pull) || m.pull.hasPrefix($0) } ?? m.pull; catalog.warmUp(model) }
                            .disabled(local.model == m.pull)
                    } else {
                        Button(L("Laden")) { catalog.pull(m.pull) }
                            .disabled(!OllamaApp.installed)
                            .help(L("Lädt das Modell einmal herunter – danach ist es aktiv und läuft auch offline"))
                    }
                }
            }
            Text(L("Passend zu diesem Mac") + String(format: " (%.0f GB ", OllamaApp.gpuGB) + L("Grafikspeicher") + "). " + L("Die Liste aktualisiert sich täglich – kommt ein besseres Modell, bekommst du Bescheid."))
                .font(.caption).foregroundStyle(.tertiary)
            LocalSetupRow()
        }
        .onAppear { local.loadModels() }
    }
}


/// Kurze Hilfsaufrufe (Planung, Agent-Wahl, Zusammenfassungen, PR-Texte, Recherche): normalerweise Claude.
/// Ist Claude pausiert, im Limit oder abgemeldet, beantwortet Codex dieselbe Frage im selben Ausgabeformat –
/// so verbraucht nichts im Hintergrund weiter Claude, obwohl du es abgeschaltet hast.
enum HelperLLM {
    static var useCodex: Bool {
        !LocalFirst.shared.useLocal && AgentManager.claudeOff && OpenModels.available(.codex) && !AgentHealth.unavailable(.codex)
    }
    /// Befehl, der die Frage aus `file` beantwortet und JSON im Format von `claude -p --output-format json` ausgibt.
    static func command(model: String, maxTurns: Int, file: String, extra: String = "", web: Bool = false) -> String {
        if useCodex {
            let effort = model == "haiku" ? "low" : "medium"
            return Accounts.shared.exports() + Shell.quote(Paths.root.appendingPathComponent("bin/aos-ask").path)
                + " --effort \(effort)" + (web ? " --web" : "")
                + (Detection.which("codex").map { " --codex " + Shell.quote($0) } ?? "") + " < " + Shell.quote(file)
        }
        return LocalFirst.cliEnv() + "claude -p --model \(model) --output-format json --max-turns \(maxTurns)" + (extra.isEmpty ? "" : " " + extra)
            + " --strict-mcp-config < " + Shell.quote(file)
    }
}
