import AgenticOSKit
import AppKit
import EventKit
import Foundation

// MARK: - Shell

enum Shell {
    /// Führt einen Befehl in einer Login-Shell aus (lädt PATH aus .zprofile/.zshrc) und liefert stdout.
    static func run(_ command: String, timeout: TimeInterval = 20, completion: @escaping (String, Int32) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-l", "-i", "-c", command]
            p.currentDirectoryURL = Paths.root
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch {
                DispatchQueue.main.async { completion("Start fehlgeschlagen: \(error.localizedDescription)", -1) }
                return
            }
            let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            while p.isRunning { usleep(20_000) }  // kein waitUntilExit: das dreht den RunLoop und kann SwiftUI mitten im Zeichnen abstürzen lassen
            timer.cancel()
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { completion(text, p.terminationStatus) }
        }
    }

    /// Startet einen Hintergrundprozess ohne auf ihn zu warten .
    @discardableResult
    static func spawn(_ command: String, log: URL? = nil) -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-i", "-c", command]
        p.currentDirectoryURL = Paths.root
        p.standardInput = FileHandle.nullDevice
        if let log {
            FileManager.default.createFile(atPath: log.path, contents: nil)
            if let h = try? FileHandle(forWritingTo: log) {
                p.standardOutput = h
                p.standardError = h
            }
        } else {
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
        }
        do { try p.run(); return p } catch { return nil }
    }

    /// Für Strings in einfachen Anführungszeichen.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func osascript(_ script: String, args: [String] = [], timeout: TimeInterval = 20, completion: @escaping (String?, String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script] + args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch {
                DispatchQueue.main.async { completion(nil, error.localizedDescription) }
                return
            }
            let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            // stderr parallel lesen – sonst blockiert osascript, wenn der Fehlerkanal voll läuft
            var errData = Data()
            let errDone = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); errDone.signal() }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            errDone.wait()
            while p.isRunning { usleep(20_000) }  // kein waitUntilExit: das dreht den RunLoop und kann SwiftUI mitten im Zeichnen abstürzen lassen
            timer.cancel()
            let text = String(decoding: data, as: UTF8.self)
            let errText = String(decoding: errData, as: UTF8.self)
            DispatchQueue.main.async {
                completion(p.terminationStatus == 0 ? text : nil, p.terminationStatus == 0 ? nil : errText)
            }
        }
    }
}

// MARK: - Kalender (alle Kalender, die auf dem Mac eingerichtet sind: iCloud, Google, Exchange)

struct CalEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let location: String?
    let calendar: String
    let calendarID: String
    let color: NSColor
    let url: URL?
    var eventID: String = ""
    var notes: String = ""
    var editable = true
    var recurring = false
}

final class CalendarService: ObservableObject {
    @Published var events: [CalEvent] = []
    @Published var calendars: [EKCalendar] = []
    private var range = 7
    @Published var access: Access = .unknown

    enum Access { case unknown, granted, denied }

    private let store = EKEventStore()

    init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.reload()
        }
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess, .authorized: access = .granted; reload()
        case .denied, .restricted, .writeOnly: access = .denied
        default: access = .unknown
        }
    }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.access = granted ? .granted : .denied
                if granted { self?.reload() }
            }
        }
    }

    func reload(days: Int? = nil) {
        guard access == .granted else { return }
        if let days { range = max(days, 7) }
        calendars = store.calendars(for: .event).sorted { ($0.source?.title ?? "", $0.title) < ($1.source?.title ?? "", $1.title) }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: range, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let found = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { e in
                CalEvent(id: (e.eventIdentifier ?? UUID().uuidString) + "\(e.startDate.timeIntervalSince1970)",
                         title: e.title ?? "Ohne Titel",
                         start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                         location: e.location,
                         calendar: e.calendar?.title ?? "",
                         calendarID: e.calendar?.calendarIdentifier ?? "",
                         color: e.calendar?.color ?? .systemBlue,
                         url: e.url ?? Self.meetingLink(in: (e.location ?? "") + " " + (e.notes ?? "")),
                         eventID: e.eventIdentifier ?? "", notes: e.notes ?? "",
                         editable: e.calendar?.allowsContentModifications ?? false, recurring: e.hasRecurrenceRules)
            }
        events = found
    }

    func events(onDayOffset offset: Int) -> [CalEvent] {
        let cal = Calendar.current
        guard let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date())) else { return [] }
        return events.filter { cal.isDate($0.start, inSameDayAs: day) || ($0.allDay && $0.start <= day && $0.end > day) }
    }

    var defaultCalendarID: String? { store.defaultCalendarForNewEvents?.calendarIdentifier }

    /// Legt einen Termin im gewählten Kalender an (iCloud, Google, Exchange …).
    func create(title: String, start: Date, minutes: Int, calendarID: String, location: String, notes: String, allDay: Bool = false) -> Bool {
        guard let c = store.calendar(withIdentifier: calendarID) else { return false }
        let e = EKEvent(eventStore: store)
        e.title = title
        e.startDate = start
        e.endDate = start.addingTimeInterval(TimeInterval(minutes * 60))
        e.isAllDay = allDay
        e.calendar = c
        if !location.isEmpty { e.location = location }
        if !notes.isEmpty { e.notes = notes }
        do {
            try store.save(e, span: .thisEvent, commit: true)
            reload()
            return true
        } catch {
            return false
        }
    }

    /// Genau dieses Vorkommen (bei Serien: nur dieser Tag) im Mac-Kalender.
    private func occurrence(_ e: CalEvent) -> EKEvent? {
        let pred = store.predicateForEvents(withStart: e.start.addingTimeInterval(-60), end: e.end.addingTimeInterval(60), calendars: nil)
        return store.events(matching: pred).first { $0.eventIdentifier == e.eventID && abs($0.startDate.timeIntervalSince(e.start)) < 1 }
            ?? store.event(withIdentifier: e.eventID)
    }

    /// Termin ändern – landet sofort im Mac-Kalender (und von dort in iCloud, Google, Exchange …).
    func update(_ e: CalEvent, title: String, start: Date, end: Date, allDay: Bool, calendarID: String,
                location: String, notes: String, wholeSeries: Bool) -> String? {
        guard let ev = occurrence(e) else { return L("Termin nicht mehr gefunden") }
        ev.title = title
        ev.startDate = start
        ev.endDate = max(end, start.addingTimeInterval(allDay ? 0 : 300))
        ev.isAllDay = allDay
        if let c = store.calendar(withIdentifier: calendarID), c.allowsContentModifications { ev.calendar = c }
        ev.location = location.isEmpty ? nil : location
        ev.notes = notes.isEmpty ? nil : notes
        do { try store.save(ev, span: wholeSeries ? .futureEvents : .thisEvent, commit: true); reload(); return nil }
        catch { return error.localizedDescription }
    }

    func delete(_ e: CalEvent, wholeSeries: Bool) -> String? {
        guard let ev = occurrence(e) else { return L("Termin nicht mehr gefunden") }
        do { try store.remove(ev, span: wholeSeries ? .futureEvents : .thisEvent, commit: true); reload(); return nil }
        catch { return error.localizedDescription }
    }

    /// Termin um Tage/Minuten verschieben (Dauer bleibt).
    func move(_ e: CalEvent, by seconds: TimeInterval) -> String? {
        update(e, title: e.title, start: e.start.addingTimeInterval(seconds), end: e.end.addingTimeInterval(seconds), allDay: e.allDay,
               calendarID: e.calendarID, location: e.location ?? "", notes: e.notes, wholeSeries: false)
    }

    /// Teams-/Zoom-/Meet-Link aus Ort oder Notizen.
    static func meetingLink(in text: String) -> URL? {
        let pattern = "https://(teams\\.microsoft\\.com|[a-z0-9.-]*zoom\\.us|meet\\.google\\.com)[^\\s<>\"]*"
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        return URL(string: String(text[r]))
    }

    /// Der nächste Termin, der noch nicht vorbei ist.
    var next: CalEvent? {
        let now = Date()
        return events.first { !$0.allDay && $0.end > now }
    }
}

// MARK: - Apple Mail (alle Postfächer, die in Mail eingerichtet sind)

struct MailItem: Identifiable, Hashable {
    let id = UUID()
    let sender: String
    let subject: String
    let date: Date?
}

final class MailService: ObservableObject {
    @Published var unread: Int?
    @Published var items: [MailItem] = []
    @Published var error: String?
    @Published var loading = false

    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.reload() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.reload() }
    }

    var mailRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty
    }

    func reload() {
        guard mailRunning else {
            error = "Mail ist nicht geöffnet."
            return
        }
        loading = true
        // Schnell auch bei großen Postfächern: nur die neuesten 40 Mails je Konto prüfen.
        let script = """
        tell application "Mail"
            set n to unread count of inbox
            set out to (n as string) & linefeed
            set c to 0
            set mbs to mailboxes of inbox
            if (count of mbs) = 0 then set mbs to {inbox}
            repeat with mb in mbs
                set k to count of messages of mb
                if k > 40 then set k to 40
                repeat with i from 1 to k
                    set m to message i of mb
                    if read status of m is false then
                        set d to ""
                        try
                            set d to ((date received of m) as «class isot» as string)
                        end try
                        set out to out & (sender of m) & tab & (subject of m) & tab & d & linefeed
                        set c to c + 1
                    end if
                    if c > 7 then exit repeat
                end repeat
                if c > 7 then exit repeat
            end repeat
            return out
        end tell
        """
        Shell.osascript(script, timeout: 45) { [weak self] out, err in
            guard let self else { return }
            self.loading = false
            guard let out else {
                self.error = (err ?? "").contains("-1743")
                    ? "Zugriff auf Mail nicht erlaubt (Systemeinstellungen > Datenschutz > Automation)."
                    : "Mail nicht lesbar: \((err ?? "").isEmpty ? "Zeitüberschreitung" : err!.trimmingCharacters(in: .whitespacesAndNewlines))"
                Self.log(err ?? "timeout")
                return
            }
            self.error = nil
            var lines = out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            self.unread = Int(lines.first?.trimmingCharacters(in: .whitespaces) ?? "")
            if !lines.isEmpty { lines.removeFirst() }
            let iso = DateFormatter()
            iso.locale = Locale(identifier: "en_US_POSIX")
            iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            self.items = lines.compactMap { line -> MailItem? in
                let parts = line.components(separatedBy: "\t")
                let sender = parts.first.map(Self.cleanSender) ?? ""
                let subject = parts.count > 1 ? parts[1] : ""
                let date = parts.count > 2 ? iso.date(from: parts[2]) : nil
                return MailItem(sender: sender, subject: subject, date: date)
            }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        }
    }

    static func log(_ text: String) {
        let url = Paths.root.appendingPathComponent("logs/mail.log")
        let line = "\(Date()): \(text)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// "Max Muster <max@x.de>" -> "Max Muster"
    static func cleanSender(_ s: String) -> String {
        if let r = s.range(of: " <") { return String(s[..<r.lowerBound]).replacingOccurrences(of: "\"", with: "") }
        return s
    }
}

// MARK: - System: CLIs

final class SystemStatus: ObservableObject {
    @Published var cliPaths: [AgentKind: String] = [:]
    @Published var cliChecked = false

    private var timer: Timer?

    init() {
        checkCLIs()
        NotificationCenter.default.addObserver(forName: Secrets.changed, object: nil, queue: .main) { [weak self] _ in self?.objectWillChange.send() }
    }

    func installed(_ kind: AgentKind) -> Bool {
        if kind == .openrouter { return cliPaths[.claude] != nil && OpenModels.hasOpenRouter }
        if kind == .ollama { return cliPaths[.claude] != nil && cliPaths[.ollama] != nil }
        return kind == .shell || cliPaths[kind] != nil
    }

    func checkCLIs() {
        let names = AgentKind.allCases.filter { $0 != .shell }.map(\.command).joined(separator: " ")
        let cmd = "for c in \(names); do printf 'AOS:%s=%s\\n' $c \"$(command -v $c 2>/dev/null)\"; done"
        Shell.run(cmd, timeout: 15) { [weak self] out, _ in
            var found: [AgentKind: String] = [:]
            for line in out.split(separator: "\n") where line.hasPrefix("AOS:") {
                let body = line.dropFirst(4)
                let parts = body.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, !parts[1].isEmpty, let kind = AgentKind.allCases.first(where: { $0.command == parts[0] }) else { continue }
                found[kind] = parts[1]
            }
            self?.cliPaths = found
            self?.cliChecked = true
        }
    }



    func stopOwnProcesses() {
    }

    private func ping(_ url: String, done: @escaping (Bool) -> Void) {
        guard let u = URL(string: url) else { return done(false) }
        var req = URLRequest(url: u, timeoutInterval: 1.5)
        req.httpMethod = "GET"
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            let ok = resp is HTTPURLResponse
            DispatchQueue.main.async { done(ok) }
        }.resume()
    }
}

// MARK: - Apps öffnen

enum Launcher {
    static func open(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Webseiten gehen in Chrome (dort sind die Logins), alles andere an die passende Mac-App.
    static func open(_ url: URL) {
        if ["http", "https"].contains(url.scheme?.lowercased() ?? ""), Chrome.installed { Chrome.open(url) }
        else { NSWorkspace.shared.open(url) }
    }

    static func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    static func openObsidian() {
        Obsidian.open()
    }
}


// MARK: - Chrome als Browser (deine Logins, Passwörter und Erweiterungen sind dort)

enum Chrome {
    static let bundleID = "com.google.Chrome"
    static var installed: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }
    /// Einstellung "Web-Apps als eigene Chrome-Fenster" (Standard: aus – Web-Apps laufen eingebettet im Salenta Code).
    static var preferred: Bool {
        installed && (UserDefaults.standard.object(forKey: "web.chrome") as? Bool ?? false)
    }

    /// Neuer Tab im normalen Chrome-Profil.
    static func open(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-b", bundleID, url.absoluteString]
        try? p.run()
    }

    /// Eigenes App-Fenster ohne Tabs und Adressleiste – mit deinem Chrome-Profil.
    static func openApp(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-na", "Google Chrome", "--args", "--app=\(url.absoluteString)"]
        try? p.run()
    }

    /// Holt einen schon offenen Tab mit dieser Seite nach vorn, sonst neues App-Fenster.
    static func show(_ url: URL) {
        guard let host = url.host else { return openApp(url) }
        let script = """
        on run argv
            set h to item 1 of argv
            if application "Google Chrome" is not running then return "none"
            tell application "Google Chrome"
                repeat with w in windows
                    set i to 0
                    repeat with t in tabs of w
                        set i to i + 1
                        if URL of t contains h then
                            set active tab index of w to i
                            set index of w to 1
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end tell
            return "none"
        end run
        """
        Shell.osascript(script, args: [host], timeout: 8) { out, _ in
            if (out ?? "").trimmingCharacters(in: .whitespacesAndNewlines) != "ok" {
                DispatchQueue.main.async { openApp(url) }
            }
        }
    }
}
