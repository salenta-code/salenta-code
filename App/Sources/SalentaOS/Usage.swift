import AgenticOSKit
import AppKit
import Charts
import SwiftUI

// Verbrauch der Agents und Modelle – gelesen aus den Verlaufsdateien von Claude Code (~/.claude/projects)
// und Codex (~/.codex/sessions, inkl. der echten Limit-Anzeige von OpenAI). Wird es bei einem Agent eng,
// verteilt die Agentenwahl Aufträge automatisch auf die anderen; läuft einer ins Limit, macht ein anderer weiter.

struct UsagePoint: Hashable, Codable {
    let id: String
    let date: Date
    let model: String
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int

    var total: Int { input + output + cacheRead + cacheWrite }
    /// Gewichtet für Limits: Cache-Lesen zählt kaum, Opus zählt mehr als Sonnet, Haiku weniger.
    var weighted: Double {
        let m = model.lowercased()
        let w = m.contains("opus") ? 1.7 : m.contains("haiku") ? 0.33 : 1.0
        return (Double(input + output + cacheWrite) + Double(cacheRead) * 0.1) * w
    }
}

struct RateWindow: Codable, Hashable {
    var usedPercent: Double
    var windowMinutes: Int
    var resetsAt: Date?
}

struct AgentSwitch: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let from: String
    let to: String
    let why: String
}

final class Usage: ObservableObject {
    static let shared = Usage()

    @Published private(set) var claude: [UsagePoint] = []
    @Published private(set) var codex: [UsagePoint] = []
    @Published private(set) var codexPrimary: RateWindow?
    @Published private(set) var codexSecondary: RateWindow?
    /// Echte Claude-Limits aus deinem Claude-Konto (nur, wenn du es einschaltest) – sonst Schätzung aus dem Verlauf
    @Published private(set) var claudeFive: RateWindow?
    @Published private(set) var claudeWeek: RateWindow?
    @Published private(set) var claudeRealAt: Date?
    @Published private(set) var blocked: [String: Date] = [:]
    @Published private(set) var switches: [AgentSwitch] = []
    @Published private(set) var lastScan: Date?
    @Published private(set) var scanning = false
    @Published var calibrated5h: Double?

    /// Für Hintergrund-Threads (Prüfschleife, Router): Werte ohne SwiftUI-Zugriff.
    private let lock = NSLock()
    private var snapPressure: [AgentKind: Double] = [:]

    private struct FileCache: Codable { var offset: UInt64; var points: [UsagePoint]; var model: String }
    /// Gelesener Stand je Datei – auf Platte, damit nach einem Neustart nicht 8 Tage Verlauf neu gelesen werden.
    private var cacheURL: URL { Paths.data.appendingPathComponent("usage-cache.json") }
    private var cacheDirty = false
    private var cache: [String: FileCache] = [:]
    private var timer: Timer?
    private let queue = DispatchQueue(label: "usage.scan", qos: .utility)
    private var stateURL: URL { Paths.data.appendingPathComponent("usage.json") }

    static let plans: [(id: String, title: String, fiveHour: Double)] = [
        ("pro", "Claude Pro", 2_500_000),
        ("max5", "Claude Max 5×", 12_000_000),
        ("max20", "Claude Max 20×", 48_000_000),
    ]

    init() {
        loadState()
        if let d = try? Data(contentsOf: cacheURL) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
            if let c = try? dec.decode([String: FileCache].self, from: d) { cache = c }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.scan() }
        timer?.tolerance = 10
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.scan() }
    }

    // MARK: Einstellungen

    var plan: String { UserDefaults.standard.string(forKey: "usage.claudePlan") ?? "max5" }
    var threshold: Double { UserDefaults.standard.object(forKey: "usage.tight") as? Double ?? 0.8 }
    var autoSwitch: Bool { UserDefaults.standard.object(forKey: "usage.autoswitch") as? Bool ?? true }
    var budget5h: Double { calibrated5h ?? Self.plans.first { $0.id == plan }?.fiveHour ?? 12_000_000 }
    var budgetWeek: Double { budget5h * 9 }

    // MARK: Kennzahlen

    func claudeWindow(hours: Double) -> Double {
        let from = Date().addingTimeInterval(-hours * 3600)
        return claude.filter { $0.date >= from }.reduce(0) { $0 + $1.weighted }
    }

    // MARK: Von dir pausiert (z. B. Kontingent fast leer → lieber über Codex arbeiten)

    private static func pauseKey(_ a: AgentKind) -> String { "agent.pausedUntil.\(a.rawValue)" }
    /// Bis wann pausiert (distantFuture = bis du ihn wieder freigibst). Thread-sicher.
    static func pausedUntil(_ a: AgentKind) -> Date? {
        let t = UserDefaults.standard.double(forKey: pauseKey(a))
        guard t > 0 else { return nil }
        let d = Date(timeIntervalSince1970: t)
        return d > Date() ? d : nil
    }
    static func isPaused(_ a: AgentKind) -> Bool { pausedUntil(a) != nil }
    /// Helfer-Arbeit geht an andere Agents; Planen und Prüfen (wenig Verbrauch) laufen weiter.
    static let pausedNote = Notification.Name("agent.paused")
    func pause(_ a: AgentKind, until: Date?) {
        UserDefaults.standard.set((until ?? .distantFuture).timeIntervalSince1970, forKey: Self.pauseKey(a))
        objectWillChange.send(); refreshSnapshot()
        NotificationCenter.default.post(name: Self.pausedNote, object: a.rawValue)   // laufende Aufgaben übergeben
    }
    func resume(_ a: AgentKind) {
        UserDefaults.standard.removeObject(forKey: Self.pauseKey(a))
        objectWillChange.send(); refreshSnapshot()
    }

    /// 0…1 (oder mehr): wie nah der Agent am Limit ist.
    func pressure(_ agent: AgentKind) -> Double {
        if Self.isPaused(agent) { return 1.0 }
        if let b = blocked[agent.rawValue], b > Date() { return 1.0 }
        // Zusatz-Abo aktiv: dessen Verbrauch kennen wir nicht – frei, bis es ein Limit meldet
        if Accounts.shared.activeAccount(agent) != nil { return 0 }
        switch agent {
        case .claude:
            if let at = claudeRealAt, at > Date().addingTimeInterval(-20 * 60) {
                let now = Date()
                let p = [claudeFive, claudeWeek].compactMap { w -> Double? in
                    guard let w else { return nil }
                    if let r = w.resetsAt, r < now { return 0 }
                    return w.usedPercent / 100
                }
                if let m = p.max() { return m }
            }
            return max(claudeWindow(hours: 5) / budget5h, claudeWindow(hours: 24 * 7) / budgetWeek)
        case .codex:
            let now = Date()
            let p = [codexPrimary, codexSecondary].compactMap { w -> Double? in
                guard let w else { return nil }
                if let r = w.resetsAt, r < now { return 0 }
                return w.usedPercent / 100
            }
            return p.max() ?? 0
        default:
            return 0
        }
    }

    /// Thread-sicher (für Hintergrund-Aufgaben).
    func isTight(_ agent: AgentKind) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (snapPressure[agent] ?? 0) >= threshold
    }

    func cachedPressure(_ agent: AgentKind) -> Double {
        lock.lock(); defer { lock.unlock() }
        return snapPressure[agent] ?? 0
    }

    func resetDate(_ agent: AgentKind) -> Date? {
        if let b = blocked[agent.rawValue], b > Date() { return b }
        switch agent {
        case .codex:
            return [codexPrimary, codexSecondary].compactMap { $0?.resetsAt }.filter { $0 > Date() }.min()
        case .claude:
            // Das 5-Stunden-Fenster beginnt mit der ersten Nachricht darin.
            let from = Date().addingTimeInterval(-5 * 3600)
            return claude.filter { $0.date >= from }.map(\.date).min()?.addingTimeInterval(5 * 3600)
        default: return nil
        }
    }

    private func refreshSnapshot() {
        var s: [AgentKind: Double] = [:]
        for a in [AgentKind.claude, .codex, .junie] { s[a] = pressure(a) }
        // Hauptkonto fast voll und ein weiteres Abo frei → schon jetzt wechseln, nicht erst beim harten Limit
        if Thread.isMainThread {
            for a in Accounts.supported where (s[a] ?? 0) >= threshold && !Self.isPaused(a) && Accounts.shared.activeAccount(a) == nil
                && (blocked[a.rawValue] ?? .distantPast) <= Date() && Accounts.shared.hasFreeAlternative(a) {
                if Accounts.shared.rotate(a, limitedUntil: resetDate(a) ?? Date().addingTimeInterval(5 * 3600)) { s[a] = 0 }
            }
        }
        lock.lock(); snapPressure = s; lock.unlock()
    }

    // MARK: Limits erkennen

    static let limitPatterns = ["usage limit", "rate limit", "rate_limit", "limit reached", "hit your limit", "you've hit your",
                                "you have hit your", "quota exceeded", "exceeded your", "too many requests", "5-hour limit",
                                "weekly limit", "credit balance is too low", "insufficient_quota", "overloaded_error",
                                "does not have access to", "upgrade your plan", "regain access on"]

    /// Prüft eine Agent-Ausgabe auf "Limit erreicht". true = erkannt (Agent wird bis zum Reset gemieden).
    @discardableResult
    func noteOutput(_ agent: AgentKind, text: String) -> Bool {
        let t = text.lowercased()
        guard Self.limitPatterns.contains(where: { t.contains($0) }) else { return false }
        // Abo-/Monatsgrenze ohne auswertbare Zeit: einen Tag meiden statt jede Stunde erneut zu scheitern
        let longBlock = ["does not have access to", "upgrade your plan", "regain access on"].contains { t.contains($0) }
        let until = Self.parseReset(text) ?? Date().addingTimeInterval(longBlock ? 86400 : 3600)
        let apply = {
            // Weiteres Abo desselben Anbieters frei? Dann damit weiterarbeiten statt den Anbieter zu sperren
            if Accounts.shared.rotate(agent, limitedUntil: until) { self.refreshSnapshot(); return }
            self.blocked[agent.rawValue] = max(until, self.blocked[agent.rawValue] ?? .distantPast)
            if agent == .claude {
                // Kalibrieren: so viel ging in 5 Stunden, bevor das Limit kam.
                let used = self.claudeWindow(hours: 5)
                if used > 200_000 { self.calibrated5h = used }
            }
            self.refreshSnapshot()
            self.saveState()
        }
        // Auf dem Hauptthread sofort – damit eine Übergabe direkt danach schon das neue Abo nutzt
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
        return true
    }

    static func parseReset(_ text: String) -> Date? {
        // Claude Code: "Claude AI usage limit reached|1730000000"
        if let r = text.range(of: "\\|([0-9]{10})", options: .regularExpression),
           let t = Double(text[r].dropFirst()) { return Date(timeIntervalSince1970: t) }
        let lower = text.lowercased()
        // "regain access on 2026-12-01 at 00:00 UTC"
        if let r = lower.range(of: "on (20[0-9]{2}-[0-9]{2}-[0-9]{2})", options: .regularExpression) {
            let day = String(lower[r].dropFirst(3))
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
            if let d = f.date(from: day), d > Date() { return d }
        }
        // "try again in 37 minutes" / "in 2 hours"
        if let r = lower.range(of: "in ([0-9]+) ?(seconds?|secs?|minutes?|mins?|hours?|hrs?|h)\\b", options: .regularExpression) {
            let part = String(lower[r])
            let n = Double(part.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 60
            let f: Double = part.contains("sec") ? 1 : part.contains("min") ? 60 : 3600
            return Date().addingTimeInterval(n * f)
        }
        // "resets 5pm" / "resets at 17:30"
        if let r = lower.range(of: "resets?( at)? ([0-9]{1,2})(:([0-9]{2}))? ?(am|pm)?", options: .regularExpression) {
            let part = String(lower[r])
            let nums = part.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }.compactMap(Int.init)
            guard var h = nums.first else { return nil }
            let m = nums.count > 1 ? nums[1] : 0
            if part.hasSuffix("pm") && h < 12 { h += 12 }
            if part.hasSuffix("am") && h == 12 { h = 0 }
            var d = Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
            if d < Date() { d = d.addingTimeInterval(86400) }
            return d
        }
        return nil
    }

    func unblock(_ agent: AgentKind) {
        blocked[agent.rawValue] = nil
        refreshSnapshot()
        saveState()
    }

    func resetCalibration() {
        calibrated5h = nil
        refreshSnapshot()
        saveState()
    }

    // MARK: Automatisch verteilen

    static func alternatives(_ a: AgentKind) -> [AgentKind] {
        rawAlternatives(a).filter { Billing.autoOK($0) && !AgentOff.isOff($0) }
    }

    private static func rawAlternatives(_ a: AgentKind) -> [AgentKind] {
        switch a {
        case .claude: [.codex, .kimi, .cursor, .gemini, .harness, .deepseek, .openrouter, .opencode, .junie, .grok, .kiro, .pi]
        case .codex: [.claude, .kimi, .cursor, .gemini, .harness, .deepseek, .openrouter, .opencode, .junie, .grok, .kiro, .pi]
        case .junie: [.claude, .codex, .cursor, .gemini, .opencode]
        case .shell: []
        default: [.claude, .codex, .gemini, .opencode]
        }
    }

    /// Passt die Wahl an, wenn ein Agent knapp wird: anderes Modell oder anderer Agent.
    func adjust(_ d: AIRouteDecision, installed: Set<AgentKind>) -> AIRouteDecision {
        guard autoSwitch else { return d }
        var d = d
        let pct = { (a: AgentKind) in "\(Int(self.pressure(a) * 100)) %" }
        if let a = d.target.agent, AgentKind.coders.contains(a), d.target != .osAgent {
            let p = pressure(a)
            let blockedNow = (blocked[a.rawValue] ?? .distantPast) > Date()
            if blockedNow || p >= threshold,
               let alt = Self.alternatives(a).first(where: { installed.contains($0) && pressure($0) < max(threshold - 0.2, 0.3) }) {
                let why = blockedNow ? L("Limit erreicht") : pct(a)
                d.target = MissionTarget.from(alt)
                d.model = alt == .claude ? (pressure(.claude) >= 0.6 ? "sonnet" : (ModelCatalog.fits(d.model ?? "", .claude) ? d.model : nil)) : nil
                d.effort = alt == .codex ? (d.effort ?? "medium") : nil
                d.reason += " · \(a.title) \(why) → \(alt.title)"
                record(from: a.title, to: alt.title, why: why)
            }
        }
        if (d.target == .claude || d.target == .osAgent), d.model == "opus", pressure(.claude) >= 0.6 {
            d.model = "sonnet"
            d.reason += " · " + L("Opus gespart (Claude \(pct(.claude)))")
            record(from: "Opus", to: "Sonnet", why: pct(.claude))
        }
        return d
    }

    func record(from: String, to: String, why: String) {
        DispatchQueue.main.async {
            self.switches.insert(AgentSwitch(date: Date(), from: from, to: to, why: why), at: 0)
            if self.switches.count > 30 { self.switches.removeLast() }
        }
    }

    /// Für die KI-Wahl: aktueller Stand als kurzer Text.
    var routerHint: String {
        let list = [AgentKind.claude, .codex].map { a -> String in
            let b = (blocked[a.rawValue] ?? .distantPast) > Date()
            return "\(a.rawValue): \(b ? "LIMIT REACHED" : "\(Int(pressure(a) * 100))% of limit used")"
        }
        return list.joined(separator: ", ")
    }

    // MARK: Dateien lesen

    private var queued = false
    private let queuedLock = NSLock()

    func scan() {
        guard Energy.due("usage", every: 300) else { return }
        // Läuft schon ein Durchgang (der erste kann Minuten dauern), keinen weiteren stapeln
        queuedLock.lock(); if queued { queuedLock.unlock(); return }; queued = true; queuedLock.unlock()
        DispatchQueue.main.async { self.scanning = true }
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.queuedLock.lock(); self.queued = false; self.queuedLock.unlock() }
            let t0 = Date()
            var fileCount = 0
            let home = FileManager.default.homeDirectoryForCurrentUser
            let since = Date().addingTimeInterval(-8 * 86400)
            var claudePts: [UsagePoint] = []
            var codexPts: [UsagePoint] = []
            var latestRate: (Date, RateWindow?, RateWindow?)?
            var live = Set<String>()

            for url in Self.files(under: home.appendingPathComponent(".claude/projects"), since: since) {
                live.insert(url.path)
                fileCount += 1
                claudePts += self.read(url) { line, _ in Self.parseClaude(line) }
            }
            for url in Self.files(under: home.appendingPathComponent(".codex/sessions"), since: since) {
                live.insert(url.path)
                codexPts += self.read(url) { line, model in
                    let (pt, newModel, rate) = Self.parseCodex(line, model: model)
                    if let rate, latestRate == nil || rate.0 > latestRate!.0 { latestRate = rate }
                    return (pt, newModel)
                }
            }
            let before = self.cache.count
            self.cache = self.cache.filter { live.contains($0.key) }
            if self.cacheDirty || self.cache.count != before {
                self.cacheDirty = false
                let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
                if let d = try? enc.encode(self.cache) { try? d.write(to: self.cacheURL, options: .atomic) }
            }
            var seen = Set<String>()
            claudePts = claudePts.filter { $0.date >= since && seen.insert($0.id).inserted }.sorted { $0.date < $1.date }
            codexPts = codexPts.filter { $0.date >= since }.sorted { $0.date < $1.date }
            Self.log("scan \(fileCount) claude files, \(live.count - fileCount) codex files → \(claudePts.count) claude / \(codexPts.count) codex points in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
            DispatchQueue.main.async {
                self.scanning = false
                self.claude = claudePts
                self.codex = codexPts
                CostHistory.shared.merge(claude: claudePts, codex: codexPts)
                if let r = latestRate { self.codexPrimary = r.1; self.codexSecondary = r.2; self.saveState() }
                self.fetchClaudeReal()
                self.lastScan = Date()
                self.blocked = self.blocked.filter { $0.value > Date() }
                self.refreshSnapshot()
            }
        }
    }

    private static func log(_ text: String) {
        let url = Paths.root.appendingPathComponent("logs/usage.log")
        let line = "\(Date()) \(text)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    private static func files(under dir: URL, since: Date) -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let u as URL in e where u.pathExtension == "jsonl" {
            if let m = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m >= since { out.append(u) }
        }
        return out
    }

    /// Liest nur neue Zeilen seit dem letzten Mal (Dateien wachsen nur).
    private func read(_ url: URL, parse: (String, String) -> (UsagePoint?, String?)) -> [UsagePoint] {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        var c = cache[url.path] ?? FileCache(offset: 0, points: [], model: "")
        if size < c.offset { c = FileCache(offset: 0, points: [], model: "") }
        if size > c.offset, let h = try? FileHandle(forReadingFrom: url) {
            // in Stücken lesen: Verlaufsdateien werden schnell Hunderte MB groß – nie ganz in den Speicher
            try? h.seek(toOffset: c.offset)
            var carry = Data()
            while true {
                let piece = autoreleasepool { h.readData(ofLength: 4 << 20) }
                if piece.isEmpty { break }
                var data = carry; data.append(piece)
                guard let lastNL = data.lastIndex(of: 0x0A) else { carry = data; if carry.count > 64 << 20 { break }; continue }
                let chunk = data[data.startIndex...lastNL]
                autoreleasepool {
                    // Zeilen auf Byte-Ebene vorfiltern (memmem) – nur passende Zeilen werden zu Text.
                    // Gemessen: die Text-Suche über jede Zeile war der größte Brocken beim Einlesen.
                    chunk.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                        guard let base = buf.baseAddress else { return }
                        var start = 0
                        let n = buf.count
                        while start < n {
                            let rest = n - start
                            let nl: UnsafeMutableRawPointer? = memchr(base + start, 0x0A, rest)
                            let end = nl.map { base.distance(to: UnsafeRawPointer($0)) } ?? n
                            let len = end - start
                            if len > 0, Self.needles.contains(where: { nd in nd.withUnsafeBytes { memmem(base + start, len, $0.baseAddress, $0.count) != nil } }) {
                                let line = String(decoding: UnsafeRawBufferPointer(start: base + start, count: len), as: UTF8.self)
                                let (pt, model) = parse(line, c.model)
                                if let model { c.model = model }
                                if let pt { c.points.append(pt) }
                            }
                            start = end + 1
                        }
                    }
                }
                c.offset += UInt64(chunk.count)
                carry = Data(data[data.index(after: lastNL)...])
            }
            try? h.close()
            cache[url.path] = c
            cacheDirty = true
        }
        return c.points
    }

    private static let needles: [[UInt8]] = ["usage", "token_count", "turn_context", "rate_limits"].map { Array($0.utf8) }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    private static func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    /// Schnell: nur die nötigen Felder per Suche statt die ganze (oft riesige) Zeile als JSON zu lesen.
    private static func field(_ line: String, _ key: String) -> String? {
        guard let r = line.range(of: "\"\(key)\":\"") else { return nil }
        guard let e = line[r.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(line[r.upperBound..<e])
    }

    private static func number(_ s: Substring, _ key: String) -> Int {
        guard let r = s.range(of: "\"\(key)\":") else { return 0 }
        let digits = s[r.upperBound...].prefix { $0.isNumber }
        return Int(digits) ?? 0
    }

    private static func parseClaude(_ line: String) -> (UsagePoint?, String?) {
        guard line.contains("\"type\":\"assistant\""), let u = line.range(of: "\"usage\":{") else { return (nil, nil) }
        let usage = line[u.upperBound...].prefix(700)
        guard let ts = field(line, "timestamp"), let when = date(ts) else { return parseClaudeJSON(line) }
        let model = field(line, "model") ?? "claude"
        if model == "<synthetic>" { return (nil, nil) }
        let id = field(line, "id").flatMap { $0.hasPrefix("msg_") ? $0 : nil } ?? field(line, "requestId") ?? field(line, "uuid") ?? UUID().uuidString
        return (UsagePoint(id: id, date: when, model: model,
                           input: number(usage, "input_tokens"), output: number(usage, "output_tokens"),
                           cacheRead: number(usage, "cache_read_input_tokens"),
                           cacheWrite: number(usage, "cache_creation_input_tokens")), nil)
    }

    private static func parseClaudeJSON(_ line: String) -> (UsagePoint?, String?) {
        guard line.contains("\"assistant\""), let d = line.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              j["type"] as? String == "assistant",
              let msg = j["message"] as? [String: Any], let u = msg["usage"] as? [String: Any],
              let when = date(j["timestamp"]) else { return (nil, nil) }
        let model = msg["model"] as? String ?? "claude"
        if model == "<synthetic>" { return (nil, nil) }
        let id = (msg["id"] as? String) ?? (j["uuid"] as? String) ?? UUID().uuidString
        return (UsagePoint(id: id, date: when, model: model,
                           input: u["input_tokens"] as? Int ?? 0, output: u["output_tokens"] as? Int ?? 0,
                           cacheRead: u["cache_read_input_tokens"] as? Int ?? 0,
                           cacheWrite: u["cache_creation_input_tokens"] as? Int ?? 0), nil)
    }

    private static func parseCodex(_ line: String, model: String) -> (UsagePoint?, String?, (Date, RateWindow?, RateWindow?)?) {
        guard let d = line.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return (nil, nil, nil) }
        let payload = j["payload"] as? [String: Any] ?? j
        let when = date(j["timestamp"]) ?? Date()
        if j["type"] as? String == "turn_context", let m = payload["model"] as? String { return (nil, m, nil) }
        guard payload["type"] as? String == "token_count" else { return (nil, nil, nil) }
        var pt: UsagePoint?
        if let info = payload["info"] as? [String: Any], let last = info["last_token_usage"] as? [String: Any] {
            let input = last["input_tokens"] as? Int ?? 0
            let cached = last["cached_input_tokens"] as? Int ?? 0
            let out = (last["output_tokens"] as? Int ?? 0)
            pt = UsagePoint(id: UUID().uuidString, date: when, model: model.isEmpty ? "codex" : model,
                            input: max(input - cached, 0), output: out, cacheRead: cached, cacheWrite: 0)
        }
        var rate: (Date, RateWindow?, RateWindow?)?
        if let r = payload["rate_limits"] as? [String: Any] {
            func win(_ k: String) -> RateWindow? {
                guard let w = r[k] as? [String: Any] else { return nil }
                let used = (w["used_percent"] as? Double) ?? Double(w["used_percent"] as? Int ?? 0)
                let mins = w["window_minutes"] as? Int ?? 0
                var reset: Date?
                if let s = w["resets_in_seconds"] as? Double { reset = when.addingTimeInterval(s) }
                else if let s = w["resets_in_seconds"] as? Int { reset = when.addingTimeInterval(Double(s)) }
                else if let a = w["resets_at"] as? Double { reset = Date(timeIntervalSince1970: a) }
                else if let a = w["resets_at"] as? Int { reset = Date(timeIntervalSince1970: Double(a)) }
                return RateWindow(usedPercent: used, windowMinutes: mins, resetsAt: reset)
            }
            rate = (when, win("primary"), win("secondary"))
        }
        return (pt, nil, rate)
    }

    // MARK: Speichern

    private func loadState() {
        guard let d = try? Data(contentsOf: stateURL), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        if let b = j["blocked"] as? [String: Double] {
            blocked = b.mapValues { Date(timeIntervalSince1970: $0) }.filter { $0.value > Date() }
        }
        calibrated5h = j["calibrated5h"] as? Double
        // Echte Limit-Stände über Neustarts behalten (der Verlauf wird nur für neue Zeilen gelesen)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        func w(_ k: String) -> RateWindow? {
            guard let o = j[k], let d = try? JSONSerialization.data(withJSONObject: o) else { return nil }
            return try? dec.decode(RateWindow.self, from: d)
        }
        codexPrimary = w("codexPrimary"); codexSecondary = w("codexSecondary")
        claudeFive = w("claudeFive"); claudeWeek = w("claudeWeek")
    }

    private func saveState() {
        var j: [String: Any] = ["blocked": blocked.mapValues { $0.timeIntervalSince1970 }]
        if let c = calibrated5h { j["calibrated5h"] = c }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        for (k, w) in [("codexPrimary", codexPrimary), ("codexSecondary", codexSecondary), ("claudeFive", claudeFive), ("claudeWeek", claudeWeek)] {
            if let w, let d = try? enc.encode(w), let o = try? JSONSerialization.jsonObject(with: d) { j[k] = o }
        }
        if let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted]) { try? d.write(to: stateURL, options: .atomic) }
    }
}

// MARK: - Anzeige

private func tokens(_ n: Double) -> String {
    n >= 1_000_000 ? String(format: "%.1f M", n / 1_000_000) : n >= 1000 ? String(format: "%.0f k", n / 1000) : String(Int(n))
}

private func pressureColor(_ p: Double) -> Color { p >= 0.9 ? .red : p >= 0.6 ? .orange : .green }

/// Kleine Anzeige neben der Modellwahl: wie viel bei Claude und Codex noch geht.
struct UsageMini: View {
    @ObservedObject private var usage = Usage.shared
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Button { app.page = .usage } label: {
            HStack(spacing: 6) {
                bar("C", usage.pressure(.claude))
                bar("X", usage.pressure(.codex))
            }
        }
        .buttonStyle(.plain)
        .help(L("Verbrauch: C = Claude, X = Codex – klicken für Details"))
    }

    private func bar(_ label: String, _ p: Double) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18)).frame(width: 26, height: 5)
                Capsule().fill(pressureColor(p)).frame(width: max(3, 26 * min(p, 1)), height: 5)
            }
        }
    }
}

struct UsageView: View {
    @ObservedObject private var usage = Usage.shared
    @ObservedObject private var missions = MissionStore.shared
    @EnvironmentObject private var system: SystemStatus
    @AppStorage("usage.claudePlan") private var plan = "max5"
    @AppStorage("usage.tight") private var threshold = 0.8
    @AppStorage("usage.autoswitch") private var autoSwitch = true

    struct DayModel: Identifiable { let id = UUID(); let day: Date; let model: String; let tokens: Double }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Grid.xl) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Verbrauch").font(.largeTitle.weight(.semibold))
                        if usage.scanning { ProgressView().controlSize(.small); Text("liest Verlauf …").font(.caption).foregroundStyle(.secondary) }
                    }
                    Text("Wie viel deine Agents und Modelle verbrauchen – und wie nah sie am Limit sind. Wird es eng, verteilt Salenta Code neue Aufträge automatisch auf die anderen.")
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: Grid.l) {
                    agentCard(.claude, detail: claudeDetail)
                    agentCard(.codex, detail: codexDetail)
                    agentCard(.junie, detail: runsDetail(.junie))
                }
                Toggle(isOn: Binding(get: { Usage.claudeRealEnabled }, set: { v in
                    UserDefaults.standard.set(v, forKey: "usage.claudeReal"); if v { usage.fetchClaudeReal(force: true) }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Echte Claude-Limits anzeigen")).font(.callout.weight(.medium))
                        Text(L("Liest den Stand (5 Stunden, Woche) direkt aus deinem Claude-Konto statt zu schätzen – dann verteilt Salenta Code Aufträge nur noch, wenn Claude wirklich knapp ist. macOS fragt einmal nach Zugriff auf den Schlüsselbund-Eintrag von Claude Code; der Schlüssel wird nicht gespeichert."))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                CostOverview()
                ToolTrackerCard()
                LocalSavingsCard()
                BillingCard()
                chartCard
                HStack(alignment: .top, spacing: Grid.l) {
                    modelTable
                    qualityTable
                }
                switchesCard
                settingsCard
            }
            .padding(Grid.xl)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Verbrauch")
        .toolbar { ToolbarItem { Button { usage.scan() } label: { Label("Aktualisieren", systemImage: "arrow.clockwise") }.help(L("Aktualisieren")) } }
    }

    // MARK: Karten pro Agent

    private func agentCard(_ a: AgentKind, detail: [String]) -> some View {
        let p = usage.pressure(a)
        let blocked = (usage.blocked[a.rawValue] ?? .distantPast) > Date()
        let hasData = a == .claude ? !usage.claude.isEmpty : a == .codex ? (usage.codexPrimary != nil || !usage.codex.isEmpty) : false
        return VStack(alignment: .leading, spacing: Grid.s) {
            HStack {
                Image(systemName: a.symbol)
                Text(a.title).font(.headline)
                Spacer()
                statusChip(p: p, blocked: blocked, hasData: hasData || blocked)
            }
            HStack(alignment: .center, spacing: Grid.m) {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 10)
                    Circle().trim(from: 0, to: min(p, 1))
                        .stroke(pressureColor(p), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.6), value: p)
                    VStack(spacing: 0) {
                        Text(hasData || blocked ? "\(Int(min(p, 9.99) * 100))%" : "–").font(.title3.weight(.bold).monospacedDigit())
                        Text("Limit").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(detail, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    if let r = usage.resetDate(a), hasData || blocked {
                        Text("Reset \(r, style: .relative)").font(.caption.weight(.medium))
                    }
                    if Accounts.supported.contains(a) { AccountsSection(agent: a) }
                    if blocked {
                        Button("Wieder freigeben") { usage.unblock(a) }.buttonStyle(.link).font(.caption)
                            .help(L("Limit-Sperre aufheben – der Agent wird wieder eingeplant"))
                    }
                    if let until = Usage.pausedUntil(a) {
                        Text(until == .distantFuture ? L("Pausiert – bis du ihn freigibst") : L("Pausiert bis") + " " + until.formatted(date: .omitted, time: .shortened))
                            .font(.caption.weight(.medium)).foregroundStyle(.orange)
                        Button(L("Fortsetzen")) { usage.resume(a) }.buttonStyle(.link).font(.caption)
                            .help(L("Pause beenden – Helfer dürfen diesen Anbieter wieder nutzen"))
                    } else {
                        Menu(L("Pausieren")) {
                            Button(L("1 Stunde")) { usage.pause(a, until: Date().addingTimeInterval(3600)) }
                            Button(L("Bis morgen früh")) { usage.pause(a, until: Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date().addingTimeInterval(86400))) }
                            Button(L("Eine Woche")) { usage.pause(a, until: Date().addingTimeInterval(7 * 86400)) }
                            Button(L("Bis ich ihn freigebe")) { usage.pause(a, until: nil) }
                        }
                        .menuStyle(.borderlessButton).fixedSize().font(.caption)
                        .help(L("Diesen Anbieter für Helfer-Arbeit pausieren – Aufgaben gehen dann an andere Agents (z. B. Codex statt Claude)"))
                    }
                }
            }
        }
        .padding(Grid.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ModernCardBackground(radius: 16))
    }

    private func statusChip(p: Double, blocked: Bool, hasData: Bool) -> some View {
        let (text, color): (String, Color) = blocked ? (L("Limit oder pausiert"), .red)
            : !hasData ? (L("keine Daten"), .secondary)
            : p >= threshold ? (L("wird eng"), .orange) : (L("frei"), .green)
        return Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15))).foregroundStyle(color)
    }

    private var claudeDetail: [String] {
        if let at = usage.claudeRealAt, at > Date().addingTimeInterval(-20 * 60) {
            var out: [String] = []
            if let f = usage.claudeFive { out.append("5 h: \(Int(f.usedPercent)) %" + (f.resetsAt.map { " · " + L("Reset") + " " + $0.formatted(.relative(presentation: .named)) } ?? "")) }
            if let w = usage.claudeWeek { out.append(L("Woche") + ": \(Int(w.usedPercent)) %" + (w.resetsAt.map { " · " + L("Reset") + " " + $0.formatted(.relative(presentation: .named)) } ?? "")) }
            out.append(L("echt aus deinem Claude-Konto"))
            return out
        }
        let five = usage.claudeWindow(hours: 5), week = usage.claudeWindow(hours: 168)
        return [
            "5 h: \(tokens(five)) / \(tokens(usage.budget5h))",
            L("Woche") + ": \(tokens(week)) / \(tokens(usage.budgetWeek))",
            usage.calibrated5h != nil ? L("an deinem Limit kalibriert") : L("geschätzt nach Abo"),
        ]
    }

    private var codexDetail: [String] {
        var out: [String] = []
        if let p = usage.codexPrimary { out.append("\(windowName(p.windowMinutes)): \(Int(p.usedPercent)) %") }
        if let s = usage.codexSecondary { out.append("\(windowName(s.windowMinutes)): \(Int(s.usedPercent)) %") }
        let today = usage.codex.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.total }
        out.append(L("Heute") + ": \(tokens(Double(today))) Tokens")
        if usage.codexPrimary != nil { out.append(L("Limits direkt von OpenAI")) }
        return out
    }

    private func windowName(_ m: Int) -> String { m >= 1440 ? L("Woche") : m > 0 ? "\(m / 60) h" : L("Fenster") }

    private func runsDetail(_ a: AgentKind) -> [String] {
        let week = missions.missions.filter { $0.agent == a.rawValue && $0.started > Date().addingTimeInterval(-7 * 86400) }
        return ["\(week.count) " + L("Aufträge in 7 Tagen"), L("Kein Token-Protokoll – Limits werden aus Fehlermeldungen erkannt")]
    }

    // MARK: Verlauf

    private var chartData: [DayModel] {
        var sums: [String: [Date: Double]] = [:]
        for p in usage.claude + usage.codex {
            let day = Calendar.current.startOfDay(for: p.date)
            sums[short(p.model), default: [:]][day, default: 0] += Double(p.input + p.output + p.cacheWrite)
        }
        return sums.flatMap { m, days in days.map { DayModel(day: $0.key, model: m, tokens: $0.value / 1_000_000) } }
            .sorted { $0.day < $1.day }
    }

    private func short(_ model: String) -> String {
        let m = model.lowercased()
        if m.contains("opus") { return "Claude Opus" }
        if m.contains("sonnet") { return "Claude Sonnet" }
        if m.contains("haiku") { return "Claude Haiku" }
        if m.hasPrefix("claude") { return "Claude" }
        return model.replacingOccurrences(of: "-", with: " ").capitalized
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: Grid.s) {
            Text("Tokens pro Tag und Modell (ohne Cache-Lesen, in Mio.)").font(.headline)
            if chartData.isEmpty {
                Text("Noch keine Verlaufsdaten gefunden.").foregroundStyle(.secondary)
            } else {
                Chart(chartData) { d in
                    BarMark(x: .value("Tag", d.day, unit: .day), y: .value("Mio. Tokens", d.tokens))
                        .foregroundStyle(by: .value("Modell", d.model))
                        .cornerRadius(3)
                }
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
                .frame(height: 220)
            }
        }
        .padding(Grid.l)
        .background(ModernCardBackground(radius: 16))
    }

    private var modelTable: some View {
        let all = usage.claude + usage.codex
        let models = Dictionary(grouping: all, by: { short($0.model) })
        let rows = models.map { (m, pts) -> (String, Double, Double) in
            let today = pts.filter { Calendar.current.isDateInToday($0.date) }.reduce(0.0) { $0 + Double($1.input + $1.output + $1.cacheWrite) }
            let week = pts.reduce(0.0) { $0 + Double($1.input + $1.output + $1.cacheWrite) }
            return (m, today, week)
        }.sorted { $0.2 > $1.2 }
        let maxWeek = rows.map(\.2).max() ?? 1
        return VStack(alignment: .leading, spacing: Grid.s) {
            Text("Modelle").font(.headline)
            ForEach(rows, id: \.0) { r in
                HStack {
                    Text(r.0).font(.callout).frame(width: 130, alignment: .leading)
                    GeometryReader { g in
                        Capsule().fill(Color.accentColor.opacity(0.7)).frame(width: max(4, g.size.width * r.2 / maxWeek), height: 8)
                            .frame(maxHeight: .infinity)
                    }
                    .frame(height: 14)
                    Text(L("heute") + " \(tokens(r.1))").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                    Text("7 T \(tokens(r.2))").font(.caption.monospacedDigit()).frame(width: 80, alignment: .trailing)
                }
            }
            if rows.isEmpty { Text("Keine Daten").foregroundStyle(.secondary) }
        }
        .padding(Grid.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ModernCardBackground(radius: 16))
    }

    /// Wie gut lief es pro Agent (30 Tage) – dieselben Zahlen nutzt die Agentenwahl.
    private var qualityTable: some View {
        let stats = Learning.stats(missions.missions)
        return VStack(alignment: .leading, spacing: Grid.s) {
            Text("Erfolg pro Agent (30 Tage)").font(.headline)
            ForEach(stats, id: \.agent) { s in
                HStack {
                    Text(s.title).font(.callout).frame(width: 110, alignment: .leading)
                    Text("\(s.runs) " + L("Läufe")).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                    ProgressView(value: s.rate).tint(pressureColor(1 - s.rate))
                    Text("\(Int(s.rate * 100)) %").font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
                }
            }
            if stats.isEmpty { Text("Noch keine abgeschlossenen Aufträge.").foregroundStyle(.secondary) }
        }
        .padding(Grid.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ModernCardBackground(radius: 16))
    }

    private var switchesCard: some View {
        VStack(alignment: .leading, spacing: Grid.s) {
            Text("Automatische Wechsel").font(.headline)
            if usage.switches.isEmpty {
                Text("Noch keine – alle Agents hatten genug Kontingent.").foregroundStyle(.secondary)
            }
            ForEach(usage.switches.prefix(8)) { s in
                HStack {
                    Text(s.date.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text("\(s.from) → \(s.to)").font(.callout.weight(.medium))
                    Text(s.why).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(Grid.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ModernCardBackground(radius: 16))
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: Grid.s) {
            Text("Einstellungen").font(.headline)
            Picker("Dein Claude-Abo", selection: $plan) {
                ForEach(Usage.plans, id: \.id) { Text($0.title).tag($0.id) }
            }
            .fixedSize()
            Toggle("Automatisch auf andere Agents verteilen, wenn es eng wird", isOn: $autoSwitch)
            HStack {
                Text("Ab wann „eng“:")
                Slider(value: $threshold, in: 0.5...0.95, step: 0.05).frame(width: 200)
                Text("\(Int(threshold * 100)) %").monospacedDigit()
            }
            HStack {
                Text("Claude-Limits sind nicht öffentlich: Salenta Code schätzt sie nach Abo und lernt dein echtes Limit, sobald einmal eins erreicht wird.")
                    .font(.caption).foregroundStyle(.secondary)
                if usage.calibrated5h != nil { Button("Kalibrierung zurücksetzen") { usage.resetCalibration() }.font(.caption) }
            }
        }
        .padding(Grid.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ModernCardBackground(radius: 16))
    }
}

/// Eintrag in der Seitenleiste: färbt sich, wenn ein Agent knapp wird.
struct UsageSidebarLabel: View {
    @ObservedObject private var usage = Usage.shared
    var body: some View {
        let p = max(usage.pressure(.claude), usage.pressure(.codex))
        Label {
            HStack {
                Text("Verbrauch")
                Spacer()
                if p >= 0.6 { Circle().fill(pressureColor(p)).frame(width: 7, height: 7) }
            }
        } icon: { Image(systemName: "gauge.with.dots.needle.50percent") }
    }
}


/// Verbrauch › Lokal statt Cloud: wie viele Aufträge das lokale Modell erledigt hat und was das ungefähr gespart hat.
struct LocalSavingsCard: View {
    @ObservedObject private var local = LocalFirst.shared
    @AppStorage("local.only") private var localOnly = false
    @State private var stats = LocalStats()

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.s) {
            HStack {
                Label(L("Lokal statt Cloud"), systemImage: "laptopcomputer").font(.headline)
                if localOnly { Text(L("Nur lokal an")).font(.caption.weight(.semibold)).foregroundStyle(.green) }
                Spacer()
                Text(L("seit ") + stats.since.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                Button { LocalStats.reset(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { stats = LocalStats.current } } label: {
                    Label(L("Zählung zurücksetzen"), systemImage: "arrow.counterclockwise").labelStyle(.iconOnly)
                }.buttonStyle(.borderless).help(L("Zählung zurücksetzen"))
            }
            if !local.ready {
                Text(L("Noch kein lokales Modell – unter Einstellungen › Modelle eins laden, dann laufen kleine Aufgaben kostenlos auf deinem Mac."))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: Grid.xl) {
                    stat("\(stats.runs)", L("Aufträge lokal"))
                    stat(stats.runs == 0 ? "–" : "\(Int((Double(stats.ok) / Double(max(stats.runs, 1)) * 100).rounded())) %", L("ohne Fehler fertig"))
                    stat("\(stats.fallbacks)", L("Claude musste übernehmen"))
                    stat(stats.tokens == 0 ? "–" : "≥ " + Self.compact(stats.tokens), L("Tokens nicht in der Cloud"))
                }
                Text(L("Gezählt werden Aufträge, die mit dem lokalen Modell liefen (klein, offline oder „Nur lokal“). Die Token-Zahl ist eine untere Schätzung."))
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(Grid.l)
        .background(ModernCardBackground(radius: 16))
        .onAppear { stats = LocalStats.current }
    }

    private func stat(_ v: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(v).font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    static func compact(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1f Mio.", Double(n) / 1_000_000) : n >= 1000 ? "\(n / 1000)k" : "\(n)"
    }
}

// MARK: - Kosten-Verlauf pro Tag (für die Übersicht: Heatmap, Monat, Hochrechnung)

struct DayCost: Codable, Hashable {
    var claude: Double = 0
    var codex: Double = 0
    var calls: Int = 0
    var input: Int = 0
    var cacheRead: Int = 0
    var total: Double { claude + codex }
}

final class CostHistory: ObservableObject {
    static let shared = CostHistory()
    @Published private(set) var days: [String: DayCost] = [:]
    @Published private(set) var backfilling = false
    private var url: URL { Paths.data.appendingPathComponent("cost-days.json") }

    static func key(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    init() {
        if let d = try? Data(contentsOf: url), let x = try? JSONDecoder().decode([String: DayCost].self, from: d) { days = x }
    }

    /// Die letzten Tage aus dem laufenden Verbrauchs-Scan übernehmen (überschreibt nur diese Tage).
    func merge(claude: [UsagePoint], codex: [UsagePoint]) {
        let fresh = Self.aggregate(claude: claude, codex: codex)
        guard !fresh.isEmpty else { return }
        var d = days
        let cut = Self.key(Date().addingTimeInterval(-7 * 86400))   // der älteste Tag im Scan ist nur halb drin
        for (k, v) in fresh where k > cut { d[k] = v }
        days = d
        save()
    }

    /// Einmalig den älteren Verlauf einlesen (bis 95 Tage) – im Hintergrund, mit niedriger Priorität.
    func backfillIfNeeded() {
        guard !backfilling, UserDefaults.standard.bool(forKey: "cost.backfilled") == false else { return }
        backfilling = true
        DispatchQueue.global(qos: .utility).async {
            let (c, x) = Usage.readHistory(days: 95)
            let agg = Self.aggregate(claude: c, codex: x)
            DispatchQueue.main.async {
                var d = self.days
                for (k, v) in agg where d[k] == nil || k < Self.key(Date().addingTimeInterval(-7 * 86400)) { d[k] = v }
                self.days = d
                self.save()
                self.backfilling = false
                UserDefaults.standard.set(true, forKey: "cost.backfilled")
            }
        }
    }

    private static func aggregate(claude: [UsagePoint], codex: [UsagePoint]) -> [String: DayCost] {
        let t = Prices.table
        var out: [String: DayCost] = [:]
        for p in claude {
            let k = key(p.date)
            out[k, default: DayCost()].claude += Prices.cost(p, Prices.price(p.model, t))
            out[k, default: DayCost()].calls += 1
            out[k, default: DayCost()].input += p.input + p.cacheWrite
            out[k, default: DayCost()].cacheRead += p.cacheRead
        }
        for p in codex {
            let k = key(p.date)
            out[k, default: DayCost()].codex += Prices.cost(p, Prices.price(p.model.isEmpty ? "gpt" : p.model, t))
            out[k, default: DayCost()].calls += 1
            out[k, default: DayCost()].input += p.input + p.cacheWrite
            out[k, default: DayCost()].cacheRead += p.cacheRead
        }
        return out
    }

    private func save() {
        if let d = try? JSONEncoder().encode(days) { try? d.write(to: url, options: .atomic) }
    }
}

extension Usage {
    /// Liest den Verlauf ohne Zwischenspeicher (nur für das einmalige Nachladen älterer Tage).
    static func readHistory(days: Int) -> ([UsagePoint], [UsagePoint]) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let since = Date().addingTimeInterval(-Double(days) * 86400)
        var claude: [UsagePoint] = [], codex: [UsagePoint] = []
        var seen = Set<String>()
        for url in files(under: home.appendingPathComponent(".claude/projects"), since: since) {
            guard let s = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in s.split(separator: "\n") {
                if let p = parseClaude(String(line)).0, p.date >= since, seen.insert(p.id).inserted { claude.append(p) }
            }
        }
        for url in files(under: home.appendingPathComponent(".codex/sessions"), since: since) {
            guard let s = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var model = ""
            for line in s.split(separator: "\n") {
                let (p, m, _) = parseCodex(String(line), model: model)
                if let m { model = m }
                if let p, p.date >= since { codex.append(p) }
            }
        }
        return (claude, codex)
    }
}


// MARK: - Echte Claude-Limits (wie in der Claude-App) – nur auf deinen Wunsch

extension Usage {
    static var claudeRealEnabled: Bool { UserDefaults.standard.bool(forKey: "usage.claudeReal") }

    /// Liest den Stand deiner Claude-Limits (5 Stunden, Woche) direkt bei Claude ab. Der Anmelde-Schlüssel kommt aus dem
    /// macOS-Schlüsselbund (dort legt Claude Code ihn ab), wird nur für diese eine Anfrage benutzt und nirgends gespeichert.
    func fetchClaudeReal(force: Bool = false) {
        guard Self.claudeRealEnabled else { return }
        if !force, let at = claudeRealAt, at > Date().addingTimeInterval(-5 * 60) { return }
        DispatchQueue.global(qos: .utility).async {
            let r = Proc.zsh("/usr/bin/security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null", in: NSTemporaryDirectory(), timeout: 30)
            guard r.code == 0, let d = r.out.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let o = j["claudeAiOauth"] as? [String: Any], let tok = o["accessToken"] as? String, !tok.isEmpty else { return }
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 20)
            req.setValue("Bearer " + tok, forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                guard (resp as? HTTPURLResponse)?.statusCode == 200, let data,
                      let u = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let iso2 = ISO8601DateFormatter()
                func win(_ k: String, minutes: Int) -> RateWindow? {
                    guard let w = u[k] as? [String: Any] else { return nil }
                    let used = (w["utilization"] as? Double) ?? Double(w["utilization"] as? Int ?? -1)
                    guard used >= 0 else { return nil }
                    let s = w["resets_at"] as? String ?? ""
                    return RateWindow(usedPercent: used, windowMinutes: minutes, resetsAt: iso.date(from: s) ?? iso2.date(from: s))
                }
                let five = win("five_hour", minutes: 300), week = win("seven_day", minutes: 10_080)
                guard five != nil || week != nil else { return }
                DispatchQueue.main.async {
                    self.claudeFive = five; self.claudeWeek = week; self.claudeRealAt = Date()
                    self.saveState()
                    self.refreshSnapshot()
                }
            }.resume()
        }
    }
}
