import AgenticOSKit
import SwiftUI

// Analytics, die zu Entscheidungen führen: welcher Agent bei welcher Aufgabenart wirklich gut ist,
// wie viel Nacharbeit nötig war und was offen liegt. Rechnet lokal aus den Auftragsdaten.

enum Quality {
    struct Row: Identifiable {
        var id: String { agent + kind.rawValue }
        let agent: String
        let title: String
        let kind: Learning.Kind
        let runs: Int
        let firstTry: Int       // grün beim ersten Versuch
        let taken: Int          // übernommen oder als PR
        let rework: Int         // Folgerunden (Nachbessern, Übergabe)
        var firstTryRate: Int { runs == 0 ? 0 : Int((Double(firstTry) / Double(runs) * 100).rounded()) }
    }

    static func rows(_ missions: [MissionRecord], days: Double = 30) -> [Row] {
        let from = Date().addingTimeInterval(-days * 86400)
        let recent = missions.filter { $0.started >= from && $0.delegated != true && !$0.isOSAgent }
        let children = Dictionary(grouping: missions.compactMap { m in m.parent.map { ($0, m) } }, by: \.0).mapValues(\.count)
        // Nur Ursprungsaufträge zählen (keine Folgerunden), damit „beim ersten Versuch“ stimmt
        let roots = recent.filter { $0.parent == nil && $0.fixRound == nil }
        let grouped = Dictionary(grouping: roots) { m in m.agent + "|" + Learning.kind(of: m.request).rawValue }
        return grouped.compactMap { _, list -> Row? in
            guard let f = list.first else { return nil }
            let first = list.filter { $0.verify?.passed == true || ($0.verify == nil && Learning.score($0) == true) }.count
            let taken = list.filter { $0.outcome == "merged" || $0.outcome == "pr" }.count
            let rework = list.reduce(0) { $0 + (children[$1.id] ?? 0) }
            return Row(agent: f.agent, title: f.agentTitle, kind: Learning.kind(of: f.request), runs: list.count,
                       firstTry: first, taken: taken, rework: rework)
        }
        .filter { $0.runs >= 1 }
        .sorted { ($0.kind.rawValue, -$0.runs) < ($1.kind.rawValue, -$1.runs) }
    }

    static func kindTitle(_ k: Learning.Kind) -> String {
        switch k {
        case .build: return L("Bauen")
        case .debug: return L("Fehler suchen")
        case .review: return L("Review")
        case .other: return L("Sonstiges")
        }
    }

    /// Ein Satz, was daraus folgt – nur wenn es genug Daten gibt.
    static func insight(_ rows: [Row]) -> String? {
        for k in Learning.Kind.allCases {
            let r = rows.filter { $0.kind == k && $0.runs >= 3 }.sorted { $0.firstTryRate > $1.firstTryRate }
            guard r.count >= 2, let best = r.first, let worst = r.last, best.firstTryRate - worst.firstTryRate >= 20 else { continue }
            return String(format: L("Bei „%@“ ist %@ beim ersten Versuch deutlich besser (%d %% statt %d %%) – die Agentenwahl berücksichtigt das."),
                          kindTitle(k), best.title, best.firstTryRate, worst.firstTryRate)
        }
        return nil
    }
}

struct QualityCard: View {
    @ObservedObject private var missions = MissionStore.shared
    @ObservedObject private var watch = Watchman.shared

    var body: some View {
        let rows = Quality.rows(missions.missions)
        if !rows.isEmpty {
            Card(title: L("Trefferquote – letzte 30 Tage"), symbol: "scope") {
                SwiftUI.Grid(alignment: .leading, horizontalSpacing: Grid.m, verticalSpacing: 6) {
                    GridRow {
                        Text("Agent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text("Art").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text("Aufträge").font(.caption.weight(.semibold)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text("Grün beim 1. Versuch").font(.caption.weight(.semibold)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text("Nacharbeit").font(.caption.weight(.semibold)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text("Übernommen").font(.caption.weight(.semibold)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    }
                    ForEach(rows.prefix(8)) { r in
                        GridRow {
                            Text(r.title).font(.callout).lineLimit(1)
                            Text(Quality.kindTitle(r.kind)).font(.callout).foregroundStyle(.secondary)
                            Text("\(r.runs)").font(.callout.monospacedDigit())
                            Text("\(r.firstTryRate) %").font(.callout.monospacedDigit())
                                .foregroundStyle(r.firstTryRate >= 70 ? .green : r.firstTryRate >= 40 ? .orange : .red)
                            Text("\(r.rework)").font(.callout.monospacedDigit()).foregroundStyle(r.rework > r.runs ? .orange : .primary)
                            Text("\(r.taken)").font(.callout.monospacedDigit())
                        }
                    }
                }
                if let s = Quality.insight(rows) {
                    Label(s, systemImage: "lightbulb").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Nacharbeit = Folgerunden zum Nachbessern oder Übergeben. Viel Nacharbeit heißt meist: Auftrag genauer beschreiben.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                if !watch.resume.isEmpty {
                    Text(String(format: L("%d offene Schleifen – siehe „Hier könntest du weitermachen“."), watch.resume.count))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Agents im Vergleich: was jeder Agent in Salenta Code kann

struct AgentCapabilities: View {
    enum Level { case full, partial, none }
    struct Cap { let title: String; let help: String }

    static let caps: [Cap] = [
        Cap(title: L("Live-Schritte"), help: L("Gedanken, Dateien und Befehle als lesbare Schritte statt Terminal")),
        Cap(title: L("Fragen"), help: L("Nur lesen und antworten, ohne etwas zu ändern")),
        Cap(title: L("Freigaben"), help: L("Riskante Schritte warten auf dich in Salenta Code")),
        Cap(title: L("Eigene Kopie"), help: L("Arbeitet in einer Arbeitskopie, dein Projekt bleibt unberührt")),
        Cap(title: L("Prüfschleife"), help: L("Build, Tests und Review nach jedem Auftrag")),
        Cap(title: L("Verbrauch"), help: L("Genaue Anzeige von Verbrauch und Limit")),
        Cap(title: L("Modellwahl"), help: L("Dein gewähltes Modell gilt immer")),
        Cap(title: L("Übergabe"), help: L("Auftrag samt Verlauf an einen anderen Agent geben")),
    ]

    /// Stand im Code (Agents.swift, Verifier, Usage): ehrlich, auch wo es noch fehlt.
    static func level(_ a: AgentKind, _ i: Int) -> Level {
        let structured: Set<AgentKind> = [.claude, .codex, .cursor, .gemini, .opencode]
        switch i {
        case 0: return structured.contains(a) ? .full : .partial          // andere: Textausgabe, lesbar aufbereitet
        case 1: return [.claude, .codex].contains(a) ? .full : .partial   // andere: Fragen gehen an Claude Code
        case 2: return a == .claude ? .full : a == .codex ? .partial : .none
        case 3, 4, 6, 7: return .full
        case 5: return [.claude, .codex].contains(a) ? .full : .none
        default: return .none
        }
    }

    var body: some View {
        let installed = AgentKind.coders.filter { OpenModels.available($0) }
        Section("Agents im Vergleich") {
            if installed.isEmpty {
                Text("Noch kein Coding-Agent installiert.").foregroundStyle(.secondary)
            } else {
                SwiftUI.Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        Text("")
                        ForEach(Array(Self.caps.enumerated()), id: \.offset) { _, c in
                            Text(c.title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).help(c.help)
                        }
                    }
                    ForEach(installed, id: \.self) { a in
                        GridRow {
                            Text(a.title).font(.callout)
                            ForEach(0..<Self.caps.count, id: \.self) { i in
                                let l = Self.level(a, i)
                                Image(systemName: l == .full ? "checkmark.circle.fill" : l == .partial ? "circle.lefthalf.filled" : "minus.circle")
                                    .foregroundStyle(l == .full ? .green : l == .partial ? .orange : .secondary)
                                    .help(l == .partial ? L("teilweise") : l == .none ? L("noch nicht") : L("voll"))
                            }
                        }
                    }
                }
                Text("Halb gefüllt = teilweise: Fragen an diese Agents beantwortet Claude Code; Freigaben gibt es dort nur über die eigene Arbeitskopie. Am besten integriert sind Claude Code und Codex.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
