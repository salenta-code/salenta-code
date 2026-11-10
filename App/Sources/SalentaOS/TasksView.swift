import AgenticOSKit
import AppKit
import SwiftUI

enum HandOff {
    /// Übergibt eine Aufgabe an einen Agent und setzt sie auf "Wartet / Agent".
    static func run(_ task: TaskItem, to agent: AgentKind, tasks: TaskStore, agents: AgentManager,
                    system: SystemStatus, app: AppModel) {
        var t = task
        t.agent = agent
        t.status = .warten
        tasks.update(t)
        agents.start(agent, prompt: Agents.prompt(for: t), taskID: t.id)
        app.page = .agents
    }
}

/// Eine ruhige Liste als Standard; das Board bleibt für die Wochenplanung verfügbar.
struct TasksView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var tasks: TaskStore
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var system: SystemStatus
    @State private var search = ""
    @State private var selectedStatus: TaskStatus?
    @AppStorage("tasks.layout.board") private var showBoard = false
    @State private var dropTarget: TaskStatus?
    @State private var showPhone = false

    private var statuses: [TaskStatus] {
        if let selectedStatus { return [selectedStatus] }
        return TaskStatus.allCases.filter { $0 != .erledigt }
    }

    private func items(_ status: TaskStatus) -> [TaskItem] {
        tasks.tasks(in: status, company: app.taskFilter, search: search)
    }

    private var visibleCount: Int { statuses.reduce(0) { $0 + items($1).count } }

    var body: some View {
        VStack(spacing: 0) {
            if let err = tasks.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).padding(Grid.s)
            }
            header
            Divider()
            GeometryReader { geo in
                if showBoard && geo.size.width >= 960 {
                    board(height: geo.size.height, availableWidth: geo.size.width)
                } else {
                    taskList
                }
            }
        }
        .navigationTitle("Aufgaben")
        .navigationSubtitle(app.taskFilter?.title ?? L("Alle Bereiche"))
        .searchable(text: $search, placement: .toolbar, prompt: "Aufgaben suchen")
        .sheet(isPresented: $showPhone) {
            VStack(alignment: .trailing, spacing: 0) {
                phoneInfo
                Button("Schließen") { showPhone = false }
                    .keyboardShortcut(.cancelAction)
                    .padding([.horizontal, .bottom], Grid.xl)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Bereich", selection: $app.taskFilter) {
                    Text("Alle Bereiche").tag(Company?.none)
                    Divider()
                    ForEach(Company.allCases) { c in Text(c.title).tag(Company?.some(c)) }
                }
                .frame(maxWidth: 160)
                Button { showBoard.toggle() } label: {
                    Label(showBoard ? L("Liste anzeigen") : L("Board anzeigen"),
                          systemImage: showBoard ? "list.bullet" : "rectangle.split.3x1")
                }
                .help(L("Auf schmalen Fenstern werden Aufgaben immer als Liste angezeigt"))
                Button { showPhone.toggle() } label: { Label("Auf dem iPhone", systemImage: "iphone") }
                Button { newTask(selectedStatus ?? .heute) } label: {
                    Label("Neue Aufgabe", systemImage: "plus")
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Grid.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(selectedStatus?.title ?? L("Offene Aufgaben")).font(.title2.bold())
                Spacer()
                Text("\(visibleCount)").font(.title2.monospacedDigit()).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                HStack(spacing: Grid.s) {
                    statusButton(nil, title: L("Offen"), symbol: "tray.full",
                                 count: TaskStatus.allCases.filter { $0 != .erledigt }.reduce(0) { $0 + items($1).count })
                    ForEach(TaskStatus.allCases) { status in
                        statusButton(status, title: status.title, symbol: status.symbol, count: items(status).count)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(Grid.l)
    }

    private func statusButton(_ status: TaskStatus?, title: String, symbol: String, count: Int) -> some View {
        Button { selectedStatus = status } label: {
            HStack(spacing: Grid.s) {
                Label(title, systemImage: symbol)
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, Grid.m).frame(minHeight: 44)
            .background(selectedStatus == status ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: Grid.s))
            .overlay(RoundedRectangle(cornerRadius: Grid.s)
                .strokeBorder(selectedStatus == status ? Color.accentColor.opacity(0.5) : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedStatus == status ? .isSelected : [])
    }

    private var taskList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Grid.l) {
                if visibleCount == 0 {
                    ContentUnavailableView {
                        Label(search.isEmpty ? L("Hier ist alles erledigt") : L("Keine Aufgaben gefunden"),
                              systemImage: search.isEmpty ? "checkmark.circle" : "magnifyingglass")
                    } description: {
                        Text(search.isEmpty ? L("Lege eine Aufgabe an oder wähle einen anderen Status.")
                             : L("Versuche einen anderen Suchbegriff oder Bereich."))
                    } actions: {
                        if search.isEmpty { Button("Neue Aufgabe") { newTask(selectedStatus ?? .heute) } }
                        else { Button("Suche zurücksetzen") { search = "" } }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, Grid.xxl)
                }
                ForEach(statuses) { status in
                    let list = items(status)
                    if !list.isEmpty {
                        VStack(alignment: .leading, spacing: Grid.s) {
                            HStack {
                                Label(status.title, systemImage: status.symbol).font(.headline)
                                Text("\(list.count)").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button { newTask(status) } label: { Image(systemName: "plus") }
                                    .buttonStyle(.borderless).help(L("Neue Aufgabe in diesem Status"))
                            }
                            .padding(.horizontal, Grid.xs)
                            ForEach(list) { task in card(task) }
                        }
                    }
                }
            }
            .padding(Grid.l)
            .frame(maxWidth: 880)
            .frame(maxWidth: .infinity)
        }
    }

    private func board(height: CGFloat, availableWidth: CGFloat) -> some View {
        let count = CGFloat(statuses.count)
        let width = max(240, (availableWidth - Grid.l * 2 - Grid.m * (count - 1)) / count)
        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Grid.m) {
                ForEach(statuses) { status in
                    VStack(alignment: .leading, spacing: Grid.s) {
                        HStack {
                            Label(status.title, systemImage: status.symbol).font(.headline)
                            Text("\(items(status).count)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { newTask(status) } label: { Image(systemName: "plus") }
                                .buttonStyle(.borderless).help(L("Neue Aufgabe in diesem Status"))
                        }
                        ScrollView {
                            LazyVStack(spacing: Grid.s) {
                                ForEach(items(status)) { task in card(task).draggable(task.id) }
                                if items(status).isEmpty {
                                    Text("Keine Aufgaben").foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, minHeight: 80)
                                }
                            }
                        }
                    }
                    .padding(Grid.m).frame(width: width)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(dropTarget == status ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: Grid.m))
                    .dropDestination(for: String.self) { ids, _ in
                        let known = ids.filter { id in tasks.tasks.contains { $0.id == id } }
                        for id in known { tasks.move(id, to: status) }
                        return !known.isEmpty
                    } isTargeted: { inside in
                        dropTarget = inside ? status : (dropTarget == status ? nil : dropTarget)
                    }
                }
            }
            .padding(Grid.l).frame(height: height)
        }
    }

    private func card(_ task: TaskItem) -> some View {
        TaskCard(task: task) { kind in
            HandOff.run(task, to: kind, tasks: tasks, agents: agents, system: system, app: app)
        }
    }

    private func newTask(_ status: TaskStatus) {
        app.editing = TaskItem(title: "", company: app.taskFilter ?? .privat, status: status)
    }

    private var phoneInfo: some View {
        VStack(alignment: .leading, spacing: Grid.l) {
            Label("Aufgaben auf dem iPhone", systemImage: "iphone").font(.headline)
            Text("Über Apple Erinnerungen kannst du Aufgaben unterwegs ansehen, bearbeiten und abhaken.")
                .fixedSize(horizontal: false, vertical: true)
            RemindersToggle()
            Text("Verwende dafür auf Mac und iPhone denselben iCloud-Account und eine iCloud-Erinnerungsliste. Der Mac gleicht ab, solange Salenta Code läuft.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Grid.xl).frame(width: 320)
    }
}

struct TaskCard: View {
    let task: TaskItem
    let onAgent: (AgentKind) -> Void
    @EnvironmentObject private var tasks: TaskStore
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var agents: AgentManager

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.s) {
            HStack(alignment: .top, spacing: Grid.s) {
                Button { tasks.toggleDone(task.id) } label: {
                    Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(task.isDone ? Color.green : Color.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(task.isDone ? L("Als offen markieren") : L("Aufgabe erledigen"))
                Button { app.editing = task } label: {
                    VStack(alignment: .leading, spacing: Grid.xs) {
                        Text(task.title).font(.body.weight(.medium))
                            .strikethrough(task.isDone).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !task.notes.isEmpty {
                            Text(task.notes).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Aufgabe öffnen"))
                Menu { actions } label: {
                    Image(systemName: "ellipsis").frame(width: 32, height: 44)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel(L("Aufgabenaktionen"))
            }
            HStack(spacing: Grid.s) {
                CompanyChip(company: task.company)
                if task.priority == .hoch {
                    Label("Hohe Priorität", systemImage: "flag.fill").foregroundStyle(.red)
                }
                if let due = task.due {
                    Label(due.formatted(.dateTime.day().month(.abbreviated)), systemImage: "calendar")
                        .foregroundStyle(task.isOverdue() ? Color.red : Color.secondary)
                }
                if let a = task.agent { Text(a.title).foregroundStyle(.secondary) }
            }
            .font(.caption)
            if let session = agents.session(forTask: task.id) { AgentStatusLine(session: session) }
        }
        .padding(Grid.m)
        .background(RoundedRectangle(cornerRadius: Grid.m).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: Grid.m).strokeBorder(.separator.opacity(0.6)))
        .contextMenu { actions }
    }

    @ViewBuilder private var actions: some View {
        Button("Aufgabe öffnen") { app.editing = task }
        Menu("Verschieben nach") {
            ForEach(TaskStatus.allCases) { s in
                Button(s.title) { tasks.move(task.id, to: s) }.disabled(s == task.status)
            }
        }
        Menu("Bereich") {
            ForEach(Company.allCases) { c in
                Button(c.title) { var t = task; t.company = c; tasks.update(t) }
            }
        }
        Divider()
        ForEach([AgentKind.claude, .codex, .junie]) { k in
            Button { onAgent(k) } label: { Label("An \(k.title) übergeben", systemImage: k.symbol) }
        }
        Divider()
        Button("Löschen", role: .destructive) { tasks.delete(task.id) }
    }
}

struct TaskEditor: View {
    @EnvironmentObject private var tasks: TaskStore
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var system: SystemStatus
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var task: TaskItem
    @State private var hasDue = false
    @State private var due = Date()

    private var isNew: Bool { !tasks.tasks.contains { $0.id == task.id } }

    var body: some View {
        HStack(spacing: 0) {
            editor
            if let s = agents.session(forTask: task.id) {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Image(systemName: s.kind.symbol)
                        Text("\(s.kind.title) · \(s.running ? "arbeitet gerade" : "beendet")").font(.headline)
                        Spacer()
                        Button("Im Terminal öffnen") { agents.selected = s.id; app.page = .agents; dismiss() }
                    }
                    .padding(Grid.m)
                    TerminalContainer(session: s).id(s.id)
                }
                .frame(width: 640)
                .background(Color(hex: 0x141418))
            }
        }
        .frame(height: 640)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Titel", text: $task.title)
                    .font(.title3)
                Picker("Bereich", selection: $task.company) {
                    ForEach(Company.allCases) { c in Text(c.title).tag(c) }
                }
                Picker("Status", selection: $task.status) {
                    ForEach(TaskStatus.allCases) { s in Text(s.title).tag(s) }
                }
                Picker("Priorität", selection: $task.priority) {
                    ForEach(Priority.allCases) { p in Text(p.title).tag(p) }
                }
                Toggle("Fällig", isOn: $hasDue)
                if hasDue {
                    DatePicker("Datum", selection: $due, displayedComponents: .date)
                }
                Section("Notizen") {
                    TextEditor(text: $task.notes)
                        .font(.body)
                        .frame(minHeight: 120)
                        .dictation($task.notes)
                }
                if let a = task.agent {
                    LabeledContent("Agent", value: a.title)
                }
                LabeledContent("Quelle", value: task.source)
            }
            .formStyle(.grouped)

            HStack {
                if !isNew {
                    Button("Löschen", role: .destructive) {
                        tasks.delete(task.id)
                        dismiss()
                    }
                }
                Menu("An Agent übergeben") {
                    ForEach([AgentKind.claude, .codex, .junie]) { k in
                        Button { save(); HandOff.run(currentTask, to: k, tasks: tasks, agents: agents, system: system, app: app); dismiss() } label: {
                            Label(k.title, systemImage: k.symbol)
                        }
                    }
                }
                .fixedSize()
                .disabled(task.title.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Anlegen" : "Sichern") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(task.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(Grid.l)
        }
        .frame(width: 520)
        .onAppear {
            if let d = task.due {
                hasDue = true
                due = d
            }
        }
    }

    private var currentTask: TaskItem {
        var t = task
        t.title = t.title.trimmingCharacters(in: .whitespaces)
        t.due = hasDue ? Calendar.current.startOfDay(for: due) : nil
        return t
    }

    private func save() {
        tasks.update(currentTask)
    }
}


/// "Junie arbeitet gerade" + Live-Ausschnitt, Klick öffnet das Terminal.
struct AgentStatusLine: View {
    @ObservedObject var session: AgentSession
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                agents.selected = session.id
                app.page = .chat(session.id.uuidString)
            } label: {
                HStack(spacing: 6) {
                    if session.running { ProgressView().controlSize(.mini) } else {
                        Image(systemName: session.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(session.succeeded ? Color.green : Color.orange)
                    }
                    Text(session.running ? "\(session.kind.title) arbeitet gerade" : (session.succeeded ? "\(session.kind.title) fertig" : "\(session.kind.title) abgebrochen"))
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("Live ansehen").font(.caption).foregroundStyle(Color.accentColor)
                }
            }
            .buttonStyle(.plain)
            if session.running { LivePreview(session: session, lines: 3) }
        }
    }
}
