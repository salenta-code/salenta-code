import Foundation

/// Übersetzt einen deutschen UI-Text (Schlüssel) – Englisch steht in en.lproj/Localizable.strings.
public func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

// Das Aufgaben-Modell. Gespeichert als ~/Salenta Code/data/tasks.json.
// Claude Code und Codex lesen und schreiben dieselbe Datei,
// darum ist das Decoding tolerant: fehlende Felder bekommen Standardwerte,
// Datum geht als "2026-11-05" oder als volles ISO-8601.

/// Ein Bereich (z. B. Firma, Projekt, Privat). Frei definierbar in den Einstellungen, gespeichert in data/areas.json.
public struct AreaDef: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var hex: UInt32
    public var symbol: String
    public var tags: [String]
    /// Ordner- oder Stichwörter, an denen Salenta Code den Bereich erkennt (z. B. Repo-Namen).
    public var keywords: [String]

    public init(id: String, title: String, hex: UInt32, symbol: String, tags: [String] = [], keywords: [String] = []) {
        self.id = id; self.title = title; self.hex = hex; self.symbol = symbol; self.tags = tags; self.keywords = keywords
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? id.capitalized
        hex = (try? c.decode(UInt32.self, forKey: .hex)) ?? 0x7C7C84
        symbol = (try? c.decode(String.self, forKey: .symbol)) ?? "folder"
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        keywords = (try? c.decode([String].self, forKey: .keywords)) ?? []
    }
}

/// Die aktuell definierten Bereiche. Die App lädt sie beim Start aus data/areas.json.
public enum AreaRegistry {
    public static let fallback: [AreaDef] = [
        AreaDef(id: "privat", title: "Privat", hex: 0x7C7C84, symbol: "person", tags: ["privat", "personal", "home"]),
        AreaDef(id: "arbeit", title: "Arbeit", hex: 0x0A84FF, symbol: "briefcase", tags: ["arbeit", "work", "job"]),
    ]
    public static var areas: [AreaDef] = fallback

    public static func def(_ id: String) -> AreaDef? { areas.first { $0.id == id } }
}

/// Bereich einer Aufgabe. Der Name `Company` bleibt aus Kompatibilität (tasks.json-Feld "company").
public struct Company: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    public let rawValue: String

    /// Nur bekannte Bereiche (für Auswahlfelder).
    public init?(rawValue: String) {
        guard AreaRegistry.def(rawValue) != nil else { return nil }
        self.rawValue = rawValue
    }

    /// Ohne Prüfung (für gespeicherte Daten aus älteren Konfigurationen).
    public init(unchecked raw: String) { rawValue = raw }

    public static let privat = Company(unchecked: "privat")
    public static var allCases: [Company] { AreaRegistry.areas.map { Company(unchecked: $0.id) } }

    public var id: String { rawValue }
    private var def: AreaDef? { AreaRegistry.def(rawValue) }
    public var title: String { def?.title ?? rawValue.capitalized }
    /// Farbe als 0xRRGGBB.
    public var hex: UInt32 { def?.hex ?? 0x7C7C84 }
    public var symbol: String { def?.symbol ?? "folder" }
    /// Kürzel für Quick-Capture (#privat, #arbeit …).
    public var tags: [String] { def?.tags ?? [] }
    public var keywords: [String] { def?.keywords ?? [] }

    public static func from(tag: String) -> Company? {
        let t = tag.lowercased()
        return allCases.first { $0.rawValue == t || $0.tags.contains(t) || $0.title.lowercased() == t }
    }

    /// Bereich, dessen Stichwörter oder Name im Text vorkommen.
    public static func match(in text: String) -> Company? {
        let t = text.lowercased()
        return allCases.first { c in
            c.rawValue != "privat" && ([c.title.lowercased(), c.rawValue] + c.tags + c.keywords).contains { $0.count >= 3 && t.contains($0.lowercased()) }
        }
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

public enum TaskStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case inbox, heute, woche, warten, erledigt

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .inbox: L("Inbox")
        case .heute: L("Heute")
        case .woche: L("Diese Woche")
        case .warten: L("Wartet / Agent")
        case .erledigt: L("Erledigt")
        }
    }

    public var symbol: String {
        switch self {
        case .inbox: "tray"
        case .heute: "sun.max"
        case .woche: "calendar"
        case .warten: "hourglass"
        case .erledigt: "checkmark.circle"
        }
    }
}

public enum Priority: Int, Codable, CaseIterable, Identifiable, Comparable, Sendable {
    case niedrig = 0, normal = 1, hoch = 2

    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .niedrig: L("Niedrig")
        case .normal: L("Normal")
        case .hoch: L("Hoch")
        }
    }

    public static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
}

public enum AgentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex, junie, shell
    // Weitere Coding-Agents: Cursor, OpenCode, Gemini, Grok Build, Kiro, Pi
    case cursor, opencode, gemini, grok, kiro, pi, kimi
    // DeepSeek Harness (CLI „dsh“) – DeepSeeks eigener Agent mit DeepSeek-Modellen
    case deepseek
    // Salenta Harness – der eigene Agent von Salenta Code (bin/salenta-harness), mit DeepSeek, Claude, OpenAI, OpenRouter oder lokal
    case harness
    // Open-Source-Modelle (Qwen, DeepSeek, Kimi, GLM …) mit Claude Code als Werkzeug: über OpenRouter oder lokal mit Ollama
    case openrouter, ollama

    /// Welches Programm wirklich läuft (OpenRouter/Ollama nutzen Claude Code mit anderem Modell-Server).
    public var harness: AgentKind { self == .openrouter || self == .ollama ? .claude : self }

    public var id: String { rawValue }

    /// Ältere Einträge können Agents nennen, die es nicht mehr gibt – dann Claude Code.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentKind(rawValue: raw) ?? .claude
    }

    /// Agents, die selbstständig in einem Repo programmieren können.
    public static let coders: [AgentKind] = [.claude, .codex, .junie, .cursor, .opencode, .gemini, .grok, .kiro, .pi, .kimi, .deepseek, .harness, .openrouter, .ollama]

    public var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .junie: "Junie"
        case .shell: "Terminal"
        case .cursor: "Cursor"
        case .opencode: "OpenCode"
        case .gemini: "Gemini CLI"
        case .grok: "Grok Build"
        case .kiro: "Kiro"
        case .pi: "Pi"
        case .kimi: "Kimi Code"
        case .deepseek: "DeepSeek Harness"
        case .harness: "Salenta Harness"
        case .openrouter: "OpenRouter"
        case .ollama: "Ollama (lokal)"
        }
    }

    /// Name des CLI-Befehls.
    public var command: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .junie: "junie"
        case .shell: "zsh"
        case .cursor: "cursor-agent"
        case .opencode: "opencode"
        case .gemini: "gemini"
        case .grok: "grok"
        case .kiro: "kiro-cli"
        case .pi: "pi"
        case .kimi: "kimi"
        case .deepseek: "dsh"
        case .harness: "salenta-harness"
        case .openrouter: "claude"
        case .ollama: "ollama"
        }
    }

    public var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .junie: "j.square"
        case .shell: "terminal"
        case .cursor: "cursorarrow.rays"
        case .opencode: "curlybraces.square"
        case .gemini: "diamond"
        case .grok: "atom"
        case .kiro: "k.square"
        case .pi: "p.square"
        case .kimi: "moon.stars"
        case .deepseek: "water.waves"
        case .harness: "bolt.horizontal.circle"
        case .openrouter: "globe"
        case .ollama: "desktopcomputer"
        }
    }

    public var installHint: String {
        switch self {
        case .claude: "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: "npm i -g @openai/codex"
        case .junie: "curl -fsSL https://junie.jetbrains.com/install.sh | bash"
        case .shell: ""
        case .cursor: "curl https://cursor.com/install -fsS | bash"
        case .opencode: "curl -fsSL https://opencode.ai/install | bash"
        case .gemini: "npm i -g @google/gemini-cli"
        case .grok: "Installation: x.ai/cli (Grok Build)"
        case .kiro: "curl -fsSL https://cli.kiro.dev/install | bash"
        case .pi: "npm i -g @mariozechner/pi-coding-agent"
        case .kimi: "curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash"
        case .deepseek: "npm i -g @deepseek-ai/dsh"
        case .harness: "Mitgeliefert – braucht Node.js (brew install node) und einen Modell-Schlüssel (Einstellungen › Modelle) oder Ollama"
        case .openrouter: "Schlüssel von openrouter.ai/keys in Einstellungen › Modelle eintragen"
        case .ollama: "brew install ollama && ollama pull qwen3-coder"
        }
    }

    /// Einmal anmelden (im Terminal).
    public var loginHint: String {
        switch self {
        case .claude: "claude auth login"
        case .codex: "codex login"
        case .junie: "junie (beim ersten Start mit JetBrains-Konto anmelden)"
        case .cursor: "cursor-agent login"
        case .opencode: "opencode auth login"
        case .gemini: "gemini (beim ersten Start mit Google anmelden)"
        case .grok: "grok login"
        case .kiro: "kiro-cli login"
        case .pi: "pi → /login"
        case .kimi: "kimi → /login"
        case .deepseek: "dsh web → Einstellungen › Modelle (DeepSeek-Schlüssel)"
        case .harness: "Einstellungen › Modelle: DeepSeek-, Anthropic-, OpenAI- oder OpenRouter-Schlüssel eintragen"
        default: ""
        }
    }

    /// Wofür der Agent am besten taugt (für die automatische Wahl).
    public var strength: String {
        switch self {
        case .claude: "build features, refactor, larger code changes, new files"
        case .codex: "code review, double-checking a diff, writing tests, second opinion"
        case .junie: "debugging, find the root cause of a bug and fix it, failing tests"
        case .cursor: "fast edits and features with Cursor's models, good for frontend/UI work"
        case .opencode: "open-source agent with any model provider – good fallback when others are at their limit"
        case .gemini: "Google Gemini – huge context, large codebases, reading many files, docs"
        case .grok: "xAI Grok Build – parallel coding, quick implementation tasks"
        case .kiro: "AWS Kiro – spec-driven development, AWS/infrastructure work"
        case .pi: "minimal agent, small focused tasks"
        case .kimi: "Moonshot Kimi Code – strong, inexpensive agentic coding with Kimi models, long tasks, frontend and visual coding; good fallback when Claude/Codex are at their limit"
        case .deepseek: "DeepSeek Harness – DeepSeek's own agent with DeepSeek models; inexpensive, good at coding and long multi-step tasks, can split work into sub-agents; pay per use via DeepSeek API"
        case .harness: "Salenta Harness – Salenta's own agent: plans, delegates read-only research to parallel sub-agents, enforces access levels, always runs the project checks before finishing; runs on your Claude or Codex subscription (no key, no extra cost), or on DeepSeek, OpenAI, OpenRouter or a local model"
        case .openrouter: "Claude Code with open-source models via OpenRouter (Qwen, DeepSeek, Kimi, GLM) – pay per use, cheap, good when subscriptions are at their limit"
        case .ollama: "Claude Code with a local open-source model (Ollama) – free and private, but slower and weaker; small tasks only"
        case .shell: ""
        }
    }
}

public struct TaskItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var notes: String
    public var company: Company
    public var status: TaskStatus
    public var priority: Priority
    public var due: Date?
    public var agent: AgentKind?
    public var createdAt: Date
    public var doneAt: Date?
    /// Wer die Aufgabe angelegt hat: "app", "claude", "codex" …
    public var source: String

    public init(id: String = TaskItem.newID(), title: String, notes: String = "",
                company: Company = .privat, status: TaskStatus = .inbox,
                priority: Priority = .normal, due: Date? = nil, agent: AgentKind? = nil,
                createdAt: Date = Date(), doneAt: Date? = nil, source: String = "app") {
        self.id = id
        self.title = title
        self.notes = notes
        self.company = company
        self.status = status
        self.priority = priority
        self.due = due
        self.agent = agent
        self.createdAt = createdAt
        self.doneAt = doneAt
        self.source = source
    }

    public static func newID() -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return "t-" + String((0..<6).map { _ in chars.randomElement()! })
    }

    public var isDone: Bool { status == .erledigt }

    public func isOverdue(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let due, !isDone else { return false }
        return calendar.startOfDay(for: due) < calendar.startOfDay(for: now)
    }

    public func isDueToday(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let due, !isDone else { return false }
        return calendar.isDate(due, inSameDayAs: now)
    }
}

extension TaskItem: Codable {
    enum CodingKeys: String, CodingKey {
        case id, title, notes, company, status, priority, due, agent, createdAt, doneAt, source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? TaskItem.newID()
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "Ohne Titel"
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? ""
        let companyRaw = (try? c.decodeIfPresent(String.self, forKey: .company))
        company = companyRaw.map { Company.from(tag: $0) ?? Company(unchecked: $0.lowercased()) } ?? .privat
        let statusRaw = (try? c.decodeIfPresent(String.self, forKey: .status))
        status = statusRaw.flatMap { TaskStatus(rawValue: $0.lowercased()) } ?? .inbox
        if let p = (try? c.decodeIfPresent(Int.self, forKey: .priority)) {
            priority = Priority(rawValue: max(0, min(2, p))) ?? .normal
        } else if let s = (try? c.decodeIfPresent(String.self, forKey: .priority)) {
            switch s.lowercased() {
            case "hoch", "high", "2": priority = .hoch
            case "niedrig", "low", "0": priority = .niedrig
            default: priority = .normal
            }
        } else {
            priority = .normal
        }
        due = DateCoding.parse((try? c.decodeIfPresent(String.self, forKey: .due)))
        let agentRaw = (try? c.decodeIfPresent(String.self, forKey: .agent))
        agent = agentRaw.flatMap { AgentKind(rawValue: $0.lowercased()) }
        createdAt = DateCoding.parse((try? c.decodeIfPresent(String.self, forKey: .createdAt))) ?? Date()
        doneAt = DateCoding.parse((try? c.decodeIfPresent(String.self, forKey: .doneAt)))
        source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? "extern"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(notes, forKey: .notes)
        try c.encode(company.rawValue, forKey: .company)
        try c.encode(status.rawValue, forKey: .status)
        try c.encode(priority.rawValue, forKey: .priority)
        try c.encodeIfPresent(due.map(DateCoding.day), forKey: .due)
        try c.encodeIfPresent(agent?.rawValue, forKey: .agent)
        try c.encode(DateCoding.stamp(createdAt), forKey: .createdAt)
        try c.encodeIfPresent(doneAt.map(DateCoding.stamp), forKey: .doneAt)
        try c.encode(source, forKey: .source)
    }
}

/// Die Datei: {"version": 1, "tasks": [...]}. Eine nackte Liste geht auch.
public struct TaskFile: Codable, Sendable {
    public var version: Int
    public var tasks: [TaskItem]

    public init(tasks: [TaskItem]) {
        self.version = 1
        self.tasks = tasks
    }

    public static func decode(_ data: Data) throws -> TaskFile {
        if let file = try? JSONDecoder().decode(TaskFile.self, from: data) { return file }
        let list = try JSONDecoder().decode([TaskItem].self, from: data)
        return TaskFile(tasks: list)
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(self)
    }
}

public enum DateCoding {
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func day(_ date: Date) -> String { dayFormatter.string(from: date) }

    public static func stamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return f.string(from: date)
    }

    public static func parse(_ string: String?) -> Date? {
        guard let s = string?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.count == 10, let d = dayFormatter.date(from: s) { return d }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        if s.count >= 10, let d = dayFormatter.date(from: String(s.prefix(10))) { return d }
        return nil
    }
}
