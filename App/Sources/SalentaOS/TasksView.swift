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

/// Kanban-Board über alle Bereiche. Karten per Drag & Drop zwischen Spalten schieben.
struct TasksView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var tasks: TaskStore
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var system: SystemStatus
    @State private var search = ""
    @State private var showDone = true
    @State private var dropTarget: TaskStatus?

    private var columns: [TaskStatus] {
        showDone ? TaskStatus.allCases : TaskStatus.allCases.filter { $0 != .erledigt }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let err = tasks.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .padding(Grid.s)
            }
            GeometryReader { geo in
                let count = CGFloat(columns.count)
                let width = max(230, (geo.size.width - Grid.l * 2 - Grid.m * (count - 1)) / count)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: Grid.m) {
                        ForEach(columns) { status in column(status, width: width) }
                    }
                    .padding(Grid.l)
                    .frame(height: geo.size.height)
                }
            }
        }
        .navigationTitle("Aufgaben")
        .navigationSubtitle(app.taskFilter?.title ?? "Alle Bereiche")
        .searchable(text: $search, placement: .toolbar, prompt: "Aufgaben suchen")
        .toolbar {
            ToolbarItemGroup {
                Picker("Bereich", selection: $app.taskFilter) {
                    Text("Alle Bereiche").tag(Company?.none)
                    Divider()
                    ForEach(Company.allCases) { c in
                        Text(c.title).tag(Company?.some(c))
                    }
                }
                .frame(width: 160)
                Toggle(isOn: $showDone) { Label("Erledigte", systemImage: "checkmark.circle") }
                RemindersToggle()
                Button { app.editing = TaskItem(title: "", company: app.taskFilter ?? .privat, status: .heute) } label: {
                    Label("Neue Aufgabe", systemImage: "plus")
                }
                Button { Launcher.reveal(Paths.tasks) } label: { Label("tasks.json zeigen", systemImage: "doc.text") }.help(L("Aufgaben-Datei im Finder zeigen"))
            }
        }
    }

    private func column(_ status: TaskStatus, width: CGFloat) -> some View {
        let list = tasks.tasks(in: status, company: app.taskFilter, search: search)
        return VStack(alignment: .leading, spacing: Grid.s) {
            HStack(spacing: Grid.s) {
                Image(systemName: status.symbol).foregroundStyle(.secondary)
                Text(status.title).font(.headline)
                Text("\(list.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    app.editing = TaskItem(title: "", company: app.taskFilter ?? .privat, status: status)
                } label: { Image(systemName: "plus") }.help(L("Neue Aufgabe in dieser Spalte"))
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, Grid.xs)
            ScrollView {
                LazyVStack(spacing: Grid.s) {
                    ForEach(list) { t in
                        TaskCard(task: t) { kind in
                            HandOff.run(t, to: kind, tasks: tasks, agents: agents, system: system, app: app)
                        }
                        .draggable(t.id)
                    }
                    if list.isEmpty {
                        Text("Leer").font(.callout).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                }
                .padding(.bottom, Grid.l)
            }
        }
        .padding(Grid.s)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(dropTarget == status ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06)))
        .dropDestination(for: String.self) { ids, _ in
            for id in ids { tasks.move(id, to: status) }
            return !ids.isEmpty
        } isTargeted: { inside in
            dropTarget = inside ? status : (dropTarget == status ? nil : dropTarget)
        }
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
                        .foregroundStyle(task.isDone ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
                Text(task.title)
                    .strikethrough(task.isDone)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if task.priority == .hoch { Image(systemName: "flag.fill").foregroundStyle(.red).font(.caption) }
            }
            if !task.notes.isEmpty {
                Text(task.notes).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            if let s = agents.session(forTask: task.id) {
                AgentStatusLine(session: s)
            }
            HStack(spacing: Grid.s) {
                CompanyChip(company: task.company)
                if let a = task.agent {
                    Label(a.title, systemImage: a.symbol).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let due = task.due {
                    Label(due.formatted(.dateTime.day().month(.abbreviated)), systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(task.isOverdue() ? Color.red : Color.secondary)
                }
            }
        }
        .padding(Grid.m)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.6)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { app.editing = task }
        .contextMenu {
            Button("Bearbeiten …") { app.editing = task }
            Menu("Verschieben nach") {
                ForEach(TaskStatus.allCases) { s in
                    Button(s.title) { tasks.move(task.id, to: s) }.disabled(s == task.status)
                }
            }
            Menu("Bereich") {
                ForEach(Company.allCases) { c in
                    Button(c.title) {
                        var t = task
                        t.company = c
                        tasks.update(t)
                    }
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
