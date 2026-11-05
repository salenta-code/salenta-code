import AgenticOSKit
import Combine
import EventKit
import SwiftUI

// Aufgaben ↔ Mac-Erinnerungen: Die Aufgaben von Salenta Code liegen zusätzlich in der Erinnerungen-Liste „Salenta Code“
// – und damit auch auf iPhone, iPad und Apple Watch. Änderungen auf beiden Seiten werden abgeglichen:
// Titel, Notizen, Fälligkeit, Priorität, erledigt. Wird etwas auf beiden Seiten gleichzeitig geändert, gewinnt Salenta Code.

final class RemindersSync: ObservableObject {
    static let shared = RemindersSync()
    @Published private(set) var status = ""
    @Published private(set) var lastSync: Date?
    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "reminders.sync") }
        set { UserDefaults.standard.set(newValue, forKey: "reminders.sync"); objectWillChange.send(); if newValue { start() } }
    }

    private let store = EKEventStore()
    private weak var tasks: TaskStore?
    private var bag: Set<AnyCancellable> = []
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var syncing = false
    private var mapURL: URL { Paths.data.appendingPathComponent("reminders-map.json") }

    /// Je Aufgabe: zugehörige Erinnerung und der zuletzt abgeglichene Stand beider Seiten.
    private struct Link: Codable { var reminder: String; var taskSig: String; var remSig: String }
    private var map: [String: Link] = [:]

    func attach(_ tasks: TaskStore) {
        self.tasks = tasks
        if let d = try? Data(contentsOf: mapURL), let m = try? JSONDecoder().decode([String: Link].self, from: d) { map = m }
        tasks.$tasks.dropFirst().sink { [weak self] _ in self?.schedule() }.store(in: &bag)
        NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: store)
            .sink { [weak self] _ in self?.schedule() }.store(in: &bag)
        if enabled { start() }
    }

    func start() {
        guard enabled else { return }
        let st = EKEventStore.authorizationStatus(for: .reminder)
        if st == .fullAccess || st == .authorized {
            schedule(now: true)
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.schedule() }
                timer?.tolerance = 20
            }
        } else {
            store.requestFullAccessToReminders { [weak self] ok, _ in
                DispatchQueue.main.async {
                    if ok { self?.start() } else { self?.status = L("Kein Zugriff auf Erinnerungen – in den Systemeinstellungen erlauben") }
                }
            }
        }
    }

    private func schedule(now: Bool = false) {
        guard enabled else { return }
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.sync() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (now ? 0.2 : 2), execute: w)
    }

    // MARK: Abgleich

    private func list() -> EKCalendar? {
        if let c = store.calendars(for: .reminder).first(where: { $0.title == "Salenta Code" }) { return c }
        let c = EKCalendar(for: .reminder, eventStore: store)
        c.title = "Salenta Code"
        guard let src = store.defaultCalendarForNewReminders()?.source ?? store.sources.first(where: { $0.sourceType == .calDAV || $0.sourceType == .local }) else { return nil }
        c.source = src
        do { try store.saveCalendar(c, commit: true); return c } catch { return nil }
    }

    private static func sig(_ title: String, _ notes: String, _ due: Date?, _ done: Bool, _ prio: Int) -> String {
        let d = due.map { String(Int(Calendar.current.startOfDay(for: $0).timeIntervalSince1970)) } ?? "-"
        return "\(title)|\(notes)|\(d)|\(done)|\(prio)"
    }
    private static func sig(_ t: TaskItem) -> String { sig(t.title, t.notes, t.due, t.isDone, t.priority.rawValue) }
    private static func prio(_ r: EKReminder) -> Int { r.priority == 0 ? 1 : (r.priority <= 4 ? 2 : (r.priority >= 6 ? 0 : 1)) }
    /// Fälligkeit einer Erinnerung als Datum (DateComponents ohne Kalender liefern sonst nil).
    static func due(_ r: EKReminder) -> Date? { r.dueDateComponents.flatMap { Calendar.current.date(from: $0) } }
    private static func sig(_ r: EKReminder) -> String {
        sig(r.title ?? "", r.notes ?? "", due(r), r.isCompleted, prio(r))
    }

    private func sync() {
        guard enabled, !syncing, let tasks, let cal = list() else { return }
        syncing = true
        let pred = store.predicateForReminders(in: [cal])
        store.fetchReminders(matching: pred) { [weak self] found in
            DispatchQueue.main.async {
                guard let self else { return }
                self.apply(found ?? [], cal: cal, tasks: tasks)
                self.syncing = false
            }
        }
    }

    private func apply(_ reminders: [EKReminder], cal: EKCalendar, tasks: TaskStore) {
        var byID: [String: EKReminder] = [:]
        for r in reminders { byID[r.calendarItemIdentifier] = r }
        var changed = 0
        let recent = Date().addingTimeInterval(-7 * 86400)

        // 1. bekannte Paare
        for (taskID, link) in map {
            let task = tasks.tasks.first { $0.id == taskID }
            let rem = byID[link.reminder]
            switch (task, rem) {
            case let (t?, r?):
                let ts = Self.sig(t), rs = Self.sig(r)
                if ts != link.taskSig { write(t, into: r); changed += 1 }                 // Salenta Code gewinnt
                else if rs != link.remSig { tasks.update(read(r, into: t)); changed += 1 }
                map[taskID] = Link(reminder: r.calendarItemIdentifier, taskSig: Self.sig(tasks.tasks.first { $0.id == taskID } ?? t), remSig: Self.sig(r))
                byID[link.reminder] = nil
            case let (nil, r?):   // Aufgabe gelöscht → Erinnerung auch
                try? store.remove(r, commit: false); map[taskID] = nil; byID[link.reminder] = nil; changed += 1
            case let (t?, nil):   // Erinnerung gelöscht → Aufgabe auch
                tasks.delete(t.id); map[taskID] = nil; changed += 1
            case (nil, nil):
                map[taskID] = nil
            }
        }
        // 2. neue Aufgaben → Erinnerungen (offene und kürzlich erledigte)
        for t in tasks.tasks where map[t.id] == nil && (!t.isDone || (t.doneAt ?? .distantPast) > recent) {
            let r = EKReminder(eventStore: store)
            r.calendar = cal
            write(t, into: r)
            map[t.id] = Link(reminder: r.calendarItemIdentifier, taskSig: Self.sig(t), remSig: Self.sig(r))
            changed += 1
        }
        // 3. neue Erinnerungen (auf iPhone, Watch, in Erinnerungen angelegt) → Aufgaben
        for r in byID.values where !(r.isCompleted && (r.completionDate ?? .distantPast) < recent) {
            let due = Self.due(r)
            var t = TaskItem(title: r.title ?? "", status: .inbox, due: due, source: "erinnerungen")
            t = read(r, into: t)
            if !t.isDone { t.status = due.map { Calendar.current.isDateInToday($0) || $0 < Date() ? .heute : .woche } ?? .inbox }
            tasks.add(t)
            map[t.id] = Link(reminder: r.calendarItemIdentifier, taskSig: Self.sig(t), remSig: Self.sig(r))
            changed += 1
        }
        try? store.commit()
        if let d = try? JSONEncoder().encode(map) { try? d.write(to: mapURL, options: .atomic) }
        lastSync = Date()
        status = changed == 0 ? L("Abgeglichen") : String(format: L("%d Änderungen abgeglichen"), changed)
    }

    private func write(_ t: TaskItem, into r: EKReminder) {
        r.title = t.title
        r.notes = t.notes.isEmpty ? nil : t.notes
        r.isCompleted = t.isDone
        r.priority = t.priority == .hoch ? 1 : (t.priority == .niedrig ? 9 : 0)
        if let due = t.due {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: due)
        } else { r.dueDateComponents = nil }
        try? store.save(r, commit: false)
    }

    private func read(_ r: EKReminder, into t: TaskItem) -> TaskItem {
        var t = t
        t.title = r.title ?? t.title
        t.notes = r.notes ?? ""
        t.due = Self.due(r)
        t.priority = Priority(rawValue: Self.prio(r)) ?? .normal
        if r.isCompleted && !t.isDone { t.status = .erledigt }
        if !r.isCompleted && t.isDone { t.status = .heute }
        return t
    }
}

/// Schalter für die Aufgaben-Seite.
struct RemindersToggle: View {
    @ObservedObject private var sync = RemindersSync.shared
    var body: some View {
        Toggle(isOn: Binding(get: { sync.enabled }, set: { sync.enabled = $0 })) {
            Label(L("Mit Erinnerungen abgleichen"), systemImage: "arrow.triangle.2.circlepath")
        }
        .help(sync.enabled ? (sync.status.isEmpty ? L("Abgleich mit der Erinnerungen-Liste „Salenta Code“") : sync.status)
                           : L("Aufgaben zusätzlich in der Erinnerungen-Liste „Salenta Code“ – auch auf iPhone und Watch"))
    }
}
