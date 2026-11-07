import AgenticOSKit
import AppKit
import Charts
import SwiftUI

// Kosten-Übersicht: was die Agents kosten (API-Gegenwert), wie effizient sie arbeiten und wo Geld verschwendet wird.
// In den Salenta-Farben. Werte sind Schätzungen nach Listenpreisen (data/prices.json) – Abos rechnen anders ab.

struct CostOverview: View {
    @ObservedObject private var history = CostHistory.shared
    @ObservedObject private var usage = Usage.shared
    @ObservedObject private var missions = MissionStore.shared
    @State private var range = 7

    private let cal = Calendar.current
    private func day(_ offset: Int) -> String { CostHistory.key(Date().addingTimeInterval(Double(-offset) * 86400)) }
    private func sum(_ last: Int, from: Int = 0) -> Double { (from..<(from + last)).reduce(0) { $0 + (history.days[day($1)]?.total ?? 0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.l) {
            HStack {
                Text(L("Kosten & Effizienz")).font(.title2.weight(.semibold))
                if history.backfilling { ProgressView().controlSize(.small); Text(L("liest älteren Verlauf …")).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Picker("", selection: $range) {
                    Text(L("Heute")).tag(1); Text("7 T").tag(7); Text("30 T").tag(30)
                }.pickerStyle(.segmented).frame(width: 200).labelsHidden()
            }
            headline.appearIn(0)
            HStack(alignment: .top, spacing: Grid.l) {
                monthCard.appearIn(0.05)
                projectionCard.appearIn(0.1)
            }
            dailyChart.appearIn(0.15)
            HStack(alignment: .top, spacing: Grid.l) {
                findingsCard.appearIn(0.2)
                providersCard.frame(maxWidth: 340).appearIn(0.25)
            }
            prCard.appearIn(0.3)
            Text(L("API-Gegenwert nach Listenpreisen – mit Abo (Claude Max, ChatGPT Pro) zahlst du nicht pro Token; die Zahl zeigt, wie viel Arbeit drinsteckt und wo sie verpufft."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { history.backfillIfNeeded() }
    }

    // MARK: Kopf: Summe, Vergleich, Aktivität, Effizienz

    private var headline: some View {
        let total = sum(range)
        let yesterday = history.days[day(1)]?.total ?? 0
        let today = history.days[day(0)]?.total ?? 0
        let avg = sum(7) / 7
        let calls = (0..<range).reduce(0) { $0 + (history.days[day($1)]?.calls ?? 0) }
        let runs = missions.missions.filter { $0.started > Date().addingTimeInterval(Double(-range) * 86400) }.count
        return card {
            HStack(alignment: .top, spacing: Grid.xl) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(range == 1 ? L("Heute") : String(format: L("Letzte %d Tage"), range)).font(.headline).foregroundStyle(.secondary)
                    Text(money(total)).font(.system(size: 40, weight: .bold, design: .rounded)).contentTransition(.numericText())
                        .animation(.snappy, value: total)
                    Text(String(format: L("%d Modell-Aufrufe · %d Agent-Läufe"), calls, runs)).font(.callout).foregroundStyle(.secondary)
                    Divider().padding(.vertical, 4)
                    HStack(spacing: Grid.l) {
                        stat(L("Gestern"), money(yesterday))
                        stat(L("Ø 7 Tage"), money(avg))
                        stat(L("Heute vs. gestern"), yesterday > 0 ? percent((today - yesterday) / yesterday) : "–",
                             tint: today <= yesterday ? SC.live : SC.warn)
                    }
                }
                Divider()
                heatmap
                Divider()
                efficiency
            }
        }
    }

    private var heatmap: some View {
        let weeks = 13
        let maxV = max(0.01, (0..<(weeks * 7)).map { history.days[day($0)]?.total ?? 0 }.max() ?? 0.01)
        let active = (0..<(weeks * 7)).filter { (history.days[day($0)]?.total ?? 0) > 0.01 }.count
        let weekdayToday = (cal.component(.weekday, from: Date()) + 5) % 7   // Mo = 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(L("Aktivität")).font(.headline).foregroundStyle(.secondary)
                Text(String(format: L("%d aktive Tage"), active)).font(.caption.monospacedDigit()).foregroundStyle(Color.accentColor)
            }
            HStack(spacing: 3) {
                ForEach(0..<weeks, id: \.self) { w in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { d in
                            let offset = (weeks - 1 - w) * 7 + (weekdayToday - d)
                            let v = offset < 0 ? 0 : (history.days[day(offset)]?.total ?? 0)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(offset < 0 ? Color.clear : (v <= 0.01 ? SC.line : Color.accentColor.opacity(0.25 + 0.75 * min(1, v / maxV))))
                                .frame(width: 11, height: 11)
                                .help(offset < 0 ? "" : day(offset) + ": " + money(v))
                        }
                    }
                }
            }
        }
    }

    private var efficiency: some View {
        let recent = missions.missions.filter { $0.started > Date().addingTimeInterval(-Double(max(range, 7)) * 86400) }
        let checked = recent.filter { $0.verify?.passed != nil }
        let oneShot = checked.isEmpty ? 0 : Double(checked.filter { $0.verify?.passed == true && ($0.fixRound ?? 0) == 0 }.count) / Double(checked.count)
        let inp = (0..<7).reduce(0) { $0 + (history.days[day($1)]?.input ?? 0) }
        let cr = (0..<7).reduce(0) { $0 + (history.days[day($1)]?.cacheRead ?? 0) }
        let cache = inp + cr == 0 ? 0 : Double(cr) / Double(inp + cr)
        let rework = recent.isEmpty ? 0 : Double(recent.filter { ($0.fixRound ?? 0) > 0 }.count) / Double(recent.count)
        let score = Int((0.5 * oneShot + 0.3 * cache + 0.2 * (1 - rework)) * 100)
        let grade = score >= 90 ? "A+" : score >= 80 ? "A" : score >= 70 ? "B" : score >= 55 ? "C" : "D"
        return HStack(spacing: Grid.l) {
            ZStack {
                Circle().stroke(SC.line, lineWidth: 9)
                Circle().trim(from: 0, to: CGFloat(score) / 100)
                    .stroke(score >= 70 ? Color.accentColor : SC.warn, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.9), value: score)
                VStack(spacing: 0) {
                    Text("\(score)").font(.system(size: 26, weight: .bold, design: .rounded)).contentTransition(.numericText())
                    Text(grade).font(.caption.weight(.bold)).foregroundStyle(score >= 70 ? SC.live : SC.warn)
                }
            }
            .frame(width: 92, height: 92)
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Effizienz")).font(.headline).foregroundStyle(.secondary)
                bar(L("Beim ersten Mal grün"), oneShot)
                bar(L("Aus dem Cache"), cache)
                bar(L("Nacharbeit"), rework, warn: true)
            }
            .frame(width: 200)
        }
    }

    // MARK: Monat und Hochrechnung

    private var monthCard: some View {
        let dom = cal.component(.day, from: Date())
        let mtd = sum(dom)
        // gleicher Zeitraum im Vormonat
        let prev = (dom..<(dom * 2)).reduce(0.0) { acc, o in
            let d = cal.date(byAdding: .month, value: -1, to: Date().addingTimeInterval(Double(-(o - dom)) * 86400)) ?? Date()
            return acc + (history.days[CostHistory.key(d)]?.total ?? 0)
        }
        let change = prev > 0 ? (mtd - prev) / prev : 0
        return card {
            VStack(alignment: .leading, spacing: 6) {
                Label(L("Monat bisher"), systemImage: "calendar").font(.headline).foregroundStyle(.secondary)
                Text(money(mtd)).font(.system(size: 30, weight: .bold, design: .rounded)).contentTransition(.numericText())
                if prev > 0 {
                    Text((change >= 0 ? "↑ " : "↓ ") + percent(abs(change)) + " " + L("vs. Vormonat"))
                        .font(.caption.weight(.semibold)).foregroundStyle(change > 0.1 ? SC.warn : SC.live)
                }
                spark((0..<dom).reversed().map { history.days[day($0)]?.total ?? 0 }, cumulative: true)
            }
        }
    }

    private var projectionCard: some View {
        let dom = cal.component(.day, from: Date())
        let days = cal.range(of: .day, in: .month, for: Date())?.count ?? 30
        let mtd = sum(dom)
        let pace = sum(7) / 7
        let projected = mtd + pace * Double(days - dom)
        return card {
            VStack(alignment: .leading, spacing: 6) {
                Label(L("Hochrechnung Monat"), systemImage: "chart.line.uptrend.xyaxis").font(.headline).foregroundStyle(.secondary)
                Text(money(projected)).font(.system(size: 30, weight: .bold, design: .rounded)).contentTransition(.numericText())
                Text(String(format: L("noch %@ bei Ø %@ pro Tag"), money(projected - mtd), money(pace))).font(.caption).foregroundStyle(.secondary)
                spark((0..<dom).reversed().map { history.days[day($0)]?.total ?? 0 } + Array(repeating: pace, count: max(0, days - dom)), cumulative: true, dashedFrom: dom)
            }
        }
    }

    // MARK: Tageskosten

    private struct DayBar: Identifiable { let id: String; let date: Date; let value: Double; let agent: String }

    private var dailyChart: some View {
        let n = max(range, 14)
        let bars: [DayBar] = (0..<n).reversed().flatMap { o -> [DayBar] in
            let d = Date().addingTimeInterval(Double(-o) * 86400)
            let v = history.days[day(o)] ?? DayCost()
            return [DayBar(id: day(o) + "c", date: d, value: v.claude, agent: "Claude"), DayBar(id: day(o) + "x", date: d, value: v.codex, agent: "Codex")]
        }
        let totals = (0..<n).map { history.days[day($0)]?.total ?? 0 }
        let peak = totals.max() ?? 0
        return card {
            VStack(alignment: .leading, spacing: Grid.s) {
                HStack {
                    Label(L("Kosten pro Tag"), systemImage: "chart.bar").font(.headline).foregroundStyle(.secondary)
                    Spacer()
                    pill(L("Ø/Tag") + " " + money(totals.reduce(0, +) / Double(n)))
                    pill(L("Spitze") + " " + money(peak))
                }
                Chart(bars) { b in
                    BarMark(x: .value("Tag", b.date, unit: .day), y: .value("$", b.value))
                        .foregroundStyle(by: .value("Agent", b.agent)).cornerRadius(3)
                }
                .chartForegroundStyleScale(["Claude": Color.accentColor, "Codex": SC.ink.opacity(0.55)])
                .frame(height: 180)
            }
        }
    }

    // MARK: Optimieren – wo Geld verpufft

    private struct Finding: Identifiable { let id = UUID(); let level: Int; let title: String; let detail: String; let fix: String }

    private var findings: [Finding] {
        var out: [Finding] = []
        let week = missions.missions.filter { $0.started > Date().addingTimeInterval(-7 * 86400) }
        let wasted = week.filter { $0.verify?.passed == false || $0.outcome == "discarded" }
        if wasted.count >= 3 {
            out.append(Finding(level: 2, title: String(format: L("%d Läufe ohne verwertbares Ergebnis"), wasted.count),
                               detail: L("rot geprüft oder verworfen – Tokens ohne Nutzen"),
                               fix: L("Aufträge enger fassen; der Betreuer bündelt Korrekturen")))
        }
        let rework = week.filter { ($0.fixRound ?? 0) >= 2 }
        if !rework.isEmpty {
            out.append(Finding(level: 1, title: String(format: L("%d Aufträge brauchten 2+ Nachbesserungen"), rework.count),
                               detail: L("jede Runde liest den Kontext neu"), fix: L("stärkeres Modell für schwierige Aufgaben wählen")))
        }
        let byAgent = Dictionary(grouping: week, by: \.agent)
        if let cx = byAgent["codex"]?.count, let cl = byAgent["claude"]?.count, cx > 0, cl > 0 {
            let cxCost = (0..<7).reduce(0.0) { $0 + (history.days[day($1)]?.codex ?? 0) } / Double(cx)
            let clCost = (0..<7).reduce(0.0) { $0 + (history.days[day($1)]?.claude ?? 0) } / Double(cl)
            if cxCost > clCost * 2 {
                out.append(Finding(level: 1, title: L("Codex kostet pro Lauf deutlich mehr"), detail: String(format: L("%@ vs. %@ pro Lauf"), money(cxCost), money(clCost)),
                                   fix: L("Denkstufe „mittel“ für Helfer (ist Standard)")))
            }
        }
        let skills = SkillCatalog.current?.skills.count ?? 0
        let used = Set(week.flatMap { $0.auto ?? [] }).count
        if skills > 15, used < skills / 3 {
            out.append(Finding(level: 0, title: String(format: L("%d Skills installiert, nur wenige genutzt"), skills),
                               detail: L("jeder Skill kostet Kontext beim Start"), fix: L("unbenutzte Skills in Erweiterungen ausschalten")))
        }
        let totals = (0..<14).map { history.days[day($0)]?.total ?? 0 }
        let avg = totals.reduce(0, +) / 14
        if let peak = totals.max(), avg > 0, peak > avg * 3 {
            out.append(Finding(level: 1, title: String(format: L("Ausreißer-Tag: %@"), money(peak)), detail: String(format: L("über dreimal so viel wie Ø %@"), money(avg)),
                               fix: L("Verlauf ansehen: meist Endlosschleifen oder viele parallele Helfer")))
        }
        if out.isEmpty { out.append(Finding(level: -1, title: L("Nichts Auffälliges"), detail: L("die Agents arbeiten sparsam"), fix: "")) }
        return out.sorted { $0.level > $1.level }
    }

    private var findingsCard: some View {
        card {
            VStack(alignment: .leading, spacing: Grid.s) {
                Label(L("Optimieren"), systemImage: "wand.and.sparkles").font(.headline).foregroundStyle(.secondary)
                ForEach(findings) { f in
                    HStack(alignment: .top, spacing: 10) {
                        Text(f.level >= 2 ? L("Hoch") : f.level == 1 ? L("Mittel") : f.level == 0 ? L("Niedrig") : "✓")
                            .font(.caption2.weight(.bold)).foregroundStyle(f.level >= 2 ? SC.red : f.level == 1 ? SC.warn : SC.live)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill((f.level >= 2 ? SC.red : f.level == 1 ? SC.warn : SC.live).opacity(0.15)))
                            .frame(width: 58, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.title).font(.callout.weight(.medium))
                            Text(f.detail + (f.fix.isEmpty ? "" : " · " + f.fix)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if f.id != findings.last?.id { Divider() }
                }
            }
        }
    }

    // MARK: Anbieter – automatisch erkannt

    private struct Provider: Identifiable { let id: String; let name: String; let found: Bool; let cost: Double?; let note: String }

    private var providers: [Provider] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func has(_ p: String) -> Bool { FileManager.default.fileExists(atPath: home + "/" + p) }
        let c7 = (0..<7).reduce(0.0) { $0 + (history.days[day($1)]?.claude ?? 0) }
        let x7 = (0..<7).reduce(0.0) { $0 + (history.days[day($1)]?.codex ?? 0) }
        return [
            Provider(id: "claude", name: "Claude Code", found: has(".claude/projects"), cost: c7, note: ""),
            Provider(id: "codex", name: "Codex", found: has(".codex/sessions"), cost: x7, note: ""),
            Provider(id: "cursor", name: "Cursor Agent", found: has(".cursor") || has(".local/share/cursor-agent"), cost: nil, note: L("Abrechnung bei Cursor")),
            Provider(id: "gemini", name: "Gemini CLI", found: has(".gemini"), cost: nil, note: ""),
            Provider(id: "kimi", name: "Kimi Code", found: has(".kimi") || has(".kimi-code"), cost: nil, note: ""),
            Provider(id: "grok", name: "Grok", found: has(".grokbot"), cost: nil, note: ""),
            Provider(id: "junie", name: "Junie", found: has(".junie"), cost: nil, note: L("pro Nutzung (API)")),
            Provider(id: "ollama", name: L("Lokal (Ollama)"), found: has(".ollama"), cost: 0, note: L("kostenlos, nur Strom")),
        ].filter(\.found)
    }

    private var providersCard: some View {
        card {
            VStack(alignment: .leading, spacing: Grid.s) {
                Label(L("Anbieter (automatisch erkannt)"), systemImage: "square.grid.2x2").font(.headline).foregroundStyle(.secondary)
                ForEach(providers) { p in
                    HStack {
                        Circle().fill(SC.live).frame(width: 7, height: 7)
                        Text(p.name).font(.callout.weight(.medium))
                        Spacer()
                        Text(p.cost.map { money($0) + " · 7 T" } ?? (p.note.isEmpty ? L("erkannt") : p.note))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Kosten pro Pull Request (Betreuer)

    private var prCard: some View {
        let rows: [(pr: Int, title: String, agent: String, runs: Int, cost: Double)] = Steward.shared.projects.flatMap { p in
            Dictionary(grouping: p.tasks.filter { $0.pr != nil && $0.missionID != nil }, by: { $0.pr! }).map { pr, ts in
                let ms = ts.compactMap { t in t.missionID.flatMap { MissionStore.shared.mission($0) } }
                let cost = ms.reduce(0.0) { $0 + Self.estimate($1) }
                return (pr, ts.first?.title ?? "", ts.first.flatMap { AgentKind(rawValue: $0.agent)?.title } ?? "", ms.count, cost)
            }
        }.sorted { $0.cost > $1.cost }
        return Group {
            if !rows.isEmpty {
                card {
                    VStack(alignment: .leading, spacing: Grid.s) {
                        Label(L("Kosten pro Pull Request (geschätzt)"), systemImage: "arrow.triangle.pull").font(.headline).foregroundStyle(.secondary)
                        ForEach(rows.prefix(6), id: \.pr) { r in
                            HStack {
                                Text("#\(r.pr)").font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(Color.accentColor)
                                Text(r.title).lineLimit(1).font(.callout)
                                Spacer()
                                Text("\(r.agent) · \(r.runs) " + L("Läufe")).font(.caption).foregroundStyle(.secondary)
                                Text(money(r.cost)).font(.callout.monospacedDigit().weight(.semibold)).frame(width: 70, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Grobe Kosten eines Laufs aus seinem Kontext und den Schritten (gecachter Kontext pro Schritt + Ausgabe).
    static func estimate(_ m: MissionRecord) -> Double {
        let runs = Paths.root.appendingPathComponent("logs/runs", isDirectory: true)
        let f = runs.appendingPathComponent((try? FileManager.default.contentsOfDirectory(atPath: runs.path))?.first { $0.hasSuffix("-\(m.agent)-\(m.id.prefix(6)).log.json") } ?? "-")
        guard let d = try? Data(contentsOf: f), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return 0 }
        // "context" ist der über alle Schritte gelesene Kontext (meist aus dem Cache), "output" die erzeugten Tokens
        let ctx = Double(j["context"] as? Int ?? 0), out = Double(j["output"] as? Int ?? 0)
        let price = Prices.price(m.model ?? (m.agent == "codex" ? "gpt" : "sonnet"), Prices.table)
        return (ctx * price.cacheRead + out * price.output) / 1_000_000
    }

    // MARK: Bausteine

    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().padding(Grid.l).frame(maxWidth: .infinity, alignment: .leading)
            .background(ModernCardBackground(radius: 16))
    }

    private func stat(_ label: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(tint)
        }
    }

    private func bar(_ label: String, _ v: Double, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Text(label).font(.caption); Spacer(); Text(percent(v)).font(.caption.monospacedDigit().weight(.semibold)) }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(SC.line)
                    Capsule().fill(warn ? (v > 0.2 ? SC.warn : SC.live) : Color.accentColor).frame(width: g.size.width * min(1, max(0, v)))
                        .animation(.easeOut(duration: 0.8), value: v)
                }
            }.frame(height: 5)
        }
    }

    private func pill(_ t: String) -> some View {
        Text(t).font(.caption.monospacedDigit()).padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(SC.line.opacity(0.6)))
    }

    private struct SparkPoint: Identifiable { let id: Int; let value: Double; let part: String }

    private func spark(_ values: [Double], cumulative: Bool, dashedFrom: Int? = nil) -> some View {
        var acc = 0.0
        var pts: [SparkPoint] = []
        for (i, v) in values.enumerated() {
            acc += v
            let y = cumulative ? acc : v
            let future = dashedFrom.map { i >= $0 } ?? false
            pts.append(SparkPoint(id: i * 2 + (future ? 1 : 0), value: y, part: future ? "b" : "a"))
            if let d = dashedFrom, i == d - 1 { pts.append(SparkPoint(id: i * 2 + 1, value: y, part: "b")) }   // nahtloser Übergang
        }
        let x: (SparkPoint) -> Int = { $0.id / 2 }
        return Chart(pts) { p in
            LineMark(x: .value("i", x(p)), y: .value("v", p.value), series: .value("t", p.part))
                .foregroundStyle(p.part == "b" ? SC.ink.opacity(0.35) : Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2, dash: p.part == "b" ? [4, 3] : []))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 44)
    }

    private func money(_ v: Double) -> String {
        let eur = UserDefaults.standard.bool(forKey: "cost.inEUR")
        let x = eur ? v * Prices.eurPerUSD : v
        return (eur ? "" : "$") + String(format: x >= 100 ? "%.0f" : "%.2f", x) + (eur ? " €" : "")
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded())) %" }
}
