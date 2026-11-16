import AgenticOSKit
import AppKit
import SwiftUI

// Welche Skills und Erweiterungen ein Auftrag bekommen hat – und wie gut sie sich bewähren (Top 10).

enum ToolKind { case skill, ext, other }

enum ToolNames {
    /// Einträge aus „Automatisch dabei“ einordnen: Skill, Erweiterung oder Sonstiges (z. B. Projektwissen).
    static func kind(_ name: String) -> ToolKind {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        if n.hasPrefix("projektwissen") || n.hasPrefix("project knowledge") || n.hasPrefix("nur ") || n.hasPrefix("only ") { return .other }
        let base = n.replacingOccurrences(of: "/", with: "").components(separatedBy: " (").first ?? n
        if ExtensionCatalog.all.contains(where: { $0.name.lowercased() == base || $0.id.lowercased() == base }) { return .ext }
        if SkillCatalog.current?.skills.contains(where: { $0.name.lowercased() == base }) == true { return .skill }
        return n.hasPrefix("/") ? .skill : .ext
    }

    static func split(_ names: [String]) -> (skills: [String], exts: [String]) {
        var s: [String] = [], e: [String] = []
        for n in names {
            switch kind(n) {
            case .skill: if !s.contains(n) { s.append(n) }
            case .ext: if !e.contains(n) { e.append(n) }
            case .other: break
            }
        }
        return (s, e)
    }
}

/// Kleine Chips: „Skills: …“ und „Erweiterungen: …“ – so siehst du sofort, was ein Auftrag mitbekommen hat.
struct ToolChips: View {
    let skills: [String]
    let exts: [String]
    var compact = false

    var body: some View {
        if !skills.isEmpty || !exts.isEmpty {
            // Nie umbrechen: passt nicht alles, werden es weniger Chips (der Rest als „+N“)
            ViewThatFits(in: .horizontal) {
                ForEach(compact ? [2, 1, 0] : [4, 3, 2, 1, 0], id: \.self) { n in row(n) }
            }
            .help(L("Diese Skills und Erweiterungen hat der Auftrag bekommen – nur diese sind geladen") + "\n" + (skills + exts).joined(separator: ", "))
        }
    }

    private func row(_ n: Int) -> some View {
        HStack(spacing: 6) {
            if !skills.isEmpty { group("wand.and.stars", L("Skills"), skills, n) }
            if !exts.isEmpty { group("puzzlepiece.extension", L("Erweiterungen"), exts, n) }
        }
        .fixedSize()
    }

    private func group(_ symbol: String, _ title: String, _ items: [String], _ n: Int) -> some View {
        let shown = Array(items.prefix(n))
        return HStack(spacing: 4) {
            Image(systemName: symbol).font(.caption2).foregroundStyle(Color.accentColor)
            ForEach(shown, id: \.self) { n in
                Text(n.replacingOccurrences(of: "/", with: ""))
                    .font(.caption2.weight(.medium)).lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.13)))
                    .foregroundStyle(Color.accentColor)
            }
            if items.count > shown.count { Text("+\(items.count - shown.count)").font(.caption2).foregroundStyle(.secondary) }
        }
        .accessibilityLabel(title + ": " + items.joined(separator: ", "))
    }
}

/// Top 10: welche Skills und Erweiterungen am häufigsten mitlaufen – und wie oft das Ergebnis beim ersten Mal grün ist.
struct ToolTrackerCard: View {
    @ObservedObject private var missions = MissionStore.shared
    @State private var days = 30

    private struct Row: Identifiable {
        let id: String
        let kind: ToolKind
        var uses = 0
        var checked = 0
        var green = 0
        var cost = 0.0
        var rate: Double { checked == 0 ? 0 : Double(green) / Double(checked) }
    }

    private var stats: (rows: [Row], avg: Double) {
        let since = Date().addingTimeInterval(-Double(days) * 86400)
        var all: [String: Row] = [:]
        var baseChecked = 0, baseGreen = 0
        for m in missions.missions where m.started >= since {
            let ok = m.verify?.passed
            if ok != nil { baseChecked += 1; if ok == true && (m.fixRound ?? 0) == 0 { baseGreen += 1 } }
            for n in m.auto ?? [] {
                let k = ToolNames.kind(n)
                guard k != .other else { continue }
                let key = n.replacingOccurrences(of: "/", with: "")
                var r = all[key] ?? Row(id: key, kind: k)
                r.uses += 1
                if let ok { r.checked += 1; if ok && (m.fixRound ?? 0) == 0 { r.green += 1 } }
                all[key] = r
            }
        }
        let avg = baseChecked == 0 ? 0 : Double(baseGreen) / Double(baseChecked)
        return (all.values.sorted { $0.uses > $1.uses }.prefix(10).map { $0 }, avg)
    }

    var body: some View {
        let st = stats
        let list = st.rows, avg = st.avg
        VStack(alignment: .leading, spacing: Grid.s) {
            HStack {
                Label(L("Skills & Erweiterungen – Top 10"), systemImage: "chart.bar.doc.horizontal").font(.headline).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $days) { Text("7 T").tag(7); Text("30 T").tag(30) }.pickerStyle(.segmented).labelsHidden().frame(width: 110)
            }
            if list.isEmpty {
                Text(L("Noch keine Aufträge mit Skills oder Erweiterungen in diesem Zeitraum.")).font(.callout).foregroundStyle(.secondary)
            } else {
                HStack {
                    Text(L("Name")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(L("Einsätze")).frame(width: 64, alignment: .trailing)
                    Text(L("Beim 1. Mal grün")).frame(width: 170, alignment: .leading)
                }
                .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                ForEach(Array(list.enumerated()), id: \.element.id) { i, r in
                    HStack(spacing: 8) {
                        Text("\(i + 1)").font(.caption.monospacedDigit().weight(.bold)).foregroundStyle(i < 3 ? Color.accentColor : .secondary).frame(width: 18)
                        Image(systemName: r.kind == .skill ? "wand.and.stars" : "puzzlepiece.extension").font(.caption).foregroundStyle(.secondary).frame(width: 14)
                        Text(r.id).font(.callout).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(r.uses)").font(.callout.monospacedDigit()).frame(width: 44, alignment: .trailing)
                        HStack(spacing: 6) {
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.08))
                                    Capsule().fill(r.checked == 0 ? Color.secondary : (r.rate >= avg ? SC.live : SC.warn))
                                        .frame(width: g.size.width * (r.checked == 0 ? 0 : r.rate))
                                    // Strich: Durchschnitt aller Aufträge
                                    Rectangle().fill(Color.primary.opacity(0.5)).frame(width: 1.5).offset(x: g.size.width * avg)
                                }
                            }
                            .frame(width: 110, height: 6)
                            Text(r.checked == 0 ? "–" : "\(Int(r.rate * 100)) %").font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
                        }
                        .frame(width: 170, alignment: .leading)
                    }
                    .padding(.vertical, 2)
                }
                Text(String(format: L("Strich = Durchschnitt aller Aufträge (%d %%). Grün: besser als der Durchschnitt, Orange: schlechter – solche Skills prüfen oder ausschalten."), Int(avg * 100)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Grid.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ModernCardBackground())
    }
}
