import AgenticOSKit
import AppKit
import EventKit
import SwiftUI

// Native Mail und Kalender: alle Konten aus Apple Mail und alle Kalender des Macs (iCloud, Google, Exchange)
// – keine Webseiten. Mail läuft über Apple Mail (AppleScript), Kalender über EventKit.

// MARK: - Mail

struct MailAccount: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let addresses: [String]
}

struct MailMessage: Identifiable, Hashable {
    var id: String { account + "/" + messageID }
    let account: String
    let messageID: String
    let sender: String
    let subject: String
    let date: Date?
    var read: Bool

    var senderName: String { MailService.cleanSender(sender) }
    var senderAddress: String {
        if let a = sender.range(of: "<"), let b = sender.range(of: ">", range: a.upperBound..<sender.endIndex) {
            return String(sender[a.upperBound..<b.lowerBound])
        }
        return sender
    }
}

final class MailClient: ObservableObject {
    @Published var accounts: [MailAccount] = []
    @Published var messages: [MailMessage] = []
    @Published var loading = false
    @Published var error: String?

    static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    func reload() {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty else {
            Launcher.open(bundleID: "com.apple.mail")
            error = "Apple Mail wird gestartet …"
            loading = true
            // automatisch erneut versuchen, sobald Mail läuft
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self else { return }
                self.loading = false
                if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty { self.reload() }
            }
            return
        }
        guard !loading else { return }   // läuft schon
        loading = true
        error = nil
        // 1. Konten und Anzahl der Posteingänge – schnell
        let list = """
        tell application "Mail"
            set out to ""
            repeat with acc in accounts
                try
                    set out to out & "A" & tab & (name of acc) & tab & ((email addresses of acc) as string) & linefeed
                end try
            end repeat
            set out to out & "N" & tab & (count of (mailboxes of inbox)) & linefeed
            return out
        end tell
        """
        Shell.osascript(list, timeout: 30) { [weak self] out, err in
            guard let self else { return }
            guard let out else {
                self.loading = false
                MailService.log("Konten: " + (err ?? "Zeitüberschreitung"))
                self.error = (err ?? "").contains("-1743") ? "Zugriff auf Mail erlauben: Systemeinstellungen › Datenschutz › Automation › Salenta Code › Mail" : "Mail nicht lesbar: \(err ?? "Zeitüberschreitung")"
                return
            }
            var accs: [MailAccount] = []
            var boxes = 0
            for line in out.components(separatedBy: "\n") {
                let p = line.components(separatedBy: "\t")
                if p.first == "A", p.count >= 3 { accs.append(MailAccount(name: p[1], addresses: p[2].components(separatedBy: ", ").filter { !$0.isEmpty })) }
                if p.first == "N", p.count >= 2 { boxes = Int(p[1].trimmingCharacters(in: .whitespaces)) ?? 0 }
            }
            self.accounts = accs
            self.collected = []
            // 2. jeden Posteingang einzeln laden – die ersten Mails erscheinen sofort, langsame Konten bremsen nicht alles
            self.loadBox(index: 1, of: max(boxes, 1), useInbox: boxes == 0)
        }
    }

    private var collected: [MailMessage] = []

    private func loadBox(index: Int, of total: Int, useInbox: Bool) {
        let script = """
        tell application "Mail"
            set out to ""
            set mb to \(useInbox ? "inbox" : "item \(index) of (mailboxes of inbox)")
            set accName to ""
            try
                set accName to name of account of mb
            end try
            set k to count of messages of mb
            if k > 40 then set k to 40
            if k > 0 then
                set ids to id of messages 1 thru k of mb
                set snd to sender of messages 1 thru k of mb
                set subj to subject of messages 1 thru k of mb
                set dts to date received of messages 1 thru k of mb
                set rds to read status of messages 1 thru k of mb
                repeat with i from 1 to k
                    set d to ""
                    try
                        set d to ((item i of dts) as «class isot» as string)
                    end try
                    set out to out & "M" & tab & accName & tab & (item i of ids) & tab & (item i of snd) & tab & (item i of subj) & tab & d & tab & (item i of rds) & linefeed
                end repeat
            end if
            return out
        end tell
        """
        Shell.osascript(script, timeout: 60) { [weak self] out, err in
            guard let self else { return }
            if let out {
                var msgs: [MailMessage] = []
                for line in out.components(separatedBy: "\n") {
                    let p = line.components(separatedBy: "\t")
                    if p.first == "M", p.count >= 7 {
                        msgs.append(MailMessage(account: p[1], messageID: p[2], sender: p[3], subject: p[4],
                                                date: Self.iso.date(from: p[5]), read: p[6] == "true"))
                    }
                }
                self.collected += msgs
                self.messages = self.collected.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            } else {
                MailService.log("Posteingang \(index): " + (err ?? "Zeitüberschreitung"))
            }
            if index < total { self.loadBox(index: index + 1, of: total, useInbox: useInbox) } else { self.loading = false }
        }
    }

    /// Findet die Nachricht in den Posteingängen und führt einen Block darauf aus.
    private func findPrefix(_ id: String) -> String {
        """
        set theMsg to missing value
        repeat with mb in (mailboxes of inbox)
            try
                set theMsg to (first message of mb whose id is \(Int(id) ?? 0))
                exit repeat
            end try
        end repeat
        """
    }

    func content(of m: MailMessage, completion: @escaping (String) -> Void) {
        let script = """
        tell application "Mail"
            \(findPrefix(m.messageID))
            if theMsg is missing value then return "(Nachricht nicht gefunden)"
            set read status of theMsg to true
            return content of theMsg
        end tell
        """
        Shell.osascript(script, timeout: 30) { [weak self] out, err in
            completion(out ?? "Fehler: \(err ?? "")")
            if let i = self?.messages.firstIndex(where: { $0.id == m.id }) { self?.messages[i].read = true }
        }
    }

    func reply(to m: MailMessage, text: String, completion: @escaping (Bool, String) -> Void) {
        let script = """
        on run argv
            tell application "Mail"
                \(findPrefix(m.messageID))
                if theMsg is missing value then return "nicht gefunden"
                set r to reply theMsg without opening window
                set content of r to (item 1 of argv) & return & return & (content of r)
                send r
                return "ok"
            end tell
        end run
        """
        Shell.osascript(script, args: [text], timeout: 40) { out, err in
            completion(out?.contains("ok") == true, out ?? err ?? "")
        }
    }

    func send(from account: MailAccount?, to: String, subject: String, text: String, completion: @escaping (Bool, String) -> Void) {
        let script = """
        on run argv
            tell application "Mail"
                set msg to make new outgoing message with properties {subject:(item 2 of argv), content:(item 3 of argv), visible:false}
                if (item 4 of argv) is not "" then set sender of msg to (item 4 of argv)
                repeat with addr in my splitText(item 1 of argv)
                    tell msg to make new to recipient at end of to recipients with properties {address:addr}
                end repeat
                send msg
                return "ok"
            end tell
        end run
        on splitText(t)
            set AppleScript's text item delimiters to ","
            set parts to text items of t
            set AppleScript's text item delimiters to ""
            return parts
        end splitText
        """
        let from = account?.addresses.first ?? ""
        Shell.osascript(script, args: [to, subject, text, from], timeout: 40) { out, err in
            completion(out?.contains("ok") == true, out ?? err ?? "")
        }
    }

    /// Signatur pro Mail-Konto (Einstellungen › Mail). Wird beim Senden angehängt.
    static func signature(for account: String) -> String? {
        let all = UserDefaults.standard.dictionary(forKey: "mail.signatures") as? [String: String] ?? [:]
        let s = all[account]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }
}

struct MailView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var client = MailClient()
    @State private var account: String = ""
    @State private var onlyUnread = false
    @State private var search = ""
    @State private var selected: String?
    @State private var body_: String = ""
    @State private var parsed: ParsedMail?
    @State private var loadingMail = false
    @State private var compose: ComposeDraft?
    @AppStorage("mail.blockRemote") private var blockRemote = false
    @State private var allowOnce = false

    private func done(_ ok: Bool, _ yes: String, _ no: String) { app.show(ok ? "✓ " + yes : no) }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Picker("Konto", selection: $account) {
                        Text("Alle Konten").tag("")
                        ForEach(client.accounts) { a in Text(a.name).tag(a.name) }
                    }
                    .fixedSize()
                    Toggle("Ungelesen", isOn: $onlyUnread).toggleStyle(.checkbox)
                    Spacer()
                    if client.loading { ProgressView().controlSize(.small) }
                }
                .padding(Grid.s)
                if let e = client.error { Text(e).font(.caption).foregroundStyle(.red).padding(.horizontal, Grid.s) }
                List(selection: $selected) {
                    ForEach(filtered) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                if !m.read { Circle().fill(Color.accentColor).frame(width: 7, height: 7) }
                                Text(m.senderName).font(.callout.weight(m.read ? .regular : .semibold)).lineLimit(1)
                                Spacer()
                                if Focus.isUrgent(subject: m.subject, sender: m.sender) {
                                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).font(.caption).help(L("Dringend"))
                                }
                                if let c = Company.match(in: m.subject + " " + m.sender) { CompanyChip(company: c, compact: true).help(c.title) }
                                if let d = m.date {
                                    Text(Calendar.current.isDateInToday(d) ? d.timeString : d.formatted(date: .numeric, time: .omitted))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(m.subject).font(.callout).lineLimit(1)
                            Text(m.account).font(.caption2).foregroundStyle(.tertiary)
                        }
                        .tag(m.id)
                        .contextMenu {
                            Button(m.read ? L("Als ungelesen markieren") : L("Als gelesen markieren")) { client.act(m, m.read ? .unread : .read) }
                            Button(L("Markieren")) { client.act(m, .flag) }
                            Button(L("Antworten")) { compose = ComposeDraft(replyTo: m, account: m.account) }
                            Divider()
                            Button(L("Archivieren")) { client.act(m, .archive) { ok in done(ok, L("Archiviert"), L("Kein Archiv-Postfach gefunden")) } }
                            Button(L("Löschen"), role: .destructive) { client.act(m, .trash) { ok in done(ok, L("Gelöscht"), L("Löschen fehlgeschlagen")) } }
                        }
                    }
                }
                .searchable(text: $search, placement: .sidebar, prompt: "Mails durchsuchen")
            }
            .frame(minWidth: 320, idealWidth: 380, maxWidth: 480)

            Group {
                if let id = selected, let m = client.messages.first(where: { $0.id == id }) {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: Grid.xs) {
                            Text(m.subject).font(.title2.weight(.semibold)).textSelection(.enabled)
                            Text("\(m.sender) · \(m.date?.formatted(date: .abbreviated, time: .shortened) ?? "")")
                                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            HStack {
                                Button { compose = ComposeDraft(replyTo: m, account: m.account) } label: { Label("Antworten", systemImage: "arrowshape.turn.up.left") }
                                    .buttonStyle(.borderedProminent)
                                Button { compose = ComposeDraft(forward: m, account: m.account, to: "", subject: "WG: " + m.subject, text: "") } label: {
                                    Label("Weiterleiten", systemImage: "arrowshape.turn.up.right")
                                }
                                .help(L("Mit allen Anhängen der Mail"))
                                Divider().frame(height: 18)
                                Button { client.act(m, .archive) { ok in done(ok, L("Archiviert"), L("Kein Archiv-Postfach gefunden")) }; selected = nil } label: {
                                    Image(systemName: "archivebox")
                                }.help(L("Archivieren"))
                                Button { client.act(m, .trash) { ok in done(ok, L("Gelöscht"), L("Löschen fehlgeschlagen")) }; selected = nil } label: {
                                    Image(systemName: "trash")
                                }.help(L("Löschen (in den Papierkorb)")).keyboardShortcut(.delete, modifiers: [])
                                Button { client.act(m, .unread); selected = nil } label: { Image(systemName: "envelope.badge") }
                                    .help(L("Als ungelesen markieren"))
                                Button { client.act(m, .flag) { ok in done(ok, L("Markiert"), L("Markieren fehlgeschlagen")) } } label: { Image(systemName: "flag") }
                                    .help(L("Markieren"))
                                Button { Launcher.open(bundleID: "com.apple.mail") } label: { Label("In Mail", systemImage: "envelope") }
                                Button {
                                    toMission(m, files: (parsed?.attachments ?? []).compactMap(AttachmentFiles.write))
                                } label: { Label("Auftrag daraus", systemImage: "paperplane") }
                                    .help(L("Macht aus der Mail einen Auftrag – die Agentenwahl sucht Projekt und Agent"))
                            }
                            .padding(.top, Grid.s)
                        }
                        .padding(Grid.l)
                        if let atts = parsed?.attachments, !atts.isEmpty {
                            AttachmentStrip(items: atts) { files in toMission(m, files: files) }
                                .padding(.horizontal, Grid.l).padding(.bottom, Grid.s)
                        }
                        Divider()
                        if blockRemote && !allowOnce, (parsed?.html ?? "").range(of: "src=[\"']https?:", options: .regularExpression) != nil {
                            HStack {
                                Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
                                Text("Bilder aus dem Internet sind blockiert (Schutz vor Tracking).").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Laden") { allowOnce = true }.controlSize(.small)
                            }
                            .padding(.horizontal, Grid.l).padding(.vertical, 6)
                        }
                        ZStack {
                            if let html = parsed?.html ?? parsed?.text.map(MailHTMLView.plain) ?? (body_.isEmpty ? nil : MailHTMLView.plain(body_)) {
                                MailHTMLView(html: html, allowRemote: !blockRemote || allowOnce)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .padding(Grid.m)
                            } else {
                                ProgressView(loadingMail ? L("Lade Mail …") : "").controlSize(.small)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .task(id: id) {
                        body_ = ""; parsed = nil; allowOnce = false; loadingMail = true
                        client.source(of: m) { raw in
                            loadingMail = false
                            if let raw {
                                let p = MIME.parse(raw)
                                parsed = p
                                body_ = p.text ?? (p.html.map { $0.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression) } ?? "")
                            } else {
                                client.content(of: m) { body_ = $0 }   // Rückfall: nur Text
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Mail wählen", systemImage: "envelope.open",
                                           description: Text("Alle Konten aus Apple Mail – Gmail, iCloud, Exchange, IMAP – direkt hier. Neue Konten richtest du einmal in Apple Mail ein, dann erscheinen sie automatisch."))
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Mail")
        .navigationSubtitle("\(client.messages.filter { !$0.read }.count) ungelesen · \(client.accounts.count) Konten")
        .toolbar {
            ToolbarItemGroup {
                Button { compose = ComposeDraft(account: account.isEmpty ? (client.accounts.first?.name ?? "") : account) } label: {
                    Label("Neue Mail", systemImage: "square.and.pencil")
                }
                Button { client.reload() } label: { Label("Abrufen", systemImage: "arrow.clockwise") }.help(L("Mails abrufen"))
            }
        }
        .onAppear { if client.messages.isEmpty { client.reload() } }
        .sheet(item: $compose) { d in ComposeSheet(client: client, draft: d) }
    }

    /// Mail (mit Anhängen als Dateien) als neuer Auftrag.
    private func toMission(_ m: MailMessage, files: [URL]) {
        let mailText = String(body_.prefix(3500))
        var d = "Mail von \(m.sender) · „\(m.subject)“ (\(m.account)):\n\n\(mailText)"
        if !files.isEmpty { d += "\n\n" + L("Anhänge (lokal gespeichert):") + "\n" + files.map { "- " + $0.path }.joined(separator: "\n") }
        app.draft = d + "\n\n---\n" + L("Aufgabe: ")
        app.page = .home
    }

    private var filtered: [MailMessage] {
        client.messages.filter { m in
            (account.isEmpty || m.account == account) && (!onlyUnread || !m.read)
                && (search.isEmpty || m.subject.localizedCaseInsensitiveContains(search) || m.sender.localizedCaseInsensitiveContains(search))
        }
    }
}

struct ComposeDraft: Identifiable {
    let id = UUID()
    var replyTo: MailMessage?
    var forward: MailMessage?
    var account: String
    var to: String = ""
    var subject: String = ""
    var text: String = ""
    var files: [URL] = []
}

struct ComposeSheet: View {
    @ObservedObject var client: MailClient
    @State var draft: ComposeDraft
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppModel
    @State private var sending = false
    @State private var addSignature = true

    private var signature: String? { MailClient.signature(for: draft.account) }

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.m) {
            Text(draft.forward != nil ? L("Weiterleiten: ") + draft.forward!.subject : (draft.replyTo == nil ? "Neue E-Mail" : "Antwort an \(draft.replyTo!.senderName)")).font(.headline).lineLimit(1)
            Form {
                Picker("Von", selection: $draft.account) {
                    ForEach(client.accounts) { a in Text("\(a.name) – \(a.addresses.first ?? "")").tag(a.name) }
                }
                .disabled(draft.replyTo != nil || draft.forward != nil)
                if draft.replyTo == nil {
                    TextField("An (mehrere mit Komma)", text: $draft.to)
                }
                if draft.replyTo == nil && draft.forward == nil {
                    TextField("Betreff", text: $draft.subject)
                }
                TextEditor(text: $draft.text).frame(minHeight: 200).font(.body).dictation($draft.text)
                if draft.forward != nil {
                    Text("Die Original-Mail geht mit allen Anhängen mit.").font(.caption).foregroundStyle(.secondary)
                }
                ComposeAttachments(files: $draft.files)
                if signature != nil {
                    Toggle("Signatur anhängen", isOn: $addSignature)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(sending ? "Sendet …" : "Senden") { send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(sending || (draft.forward == nil && draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || (draft.replyTo == nil && draft.to.isEmpty))
            }
        }
        .padding(Grid.l)
        .frame(width: 660, height: 640)
    }

    private func send() {
        sending = true
        var text = draft.text
        if addSignature, let sig = signature { text += "\n\n--\n" + sig }
        let done: (Bool, String) -> Void = { ok, msg in
            sending = false
            app.show(ok ? "✓ Mail gesendet" : "Mail nicht gesendet: \(msg.prefix(120))")
            if ok { dismiss() }
        }
        if let m = draft.forward {
            client.forward(m, to: draft.to, text: draft.text.isEmpty ? "" : text, files: draft.files, completion: done)
        } else if let m = draft.replyTo {
            client.reply(to: m, text: text, files: draft.files, completion: done)
        } else {
            client.send(from: client.accounts.first { $0.name == draft.account }, to: draft.to, subject: draft.subject, text: text, files: draft.files, completion: done)
        }
    }
}

// MARK: - Kalender (nativ, EventKit)

struct CalendarView: View {
    @EnvironmentObject private var calendar: CalendarService
    @State private var days = 14
    @State private var hidden: Set<String> = []
    @State private var newEvent = false
    @State private var editing: CalEvent?
    @State private var newOn: Date?

    var body: some View {
        Group {
            switch calendar.access {
            case .granted:
                HSplitView {
                    List {
                        Section("Kalender") {
                            ForEach(calendar.calendars, id: \.calendarIdentifier) { c in
                                Toggle(isOn: Binding(get: { !hidden.contains(c.calendarIdentifier) },
                                                     set: { on in if on { hidden.remove(c.calendarIdentifier) } else { hidden.insert(c.calendarIdentifier) } })) {
                                    HStack {
                                        Circle().fill(Color(nsColor: c.color ?? .systemBlue)).frame(width: 9, height: 9)
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(c.title).lineLimit(1)
                                            Text(c.source?.title ?? "").font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 300)
                    agenda.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                }
            case .denied:
                ContentUnavailableView("Kein Kalenderzugriff", systemImage: "calendar.badge.exclamationmark",
                                       description: Text("Systemeinstellungen › Datenschutz & Sicherheit › Kalender › Salenta Code erlauben."))
            case .unknown:
                ContentUnavailableView {
                    Label("Kalender verbinden", systemImage: "calendar")
                } description: {
                    Text("Alle Kalender deines Macs: iCloud, Google, Exchange – nativ, ohne Webseite.")
                } actions: {
                    Button("Zugriff erlauben") { calendar.requestAccess() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Kalender")
        .toolbar {
            ToolbarItemGroup {
                Picker("Zeitraum", selection: $days) {
                    Text("7 Tage").tag(7)
                    Text("14 Tage").tag(14)
                    Text("30 Tage").tag(30)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Button { newEvent = true } label: { Label("Neuer Termin", systemImage: "plus") }.help(L("Neuer Termin"))
                    .disabled(calendar.access != .granted)
            }
        }
        .onAppear { calendar.reload(days: days) }
        .onChange(of: days) { _, d in calendar.reload(days: d) }
        .sheet(isPresented: $newEvent) { NewEventSheet(day: newOn) }
        .sheet(item: $editing) { e in NewEventSheet(event: e) }
    }

    @EnvironmentObject private var app: AppModel
    private func report(_ err: String?) { app.show(err.map { L("Nicht geändert: ") + $0 } ?? "✓ " + L("Im Mac-Kalender geändert")) }

    private var agenda: some View {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let visible = calendar.events.filter { !hidden.contains($0.calendarID) }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Grid.l) {
                ForEach(0..<days, id: \.self) { offset in
                    let day = cal.date(byAdding: .day, value: offset, to: start) ?? start
                    let list = visible.filter { cal.isDate($0.start, inSameDayAs: day) || ($0.allDay && $0.start <= day && $0.end > day) }
                    if !list.isEmpty || offset < 2 {
                        VStack(alignment: .leading, spacing: Grid.s) {
                            HStack {
                                Text(offset == 0 ? "Heute" : offset == 1 ? "Morgen" : day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                                    .font(.headline)
                                    .foregroundStyle(offset == 0 ? Color.accentColor : Color.primary)
                                Spacer()
                                Button { newOn = day; newEvent = true } label: { Image(systemName: "plus") }
                                    .buttonStyle(.borderless).help(L("Termin an diesem Tag anlegen"))
                            }
                            if list.isEmpty { Text("Keine Termine").foregroundStyle(.tertiary) }
                            ForEach(list) { e in
                                HStack(alignment: .top, spacing: Grid.m) {
                                    RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: e.color)).frame(width: 4)
                                    Text(e.allDay ? "ganztägig" : "\(e.start.timeString)–\(e.end.timeString)")
                                        .font(.callout.monospacedDigit()).frame(width: 110, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(e.title).font(.callout.weight(.medium))
                                        Text([e.calendar, e.location ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let url = e.url { Button("Beitreten") { Launcher.open(url) }.controlSize(.small) }
                                }
                                .padding(Grid.s)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: e.color).opacity(0.08)))
                                .opacity(e.end < Date() ? 0.5 : 1)
                                .contentShape(Rectangle())
                                .onTapGesture { if e.editable { editing = e } }
                                .help(e.editable ? L("Klicken zum Bearbeiten") : L("Dieser Kalender ist schreibgeschützt"))
                                .contextMenu {
                                    if e.editable {
                                        Button(L("Bearbeiten …")) { editing = e }
                                        Button(L("Eine Stunde später")) { report(calendar.move(e, by: 3600)) }
                                        Button(L("Auf morgen verschieben")) { report(calendar.move(e, by: 86400)) }
                                        Divider()
                                        Button(L("Löschen"), role: .destructive) { report(calendar.delete(e, wholeSeries: false)) }
                                    }
                                    if let url = e.url { Button(L("Beitreten")) { Launcher.open(url) } }
                                }
                            }
                        }
                    }
                }
            }
            .padding(Grid.l)
        }
    }
}

struct NewEventSheet: View {
    var event: CalEvent? = nil
    var day: Date? = nil
    @EnvironmentObject private var calendar: CalendarService
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var start = Calendar.current.date(bySettingHour: Calendar.current.component(.hour, from: Date()) + 1, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var end = Date()
    @State private var allDay = false
    @State private var calendarID = ""
    @State private var location = ""
    @State private var notes = ""
    @State private var wholeSeries = false

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.m) {
            Text(event == nil ? "Neuer Termin" : "Termin bearbeiten").font(.headline)
            Form {
                TextField("Titel", text: $title)
                Toggle("Ganztägig", isOn: $allDay)
                DatePicker("Beginn", selection: $start, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                    .onChange(of: start) { old, new in end = end.addingTimeInterval(new.timeIntervalSince(old)) }   // Dauer bleibt
                DatePicker("Ende", selection: $end, in: start..., displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                HStack(spacing: 6) {
                    Text("Dauer").foregroundStyle(.secondary)
                    ForEach([15, 30, 60, 90, 120], id: \.self) { m in
                        Button(m < 60 ? "\(m) Min." : "\(m / 60)\(m % 60 == 0 ? "" : ",5") Std.") { end = start.addingTimeInterval(TimeInterval(m * 60)) }
                            .controlSize(.small)
                    }
                }
                .disabled(allDay)
                Picker("Kalender", selection: $calendarID) {
                    ForEach(calendar.calendars.filter(\.allowsContentModifications), id: \.calendarIdentifier) { c in
                        Text("\(c.title) (\(c.source?.title ?? ""))").tag(c.calendarIdentifier)
                    }
                }
                TextField("Ort oder Link", text: $location)
                TextField("Notizen", text: $notes, axis: .vertical).lineLimit(3...8).dictation($notes, alignment: .trailing)
                if event?.recurring == true {
                    Toggle("Auch alle folgenden Termine der Serie ändern", isOn: $wholeSeries)
                }
            }
            .formStyle(.grouped)
            HStack {
                if let e = event {
                    Button("Löschen", role: .destructive) {
                        let err = calendar.delete(e, wholeSeries: wholeSeries)
                        app.show(err.map { "Nicht gelöscht: " + $0 } ?? "✓ Termin gelöscht")
                        if err == nil { dismiss() }
                    }
                }
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(event == nil ? "Anlegen" : "Sichern") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || calendarID.isEmpty)
            }
        }
        .padding(Grid.l)
        .frame(width: 520)
        .onAppear(perform: load)
    }

    private func load() {
        if let e = event {
            title = e.title; start = e.start; end = e.end; allDay = e.allDay
            calendarID = e.calendarID; location = e.location ?? ""; notes = e.notes
        } else {
            if let d = day {
                let h = Calendar.current.component(.hour, from: Date())
                start = Calendar.current.date(bySettingHour: Calendar.current.isDateInToday(d) ? min(h + 1, 22) : 10, minute: 0, second: 0, of: d) ?? d
            }
            end = start.addingTimeInterval(3600)
            calendarID = calendar.defaultCalendarID ?? calendar.calendars.first(where: \.allowsContentModifications)?.calendarIdentifier ?? ""
        }
    }

    private func save() {
        var s = start, e = end
        if allDay { s = Calendar.current.startOfDay(for: start); e = Calendar.current.startOfDay(for: end).addingTimeInterval(86399) }
        if let ev = event {
            let err = calendar.update(ev, title: title, start: s, end: e, allDay: allDay, calendarID: calendarID,
                                      location: location, notes: notes, wholeSeries: wholeSeries)
            app.show(err.map { "Nicht gesichert: " + $0 } ?? "✓ Im Mac-Kalender gesichert")
            if err == nil { dismiss() }
        } else {
            let ok = calendar.create(title: title, start: s, minutes: max(1, Int(e.timeIntervalSince(s) / 60)), calendarID: calendarID,
                                     location: location, notes: notes, allDay: allDay)
            app.show(ok ? "✓ Termin angelegt" : "Termin konnte nicht angelegt werden")
            if ok { dismiss() }
        }
    }
}
