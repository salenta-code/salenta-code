import AgenticOSKit
import AppKit
import SwiftUI

/// Die Startseite: Was ist heute dran, was läuft, was kam rein.
struct CockpitView: View {
    @EnvironmentObject private var hub: MCPHub
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var tasks: TaskStore
    @EnvironmentObject private var calendar: CalendarService
    @EnvironmentObject private var mail: MailService
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var system: SystemStatus
    @EnvironmentObject private var approvals: ApprovalCenter
    @ObservedObject private var missions = MissionStore.shared
    @ObservedObject private var night = NightShift.shared

    @State private var capture = ""
    @FocusState private var captureFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Grid.xl) {
                header
                captureField
                stats
                TipsCard()
                HStack(alignment: .top, spacing: Grid.l) {
                    // links: Coden – was dich braucht, wie es läuft, deine Projekte
                    VStack(spacing: Grid.l) {
                        if let r = night.report, r.ended != nil || night.active { NightBriefingCard(report: r).appearSoftly() }
                        NeedsYouCard().appearSoftly()
                        AgentInsightsCard().appearSoftly(delay: 0.06)
                        ProjectsCard().appearSoftly(delay: 0.12)
                        agentsCard.appearSoftly(delay: 0.18)
                    }
                    .frame(maxWidth: .infinity)
                    // rechts: dein Tag und dein Business
                    VStack(spacing: Grid.l) {
                        focusCard.appearSoftly(delay: 0.03)
                        calendarCard.appearSoftly(delay: 0.09)
                        mailCard.appearSoftly(delay: 0.15)
                        companiesCard
                    }
                    .frame(maxWidth: .infinity)
                }
                launchRow
            }
            .padding(Grid.xl)
            .frame(maxWidth: 1280, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(L("Übersicht"))
        .toolbar {
            ToolbarItem { WidgetCommands().help(L("Kleine Live-Karten direkt auf deinem Schreibtisch")) }
            ToolbarItem {
                Button {
                    calendar.reload()
                    mail.reload()
                    tasks.load()
                } label: { Label("Aktualisieren", systemImage: "arrow.clockwise") }.help(L("Aktualisieren"))
            }
        }
    }

    // MARK: Kopf

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<11: return "Guten Morgen"
        case 11..<17: return "Hallo"
        case 17..<23: return "Guten Abend"
        default: return "Gute Nacht"
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Grid.xs) {
                Text("\(greeting), \(Profile.name)").font(.largeTitle.weight(.bold))
                Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide).year()) + " · KW \(Calendar(identifier: .iso8601).component(.weekOfYear, from: Date()))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: Grid.s) {
                RunningButton()
                if let next = calendar.next {
                    Text("Nächster Termin: \(next.start.timeString) · \(next.title)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private var captureField: some View {
        HStack(spacing: Grid.s) {
            Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor).font(.title3)
            TextField("Neue Aufgabe notieren …  z. B. „Angebot schreiben #arbeit ! morgen“ oder „Login-Bug fixen @claude“", text: $capture)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($captureFocused)
                .onSubmit(addCapture)
            if !capture.isEmpty {
                let d = QuickCapture.parse(capture)
                CompanyChip(company: d.company)
                Text(d.status.title).font(.caption).foregroundStyle(.secondary)
                if let a = d.agent { Label(a.title, systemImage: a.symbol).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(Grid.m)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(captureFocused ? Color.accentColor : Color.secondary.opacity(0.25)))
    }

    private func addCapture() {
        let text = capture.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let t = QuickCapture.parse(text)
        tasks.add(t)
        capture = ""
        if let agent = t.agent { handOff(t, to: agent) } else { app.show("Aufgabe angelegt: \(t.title)") }
    }

    private func handOff(_ task: TaskItem, to agent: AgentKind) {
        var t = task
        t.agent = agent
        t.status = .warten
        tasks.update(t)
        agents.start(agent, prompt: Agents.prompt(for: t), taskID: t.id)
        app.page = .agents
    }

    // MARK: Zahlen

    private var stats: some View {
        let overdue = tasks.open.filter { $0.isOverdue() }.count
        let att = Insights.attention(missions: missions.missions, sessions: agents.sessions, approvals: approvals.pending)
        let needs = att.filter { $0.kind != .ready }.count, ready = att.filter { $0.kind == .ready }.count
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Grid.m), count: 6), spacing: Grid.m) {
            StatTile(value: "\(needs)", label: L("Braucht dich"), symbol: "person.crop.circle.badge.exclamationmark", tint: needs > 0 ? .orange : .secondary)
            StatTile(value: "\(ready)", label: L("Fertig & grün"), symbol: "checkmark.seal.fill", tint: ready > 0 ? .green : .secondary)
            StatTile(value: "\(agents.runningCount)", label: L("Agents aktiv"), symbol: "dot.radiowaves.left.and.right", tint: .purple)
            StatTile(value: "\(tasks.focus.count)" + (overdue > 0 ? " · \(overdue)!" : ""), label: overdue > 0 ? L("Fokus · überfällig") : L("Fokus heute"),
                     symbol: "sun.max.fill", tint: overdue > 0 ? .red : .orange)
            StatTile(value: calendar.access == .granted ? "\(calendar.events(onDayOffset: 0).count)" : "–", label: L("Termine heute"), symbol: "calendar", tint: .blue)
            StatTile(value: mail.unread.map { "\($0)" } ?? "–", label: L("Ungelesen (Mail)"), symbol: "envelope.fill", tint: .teal)
        }
    }

    // MARK: Karten

    private var focusCard: some View {
        Card(title: "Fokus heute", symbol: "sun.max",
             trailing: AnyView(Button("Alle") { app.page = .tasks }.buttonStyle(.link))) {
            let list = tasks.focus
            if list.isEmpty {
                Text("Nichts für heute geplant. Zieh Aufgaben in „Heute“ oder tipp oben eine ein.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: Grid.xs) {
                    ForEach(list.prefix(8)) { t in TaskRow(task: t, onAgent: { handOff(t, to: $0) }) }
                }
            }
        }
    }

    private var companiesCard: some View {
        Card(title: "Bereiche", symbol: "building.2") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: Grid.s)], spacing: Grid.s) {
                ForEach(Company.allCases) { c in
                    let count = tasks.open.filter { $0.company == c }.count
                    Button {
                        app.taskFilter = c
                        app.page = .tasks
                    } label: {
                        HStack(spacing: Grid.s) {
                            Image(systemName: c.symbol).foregroundStyle(c.color).frame(width: 18)
                            Text(c.title).lineLimit(1)
                            Spacer()
                            Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, Grid.s)
                        .padding(.vertical, 6)
                        .background(c.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var calendarCard: some View {
        Card(title: "Termine", symbol: "calendar",
             trailing: AnyView(Button("Kalender") { app.page = .calendar }.buttonStyle(.link))) {
            switch calendar.access {
            case .granted:
                let today = calendar.events(onDayOffset: 0)
                let tomorrow = calendar.events(onDayOffset: 1)
                VStack(alignment: .leading, spacing: Grid.s) {
                    dayList("Heute", today)
                    dayList("Morgen", tomorrow)
                }
            case .denied:
                Text("Kein Zugriff auf Kalender. Systemeinstellungen > Datenschutz & Sicherheit > Kalender > Salenta Code erlauben.")
                    .foregroundStyle(.secondary)
            case .unknown:
                VStack(alignment: .leading, spacing: Grid.s) {
                    Text("Zeigt alle Kalender, die auf deinem Mac eingerichtet sind (iCloud, Google, Exchange).")
                        .foregroundStyle(.secondary)
                    Button("Kalender verbinden") { calendar.requestAccess() }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    @ViewBuilder private func dayList(_ title: String, _ events: [CalEvent]) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        if events.isEmpty {
            Text("Keine Termine").font(.callout).foregroundStyle(.tertiary)
        } else {
            ForEach(events.prefix(8)) { e in
                HStack(alignment: .top, spacing: Grid.s) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: e.color)).frame(width: 4, height: 30)
                    Text(e.allDay ? "ganztägig" : e.start.timeString)
                        .font(.callout.monospacedDigit())
                        .frame(width: 72, alignment: .leading)
                        .foregroundStyle(e.end < Date() ? HierarchicalShapeStyle.tertiary : HierarchicalShapeStyle.primary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).lineLimit(1)
                            .foregroundStyle(e.end < Date() ? HierarchicalShapeStyle.tertiary : HierarchicalShapeStyle.primary)
                        Text([e.calendar, e.location ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }

    private var mailCard: some View {
        Card(title: "Posteingang", symbol: "envelope",
             trailing: AnyView(HStack {
                 if mail.loading { ProgressView().controlSize(.small) }
                 Button("Alle Mails") { app.page = .mail }.buttonStyle(.link)
                 Button("Outlook") { app.page = .panel("outlook") }.buttonStyle(.link)
             })) {
            if let err = mail.error {
                VStack(alignment: .leading, spacing: Grid.s) {
                    Text(err).foregroundStyle(.secondary)
                    Button("Erneut versuchen") { mail.reload() }
                }
            } else if mail.items.isEmpty {
                Text(mail.unread == nil ? "Lade …" : "Keine ungelesenen Mails. 🎉").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: Grid.s) {
                    let shown = Focus.isOn ? mail.items.filter { Focus.isUrgent(subject: $0.subject, sender: $0.sender) } : mail.items
                    if Focus.isOn {
                        Label("Fokus: \(mail.items.count - shown.count) " + L("Mails ausgeblendet, nur dringende sichtbar"), systemImage: "moon.fill")
                            .font(.caption).foregroundStyle(.purple)
                    }
                    ForEach(shown) { m in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack {
                                Text(m.sender).font(.callout.weight(.semibold)).lineLimit(1)
                                Spacer()
                                if let d = m.date {
                                    Text(Calendar.current.isDateInToday(d) ? d.timeString : d.formatted(date: .numeric, time: .omitted))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(m.subject).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private var agentsCard: some View {
        Card(title: "Läuft gerade", symbol: "dot.radiowaves.left.and.right",
             trailing: AnyView(Button("Mission Control") { app.page = .mission }.buttonStyle(.link))) {
            VStack(alignment: .leading, spacing: Grid.s) {
                if agents.sessions.isEmpty {
                    Text("Keine Sitzung offen.").foregroundStyle(.secondary)
                }
                ForEach(agents.sessions) { s in
                    SessionLine(session: s)
                }
            }
        }
    }

    private var launchRow: some View {
        VStack(alignment: .leading, spacing: Grid.s) {
            Text("Schnellstart").font(.headline)
            FlowLayout(spacing: Grid.s) {
                ForEach([AgentKind.claude, .codex, .junie]) { k in
                    Button {
                        agents.start(k)
                        app.page = .agents
                    } label: { Label(k.title, systemImage: k.symbol).lineLimit(1).fixedSize() }
                    .disabled(system.cliChecked && !system.installed(k))
                }
                Button { app.page = .panel("claude") } label: { Label("Claude", systemImage: "sparkle") }
                Button { app.page = .panel("chatgpt") } label: { Label("ChatGPT", systemImage: "bubble.left.and.bubble.right") }
                Button { Launcher.openObsidian() } label: { Label("Obsidian", systemImage: "books.vertical") }
                Button { Launcher.reveal(Paths.tasks) } label: { Label("Datenordner", systemImage: "folder") }
            }
            .controlSize(.large)
        }
    }
}

struct SessionLine: View {
    @ObservedObject var session: AgentSession
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var agents: AgentManager

    var body: some View {
        Button {
            agents.selected = session.id
            app.page = .agents
        } label: {
            HStack(spacing: Grid.s) {
                Circle().fill(session.running ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                Image(systemName: session.kind.symbol)
                Text(session.label).lineLimit(1)
                Spacer()
                Text("\(session.kind.title) · \(session.mode.title)").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.callout)
    }
}

/// Eine Aufgabenzeile mit Abhaken und Agent-Übergabe.
struct TaskRow: View {
    let task: TaskItem
    var onAgent: ((AgentKind) -> Void)? = nil
    @EnvironmentObject private var tasks: TaskStore
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: Grid.s) {
            Button { tasks.toggleDone(task.id) } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isDone ? Color.green : Color.secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            CompanyChip(company: task.company, compact: true)
            Text(task.title).lineLimit(1).strikethrough(task.isDone)
            if task.priority == .hoch { Image(systemName: "flag.fill").foregroundStyle(.red).font(.caption) }
            Spacer()
            if let a = task.agent { Image(systemName: a.symbol).foregroundStyle(.secondary).help(a.title) }
            if let due = task.due {
                Text(due.formatted(.dateTime.day().month(.abbreviated)))
                    .font(.caption)
                    .foregroundStyle(task.isOverdue() ? Color.red : Color.secondary)
            }
            if let onAgent {
                Menu {
                    ForEach([AgentKind.claude, .codex, .junie]) { k in
                        Button { onAgent(k) } label: { Label("An \(k.title)", systemImage: k.symbol) }
                    }
                } label: { Image(systemName: "arrow.up.forward.app") }.help(L("An einen Agent übergeben"))
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("An einen Agent übergeben")
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { app.editing = task }
    }
}
