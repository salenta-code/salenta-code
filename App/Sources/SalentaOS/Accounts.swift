import AgenticOSKit
import SwiftUI

// Mehrere Abos pro Anbieter (z. B. 3× Codex, 2× Claude).
// Das Hauptkonto bleibt, wie es ist (~/.claude bzw. ~/.codex) – nichts abmelden.
// Jedes weitere Konto bekommt einen eigenen Ordner (CLAUDE_CONFIG_DIR / CODEX_HOME) und wird dort einmal angemeldet.
// Ist ein Konto im Limit oder fast voll, wechselt Salenta Code von selbst zum nächsten freien Konto desselben Anbieters.

struct AgentAccount: Codable, Identifiable, Hashable {
    var id = String(UUID().uuidString.prefix(6)).lowercased()
    var agent: String            // "claude" | "codex"
    var name: String
    var limitedUntil: Date? = nil
}

final class Accounts: ObservableObject {
    static let shared = Accounts()
    static let supported: [AgentKind] = [.claude, .codex]

    @Published private(set) var extra: [AgentAccount] = []
    /// Aktives Konto je Anbieter ("" = Hauptkonto)
    @Published private(set) var active: [String: String] = [:]
    @Published private(set) var mainLimitedUntil: [String: Date] = [:]

    private struct State: Codable { var extra: [AgentAccount]; var active: [String: String]; var mainLimitedUntil: [String: Date]? }
    private var url: URL { Paths.data.appendingPathComponent("accounts.json") }
    private let lock = NSLock()
    private var snapEnv: [String: String] = [:]

    init() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: url), let s = try? dec.decode(State.self, from: d) {
            extra = s.extra; active = s.active; mainLimitedUntil = s.mainLimitedUntil ?? [:]
        }
        refreshEnv()
    }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        if let d = try? enc.encode(State(extra: extra, active: active, mainLimitedUntil: mainLimitedUntil)) { try? d.write(to: url, options: .atomic) }
        refreshEnv()
    }

    static func dir(_ a: AgentAccount) -> String {
        let d = Paths.data.appendingPathComponent("accounts/\(a.agent)-\(a.id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.path
    }
    static func envName(_ agent: String) -> String { agent == "codex" ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR" }

    func accounts(_ k: AgentKind) -> [AgentAccount] { extra.filter { $0.agent == k.rawValue } }
    func activeAccount(_ k: AgentKind) -> AgentAccount? {
        guard let id = active[k.rawValue], !id.isEmpty else { return nil }
        return extra.first { $0.id == id && $0.agent == k.rawValue }
    }
    func activeName(_ k: AgentKind) -> String { activeAccount(k)?.name ?? L("Hauptkonto") }

    /// Umgebung für alle Agent-Aufrufe (thread-sicher): nur gesetzt, wenn ein Zusatzkonto aktiv ist.
    func env() -> [String: String] { lock.lock(); defer { lock.unlock() }; return snapEnv }
    func exports() -> String { env().map { "export \($0.key)=\(Shell.quote($0.value)); " }.sorted().joined() }

    private func refreshEnv() {
        var e: [String: String] = [:]
        for k in Self.supported { if let a = activeAccount(k) { e[Self.envName(k.rawValue)] = Self.dir(a) } }
        lock.lock(); snapEnv = e; lock.unlock()
    }

    func add(_ k: AgentKind) {
        let n = accounts(k).count + 2
        let a = AgentAccount(agent: k.rawValue, name: String(format: L("Konto %d"), n))
        extra.append(a); save()
        login(a)
    }
    func remove(_ a: AgentAccount) {
        extra.removeAll { $0.id == a.id }
        if active[a.agent] == a.id { active[a.agent] = "" }
        save()
    }
    func use(_ k: AgentKind, _ a: AgentAccount?) { active[k.rawValue] = a?.id ?? ""; save() }

    /// Einmal im Terminal anmelden – nur für diesen Konto-Ordner, das Hauptkonto bleibt angemeldet.
    func login(_ a: AgentAccount) {
        let d = Shell.quote(Self.dir(a))
        let done = L("✓ Fertig – zurück zu Salenta Code.")
        if a.agent == "codex" {
            Detection.runInTerminal("CODEX_HOME=\(d) codex login ; echo '\(done)'")
        } else {
            Detection.runInTerminal("echo '\(L("Im Claude-Fenster /login eingeben, mit dem zweiten Abo anmelden, dann /exit."))'; CLAUDE_CONFIG_DIR=\(d) claude ; echo '\(done)'")
        }
    }

    func isLoggedIn(_ a: AgentAccount) -> Bool {
        let fm = FileManager.default, d = Self.dir(a)
        if a.agent == "codex" { return fm.fileExists(atPath: d + "/auth.json") }
        // Claude legt nach dem Login seine Einstellungen im Ordner an (Zugangsdaten selbst liegen im Schlüsselbund)
        return fm.fileExists(atPath: d + "/.claude.json") || ((try? fm.contentsOfDirectory(atPath: d)) ?? []).contains { $0.hasSuffix(".json") }
    }

    private func free(_ k: AgentKind) -> [String] {
        // Reihenfolge: Hauptkonto, dann Zusatzkonten – nur die nicht im Limit
        var ids: [String] = []
        if (mainLimitedUntil[k.rawValue] ?? .distantPast) <= Date() { ids.append("") }
        ids += accounts(k).filter { ($0.limitedUntil ?? .distantPast) <= Date() && isLoggedIn($0) }.map(\.id)
        return ids
    }

    /// Aktives Konto ist im Limit → nächstes freies Konto nehmen. true = gewechselt (Anbieter bleibt nutzbar).
    @discardableResult
    func rotate(_ k: AgentKind, limitedUntil until: Date) -> Bool {
        guard Self.supported.contains(k), !accounts(k).isEmpty else { return false }
        let cur = active[k.rawValue] ?? ""
        if cur.isEmpty { mainLimitedUntil[k.rawValue] = until }
        else if let i = extra.firstIndex(where: { $0.id == cur }) { extra[i].limitedUntil = until }
        let options = free(k).filter { $0 != cur }
        guard let next = options.first else { save(); return false }
        active[k.rawValue] = next
        save()
        let name = next.isEmpty ? L("Hauptkonto") : (extra.first { $0.id == next }?.name ?? next)
        NotifyCenter.shared.post(.limit, title: "⇄ " + k.title + ": " + name, body: L("Das bisherige Konto ist im Limit – Salenta Code arbeitet mit dem nächsten Abo weiter."), route: .none)
        return true
    }

    /// Gibt es für diesen Anbieter gerade ein freies Zusatzkonto? (dann zählt die Auslastung des Hauptkontos nicht)
    func hasFreeAlternative(_ k: AgentKind) -> Bool { free(k).contains { $0 != (active[k.rawValue] ?? "") } }
}

/// Konten-Liste auf der Verbrauch-Seite (je Anbieter)
struct AccountsSection: View {
    let agent: AgentKind
    @ObservedObject private var accounts = Accounts.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Abos")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            row(nil)
            ForEach(accounts.accounts(agent)) { row($0) }
            Button(L("+ Weiteres Abo verbinden")) { accounts.add(agent) }
                .buttonStyle(.link).font(.caption)
                .help(L("Zweites oder drittes Abo dieses Anbieters anmelden – ist eins im Limit, arbeitet Salenta Code mit dem nächsten weiter"))
        }
    }

    @ViewBuilder private func row(_ a: AgentAccount?) -> some View {
        let isActive = (accounts.active[agent.rawValue] ?? "") == (a?.id ?? "")
        let limited = a.map { ($0.limitedUntil ?? .distantPast) > Date() } ?? ((accounts.mainLimitedUntil[agent.rawValue] ?? .distantPast) > Date())
        HStack(spacing: 6) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle").foregroundStyle(isActive ? .green : .secondary).font(.caption)
            Text(a?.name ?? L("Hauptkonto")).font(.caption)
            if limited { Text(L("im Limit")).font(.caption2).foregroundStyle(.red) }
            if let a, !accounts.isLoggedIn(a) { Text(L("nicht angemeldet")).font(.caption2).foregroundStyle(.orange) }
            Spacer()
            if !isActive {
                Button(L("Nutzen")) { accounts.use(agent, a) }.buttonStyle(.link).font(.caption)
                    .help(L("Ab jetzt dieses Abo verwenden"))
            }
            if let a {
                Button(L("Anmelden")) { accounts.login(a) }.buttonStyle(.link).font(.caption)
                    .help(L("Dieses Abo im Terminal anmelden"))
                Button { accounts.remove(a) } label: { Image(systemName: "trash") }.buttonStyle(.plain).font(.caption)
                    .help(L("Abo aus Salenta Code entfernen"))
            }
        }
    }
}
