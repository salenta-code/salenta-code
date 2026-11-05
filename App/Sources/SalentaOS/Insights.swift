import AgenticOSKit
import Charts
import SwiftUI

// Übersicht › Insights: was gerade dich braucht und wie die Agents in den letzten 7 Tagen gearbeitet haben.

/// Ein Punkt, der eine Entscheidung von dir braucht.
struct AttentionItem: Identifiable {
    enum Kind { case approval, waiting, red, ready, failed, login, customer, customerReply }
    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let missionID: String?

    var symbol: String {
        switch kind {
        case .approval: "hand.raised.fill"
        case .waiting: "bubble.left.and.exclamationmark.bubble.right.fill"
        case .red: "xmark.seal.fill"
        case .ready: "checkmark.seal.fill"
        case .failed: "exclamationmark.octagon.fill"
        case .login: "key.fill"
        case .customer: "ladybug.fill"
        case .customerReply: "checkmark.bubble.fill"
        }
    }
    var tint: Color {
        switch kind {
        case .approval, .waiting, .login, .customer: .orange
        case .customerReply: .green
        case .red, .failed: .red
        case .ready: .green
        }
    }
    var action: String {
        switch kind {
        case .approval: L("Freigeben")
        case .waiting: L("Antworten")
        case .red: L("Ansehen")
        case .ready: L("Übernehmen")
        case .failed: L("Ansehen")
        case .login: L("Anmelden")
        case .customer: L("Beheben")
        case .customerReply: L("Kunde informieren")
        }
    }
}

enum Insights {
    /// Alles, was jetzt dich braucht – Wichtigstes zuerst.
    static func attention(missions: [MissionRecord], sessions: [AgentSession], approvals: [ApprovalRequest]) -> [AttentionItem] {
        var out: [AttentionItem] = []
        if !approvals.isEmpty {
            out.append(AttentionItem(id: "approvals", kind: .approval,
                                     title: approvals.count == 1 ? L("1 Freigabe wartet") : String(format: L("%d Freigaben warten"), approvals.count),
                                     detail: approvals.prefix(2).map(\.title).joined(separator: " · "), missionID: nil))
        }
        for a in AgentHealth.flagged {
            out.append(AttentionItem(id: "login-" + a.rawValue, kind: .login, title: a.title + " " + L("ist nicht angemeldet"),
                                     detail: L("Einmal anmelden, dann nutzt Salenta Code ihn wieder:") + " " + AgentHealth.hint(a), missionID: nil))
        }
        for m in missions where m.archived != true {
            let s = sessions.first { $0.id.uuidString == m.id }
            let phase = m.phase(session: s)
            let sub = "\(m.agentTitle) · \((m.directory as NSString).lastPathComponent)"
            if phase == .waiting {
                out.append(AttentionItem(id: m.id, kind: .waiting, title: m.title, detail: L("wartet auf deine Antwort") + " · " + sub, missionID: m.id))
            } else if phase != .running, m.verify?.passed == false {
                out.append(AttentionItem(id: m.id, kind: .red, title: m.title,
                                         detail: (m.verify?.diagnosis?.why ?? L("Prüfung rot")) + " · " + sub, missionID: m.id))
            } else if phase != .running, m.verify?.passed == true, m.worktree != nil, m.outcome == nil {
                out.append(AttentionItem(id: m.id, kind: .ready, title: m.title, detail: L("geprüft und grün – bereit zum Übernehmen") + " · " + sub, missionID: m.id))
            } else if phase == .failed {
                out.append(AttentionItem(id: m.id, kind: .failed, title: m.title, detail: L("abgebrochen") + " · " + sub, missionID: m.id))
            }
        }
        let order: [AttentionItem.Kind] = [.approval, .waiting, .customer, .login, .red, .failed, .customerReply, .ready]
        return out.sorted { order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! }
    }

    struct DayStat: Identifiable {
        var id: String { "\(day.timeIntervalSince1970)-\(result)" }
        let day: Date
        let result: String
        let count: Int
    }

    struct Week {
        var days: [DayStat] = []
        var total = 0
        var verified = 0
        var passed = 0
        var merged = 0
        var agentSeconds: TimeInterval = 0
        var byAgent: [(String, Int)] = []
        var successRate: Int? { verified > 0 ? Int((Double(passed) / Double(verified) * 100).rounded()) : nil }
    }

    static let green = L("erfolgreich"), red = L("rot / abgebrochen"), open = L("offen")

    static func week(_ missions: [MissionRecord]) -> Week {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date().addingTimeInterval(-6 * 86400))
        let recent = missions.filter { $0.started >= start && $0.plan != true }
        var w = Week()
        w.total = recent.count
        var counts: [Date: [String: Int]] = [:]
        var agents: [String: Int] = [:]
        for m in recent {
            let day = cal.startOfDay(for: m.started)
            let result = m.ended == nil && m.ok == nil ? open : (m.ok == false || m.verify?.passed == false ? red : green)
            counts[day, default: [:]][result, default: 0] += 1
            agents[m.agentTitle, default: 0] += 1
            if let p = m.verify?.passed { w.verified += 1; if p { w.passed += 1 } }
            if m.outcome == "merged" || m.outcome == "pr" { w.merged += 1 }
            if m.runMode == .autonom, let e = m.ended { w.agentSeconds += min(e.timeIntervalSince(m.started), 8 * 3600) }
        }
        for i in 0..<7 {
            let day = cal.date(byAdding: .day, value: i, to: start)!
            for r in [green, red, open] { w.days.append(DayStat(day: day, result: r, count: counts[day]?[r] ?? 0)) }
        }
        w.byAgent = agents.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        return w
    }

    static func duration(_ s: TimeInterval) -> String {
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }
}

/// „Braucht dich“: Freigaben, Rückfragen, rote Prüfungen, fertige Arbeit zum Übernehmen.
struct NeedsYouCard: View {
    @ObservedObject private var missions = MissionStore.shared
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var approvals: ApprovalCenter
    @EnvironmentObject private var app: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            let items = Insights.attention(missions: missions.missions, sessions: agents.sessions, approvals: approvals.pending)
            Card(title: L("Braucht dich"), symbol: "person.crop.circle.badge.exclamationmark",
                 trailing: items.isEmpty ? nil : AnyView(Text("\(items.count)").font(.callout.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(Color.orange.opacity(0.18))))) {
                if items.isEmpty {
                    Label(L("Alles erledigt – nichts wartet auf dich."), systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                ForEach(items.prefix(7)) { it in
                    Button { open(it) } label: {
                        HStack(spacing: Grid.s) {
                            Image(systemName: it.symbol).foregroundStyle(it.tint).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(it.title).lineLimit(1)
                                Text(it.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(it.action).font(.caption.weight(.medium)).foregroundStyle(it.tint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                if items.count > 7 { Text(String(format: L("+ %d weitere"), items.count - 7)).font(.caption).foregroundStyle(.tertiary) }
            }
            .animation(.snappy, value: items.map(\.id))
        }
    }

    private func open(_ it: AttentionItem) {
        if it.kind == .login, let a = AgentKind(rawValue: String(it.id.dropFirst("login-".count))) {
            Detection.runInTerminal(AgentHealth.loginCommand(a))
            AgentHealth.clear(a)
            return
        }
        if let id = it.missionID { app.page = .chat(id) } else { app.page = .mission }
    }
}

/// Agents in den letzten 7 Tagen: Aufträge pro Tag, Erfolgsquote, Arbeitszeit, welche Agents.
struct AgentInsightsCard: View {
    @ObservedObject private var missions = MissionStore.shared
    @EnvironmentObject private var app: AppModel

    var body: some View {
        let w = Insights.week(missions.missions)
        Card(title: L("Agents – letzte 7 Tage"), symbol: "chart.bar.xaxis",
             trailing: AnyView(HStack(spacing: 10) {
                 Button(L("Rückblick teilen")) { app.page = .recap }.buttonStyle(.link).font(.caption)
                 Button(L("Verbrauch")) { app.page = .usage }.buttonStyle(.link).font(.caption)
             })) {
            HStack(spacing: Grid.l) {
                kpi("\(w.total)", L("Aufträge"))
                kpi(w.successRate.map { "\($0) %" } ?? "–", L("Prüfung grün"))
                kpi("\(w.merged)", L("übernommen"))
                kpi(Insights.duration(w.agentSeconds), L("Agents gearbeitet"))
            }
            Chart(w.days) { d in
                BarMark(x: .value(L("Tag"), d.day, unit: .day), y: .value(L("Aufträge"), d.count))
                    .foregroundStyle(by: .value(L("Ergebnis"), d.result))
                    .cornerRadius(3)
            }
            .chartForegroundStyleScale([Insights.green: Color.green.opacity(0.75), Insights.red: Color.red.opacity(0.7), Insights.open: Color.secondary.opacity(0.4)])
            .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine(); AxisValueLabel() } }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 120)
            if !w.byAgent.isEmpty {
                let maxCount = Double(w.byAgent.first?.1 ?? 1)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(w.byAgent.prefix(4), id: \.0) { name, n in
                        HStack(spacing: Grid.s) {
                            Text(name).font(.caption).frame(width: 96, alignment: .leading).lineLimit(1)
                            GeometryReader { g in
                                Capsule().fill(Color.accentColor.opacity(0.55)).frame(width: max(4, g.size.width * Double(n) / maxCount))
                            }
                            .frame(height: 6)
                            Text("\(n)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private func kpi(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
