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
                        Text("Ein Koordinator pro Projekt: plant, schickt Helfer los, prüft und pflegt – über Wochen. Schreibt selbst keinen Code.")
                            .foregroundStyle(.secondary)
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
                                .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
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
                    if p.paused { Text("pausiert").font(.caption).foregroundStyle(.secondary) }
                }
                Text(p.goal.isEmpty ? L("Noch kein Ziel") : p.goal).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: Grid.m) {
                    stat(p.count(.running), L("läuft"), .blue)
                    stat(p.count(.review), L("zum Übernehmen"), .green)
                    stat(p.count(.red), L("rot"), .red)
                    stat(p.count(.queued) + p.count(.idea), L("geplant"), .secondary)
                }
                .font(.caption)
            }
            .padding(Grid.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(.background.secondary))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.secondary.opacity(0.15)))
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
    @EnvironmentObject private var app: AppModel
    @State private var input = ""
    @State private var newTask = ""
    @State private var showSetup = false
    @State private var showDone = false
    @State private var showMemory = false

    var body: some View {
        if let p = steward.project(id) {
            VStack(spacing: 0) {
                header(p)
                Divider()
                HStack(spacing: 0) {
                    chat(p).frame(minWidth: 340, idealWidth: 460)
                    Divider()
                    board(p).frame(minWidth: 380)
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
                    Text(p.name).font(.title3.weight(.semibold))
                    TextField(L("Ziel, z. B. „Bis Ende Monat: Zahlungen live und keine roten Tests“"), text: Binding(
                        get: { p.goal },
                        set: { v in if let i = steward.projects.firstIndex(where: { $0.id == id }) { steward.projects[i].goal = v } }))
                        .textFieldStyle(.plain).foregroundStyle(.secondary)
                        .onSubmit { steward.save() }
                }
                Spacer()
                Menu {
                    Picker(L("Vertrauen"), selection: binding(\.trust)) {
                        Text("Nur vorschlagen").tag(0)
                        Text("Selbst starten, du übernimmst").tag(1)
                        Text("Grünes selbst übernehmen").tag(2)
                    }
                    Divider()
                    Picker(L("Parallel"), selection: binding(\.parallel)) { ForEach(1...4, id: \.self) { Text("\($0) " + L("gleichzeitig")).tag($0) } }
                    Picker(L("Tagesbudget"), selection: binding(\.dailyRuns)) { ForEach([3, 5, 8, 12, 20], id: \.self) { Text("\($0) " + L("Aufträge/Tag")).tag($0) } }
                    Picker(L("Täglicher Rundgang"), selection: binding(\.roundHour)) { ForEach([6, 7, 8, 9, 12, 18, 22], id: \.self) { Text("\($0):00").tag($0) } }
                    Divider()
                    Toggle(L("CI auf GitHub beobachten"), isOn: binding(\.watchCI))
                    Divider()
                    Button(L("Betreuung beenden"), role: .destructive) { steward.release(id); app.page = .stewards }
                } label: {
                    Label(trustLabel(p.trust), systemImage: p.trust == 2 ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                }
                .fixedSize()
                Toggle(isOn: binding(\.paused)) { Image(systemName: p.paused ? "play.fill" : "pause.fill") }
                    .toggleStyle(.button).help(p.paused ? L("Weiter betreuen") : L("Pausieren – startet nichts Neues"))
            }
            Text(trustExplain(p.trust)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Grid.m) {
                chip("bolt.fill", "\(p.runsToday)/\(p.dailyRuns) " + L("heute"), L("Gestartete Helfer heute / Tagesbudget"))
                chip("square.stack.3d.up", "\(p.parallel) " + L("parallel"), L("Höchstens so viele Helfer gleichzeitig"))
                if p.greenStreak > 0 { chip("checkmark.seal", "\(p.greenStreak) " + L("grün in Folge"), L("Grüne Ergebnisse hintereinander")) }
                if p.watchCI, p.setup?.remote?.contains("github") == true { chip("antenna.radiowaves.left.and.right", L("CI-Wache"), L("Rote GitHub-CI wird automatisch zur Aufgabe")) }
                chip("sunrise", L("Rundgang") + " \(p.roundHour):00", L("Täglicher Rundgang: der Betreuer plant den Tag"))
                Spacer()
                Button { showSetup.toggle() } label: { Label(L("Einrichtung"), systemImage: "wrench.and.screwdriver") }
                    .buttonStyle(.borderless).popover(isPresented: $showSetup) { setupView(p) }
                Button { showMemory = true } label: { Label(L("Projektwissen"), systemImage: "brain.head.profile") }
                    .buttonStyle(.borderless).help(L("Was die Agents über dieses Projekt gelernt haben – gilt für alle Agents"))
                    .sheet(isPresented: $showMemory) { ProjectMemorySheet(directory: id) }
            }
            .font(.caption)
        }
        .padding(.horizontal, Grid.l).padding(.vertical, Grid.m)
    }

    private func chip(_ icon: String, _ text: String, _ help: String) -> some View {
        Label(text, systemImage: icon).foregroundStyle(.secondary).help(help)
    }

    private func trustExplain(_ t: Int) -> String {
        [L("Nur vorschlagen: Der Betreuer plant und schlägt Aufgaben vor – gestartet wird erst, wenn du auf „Starten“ klickst."),
         L("Selbst starten: Der Betreuer startet Helfer im Rahmen von Tagesbudget und Parallel-Grenze. Übernehmen entscheidest du."),
         L("Grünes übernehmen: Ist alles geprüft und grün, übernimmt der Betreuer selbst. Rotes und Riskantes landet immer bei dir.")][min(max(t, 0), 2)]
    }

    private func trustLabel(_ t: Int) -> String {
        [L("Vertrauen: vorschlagen"), L("Vertrauen: selbst starten"), L("Vertrauen: Grünes übernehmen")][min(max(t, 0), 2)]
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
                    .help(L("Schreibt Test-, Lint-, Typen- und Build-Befehl in .salenta-os.json – jede Aufgabe wird damit geprüft"))
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
                        ForEach(p.messages) { m in bubble(m) }
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
            Divider()
            HStack(spacing: Grid.s) {
                TextField(p.goal.isEmpty ? L("Was ist das Ziel?") : L("Sag dem Betreuer, was als Nächstes wichtig ist …"), text: $input, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...5)
                    .onSubmit { sendInput() }
                MicButton { t in input += (input.isEmpty || input.hasSuffix(" ") ? "" : " ") + t }
                Button { sendInput() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }.help(L("Senden"))
                    .buttonStyle(.plain).disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || p.thinking == true)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(Grid.m)
        }
    }

    private func sendInput() {
        let t = input; input = ""
        if steward.project(id)?.goal.isEmpty == true, let i = steward.projects.firstIndex(where: { $0.id == id }) {
            steward.projects[i].goal = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        steward.send(id, t)
    }

    @ViewBuilder private func bubble(_ m: StewardMessage) -> some View {
        switch m.role {
        case "du":
            HStack { Spacer(minLength: 60); Text(m.text).textSelection(.enabled).padding(Grid.m)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.12))) }
        case "system":
            Text(LocalizedStringKey(m.text)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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
                    section(L("Braucht dich"), p.tasks.filter { $0.state == .review || $0.state == .red }, p)
                    section(L("Läuft"), p.tasks.filter { $0.state == .running }, p)
                    section(L("Warteschlange"), p.tasks.filter { $0.state == .queued }.sorted { $0.priority < $1.priority }, p)
                    section(L("Vorschläge"), p.tasks.filter { $0.state == .idea }, p)
                    let done = p.tasks.filter { $0.state == .done || $0.state == .dropped }
                    if !done.isEmpty {
                        DisclosureGroup(isExpanded: $showDone) {
                            VStack(alignment: .leading, spacing: 6) { ForEach(done.suffix(30).reversed()) { row($0, p) } }
                        } label: { Text("\(L("Erledigt")) (\(done.count))").font(.headline) }
                    }
                    if p.tasks.isEmpty {
                        Text("Noch keine Aufgaben. Sag dem Betreuer links das Ziel – er plant dann.").foregroundStyle(.secondary)
                        StewardHowItWorks(expanded: true)
                    }
                }
                .padding(Grid.l)
            }
            Divider()
            HStack {
                TextField(L("Eigene Aufgabe direkt einreihen …"), text: $newTask).textFieldStyle(.plain)
                    .onSubmit { steward.addTask(id, title: newTask); newTask = "" }
                Button(L("Einreihen")) { steward.addTask(id, title: newTask); newTask = "" }
                    .disabled(newTask.trimmingCharacters(in: .whitespaces).isEmpty)
                Button { steward.think(id, trigger: L("Bitte prüf den Stand und plan die nächsten Schritte.")) } label: {
                    Label(L("Neu planen"), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(p.thinking == true)
            }
            .padding(Grid.m)
        }
    }

    @ViewBuilder private func section(_ title: String, _ items: [StewardTask], _ p: StewardProject) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(title) (\(items.count))").font(.headline)
                ForEach(items) { row($0, p) }
            }
        }
    }

    private func row(_ t: StewardTask, _ p: StewardProject) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: Grid.s) {
                stateIcon(t.state)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).fontWeight(.medium).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(sourceLabel(t.source))
                        if t.agent != "auto" { Text("· " + (AgentKind(rawValue: t.agent)?.title ?? t.agent) + (t.model.isEmpty ? "" : " " + t.model)) }
                        if let s = t.started, t.state == .running { Text("· ") + Text(s, style: .relative) }
                    }
                    .font(.caption).foregroundStyle(.tertiary)
                    if let n = t.note, !n.isEmpty { Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                }
                Spacer()
            }
            HStack(spacing: 6) {
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
                    Button(L("Übernehmen")) { steward.resolve(id, task: t.id, accept: true) { app.show($0) } }
                        .buttonStyle(.borderedProminent).tint(.green)
                case .red:
                    if let m = t.missionID { Button(L("Ansehen")) { app.page = .chat(m) } }
                    Button(L("Verwerfen")) { steward.resolve(id, task: t.id, accept: false) { app.show($0) } }
                    Button(L("Nochmal versuchen")) { steward.retry(id, task: t.id) }.buttonStyle(.borderedProminent).tint(.orange)
                case .done, .dropped:
                    if let m = t.missionID { Button(L("Ansehen")) { app.page = .chat(m) } }
                }
            }
            .controlSize(.small)
        }
        .padding(Grid.s)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
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
                step(4, "hand.raised", L("Du entscheidest"), L("Je nach Vertrauen schlägt er nur vor, startet selbst oder übernimmt sogar Grünes. Tagesbudget und Parallel-Grenze halten die Kosten im Rahmen."))
                Label(L("Er schreibt selbst keinen Code, deployt nie, veröffentlicht nichts und schreibt keinen Kunden an."), systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, Grid.s)
        } label: {
            Label(L("So funktioniert der Projekt-Betreuer"), systemImage: "questionmark.circle").font(.headline)
        }
        .padding(Grid.m)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
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
