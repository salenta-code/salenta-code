import AgenticOSKit
import AppKit
import SwiftUI

// Hintergrund-Assistent: schaut regelmäßig nach, was dich gerade braucht, und meldet es über die Mitteilungs-Zentrale.
//  • Termine kurz vor Beginn, fällige und überfällige Aufgaben
//  • neue Mails, die eine Antwort brauchen – vorsortiert vom lokalen Modell (offline, kostenlos), sonst nach einfachen Regeln
//  • Limits der Agents, Pull Requests bereit zum Mergen, rote CI
//  • „Hier könntest du weitermachen“: liegengebliebene Arbeit wie fertige, nicht übernommene Aufträge oder nicht hochgeladene Commits
// Er schlägt nur vor: Er startet nichts, sendet nichts und merged nichts ohne deinen Klick.

struct ResumeItem: Identifiable, Hashable {
    let id: String
    let symbol: String
    let title: String
    let detail: String
    let page: String          // wohin „Weitermachen“ führt
    let date: Date
}

final class Watchman: ObservableObject {
    static let shared = Watchman()

    @Published private(set) var resume: [ResumeItem] = []
    @Published private(set) var lastRound: Date?
    @Published private(set) var triageModel: String?

    private weak var calendar: CalendarService?
    private weak var mail: MailService?
    private weak var tasks: TaskStore?
    private weak var projects: ProjectCatalog?
    private var timer: Timer?
    private var minute = 0
    private let d = UserDefaults.standard
    private var notified: Set<String> {
        get { Set(d.stringArray(forKey: "watch.notified") ?? []) }
        set { d.set(Array(newValue.suffix(800)), forKey: "watch.notified") }
    }

    var enabled: Bool { d.object(forKey: "watch.on") as? Bool ?? true }

    func start(calendar: CalendarService, mail: MailService, tasks: TaskStore, projects: ProjectCatalog) {
        self.calendar = calendar; self.mail = mail; self.tasks = tasks; self.projects = projects
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.round(full: true) }
    }

    private func tick() {
        guard enabled, Energy.due("watchman", every: 120) else { return }
        minute += 1
        checkCalendar()                         // jede Minute: Termine sind zeitkritisch
        if minute % 10 == 0 { round(full: minute % 30 == 0) }
    }

    /// Ein Rundgang. `full`: auch GitHub (teurer).
    func round(full: Bool = false) {
        guard enabled else { return }
        // Akku schonen: unter 40 % ohne Strom nur das Nötigste
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        checkTasks()
        checkLimits()
        checkResume()
        if !lowPower { checkMail() }
        if full && !lowPower { checkGitHub() }
        lastRound = Date()
    }

    private func once(_ key: String) -> Bool {
        if notified.contains(key) { return false }
        notified.insert(key)
        return true
    }

    // MARK: Termine

    private func checkCalendar() {
        guard let calendar else { return }
        let lead = Double(NotifyCenter.shared.calendarLead) * 60
        let now = Date()
        for e in calendar.events where !e.allDay && e.start > now && e.start.timeIntervalSince(now) <= lead {
            guard once("cal:" + e.id + ":" + String(Int(e.start.timeIntervalSince1970))) else { continue }
            let mins = max(1, Int(e.start.timeIntervalSince(now) / 60))
            var body = String(format: L("in %d Minuten"), mins)
            if let loc = e.location, !loc.isEmpty { body += " · " + loc }
            NotifyCenter.shared.post(.calendar, title: e.title, body: body, route: .page("calendar"))
        }
    }

    // MARK: Aufgaben

    private func checkTasks() {
        guard let tasks else { return }
        let cal = Calendar.current
        let endOfDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        let day = DateCoding.day(Date())
        for t in tasks.tasks where t.status != .erledigt {
            guard let due = t.due, due < endOfDay else { continue }
            // Nicht vor 8 Uhr an „heute fällig“ erinnern; Überfälliges einmal pro Tag
            let overdue = due < cal.startOfDay(for: Date())
            if !overdue && cal.component(.hour, from: Date()) < 8 { continue }
            if !overdue && due > Date() && due.timeIntervalSinceNow > 3600 && cal.component(.hour, from: due) != 0 { continue }   // mit Uhrzeit: erst kurz vorher
            guard once("task:" + t.id + ":" + day) else { continue }
            NotifyCenter.shared.post(.task, title: t.title, body: overdue ? L("überfällig") : L("heute fällig"), route: .task(t.id))
        }
    }

    // MARK: Limits

    private func checkLimits() {
        for a in [AgentKind.claude, .codex] {
            let p = Usage.shared.pressure(a)
            guard p >= 0.8, p < 1.01 else { continue }
            let slot = Int(Date().timeIntervalSince1970 / (5 * 3600))   // höchstens einmal je 5-Stunden-Fenster
            guard once("limit:" + a.rawValue + ":" + String(slot)) else { continue }
            NotifyCenter.shared.post(.limit, title: String(format: L("%@ bei %d %% des Limits"), a.title, Int(p * 100)),
                                     body: L("Neue Aufträge gehen automatisch an andere Agents."), route: .page("cockpit"))
        }
    }

    // MARK: Weitermachen

    private func checkResume() {
        let now = Date()
        var items: [ResumeItem] = []
        for m in MissionStore.shared.missions.suffix(200) where m.archived != true && m.outcome == nil && m.delegated != true {
            guard let ended = m.ended, now.timeIntervalSince(ended) > 2 * 3600, now.timeIntervalSince(ended) < 14 * 86400 else { continue }
            if m.worktree != nil, m.verify?.passed == true, m.pr == nil {
                items.append(ResumeItem(id: "merge:" + m.id, symbol: "checkmark.seal", title: m.title,
                                        detail: L("Fertig und grün, aber noch nicht übernommen"), page: "chat:" + m.id, date: ended))
            } else if m.verify?.passed == false {
                items.append(ResumeItem(id: "red:" + m.id, symbol: "xmark.seal", title: m.title,
                                        detail: L("Prüfung rot – beheben lassen oder verwerfen"), page: "chat:" + m.id, date: ended))
            } else if let q = m.digest?.question, !q.isEmpty, m.ok == true {
                items.append(ResumeItem(id: "q:" + m.id, symbol: "questionmark.bubble", title: m.title,
                                        detail: L("Der Agent hat eine Frage an dich"), page: "chat:" + m.id, date: ended))
            }
        }
        // Nicht hochgeladene Commits in deinen Projekten (ohne Netz, nur lokaler Vergleich)
        let paths = (projects?.local ?? []).prefix(12).map(\.path)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var extra: [ResumeItem] = []
            // Wöchentliche Aufräumrunde fürs Projektwissen: nur vorschlagen, wenn es etwas aufzuräumen gibt
            for p in paths {
                let last = ProjectMemory.lastCleanup(p) ?? .distantPast
                guard Date().timeIntervalSince(last) > 7 * 86400, ProjectMemory.load(p).count >= 8 else { continue }
                let n = ProjectMemory.proposeCleanup(p).drop.count
                guard n >= 2 else { continue }
                extra.append(ResumeItem(id: "memory:" + p, symbol: "brain.head.profile", title: (p as NSString).lastPathComponent,
                                        detail: String(format: L("Projektwissen aufräumen: %d Einträge doppelt oder veraltet"), n), page: "projects", date: Date()))
            }
            for p in paths {
                let r = Git.run(["rev-list", "--count", "@{u}..HEAD"], in: p, timeout: 5)
                guard r.code == 0, let n = Int(r.out.trimmingCharacters(in: .whitespacesAndNewlines)), n > 0 else { continue }
                extra.append(ResumeItem(id: "push:" + p, symbol: "arrow.up.circle", title: (p as NSString).lastPathComponent,
                                        detail: String(format: L("%d Commit(s) nur auf deinem Mac"), n), page: "projects", date: Date()))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let all = (items.sorted { $0.date > $1.date } + extra).prefix(8)
                let fresh = all.filter { !self.resume.map(\.id).contains($0.id) }
                self.resume = Array(all)
                for i in fresh where self.once("resume:" + i.id) {
                    NotifyCenter.shared.post(.resume, title: i.title, body: i.detail, route: .page(i.page))
                }
            }
        }
    }

    // MARK: Mails

    private func checkMail() {
        guard let mail else { return }
        let since = Date(timeIntervalSince1970: d.double(forKey: "watch.mailSince"))
        let newOnes = mail.items.filter { ($0.date ?? .distantPast) > since }
        if let latest = mail.items.compactMap(\.date).max() { d.set(latest.timeIntervalSince1970, forKey: "watch.mailSince") }
        // Beim allerersten Rundgang nichts Altes melden
        guard since.timeIntervalSince1970 > 0, !newOnes.isEmpty else { return }
        let list = Array(newOnes.prefix(15))
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            for m in list {
                guard self.needsReply(subject: m.subject, sender: m.sender) else { continue }
                NotifyCenter.shared.post(.mail, title: m.subject.isEmpty ? L("(ohne Betreff)") : m.subject,
                                         body: m.sender, route: .page("mail"))
            }
        }
    }

    /// Braucht die Mail eine Antwort? Lokales Modell, wenn vorhanden – sonst Regeln.
    func needsReply(subject: String, sender: String) -> Bool {
        let s = sender.lowercased()
        let auto = ["noreply", "no-reply", "donotreply", "newsletter", "notifications@", "notification@", "mailer-daemon", "info@", "news@", "marketing", "github.com", "calendar-notification"]
        if auto.contains(where: { s.contains($0) }) { return false }
        if Focus.isUrgent(subject: subject, sender: sender) { return true }
        if let answer = localAsk("""
        Classify this email for a busy person. Reply with exactly one word: REPLY if a human probably expects an answer or action from them, otherwise SKIP (newsletters, receipts, notifications, ads).
        From: \(sender.prefix(120))
        Subject: \(subject.prefix(200))
        """) {
            return answer.uppercased().contains("REPLY")
        }
        let t = subject.lowercased()
        return t.contains("?") || t.hasPrefix("re:") || t.hasPrefix("aw:") || ["frage", "anfrage", "bitte", "rückmeldung", "termin", "angebot", "question", "request", "please"].contains { t.contains($0) }
    }

    /// Das kleinste geladene lokale Modell, damit der Mac nicht ausgebremst wird.
    private var smallModel: String? {
        let models = LocalFirst.shared.installedModels
        func size(_ m: String) -> Double {
            guard let r = m.range(of: #"(\d+(\.\d+)?)b"#, options: [.regularExpression, .caseInsensitive]) else { return 99 }
            return Double(m[r].dropLast()) ?? 99
        }
        return models.min { size($0) < size($1) }
    }

    /// Kurze Frage ans lokale Modell (Ollama). nil = keins da oder zu langsam.
    func localAsk(_ prompt: String) -> String? {
        guard let model = smallModel, let url = URL(string: "http://localhost:11434/api/generate") else { return nil }
        DispatchQueue.main.async { self.triageModel = model }
        var r = URLRequest(url: url, timeoutInterval: 25)
        r.httpMethod = "POST"
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "prompt": prompt, "stream": false,
                                                                 "options": ["temperature": 0, "num_predict": 8], "keep_alive": "10m"])
        let sem = DispatchSemaphore(value: 0)
        var out: String?
        URLSession.shared.dataTask(with: r) { data, _, _ in
            if let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { out = j["response"] as? String }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 26)
        return out
    }

    // MARK: GitHub

    private func checkGitHub() {
        guard Detection.which("gh") != nil else { return }
        let paths = (projects?.local ?? []).prefix(8).map(\.path)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            for p in paths where Git.run(["remote", "get-url", "origin"], in: p, timeout: 5).code == 0 {
                let name = (p as NSString).lastPathComponent
                let pr = Proc.zsh("gh pr list --limit 8 --json number,title,isDraft,mergeable,statusCheckRollup", in: p, timeout: 25)
                if let arr = try? JSONSerialization.jsonObject(with: Data(pr.out.utf8)) as? [[String: Any]] {
                    for x in arr {
                        let checks = (x["statusCheckRollup"] as? [[String: Any]]) ?? []
                        let states = checks.map { (($0["conclusion"] as? String) ?? ($0["state"] as? String) ?? "").uppercased() }
                        let green = !states.contains { ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", ""].contains($0) } && !states.contains("PENDING")
                        let ready = (x["isDraft"] as? Bool) == false && (x["mergeable"] as? String ?? "").uppercased() == "MERGEABLE" && green
                        guard ready, let n = x["number"] as? Int, self.once("pr:" + p + ":" + String(n)) else { continue }
                        NotifyCenter.shared.post(.prReady, title: "#\(n) " + (x["title"] as? String ?? ""),
                                                 body: String(format: L("%@ · alle Prüfungen grün"), name), route: .page("projects"))
                    }
                }
                let run = Proc.zsh("gh run list --limit 1 --branch \"$(git rev-parse --abbrev-ref HEAD)\" --json databaseId,conclusion,displayTitle", in: p, timeout: 20)
                if let arr = try? JSONSerialization.jsonObject(with: Data(run.out.utf8)) as? [[String: Any]], let r = arr.first,
                   (r["conclusion"] as? String) == "failure", let id = r["databaseId"] as? Int, self.once("ci:" + String(id)) {
                    NotifyCenter.shared.post(.ciRed, title: String(format: L("CI rot in %@"), name),
                                             body: r["displayTitle"] as? String ?? "", route: .page("projects"))
                }
            }
        }
    }
}

// MARK: - Karte im Cockpit: „Hier könntest du weitermachen“ + Morgen-Briefing

struct ResumeCard: View {
    @ObservedObject private var w = Watchman.shared
    @ObservedObject private var n = NotifyCenter.shared
    @EnvironmentObject private var app: AppModel

    var body: some View {
        if !w.resume.isEmpty || !n.briefing.isEmpty {
            VStack(alignment: .leading, spacing: Grid.s) {
                if !n.briefing.isEmpty {
                    HStack {
                        Label(String(format: L("Während der Ruhezeit: %d Meldungen"), n.briefing.count), systemImage: "sunrise")
                            .font(.headline)
                        Spacer()
                        Button(L("Gelesen")) { withAnimation { n.clearBriefing() } }.controlSize(.small)
                    }
                    ForEach(n.briefing.suffix(6).reversed()) { b in
                        HStack(spacing: 6) {
                            Text(b.title).font(.callout).lineLimit(1)
                            if !b.body.isEmpty { Text("· " + b.body).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            Spacer()
                            Text(b.date, style: .time).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    if !w.resume.isEmpty { Divider() }
                }
                if !w.resume.isEmpty {
                    HStack {
                        Label(L("Hier könntest du weitermachen"), systemImage: "arrow.uturn.forward.circle").font(.headline)
                        Spacer()
                        Text(Intelligence.name).font(.caption2).foregroundStyle(.tertiary)
                    }
                    ForEach(w.resume.prefix(5)) { i in
                        HStack(spacing: Grid.s) {
                            Image(systemName: i.symbol).foregroundStyle(.secondary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(i.title).font(.callout).lineLimit(1)
                                Text(i.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button(L("Weitermachen")) { go(i.page) }.controlSize(.small)
                        }
                    }
                }
            }
            .padding(Grid.m)
            .background(ModernCardBackground(radius: 12))
        }
    }

    private func go(_ p: String) {
        if p.hasPrefix("chat:") { app.page = .chat(String(p.dropFirst(5))) } else if p == "projects" { app.page = .projects } else { app.page = .cockpit }
    }
}

struct WatchmanSettings: View {
    @ObservedObject private var w = Watchman.shared

    var body: some View {
        Section("Hintergrund-Assistent") {
            Toggle("Im Hintergrund nach Wichtigem schauen", isOn: Binding(
                get: { w.enabled }, set: { UserDefaults.standard.set($0, forKey: "watch.on"); w.objectWillChange.send() }))
            Text("Prüft alle 10 Minuten Termine, Aufgaben, neue Mails, Limits und liegengebliebene Arbeit; alle 30 Minuten auch Pull Requests und CI auf GitHub. Er schlägt nur vor – er startet, sendet und merged nichts ohne dich.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Mails sortiert")
                Spacer()
                Text(w.triageModel.map { L("lokal mit") + " " + $0 } ?? L("nach einfachen Regeln (kein lokales Modell geladen)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let t = w.lastRound {
                HStack { Text("Letzter Rundgang"); Spacer(); Text(t, style: .relative).font(.caption).foregroundStyle(.secondary) }
            }
            Button("Jetzt nachsehen") { w.round(full: true) }
        }
    }
}
