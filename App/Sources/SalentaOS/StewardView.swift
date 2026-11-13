import AgenticOSKit
import SwiftUI

// Oberfläche des Projekt-Betreuers: Übersicht aller betreuten Projekte und die Projektseite
// (Gespräch mit dem Betreuer links, Aufgaben-Tafel rechts, Einrichtung und Signale oben).

struct StewardsView: View {
    @ObservedObject private var steward = Steward.shared
    @EnvironmentObject private var projects: ProjectCatalog
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Grid.l) {
                HStack(spacing: Grid.m) {
                    Image(systemName: "safari").font(.largeTitle).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Projekt-Betreuer").font(.largeTitle.weight(.semibold))
                        Text("Plant, schickt Helfer los, prüft und pflegt – pro Projekt.")
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                StewardHowItWorks(expanded: steward.projects.isEmpty)
                if !steward.projects.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: Grid.m)], spacing: Grid.m) {
                        ForEach(steward.projects) { p in card(p) }
                    }
                }
                Divider()
                Text("Projekt in Betreuung geben").font(.headline)
                // nur echte Repos – Arbeitskopien (git worktree: .git ist eine Datei) gehören zu ihrem Haupt-Repo
                let free = projects.local.filter { pr in
                    var isDir: ObjCBool = false
                    let gitIsDir = FileManager.default.fileExists(atPath: pr.path + "/.git", isDirectory: &isDir) && isDir.boolValue
                    return pr.isGit && gitIsDir && !steward.projects.map(\.id).contains(pr.path)
                }
                if free.isEmpty {
                    HStack {
                        Text(projects.local.isEmpty ? L("Noch keine Projekte – füge zuerst eins hinzu.")
                                                    : L("Alle deine Git-Projekte sind schon in Betreuung."))
                            .foregroundStyle(.secondary)
                        Button { app.page = .projects } label: { Label(L("Projekt hinzufügen"), systemImage: "plus") }
                            .help(L("Unter Projekte einen Ordner oder ein GitHub-Repo hinzufügen"))
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Grid.s)], spacing: Grid.s) {
                        ForEach(free) { pr in
                            Button {
                                let id = steward.adopt(pr.path)
                                app.page = .steward(id)
                            } label: {
                                HStack {
                                    Image(systemName: "plus.circle")
                                    VStack(alignment: .leading) {
                                        Text(pr.name).fontWeight(.medium)
                                        Text(pr.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(Grid.s)
                                .background(ModernCardBackground(radius: 10, accent: false))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(Grid.xl)
            .frame(maxWidth: 1100, alignment: .leading)
        }
    }

    private func card(_ p: StewardProject) -> some View {
        Button { app.page = .steward(p.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(p.name).font(.headline)
                    Spacer()
                    if p.count(.running) > 0 { LiveMark(size: 14, active: true) }
                    if p.continuous, !p.paused { Image(systemName: "infinity").foregroundStyle(Color.accentColor).help(L("Arbeitet bis zum Ziel")) }
                    if p.paused { Text("pausiert").font(.caption).foregroundStyle(.secondary) }
                }
                Text(p.goal.isEmpty ? L("Noch kein Ziel") : p.goal).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Grid.m) {
                        stat(p.count(.running), L("läuft"), .blue)
                        stat(p.count(.review), L("zum Übernehmen"), .green)
                        stat(p.count(.red), L("rot"), .red)
                        stat(p.count(.queued) + p.count(.idea), L("geplant"), .secondary)
                    }
                    HStack(spacing: Grid.s) {
                        stat(p.count(.running), L("läuft"), .blue)
                        stat(p.count(.review), L("fertig"), .green)
                        stat(p.count(.red), L("rot"), .red)
                    }
                }
                .font(.caption).lineLimit(1)
            }
            .padding(Grid.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ModernCardBackground(radius: 14))
        }
        .buttonStyle(.plain)
    }

    private func stat(_ n: Int, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 3) { Text("\(n)").fontWeight(.semibold).foregroundStyle(n > 0 ? color : .secondary); Text(label).foregroundStyle(.secondary) }
    }
}

struct StewardProjectView: View {
    let id: String
    @ObservedObject private var steward = Steward.shared
    @ObservedObject private var exts = ExtensionStore.shared
    @EnvironmentObject private var app: AppModel
    @State private var input = ""
    @State private var newTask = ""
    @State private var showSetup = false
    @State private var showDone = false
    @State private var showMemory = false
    @State private var overview: StewardOverview.Filter?
    @State private var tab: BoardTab = .now
    @AppStorage("steward.showActivity") private var showActivity = false
    @AppStorage("steward.collapsed") private var collapsedRaw = ""          // eingeklappte Abschnitte (gemerkt)
    @State private var openRows: Set<String> = []                          // aufgeklappte Einträge
    enum BoardTab: String { case now, tasks, prs, done }
    @AppStorage("steward.narrowPane") private var narrowPane = "board"     // schmales Fenster: Gespräch oder Tafel

    var body: some View {
        if let p = steward.project(id) {
            VStack(spacing: 0) {
                header(p)
                Divider()
                GeometryReader { geo in
                    if geo.size.width >= 820 {
                        HStack(spacing: 0) {
                            chat(p).frame(minWidth: 340, idealWidth: 460)
                            Divider()
                            board(p).frame(minWidth: 380)
                        }
                    } else {
                        // Schmal: eine Spalte, oben umschalten statt zwei gequetschter Spalten
                        VStack(spacing: 0) {
                            Picker("", selection: $narrowPane) {
                                Text(L("Gespräch")).tag("chat")
                                Text(L("Aufgaben")).tag("board")
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                            .padding(.vertical, Grid.s)
                            Divider()
                            if narrowPane == "chat" { chat(p) } else { board(p) }
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("Projekt nicht in Betreuung", systemImage: "safari")
        }
    }

    // MARK: Kopf

    private func header(_ p: StewardProject) -> some View {
        VStack(alignment: .leading, spacing: Grid.s) {
            HStack(spacing: Grid.m) {
                Image(systemName: "safari").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(p.name).font(.title3.weight(.semibold))
                        StewardStatusPill(p: p)
                    }
                    TextField(L("Ziel, z. B. „Bis Ende Monat: Zahlungen live und keine roten Tests“"), text: Binding(
                        get: { p.goal },
                        set: { v in if let i = steward.projects.firstIndex(where: { $0.id == id }) { steward.projects[i].goal = v } }))
                        .textFieldStyle(.plain).foregroundStyle(.secondary)
                        .onSubmit { steward.save() }
                }
                Spacer(minLength: Grid.s)
                ViewThatFits(in: .horizontal) {
                    headerControls(p, small: false)
                    headerControls(p, small: true)
                }
                .layoutPriority(1)   // Bedienelemente zuerst, das Ziel-Feld nimmt den Rest
            }
            if p.continuous { continuousBar(p) }
            ViewThatFits(in: .horizontal) {
                statusLine(p, small: false)
                statusLine(p, small: true)
            }
        }
        .padding(.horizontal, Grid.l).padding(.vertical, Grid.m)
    }

    // MARK: Kopf-Bausteine (passen sich der Breite an, nichts bricht um)

    @ViewBuilder private func headerControls(_ p: StewardProject, small: Bool) -> some View {
        HStack(spacing: small ? 6 : Grid.s) {
            Menu {
                    Picker(L("Vertrauen"), selection: binding(\.trust)) {
                        Text("Nur vorschlagen").tag(0)
                        Text("Selbst starten, du übernimmst").tag(1)
                        Text("Grünes selbst übernehmen").tag(2)
                    }
                    Divider()
                    Picker(L("Parallel"), selection: binding(\.parallel)) { ForEach(1...4, id: \.self) { Text("\($0) " + L("gleichzeitig")).tag($0) } }
                    Picker(L("Tagesbudget"), selection: binding(\.dailyRuns)) {
                        ForEach([3, 5, 8, 12, 20, 40], id: \.self) { Text("\($0) " + L("Aufträge/Tag")).tag($0) }
                        Text(L("Unbegrenzt (kein Tagesbudget)")).tag(0)
                    }
                    Picker(L("Täglicher Rundgang"), selection: binding(\.roundHour)) { ForEach([6, 7, 8, 9, 12, 18, 22], id: \.self) { Text("\($0):00").tag($0) } }
                    Divider()
                    Toggle(L("CI auf GitHub beobachten"), isOn: binding(\.watchCI))
                    Section(L("GitHub-Wächter")) {
                        Toggle(L("Ergebnisse als Pull Request liefern"), isOn: optBinding(\.github, true))
                        Toggle(L("Grüne, geprüfte PRs selbst mergen"), isOn: Binding(get: { steward.project(id)?.mergesPRs == true },
                                                                                    set: { v in steward.update(id) { $0.autoMerge = v } }))
                        Toggle(L("Auch PRs von anderen mergen"), isOn: optBinding(\.mergeAll, false))
                        Toggle(L("Review als Kommentar auf GitHub schreiben"), isOn: optBinding(\.postReviews, true))
                        TextField(L("Label nach grünem Review (leer = aus)"), text: Binding(get: { steward.project(id)?.reviewLabel ?? "" },
                                                                                            set: { v in steward.update(id) { $0.reviewLabel = v.isEmpty ? nil : v } }))
                            .help(L("Verlangt dein Repo eine Freigabe per Label, bevor ein PR grün wird? Trag den Namen ein – der Betreuer setzt es nach seinem grünen Review."))
                        let def = p.setup?.defaultBranch ?? "main"
                        let options = Array(Set([def, "main", p.prBase ?? def])).sorted()
                        Picker(L("Pull Requests gehen nach"), selection: Binding(get: { steward.project(id)?.prBase ?? def },
                                                                               set: { v in steward.update(id) { $0.prBase = v } })) {
                            ForEach(options, id: \.self) { b in Text(b + (b == def ? " (" + L("Haupt-Branch") + ")" : "")).tag(b) }
                        }
                    }
                    Divider()
                    Toggle(L("Bis zum Ziel durcharbeiten"), isOn: Binding(get: { steward.project(id)?.continuous == true }, set: { steward.setContinuous(id, $0) }))
                    Toggle(L("Danach selbst verbessern"), isOn: Binding(get: { steward.project(id)?.improve == true }, set: { steward.setImprove(id, $0) }))
                    Divider()
                    Button(L("Betreuung beenden"), role: .destructive) { steward.release(id); app.page = .stewards }
            } label: {
                if small { Image(systemName: p.trust == 2 ? "checkmark.shield.fill" : "shield.lefthalf.filled") }
                else { Label(trustLabel(p.trust), systemImage: p.trust == 2 ? "checkmark.shield.fill" : "shield.lefthalf.filled") }
            }
            .fixedSize()
            .help(trustExplain(p.trust))
            extensionMenu(p)
            Toggle(isOn: Binding(get: { steward.project(id)?.continuous == true }, set: { steward.setContinuous(id, $0) })) {
                if small { Image(systemName: "infinity") } else { Text(L("Bis zum Ziel")).font(.callout) }
            }
            .toggleStyle(.switch).controlSize(.small).fixedSize()
            .help(L("Dauerbetrieb: Der Betreuer plant immer wieder neu und arbeitet weiter, bis das Ziel erreicht ist – im Rahmen von Tagesbudget und Limits. Nur wenn er dich wirklich braucht, hält er an."))
            Toggle(isOn: Binding(get: { steward.project(id)?.paused != true }, set: { v in steward.update(id) { $0.paused = !v }; if v { steward.dispatch(id) } })) {
                Text(p.paused ? L("Aus") : L("An")).font(.callout.weight(.semibold)).foregroundStyle(p.paused ? Color.secondary : Color.green)
            }
            .toggleStyle(.switch).tint(.green).fixedSize()
            .help(p.paused ? L("Betreuer ist aus – einschalten, damit er plant, Helfer startet und liefert") : L("Betreuer ist an – ausschalten startet nichts Neues (laufende Helfer machen fertig)"))
        }
        .lineLimit(1)
    }

    // MARK: Statuszeile – das Wichtige als Zahlen (ein Klick öffnet die Übersicht), rechts Einrichtung und Projektwissen

    @ViewBuilder private func statusLine(_ p: StewardProject, small: Bool) -> some View {
        let done = p.tasks.filter { $0.state == .done }
        let working = p.tasks.filter { [.running, .queued].contains($0.state) || ($0.state == .review && $0.pr != nil) }
        let needs = p.tasks.filter { ($0.state == .review && $0.pr == nil) || $0.state == .red }
        let week = done.filter { ($0.finished ?? $0.created) > Date().addingTimeInterval(-7 * 86400) }.count
        let details = [L("Gestartete Helfer heute / Tagesbudget") + ": " + p.budgetText, "\(p.parallel) " + L("parallel"),
                       p.greenStreak > 0 ? "\(p.greenStreak) " + L("grün in Folge") : "", L("Rundgang") + " \(p.roundHour):00"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        HStack(spacing: small ? Grid.s : Grid.m) {
            count("hand.raised.fill", .orange, needs.count, small ? "" : L("braucht dich"), .needs, strong: !needs.isEmpty)
            count("gearshape.2.fill", .blue, working.count, small ? "" : L("in Arbeit"), .working)
            if p.hasGitHub, steward.isGitHubWatcher(id) { count("arrow.triangle.pull", .purple, (p.prs ?? []).count, small ? "" : L("PRs offen"), .prs) }
            count("checkmark.seal.fill", .green, done.count, small ? "" : L("erledigt") + (week > 0 ? " · \(week) " + L("diese Woche") : ""), .done)
            Spacer(minLength: Grid.s)
            if !p.budgetLeft {
                Button(L("Heute +10")) { steward.update(id) { q in var e = q.extraToday ?? [:]; e[q.today, default: 0] += 10; q.extraToday = e }; steward.dispatch(id) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).fixedSize().help(L("Nur für heute 10 Aufträge mehr – morgen gilt wieder das normale Budget"))
                Button(L("Unbegrenzt")) { steward.update(id) { $0.dailyRuns = 0 }; steward.dispatch(id) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).fixedSize().help(L("Tagesbudget ganz abschalten – gebremst wird nur noch durch Parallel-Grenze, Limits und Energiesparen"))
            }
            if !small { Label(p.budgetText, systemImage: "bolt.fill").foregroundStyle(.secondary).help(details) }
            Button { showSetup.toggle() } label: {
                if small { Image(systemName: "wrench.and.screwdriver") } else { Label(L("Einrichtung"), systemImage: "wrench.and.screwdriver") }
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary).fixedSize().help(L("Einrichtung"))
            .popover(isPresented: $showSetup) { setupView(p) }
            Button { showMemory = true } label: {
                if small { Image(systemName: "brain.head.profile") } else { Label(L("Projektwissen"), systemImage: "brain.head.profile") }
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary).fixedSize().help(L("Was die Agents über dieses Projekt gelernt haben – gilt für alle Agents"))
            .sheet(isPresented: $showMemory) { ProjectMemorySheet(directory: id) }
        }
        .font(.callout).lineLimit(1)
        .sheet(item: $overview) { f in StewardOverview(id: id, filter: f) }
    }

    private func count(_ icon: String, _ color: Color, _ n: Int, _ label: String, _ f: StewardOverview.Filter, strong: Bool = false) -> some View {
        Button { overview = f } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption).foregroundStyle(n > 0 ? color : Color.secondary)
                Text("\(n)").fontWeight(.semibold).monospacedDigit()
                if !label.isEmpty { Text(label).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, strong ? 8 : 0).padding(.vertical, strong ? 3 : 0)
            .background { if strong { Capsule().fill(color.opacity(0.16)) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).fixedSize()
        .help(L("Übersicht öffnen"))
    }

    // MARK: Dauerbetrieb und Erweiterungen

    @ViewBuilder private func continuousBar(_ p: StewardProject) -> some View {
        let reached = p.goalReached != nil
        let (icon, color, title, text): (String, Color, String, String) = {
            if let b = p.blocked { return ("hand.raised.fill", .orange, L("Wartet auf dich"), b) }
            if p.paused { return ("pause.fill", .secondary, L("Pausiert"), L("Dauerbetrieb ist an, aber pausiert – es startet nichts Neues.")) }
            if !Energy.backgroundAgentsOK { return ("leaf.fill", .green, L("Wartet aufs Netzteil"), (Energy.reason ?? "") + " – " + L("spart Akku und macht am Netzteil automatisch weiter. Änderbar unter Einstellungen › Energie & Akku.")) }
            if reached && p.improve != true { return ("flag.checkered", .green, L("Ziel erreicht"), L("Fertig. Schalte „Danach selbst verbessern“ ein oder gib ein neues Ziel.")) }
            if !p.budgetLeft { return ("moon.zzz", .secondary, L("Tagesbudget aufgebraucht"), L("Macht morgen automatisch weiter – oder jetzt weiter mit „Heute +10“ bzw. „Unbegrenzt“ (Zeile darunter).")) }
            if reached { return ("sparkles", .purple, L("Ziel erreicht – verbessert weiter"), p.progress ?? L("Sucht selbst nach Fehlern, Tests, Tempo, Sicherheit und Bedienung.")) }
            return ("infinity", .accentColor, L("Arbeitet bis zum Ziel"), p.progress ?? L("Plant nach jeder Runde sofort die nächste."))
        }()
        HStack(alignment: .firstTextBaseline, spacing: Grid.s) {
            Image(systemName: icon).foregroundStyle(color)
            (Text(title).fontWeight(.semibold) + Text("  " + text).foregroundStyle(.secondary))
                .font(.callout).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .help(text)
            Spacer(minLength: 0)
            if p.blocked != nil {
                Button(L("Weiter versuchen")) { steward.setContinuous(id, true) }.controlSize(.small)
            }
        }
        .padding(.horizontal, Grid.s).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.08)))
    }

    private func extensionMenu(_ p: StewardProject) -> some View {
        let installed = ExtensionStore.shared.installedList
        let chosen = Set(p.extensions ?? [])
        return Menu {
            if installed.isEmpty {
                Text("Noch keine Erweiterung installiert")
            } else {
                Section(L("Jeder Helfer nutzt die ausgewählten")) {
                    ForEach(installed) { e in
                        Toggle(e.name, isOn: Binding(get: { chosen.contains(e.id) }, set: { _ in steward.toggleExtension(id, e.id) }))
                    }
                }
            }
            Divider()
            Button(L("Erweiterungen verwalten …")) { app.page = .extensions }
        } label: {
            Label(chosen.isEmpty ? L("Erweiterungen") : "\(chosen.count) " + L("Erweiterungen"), systemImage: "puzzlepiece.extension")
        }
        .fixedSize()
        .help(L("Plugins, Skills und MCP-Server, die jeder Helfer in diesem Projekt nutzen soll. Plugins und Skills gehen an Claude Code, MCP-Server an alle Agents."))
    }

    private func trustExplain(_ t: Int) -> String {
        [L("Nur vorschlagen: Der Betreuer plant und schlägt Aufgaben vor – gestartet wird erst, wenn du auf „Starten“ klickst."),
         L("Selbst starten: Der Betreuer startet Helfer im Rahmen von Tagesbudget und Parallel-Grenze. Übernehmen entscheidest du."),
         L("Grünes übernehmen: Ist alles geprüft und grün, übernimmt der Betreuer selbst. Rotes und Riskantes landet immer bei dir.")][min(max(t, 0), 2)]
    }

    private func trustLabel(_ t: Int) -> String {
        [L("Vertrauen: vorschlagen"), L("Vertrauen: selbst starten"), L("Vertrauen: Grünes übernehmen")][min(max(t, 0), 2)]
    }

    private func optBinding(_ kp: WritableKeyPath<StewardProject, Bool?>, _ def: Bool) -> Binding<Bool> {
        Binding(get: { steward.project(id)?[keyPath: kp] ?? def },
                set: { v in steward.update(id) { $0[keyPath: kp] = v } })
    }

    private func binding<T>(_ kp: WritableKeyPath<StewardProject, T>) -> Binding<T> {
        Binding(get: { steward.project(id)![keyPath: kp] },
                set: { v in
                    if let i = steward.projects.firstIndex(where: { $0.id == id }) { steward.projects[i][keyPath: kp] = v; steward.save(); steward.dispatch(id) }
                })
    }

    private func setupView(_ p: StewardProject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Einrichtung").font(.headline)
            if let s = p.setup {
                Text(s.stack.isEmpty ? L("Stack nicht erkannt") : s.stack.joined(separator: " · ")).foregroundStyle(.secondary)
                ForEach(s.commands.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                    HStack { Text(k).frame(width: 80, alignment: .leading).foregroundStyle(.secondary); Text(v).font(.system(.caption, design: .monospaced)) }
                }
                if !s.envFiles.isEmpty { Text(L("Umgebung: ") + s.envFiles.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                Text(L("Branch: ") + s.defaultBranch + (s.remote.map { " · " + $0 } ?? "")).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            } else {
                HStack { ProgressView().controlSize(.small); Text("Wird eingerichtet …") }
            }
            Divider()
            HStack {
                Button(L("Neu erkennen")) { steward.runSetup(id) }
                Button(L("Als Prüfschleife festlegen")) { steward.saveVerifyConfig(id) }
                    .help(L("Merkt sich Test-, Lint-, Typen- und Build-Befehl für dieses Projekt – jede Aufgabe wird damit geprüft (nichts davon landet im Code)"))
                    .disabled(p.setup == nil)
            }
            Divider()
            Button(L("Betreuung beenden"), role: .destructive) { showSetup = false; steward.release(id); app.page = .stewards }
                .help(L("Der Betreuer hört auf – laufende Aufträge und das Projektwissen bleiben"))
        }
        .padding(Grid.m).frame(width: 440)
    }

    // MARK: Gespräch

    private func chat(_ p: StewardProject) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Grid.m) {
                        // Ruhiger Verlauf: dein Gespräch mit dem Betreuer; technische Meldungen nur, wenn wichtig oder eingeschaltet
                        ForEach(p.messages.filter { m in showActivity || m.role != "system" || Self.important(m.text) }) { m in bubble(m) }
                        if p.thinking == true {
                            HStack(spacing: Grid.s) { ProgressView().controlSize(.small); Text("Betreuer denkt nach …").foregroundStyle(.secondary) }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(Grid.l)
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: p.messages.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
            HStack {
                let hidden = p.messages.filter { $0.role == "system" && !Self.important($0.text) }.count
                Toggle(isOn: $showActivity) { Text(L("Technische Meldungen zeigen") + (hidden > 0 && !showActivity ? " (\(hidden))" : "")) }
                    .toggleStyle(.checkbox).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, Grid.m).padding(.vertical, 4)
            Divider()
            StewardLivePanel(id: id)
            // Eigene Ansicht mit eigenem Zustand: Tippen oder Einfügen (auch sehr lange Texte) baut nicht die ganze Seite neu
            StewardInput(placeholder: p.goal.isEmpty ? L("Was ist das Ziel?") : L("Sag dem Betreuer, was als Nächstes wichtig ist …"),
                         busy: p.thinking == true) { t in sendInput(t) }
        }
    }

    static func important(_ t: String) -> Bool {
        ["✋", "🔴", "🎯", "🎉"].contains { t.hasPrefix($0) }
    }

    private func sendInput(_ t: String) {
        if steward.project(id)?.goal.isEmpty == true, let i = steward.projects.firstIndex(where: { $0.id == id }) {
            // Ziel = erster Absatz (kurz); der ganze Text geht als Nachricht an den Betreuer
            let first = t.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first ?? t
            steward.projects[i].goal = String(first.prefix(300))
        }
        steward.send(id, t)
    }

    @ViewBuilder private func bubble(_ m: StewardMessage) -> some View {
        switch m.role {
        case "du":
            HStack { Spacer(minLength: 60); Text(m.text).textSelection(.enabled).padding(Grid.m)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.12))) }
        case "status":
            HStack(spacing: 6) {
                Text(m.text).font(.caption).foregroundStyle(m.text.hasPrefix("✗") ? .red : .secondary).lineLimit(2)
                Spacer()
                Text(m.date.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Grid.s)
        case "system":
            // Alte Rohfehler von git/GitHub auch nachträglich verständlich zeigen
            let raw = m.text.contains("[rejected]") || m.text.contains("error:") || m.text.contains("fatal:")
            let shown = raw ? "⚠️ " + (m.text.components(separatedBy: ":").first ?? "") + ": " + GitError.explain(m.text) : m.text
            Text(LocalizedStringKey(shown)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .padding(.horizontal, Grid.s)
        default:
            HStack(alignment: .top, spacing: Grid.s) {
                Image(systemName: "safari").foregroundStyle(Color.accentColor)
                Text(LocalizedStringKey(m.text)).textSelection(.enabled)
                Spacer(minLength: 20)
            }
        }
    }

    // MARK: Aufgaben-Tafel

    private func board(_ p: StewardProject) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Grid.m) {
                    let needs = p.tasks.filter { ($0.state == .review && $0.pr == nil) || $0.state == .red }
                    let running = p.tasks.filter { $0.state == .running }
                    let onGitHub = p.tasks.filter { $0.state == .review && $0.pr != nil }
                    let queued = p.tasks.filter { $0.state == .queued }.sorted { $0.priority < $1.priority }
                    let ideas = p.tasks.filter { $0.state == .idea }
                    let done = p.tasks.filter { $0.state == .done || $0.state == .dropped }
                    let watcher = p.hasGitHub && steward.isGitHubWatcher(id)
                    // Reiter: Jetzt (das Wichtige) · Aufgaben · Pull Requests · Erledigt
                    HStack(spacing: Grid.s) {
                        ViewThatFits(in: .horizontal) {
                            boardTabs(p, counts: (needs.count, queued.count + ideas.count, watcher ? (p.prs ?? []).count : -1, done.filter { $0.state == .done }.count))
                            boardTabs(p, counts: nil)
                        }
                        Spacer(minLength: 0)
                        Button { steward.think(id, trigger: L("Bitte prüf den Stand und plan die nächsten Schritte.")) } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help(L("Neu planen")).disabled(p.thinking == true)
                    }
                    StewardOrderComposer(projectID: id, busy: p.thinking == true)
                    switch tab {
                    case .now:
                        StewardOrdersCard(p: p)
                        if needs.isEmpty && running.isEmpty {
                            Label(queued.isEmpty ? L("Alles ruhig – nichts braucht dich gerade.") : String(format: L("Alles ruhig – %d Aufgaben warten in der Warteschlange."), queued.count),
                                  systemImage: "checkmark.circle").foregroundStyle(.secondary)
                        }
                        section(L("Braucht dich"), needs, p)
                        section(L("Läuft"), running, p)
                        section(L("Als PR auf GitHub – wartet auf CI, Review und Merge"), onGitHub, p)
                        if !queued.isEmpty {
                            section(L("Als Nächstes"), Array(queued.prefix(3)), p)
                            if queued.count > 3 { Button(String(format: L("Alle %d Aufgaben ansehen"), queued.count)) { tab = .tasks }.buttonStyle(.link) }
                        }
                    case .tasks:
                        section(L("Warteschlange"), queued, p)
                        section(L("Vorschläge"), ideas, p)
                        if queued.isEmpty && ideas.isEmpty { Text("Keine offenen Aufgaben.").foregroundStyle(.secondary) }
                    case .prs:
                        StewardPRSection(id: id)
                    case .done:
                        if done.isEmpty { Text("Noch nichts erledigt.").foregroundStyle(.secondary) }
                        VStack(alignment: .leading, spacing: 6) { ForEach(done.suffix(40).reversed()) { row($0, p) } }
                    }
                    if p.tasks.isEmpty {
                        Text("Noch keine Aufgaben. Sag dem Betreuer links das Ziel – er plant dann.").foregroundStyle(.secondary)
                        StewardHowItWorks(expanded: true)
                    }
                }
                .padding(Grid.l)
            }
            // Eine einzelne Aufgabe direkt einreihen – nur im Reiter „Aufgaben“, damit die Startansicht ruhig bleibt
            if tab == .tasks {
                Divider()
                HStack {
                    TextField(L("Einzelaufgabe einreihen …"), text: $newTask).textFieldStyle(.plain)
                        .onSubmit { steward.addTask(id, title: newTask); newTask = "" }
                    Button { steward.addTask(id, title: newTask); newTask = "" } label: { Image(systemName: "plus") }
                        .help(L("Einreihen"))
                        .disabled(newTask.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(Grid.m)
            }
        }
    }

    private func boardTabs(_ p: StewardProject, counts: (Int, Int, Int, Int)?) -> some View {
        func n(_ v: Int?) -> String { guard let v, v > 0 else { return "" }; return " \(v)" }
        return Picker("", selection: $tab) {
            Text(L("Jetzt") + n(counts?.0)).tag(BoardTab.now)
            Text(L("Aufgaben") + n(counts?.1)).tag(BoardTab.tasks)
            if p.hasGitHub { Text("PRs" + n(counts.map { $0.2 })).tag(BoardTab.prs) }
            Text(L("Erledigt") + n(counts?.3)).tag(BoardTab.done)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
    }

    @ViewBuilder private func section(_ title: String, _ items: [StewardTask], _ p: StewardProject) -> some View {
        if !items.isEmpty {
            let key = title
            let collapsed = collapsedRaw.split(separator: "|").contains(Substring(key))
            DisclosureGroup(isExpanded: Binding(get: { !collapsed }, set: { open in
                var set = Set(collapsedRaw.split(separator: "|").map(String.init))
                if open { set.remove(key) } else { set.insert(key) }
                collapsedRaw = set.sorted().joined(separator: "|")
            })) {
                VStack(alignment: .leading, spacing: 4) { ForEach(items) { row($0, p) } }.padding(.top, 4)
            } label: {
                Text("\(title) (\(items.count))").font(.headline)
            }
        }
    }

    private func row(_ t: StewardTask, _ p: StewardProject) -> some View {
        let open = openRows.contains(t.id)
        let urgent = [.review, .red, .idea].contains(t.state) && t.pr == nil
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: Grid.s) {
                stateIcon(t.state)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).fontWeight(.medium).lineLimit(open ? 3 : 1)
                    if open || urgent { HStack(spacing: 6) {
                        Text(sourceLabel(t.source))
                        if t.agent != "auto" { Text("· " + (AgentKind(rawValue: t.agent)?.title ?? t.agent) + (t.model.isEmpty ? "" : " " + t.model)) }
                        if let s = t.started, t.state == .running { Text("· ") + Text(s, style: .relative) }
                    }
                    .font(.caption).foregroundStyle(.tertiary) }
                    if let n = t.note, !n.isEmpty, open || urgent { Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(open ? 8 : 2) }
                    // Was diese Aufgabe mitbekommt: vom Betreuer gewählte Skills und Erweiterungen
                    if open || t.state == .running {
                        let ext = (t.exts ?? []).compactMap { ExtensionCatalog.find($0)?.name }
                        ToolChips(skills: t.skills ?? [], exts: ext, compact: !open)
                    }
                }
                Spacer()
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture { if open { openRows.remove(t.id) } else { openRows.insert(t.id) } }
            if open || urgent { HStack(spacing: 6) {
                Spacer()
                switch t.state {
                case .idea:
                    Button(L("Verwerfen")) { steward.drop(id, task: t.id) }
                    Button(L("Los")) { steward.start(id, task: t.id) }.buttonStyle(.borderedProminent)
                case .queued:
                    Button(L("Entfernen")) { steward.drop(id, task: t.id) }
                case .running:
                    if let m = t.missionID { Button(L("Ansehen")) { app.page = .chat(m) } }
                case .review:
                    if let m = t.missionID { Button(L("Ansehen")) { app.page = .chat(m) } }
                    Button(L("Verwerfen")) { steward.resolve(id, task: t.id, accept: false) { app.show($0) } }
                    Button(t.pr.map { String(format: L("PR #%d mergen"), $0) } ?? L("Übernehmen")) { steward.resolve(id, task: t.id, accept: true) { app.show($0) } }
                        .buttonStyle(.borderedProminent).tint(.green)
                case .red:
                    if let m = t.missionID { Button(L("Ansehen")) { app.page = .chat(m) } }
                    Button(L("Verwerfen")) { steward.resolve(id, task: t.id, accept: false) { app.show($0) } }
                    Button(L("Nochmal versuchen")) { steward.retry(id, task: t.id) }.buttonStyle(.borderedProminent).tint(.orange)
                case .done, .dropped:
                    if let m = t.missionID { Button(L("Ansehen")) { app.page = .chat(m) } }
                }
            }
            .controlSize(.small).lineLimit(1).fixedSize() }
        }
        .padding(.horizontal, Grid.s).padding(.vertical, open || urgent ? Grid.s : 6)
        .background(ModernCardBackground(radius: 10, accent: false))
        .opacity(t.state == .dropped ? 0.5 : 1)
    }

    @ViewBuilder private func stateIcon(_ s: StewardTask.State) -> some View {
        switch s {
        case .idea: Image(systemName: "lightbulb").foregroundStyle(.yellow)
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: LiveMark(size: 16, active: true)
        case .review: Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
        case .red: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .done: Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        case .dropped: Image(systemName: "minus.circle").foregroundStyle(.tertiary)
        }
    }

    private func sourceLabel(_ s: String) -> String {
        switch s {
        case "du": return L("von dir")
        case "ci": return L("CI rot")
        case "kunde": return L("Kunde")
        case "rundgang": return L("Rundgang")
        default: return L("Betreuer")
        }
    }
}


/// Kurz erklärt, wie der Projekt-Betreuer arbeitet – auf der Übersicht und im Projekt.
struct StewardHowItWorks: View {
    @State var expanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: Grid.s) {
                step(1, "plus.circle", L("Projekt in Betreuung geben"), L("Unten ein Projekt wählen. Der Betreuer erkennt Technik, Test- und Build-Befehle selbst."))
                step(2, "target", L("Ziel setzen"), L("Oben im Projekt in einem Satz, z. B. „Bis Freitag: Checkout fertig, keine roten Tests“. Du kannst ihm jederzeit links schreiben."))
                step(3, "sunrise", L("Er plant und arbeitet"), L("Beim täglichen Rundgang plant er Aufgaben, schickt Helfer (Claude, Codex, Junie, lokal …) los, prüft jedes Ergebnis mit Tests und Review und beobachtet die CI auf GitHub."))
                step(4, "infinity", L("Bis zum Ziel"), L("Mit „Bis zum Ziel“ hört er nicht nach einer Runde auf: Er plant immer wieder neu, bis das Ziel erreicht ist – und sucht danach auf Wunsch selbst Verbesserungen. Er hält nur an, wenn er dich wirklich braucht."))
                step(5, "hand.raised", L("Du entscheidest"), L("Je nach Vertrauen schlägt er nur vor, startet selbst oder übernimmt sogar Grünes. Tagesbudget und Parallel-Grenze halten die Kosten im Rahmen."))
                Label(L("Er schreibt selbst keinen Code, deployt nie, veröffentlicht nichts und schreibt keinen Kunden an."), systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, Grid.s)
        } label: {
            Label(L("So funktioniert der Projekt-Betreuer"), systemImage: "questionmark.circle").font(.headline)
        }
        .padding(Grid.m)
        .background(ModernCardBackground(radius: 12))
    }

    private func step(_ n: Int, _ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Grid.m) {
            Text("\(n)").font(.callout.weight(.bold)).foregroundStyle(.white).frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: icon).font(.callout.weight(.semibold))
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}


/// Übersicht des Betreuers: was erledigt ist (nach Tagen), was läuft, was dich braucht, offene PRs.
struct StewardOverview: View {
    enum Filter: String, Identifiable { case done, working, needs, prs; var id: String { rawValue } }
    let id: String
    let filter: Filter
    @ObservedObject private var steward = Steward.shared
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var current: Filter

    init(id: String, filter: Filter) { self.id = id; self.filter = filter; _current = State(initialValue: filter) }

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.m) {
            HStack {
                Text(steward.project(id)?.name ?? "").font(.title3.weight(.semibold))
                Spacer()
                Picker("", selection: $current) {
                    Text("Erledigt").tag(Filter.done)
                    Text("In Bearbeitung").tag(Filter.working)
                    Text("Braucht dich").tag(Filter.needs)
                    if steward.project(id)?.hasGitHub == true { Text("Pull Requests").tag(Filter.prs) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 460)
                Button(L("Schließen")) { dismiss() }
            }
            if let p = steward.project(id) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Grid.m) {
                        switch current {
                        case .done: doneList(p)
                        case .working: list(p.tasks.filter { [.running, .queued].contains($0.state) || ($0.state == .review && $0.pr != nil) })
                        case .needs: list(p.tasks.filter { ($0.state == .review && $0.pr == nil) || $0.state == .red })
                        case .prs: StewardPRSection(id: id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(Grid.l)
        .frame(width: 760, height: 600)
    }

    @ViewBuilder private func doneList(_ p: StewardProject) -> some View {
        let done = p.tasks.filter { $0.state == .done }.sorted { ($0.finished ?? $0.created) > ($1.finished ?? $1.created) }
        if done.isEmpty { Text("Noch nichts erledigt.").foregroundStyle(.secondary) }
        let days = Dictionary(grouping: done) { Calendar.current.startOfDay(for: $0.finished ?? $0.created) }
        ForEach(days.keys.sorted(by: >), id: \.self) { day in
            VStack(alignment: .leading, spacing: 4) {
                Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.headline)
                list(days[day] ?? [])
            }
        }
    }

    private func list(_ tasks: [StewardTask]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if tasks.isEmpty { Text("Nichts.").foregroundStyle(.secondary) }
            ForEach(tasks) { t in
                Button {
                    if let m = t.missionID { dismiss(); app.page = .chat(m) }
                } label: {
                    HStack(alignment: .top, spacing: Grid.s) {
                        Image(systemName: t.state == .done ? "checkmark.circle.fill" : t.state == .red ? "xmark.octagon.fill" : t.state == .running ? "gearshape.2" : "clock")
                            .foregroundStyle(t.state == .done ? .green : t.state == .red ? .red : .blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).fontWeight(.medium)
                            if let n = t.note, !n.isEmpty { Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                            HStack(spacing: 6) {
                                if t.agent != "auto" { Text(AgentKind(rawValue: t.agent)?.title ?? t.agent) }
                                if let pr = t.pr { Text("PR #\(pr)") }
                                if let f = t.finished { Text(f.formatted(date: .omitted, time: .shortened)) }
                            }
                            .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if t.missionID != nil { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                    }
                    .padding(Grid.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ModernCardBackground(radius: 10, accent: false))
                }
                .buttonStyle(.plain)
                .disabled(t.missionID == nil)
            }
        }
    }
}


/// Eingabe beim Betreuer: mehrzeilig, scrollt bei langen Texten, ⌘↩ sendet.
struct StewardInput: View {
    let placeholder: String
    let busy: Bool
    let send: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    static func height(for text: String) -> CGFloat {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { $0 + max(1, ($1.count + 69) / 70) }
        return min(140, max(22, CGFloat(lines) * 17 + 5))
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: Grid.s) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).foregroundStyle(.tertiary).padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    // Feste, geschätzte Höhe statt fixedSize: sonst misst SwiftUI bei langem Text die ganze Seite
                    // immer wieder neu (Hänger von mehreren Sekunden beim Einfügen langer Nachrichten)
                    .frame(height: Self.height(for: text))
            }
            MicButton { t in text += (text.isEmpty || text.hasSuffix(" ") ? "" : " ") + t }
            Button { submit() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .help(L("Senden (⌘↩)"))
                .buttonStyle(.plain)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(Grid.m)
    }

    private func submit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        text = ""
        send(t)
    }
}


/// Was der Betreuer gerade tut: jeder laufende Helfer mit aktuellem Schritt, Dauer und Schrittzahl – live.
struct StewardLivePanel: View {
    let id: String
    @ObservedObject private var steward = Steward.shared
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var app: AppModel

    var body: some View {
        if let p = steward.project(id) {
            let running = p.tasks.filter { $0.state == .running }
            let waitingPR = p.tasks.filter { $0.state == .review && $0.pr != nil }.count
            if !running.isEmpty || p.thinking == true || waitingPR > 0 {
                TimelineView(.periodic(from: .now, by: Energy.saving ? 10 : 3)) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Circle().fill(.green).frame(width: 7, height: 7)
                            Text("Gerade los").font(.caption.weight(.semibold))
                            Spacer()
                            if waitingPR > 0 { Text(String(format: L("%d PRs warten auf CI/Review"), waitingPR)).font(.caption2).foregroundStyle(.secondary) }
                        }
                        if p.thinking == true {
                            Label(L("Betreuer plant die nächsten Schritte …"), systemImage: "brain").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(running) { t in line(t) }
                    }
                    .padding(Grid.s)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.06)))
                    .padding(.horizontal, Grid.m)
                }
            }
        }
    }

    private func line(_ t: StewardTask) -> some View {
        let s = t.missionID.flatMap { mid in agents.sessions.first { $0.id.uuidString == mid } }
        var last = "", steps = 0
        if let s, let d = try? Data(contentsOf: URL(fileURLWithPath: s.logFile.path + ".json")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            last = j["last"] as? String ?? ""; steps = j["steps"] as? Int ?? 0
        }
        if last.isEmpty, let s { last = s.screenTail(1).first?.trimmingCharacters(in: .whitespaces) ?? "" }
        // Fertig, aber noch nicht (fertig) geprüft – auch wenn die Prüfung nach einem Neustart nachgeholt wird
        let verifying = t.missionID.flatMap { MissionStore.shared.mission($0) }.map { $0.ended != nil && $0.verify?.finished == nil } ?? false
        return Button { if let m = t.missionID { app.page = .chat(m) } } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(t.title).font(.caption.weight(.medium)).lineLimit(1)
                    Spacer()
                    if let st = t.started { Text(st, style: .relative).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary) }
                }
                Text(verifying ? "🔍 " + L("Prüfschleife läuft (Typen, Tests, Build, Review) …")
                     : (last.isEmpty ? L("startet …") : last) + (steps > 0 ? "  · " + String(format: L("%d Schritte"), steps) : ""))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text((AgentKind(rawValue: t.agent)?.title ?? t.agent) + (t.model.isEmpty ? "" : " · " + t.model))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .help(L("Auftrag öffnen"))
    }
}


/// Deine Aufträge oben im Betreuer: was du wolltest, wer daran arbeitet, wie weit es ist – und das Ergebnis.
struct StewardOrdersCard: View {
    let p: StewardProject

    var body: some View {
        let recent = (p.orders ?? []).filter { $0.finished == nil || $0.finished! > Date().addingTimeInterval(-86400) }.suffix(3)
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(recent.reversed())) { o in
                    let mine = p.tasks.filter { $0.order == o.id }
                    let done = mine.filter { $0.state == .done }.count
                    let total = mine.filter { $0.state != .dropped }.count
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: o.finished != nil ? "checkmark.seal.fill" : (o.planned ? "person.3.fill" : "brain"))
                                .foregroundStyle(o.finished != nil ? Color.green : Color.accentColor)
                            Text(o.text.components(separatedBy: .newlines).first ?? o.text).lineLimit(1).font(.callout.weight(.semibold))
                            Spacer()
                            Text(o.finished != nil ? L("fertig") : (o.planned ? "\(done)/\(max(total, 1))" : L("plant …")))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        if o.planned, o.finished == nil {
                            ProgressView(value: Double(done), total: Double(max(total, 1))).controlSize(.small)
                            ForEach(mine.filter { $0.state != .dropped }) { t in
                                HStack(spacing: 6) {
                                    Image(systemName: t.state == .done ? "checkmark.circle.fill" : t.state == .running ? "circle.dotted" : t.state == .review ? "arrow.triangle.pull" : t.state == .red ? "exclamationmark.circle" : "circle")
                                        .foregroundStyle(t.state == .done ? Color.green : t.state == .red ? Color.orange : Color.secondary)
                                    Text(t.title).lineLimit(1).font(.caption)
                                    Spacer()
                                    Text(AgentKind(rawValue: t.agent)?.title ?? L("Automatisch")).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if let s = o.summary, o.finished != nil { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(6) }
                    }
                    .padding(10)
                    .background(ModernCardBackground(radius: 10, accent: false))
                }
            }
        }
    }
}


/// Auf einen Blick: ist der Betreuer an, arbeitet er gerade, wartet er auf dich?
struct StewardStatusPill: View {
    let p: StewardProject
    var body: some View {
        let (text, color, symbol): (String, Color, String) = {
            if p.paused { return (L("Aus"), .secondary, "pause.circle.fill") }
            if p.blocked != nil || p.count(.review) > 0 && p.trust < 2 { return (L("Wartet auf dich"), .orange, "hand.raised.circle.fill") }
            if p.thinking == true { return (L("Plant gerade"), .purple, "brain.head.profile") }
            if p.count(.running) > 0 { return (String(format: L("Arbeitet · %d Helfer"), p.count(.running)), .green, "circle.fill") }
            if p.count(.queued) > 0 { return (L("An · wartet auf freien Platz"), .blue, "clock.fill") }
            return (L("An · bereit"), .green, "checkmark.circle.fill")
        }()
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}


/// Neuer Auftrag an den Betreuer – groß und deutlich: Text rein, Teamgröße wählen, abgeben.
/// Der Betreuer plant ihn als Team (Hauptaufgabe + Zuarbeiten mit passenden Skills), setzt um und meldet das Ergebnis.
struct StewardOrderComposer: View {
    let projectID: String
    let busy: Bool
    @ObservedObject private var steward = Steward.shared
    @State private var text = ""
    @State private var team = 1
    @State private var open = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.s) {
            if !open {
                Button { withAnimation(.snappy) { open = true }; DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L("Neuer Auftrag an den Betreuer")).font(.callout.weight(.semibold))
                            Text(L("Beschreib, was fertig werden soll – er plant, verteilt, prüft und meldet sich mit dem Ergebnis.")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                HStack {
                    Label(L("Neuer Auftrag"), systemImage: "plus.circle.fill").font(.callout.weight(.semibold)).foregroundStyle(Color.accentColor)
                    Spacer()
                    Button { withAnimation(.snappy) { open = false } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help(L("Schließen"))
                }
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(L("z. B. „Termin-Buchung im Webchat reparieren und mit Tests absichern“ – oder einen ganzen Plan einfügen"))
                            .foregroundStyle(.tertiary).padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .font(.body).scrollContentBackground(.hidden).focused($focused)
                        .frame(minHeight: 60, maxHeight: 180)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                HStack(spacing: Grid.s) {
                    Picker("", selection: $team) {
                        Text(L("Ein Agent")).tag(1)
                        Text(L("Team bis 2")).tag(2)
                        Text(L("Team bis 3")).tag(3)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                    .help(L("Wie viele verschiedene Agents höchstens mitarbeiten – der Betreuer verteilt die Teilaufgaben nach Stärke"))
                    MicButton { t in text += (text.isEmpty || text.hasSuffix(" ") ? "" : " ") + t }
                    Spacer()
                    Button { submit() } label: { Label(L("Auftrag geben"), systemImage: "paperplane.fill") }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).count < 4)
                }
                if busy { Text(L("Der Betreuer plant gerade – dein Auftrag kommt direkt danach dran.")).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(Grid.m)
        .background(ModernCardBackground(radius: 12))
    }

    private func submit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 4 else { return }
        steward.takeOrder(projectID, text: t, lead: nil, teamSize: team)
        text = ""
        withAnimation(.snappy) { open = false }
    }
}
