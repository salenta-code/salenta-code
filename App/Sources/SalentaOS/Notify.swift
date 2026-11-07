import AgenticOSKit
import AppKit
import SwiftUI
import UserNotifications

// Mitteilungs-Zentrale: jede Meldung von Salenta Code läuft hier durch.
//  • Stufe je Ereignis (leise · normal · wichtig · dringend) bestimmt Mitteilung und Ton
//  • Ruhezeiten und Fokus: nur Dringendes kommt durch, der Rest landet im Morgen-Briefing
//  • Bündeln: gleiche Ereignisse innerhalb von 10 Minuten werden zu einer Mitteilung
//  • Aktionen direkt in der Mitteilung (Erlauben, Ablehnen, Erledigt, Morgen, Öffnen)
//  • Läuft über die Mac-Mitteilungen; aufs Handy über den Push-Dienst (ntfy) – dort mit derselben Stufe

enum NotifyLevel: Int, Codable, CaseIterable, Comparable {
    case quiet = 0, normal, important, urgent
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    var title: String {
        switch self {
        case .quiet: return L("Leise")
        case .normal: return L("Normal")
        case .important: return L("Wichtig")
        case .urgent: return L("Dringend")
        }
    }
}

enum NotifyEvent: String, CaseIterable, Codable {
    case approval, runDone, runFailed, prReady, ciRed, mail, calendar, task, limit, resume, briefing

    var title: String {
        switch self {
        case .approval: return L("Agent wartet auf Freigabe oder Antwort")
        case .runDone: return L("Auftrag fertig und geprüft")
        case .runFailed: return L("Prüfung rot oder Auftrag abgebrochen")
        case .prReady: return L("Pull Request bereit zum Mergen")
        case .ciRed: return L("CI auf GitHub rot")
        case .mail: return L("Neue Mail, die eine Antwort braucht")
        case .calendar: return L("Termin beginnt bald")
        case .task: return L("Aufgabe heute fällig oder überfällig")
        case .limit: return L("Limit eines Agents fast erreicht")
        case .resume: return L("Hier könntest du weitermachen")
        case .briefing: return L("Morgen-Briefing")
        }
    }

    var level: NotifyLevel {
        switch self {
        case .approval: return .urgent
        case .runFailed, .ciRed, .calendar: return .important
        case .runDone, .prReady, .mail, .task, .briefing: return .normal
        case .limit, .resume: return .quiet
        }
    }

    /// Diese Ereignisse werden innerhalb von 10 Minuten zu einer Mitteilung gebündelt.
    var bundles: Bool { [.mail, .runDone, .resume].contains(self) }
}

/// Was in der Mitteilung angeklickt werden kann.
enum NotifyRoute {
    case page(String)           // "chat:<id>", "projects", "mail", "calendar", "tasks", "cockpit"
    case approval(String)       // Freigabe-ID
    case task(String)           // Aufgaben-ID
    case none
}

struct BriefingItem: Codable, Hashable, Identifiable {
    var id = UUID().uuidString
    var event: String
    var title: String
    var body: String
    var date = Date()
}

final class NotifyCenter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotifyCenter()

    /// Was über Nacht / im Fokus aufgelaufen ist – erscheint als Morgen-Briefing.
    @Published private(set) var briefing: [BriefingItem] = []
    weak var app: AppModel?
    weak var approvals: ApprovalCenter?
    weak var tasks: TaskStore?

    private var bundleCount: [String: (Int, Date)] = [:]
    private var timer: Timer?
    private let d = UserDefaults.standard

    // MARK: Einstellungen

    func enabled(_ e: NotifyEvent) -> Bool { d.object(forKey: "notify.on." + e.rawValue) as? Bool ?? true }
    func setEnabled(_ e: NotifyEvent, _ on: Bool) { d.set(on, forKey: "notify.on." + e.rawValue); objectWillChange.send() }
    /// Ton ab dieser Stufe (Standard: Wichtig)
    var soundFrom: NotifyLevel {
        get { NotifyLevel(rawValue: d.object(forKey: "notify.soundFrom") as? Int ?? NotifyLevel.important.rawValue) ?? .important }
        set { d.set(newValue.rawValue, forKey: "notify.soundFrom"); objectWillChange.send() }
    }
    var soundName: String {
        get { d.string(forKey: "notify.sound") ?? "Glass" }
        set { d.set(newValue, forKey: "notify.sound"); objectWillChange.send() }
    }
    var quietOn: Bool {
        get { d.object(forKey: "notify.quietOn") as? Bool ?? true }
        set { d.set(newValue, forKey: "notify.quietOn"); objectWillChange.send() }
    }
    var quietFrom: Int { get { d.object(forKey: "notify.quietFrom") as? Int ?? 22 } set { d.set(newValue, forKey: "notify.quietFrom"); objectWillChange.send() } }
    var quietTo: Int { get { d.object(forKey: "notify.quietTo") as? Int ?? 7 } set { d.set(newValue, forKey: "notify.quietTo"); objectWillChange.send() } }
    /// Minuten vor einem Termin
    var calendarLead: Int { get { d.object(forKey: "notify.calLead") as? Int ?? 15 } set { d.set(newValue, forKey: "notify.calLead"); objectWillChange.send() } }

    static let sounds = ["Glass", "Ping", "Pop", "Purr", "Tink", "Hero", "Submarine", "Funk", "Blow"]

    var isQuietNow: Bool {
        if Focus.isOn { return true }
        guard quietOn else { return false }
        let h = Calendar.current.component(.hour, from: Date())
        return quietFrom > quietTo ? (h >= quietFrom || h < quietTo) : (h >= quietFrom && h < quietTo)
    }

    // MARK: Start

    func start(app: AppModel, approvals: ApprovalCenter, tasks: TaskStore) {
        self.app = app; self.approvals = approvals; self.tasks = tasks
        guard timer == nil else { return }
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        let open = UNNotificationAction(identifier: "open", title: L("Öffnen"), options: [.foreground])
        c.setNotificationCategories([
            UNNotificationCategory(identifier: "approval", actions: [
                UNNotificationAction(identifier: "allow", title: L("Erlauben"), options: []),
                UNNotificationAction(identifier: "deny", title: L("Ablehnen"), options: [.destructive]), open], intentIdentifiers: []),
            UNNotificationCategory(identifier: "task", actions: [
                UNNotificationAction(identifier: "done", title: L("Erledigt"), options: []),
                UNNotificationAction(identifier: "tomorrow", title: L("Morgen"), options: []), open], intentIdentifiers: []),
            UNNotificationCategory(identifier: "open", actions: [open], intentIdentifiers: []),
        ])
        if let data = d.data(forKey: "notify.briefing"), let list = try? JSONDecoder().decode([BriefingItem].self, from: data) { briefing = list }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Ruhezeit vorbei → das Gesammelte als ein Briefing melden.
    private func tick() {
        guard !isQuietNow, !briefing.isEmpty, d.object(forKey: "notify.briefingSent") as? Double ?? 0 < (briefing.first?.date.timeIntervalSince1970 ?? 0) else { return }
        d.set(Date().timeIntervalSince1970, forKey: "notify.briefingSent")
        let lines = briefing.prefix(6).map { "• " + $0.title }.joined(separator: "\n")
        deliver(.briefing, title: String(format: L("Morgen-Briefing: %d Punkte"), briefing.count), body: lines, route: .page("cockpit"), ignoreQuiet: true)
    }

    func clearBriefing() {
        briefing = []
        d.removeObject(forKey: "notify.briefing")
    }

    // MARK: Melden

    /// Einziger Weg für Meldungen. Ruhezeit: alles unter „Dringend“ wandert ins Briefing.
    func post(_ e: NotifyEvent, title: String, body: String = "", route: NotifyRoute = .none, key: String? = nil) {
        DispatchQueue.main.async { [self] in
            guard enabled(e) else { return }
            if isQuietNow && e.level < .urgent {
                if e.level > .quiet {
                    briefing.append(BriefingItem(event: e.rawValue, title: title, body: body))
                    if briefing.count > 40 { briefing.removeFirst(briefing.count - 40) }
                    if let data = try? JSONEncoder().encode(briefing) { d.set(data, forKey: "notify.briefing") }
                }
                return
            }
            deliver(e, title: title, body: body, route: route, key: key)
        }
    }

    private func deliver(_ e: NotifyEvent, title: String, body: String, route: NotifyRoute, key: String? = nil, ignoreQuiet: Bool = false) {
        let c = UNMutableNotificationContent()
        var t = title, b = body
        var id = key.map { e.rawValue + ":" + $0 } ?? UUID().uuidString
        // Bündeln: gleiche Art innerhalb von 10 Minuten → eine Mitteilung „3 neue …“
        if e.bundles {
            let prev = bundleCount[e.rawValue]
            let n = (prev.map { Date().timeIntervalSince($0.1) < 600 ? $0.0 : 0 } ?? 0) + 1
            bundleCount[e.rawValue] = (n, Date())
            id = "bundle:" + e.rawValue
            if n > 1 { b = title + (b.isEmpty ? "" : " – " + b); t = String(format: L("%d × %@"), n, e.title) }
        }
        c.title = t
        c.body = String(b.prefix(400))
        c.threadIdentifier = e.rawValue
        if e.level >= soundFrom { c.sound = UNNotificationSound(named: UNNotificationSoundName(soundName)) }
        if e.level >= .urgent { c.interruptionLevel = .timeSensitive }
        switch route {
        case .approval(let rid): c.categoryIdentifier = "approval"; c.userInfo = ["approval": rid]
        case .task(let tid): c.categoryIdentifier = "task"; c.userInfo = ["task": tid]
        case .page(let p): c.categoryIdentifier = "open"; c.userInfo = ["page": p]
        case .none: break
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
        // Aufs Handy (ntfy), wenn eingerichtet – Leises nicht
        if e.level >= .normal { Notifier.push(t, String(b.prefix(400)), priority: e.level == .urgent ? 5 : e.level == .important ? 4 : 3, tags: "bell") }
        if e.level >= .important, !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    // MARK: Delegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound, .list])   // auch zeigen, wenn Salenta Code vorne ist
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        DispatchQueue.main.async { [self] in
            if let rid = info["approval"] as? String, let r = approvals?.pending.first(where: { $0.id == rid }), action == "allow" || action == "deny" {
                approvals?.decide(r, allow: action == "allow")
            } else if let tid = info["task"] as? String, var t = tasks?.tasks.first(where: { $0.id == tid }), action == "done" || action == "tomorrow" {
                if action == "done" { t.status = .erledigt; t.doneAt = Date() }
                else { t.due = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))?.addingTimeInterval(9 * 3600) }
                tasks?.update(t)
            } else {
                NSApp.activate(ignoringOtherApps: true)
                AppDelegate.openMain?()
                if let p = info["page"] as? String { open(p) }
                else if info["approval"] != nil { app?.page = .cockpit }
                else if info["task"] != nil { app?.page = .tasks }
            }
            done()
        }
    }

    private func open(_ p: String) {
        guard let app else { return }
        if p.hasPrefix("chat:") { app.page = .chat(String(p.dropFirst(5))); return }
        if p.hasPrefix("steward:") { app.page = .steward(String(p.dropFirst(8))); return }
        switch p {
        case "projects": app.page = .projects
        case "mail": app.page = .mail
        case "calendar": app.page = .calendar
        case "tasks": app.page = .tasks
        default: app.page = .cockpit
        }
    }
}

// MARK: - Einstellungen › Mitteilungen

struct NotifySettings: View {
    @ObservedObject private var n = NotifyCenter.shared

    var body: some View {
        Section("Mitteilungen") {
            ForEach(NotifyEvent.allCases.filter { $0 != .briefing }, id: \.self) { e in
                Toggle(isOn: Binding(get: { n.enabled(e) }, set: { n.setEnabled(e, $0) })) {
                    HStack {
                        Text(e.title)
                        Spacer()
                        Text(e.level.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Picker("Ton ab Stufe", selection: Binding(get: { n.soundFrom }, set: { n.soundFrom = $0 })) {
                ForEach(NotifyLevel.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            HStack {
                Picker("Ton", selection: Binding(get: { n.soundName }, set: { n.soundName = $0 })) {
                    ForEach(NotifyCenter.sounds, id: \.self) { Text($0).tag($0) }
                }
                Button { NSSound(named: n.soundName)?.play() } label: { Image(systemName: "speaker.wave.2") }
                    .buttonStyle(.borderless).help(L("Ton anhören"))
            }
            Stepper(value: Binding(get: { n.calendarLead }, set: { n.calendarLead = $0 }), in: 5...60, step: 5) {
                Text(String(format: L("Termin-Erinnerung %d Minuten vorher"), n.calendarLead))
            }
            Toggle("Ruhezeit (nur Dringendes, der Rest kommt ins Morgen-Briefing)", isOn: Binding(get: { n.quietOn }, set: { n.quietOn = $0 }))
            if n.quietOn {
                HStack {
                    Picker("von", selection: Binding(get: { n.quietFrom }, set: { n.quietFrom = $0 })) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                    Picker("bis", selection: Binding(get: { n.quietTo }, set: { n.quietTo = $0 })) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                }
            }
            Text("Im Fokus-Modus gilt dasselbe wie in der Ruhezeit. Aufs Handy kommen Meldungen über den Push-Dienst (ntfy, weiter unten), Aufgaben zusätzlich über die Erinnerungen-App.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
