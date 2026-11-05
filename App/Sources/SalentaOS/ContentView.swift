import AgenticOSKit
import AppKit
import SwiftUI

enum Page: Hashable {
    case cockpit, mission, tasks, agents, connectors, mcp, mail, calendar, history, wissen, projects, usage, extensions, mods, nightshift, recap, stewards, help
    case steward(String)
    case live(String)
    case chat(String)
    case home
    case mcpApp(String)
    case panel(String)
}

/// Navigation und App-weite Zustände.
final class AppModel: ObservableObject {
    @Published var page: Page? = .home
    @Published var showPalette = false
    @Published var editing: TaskItem?
    @Published var taskFilter: Company?
    @Published var toast: String?
    /// Vorbelegung für "Neuer Auftrag" (aus Mail, Projekt-Cockpit …).
    @Published var draft: String?
    @Published var draftDir: String?

    func show(_ text: String) {
        let text = L(text)
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }
}

struct ContentView: View {
    @ObservedObject private var steward = Steward.shared
    static var restored = false
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var tasks: TaskStore
    @EnvironmentObject private var panels: PanelStore
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var hub: MCPHub
    @EnvironmentObject private var projects: ProjectCatalog
    @EnvironmentObject private var bridge: Bridge
    @EnvironmentObject private var live: LiveMonitor
    @AppStorage("sidebar.apps") private var showApps = true
    @AppStorage("sidebar.tech") private var showTech = false
    @AppStorage("sidebar.tools") private var showTools = true
    @State private var collapsedMissions: Set<String> = []

    /// Wurde ein Auftrag fortgesetzt (Weitermachen/Übergabe), hängen seine Helfer am neuesten offenen Teil der Kette.
    private func hostID(_ id: String, open: [MissionRecord]) -> String {
        var cur = id
        var guardCount = 0
        while !open.contains(where: { $0.id == cur }), guardCount < 20,
              let next = missions.missions.last(where: { $0.parent == cur && $0.delegated != true }) {
            cur = next.id; guardCount += 1
        }
        return cur
    }

    /// Alle Helfer eines Auftrags (auch Helfer von Helfern und von früheren Teilen der Kette), in Startreihenfolge.
    private func helpers(of id: String, in list: [MissionRecord]) -> [MissionRecord] {
        let direct = list.filter { m in m.delegated == true && m.parent.map { hostID($0, open: list) == id && $0 != m.id } == true }
        var out = direct
        for k in direct { out += helpers(of: k.id, in: list).filter { x in !out.contains { $0.id == x.id } } }
        return out.sorted { $0.started < $1.started }
    }

    @ViewBuilder private func missionRow(_ m: MissionRecord, helpers: Int = 0) -> some View {
        MissionRow(rec: m, helpers: helpers).tag(Page.chat(m.id))
            .contextMenu {
                Button("Abschließen") {
                    if app.page == .chat(m.id) { app.page = .home }
                    missions.archive(m.id, agents: agents, tasks: tasks)
                }
                Button("Aus der Liste entfernen", role: .destructive) {
                    if app.page == .chat(m.id) { app.page = .home }
                    missions.remove(m.id)
                }
            }
    }
    @EnvironmentObject private var calendar: CalendarService
    @EnvironmentObject private var mail: MailService
    @Environment(\.openWindow) private var openWindow
    @State private var editApp: WebPanel?
    @AppStorage("setup.done") private var setupDone = false
    @ObservedObject private var missions = MissionStore.shared
    @EnvironmentObject private var approvals: ApprovalCenter
    @EnvironmentObject private var projectCatalog: ProjectCatalog
    @EnvironmentObject private var skillCatalog: SkillCatalog

    /// Wie viele Dinge gerade dich brauchen (Freigaben, Rückfragen, rote Prüfungen, Abbrüche).
    private var attentionCount: Int {
        Insights.attention(missions: missions.missions, sessions: agents.sessions, approvals: approvals.pending).filter { $0.kind != .ready }.count
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $app.page) {
                Label("Neuer Auftrag", systemImage: "square.and.pencil").tag(Page.home)
                Label(L("Übersicht"), systemImage: "rectangle.3.group")
                    .badge(attentionCount)
                    .tag(Page.cockpit)

                // Coden: Aufträge, Projekte und alles, was die Agents gerade tun
                Section(L("Coden")) {
                    Label("Projekte", systemImage: "square.grid.2x2").tag(Page.projects)
                    Label(L("Projekt-Betreuer"), systemImage: "safari")
                        .badge(steward.projects.reduce(0) { $0 + $1.count(.review) + $1.count(.red) })
                        .tag(Page.stewards)
                    ForEach(steward.projects) { sp in
                        HStack(spacing: 6) {
                            // gleiche Namen (z. B. zwei Klone desselben Repos) am Elternordner unterscheiden
                            let twin = steward.projects.contains { $0.id != sp.id && $0.name == sp.name }
                            let parent = URL(fileURLWithPath: sp.id).deletingLastPathComponent().lastPathComponent
                            (Text(sp.name) + (twin ? Text(" · " + parent).foregroundColor(.secondary) : Text(""))).lineLimit(1)
                                .help(sp.id.replacingOccurrences(of: Paths.home.path, with: "~"))
                            Spacer()
                            if sp.count(.running) > 0 { LiveMark(size: 10, active: true) }
                        }
                        .padding(.leading, 22)
                        .font(.callout)
                        .badge(sp.count(.review) + sp.count(.red))
                        .tag(Page.steward(sp.id))
                    }
                    Label("Läuft gerade", systemImage: "dot.radiowaves.left.and.right")
                        .badge(agents.runningCount + live.active.count)
                        .tag(Page.mission)
                    Label(L("Nachtschicht"), systemImage: "moon.stars")
                        .badge(NightShift.shared.items.filter { $0.state == .queued || $0.state == .running }.count)
                        .tag(Page.nightshift)
                    Label(L("Verlauf"), systemImage: "clock.arrow.circlepath").tag(Page.history)
                    UsageSidebarLabel().tag(Page.usage)
                    Label(L("Wochenrückblick"), systemImage: "sparkles.rectangle.stack").tag(Page.recap)
                }
                Section("Aufträge") {
                    if missions.open.isEmpty {
                        Text("Nichts offen – oben „Neuer Auftrag“").font(.callout).foregroundStyle(.tertiary)
                    }
                    // Helfer (vom Agent gestartete Sub-Agents) hängen aufklappbar unter ihrem Hauptauftrag
                    // Läuft ein Helfer/Mod noch, obwohl sein Hauptauftrag schon abgeschlossen ist, bleibt der Hauptauftrag
                    // als Kopf sichtbar – so hängt nie etwas lose in der Liste.
                    let base = Array(missions.open.prefix(40))
                    let roots = Set(base.filter { $0.delegated == true }.map { missions.rootID(of: $0.id) })
                    let extra = roots.filter { r in !base.contains { $0.id == r } }.compactMap { missions.mission($0) }
                    let open = (base + extra).sorted { $0.started > $1.started }
                    let isHelper: (MissionRecord) -> Bool = { m in
                        guard m.delegated == true, let p = m.parent else { return false }
                        return open.contains { $0.id == hostID(p, open: open) }
                    }
                    ForEach(open.filter { !isHelper($0) }) { m in
                        let kids = helpers(of: m.id, in: open)
                        if kids.isEmpty {
                            missionRow(m)
                        } else {
                            DisclosureGroup(isExpanded: Binding(get: { !collapsedMissions.contains(m.id) },
                                                                set: { on in if on { collapsedMissions.remove(m.id) } else { collapsedMissions.insert(m.id) } })) {
                                ForEach(kids) { k in missionRow(k) }
                            } label: {
                                missionRow(m, helpers: kids.count)
                            }
                        }
                    }
                }

                // Dein Tag: Aufgaben, Mails, Termine, Wissen
                Section(L("Mein Tag")) {
                    Label("Aufgaben", systemImage: "checklist")
                        .badge(Focus.isOn ? 0 : tasks.focus.count)
                        .tag(Page.tasks)
                    Label("Mail", systemImage: "envelope").tag(Page.mail)
                    Label("Kalender", systemImage: "calendar").tag(Page.calendar)
                    Label("Wissen", systemImage: "books.vertical").tag(Page.wissen)
                }

                // Verbundene Apps (MCP) bekommen eine eigene Seite
                let integrations = hub.all.filter { s in s.origin == "Salenta OS" || hub.connections[s.id]?.state == .connected }
                if !integrations.isEmpty { Section(L("Verbundene Apps")) {
                    ForEach(integrations) { s in
                        Label(s.name.capitalized, systemImage: "app.connected.to.app.below.fill").tag(Page.mcpApp(s.id))
                    }
                } }
                Section("Apps", isExpanded: $showApps) {
                    ForEach(panels.panels) { p in
                        AppLabel(panel: p).tag(Page.panel(p.id))
                            .contextMenu {
                                Button("Bearbeiten …") { editApp = p }
                                Button("Nach oben") { panels.move(p.id, by: -1) }
                                Button("Nach unten") { panels.move(p.id, by: 1) }
                                Divider()
                                Button("Entfernen", role: .destructive) {
                                    if app.page == .panel(p.id) { app.page = .cockpit }
                                    panels.remove(p.id)
                                }
                            }
                    }
                    .onMove { from, to in panels.panels.move(fromOffsets: from, toOffset: to); panels.save() }
                    Button { editApp = WebPanel(id: "", title: "", url: "https://", symbol: "globe", group: "Business") } label: {
                        Label("App hinzufügen", systemImage: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                // Werkzeuge: was Salenta Code erweitert und einstellt
                Section(L("Werkzeuge"), isExpanded: $showTools) {
                    Label("Erweiterungen", systemImage: "puzzlepiece.extension").tag(Page.extensions)
                    Label("Mods", systemImage: "bolt.badge.automatic").tag(Page.mods)
                    Label(L("Integrationen"), systemImage: "point.3.connected.trianglepath.dotted").tag(Page.mcp)
                    Label("Terminals", systemImage: "terminal")
                        .badge(agents.sessions.count)
                        .tag(Page.agents)
                    SettingsLink { Label("Einstellungen", systemImage: "gearshape") }.buttonStyle(.plain)
                    Label(L("Hilfe"), systemImage: "questionmark.circle").tag(Page.help)
                }
                Section("Mehr", isExpanded: $showTech) {
                    Label(L("Claude-Connectors"), systemImage: "link").tag(Page.connectors)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { BrandHeader(active: agents.runningCount > 0) }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            // Sicherheitsnetz: eine zu hohe Ansicht wird unten abgeschnitten, statt Kopf und Seitenleiste wegzuschieben
            detail
                .containedInWindow()
        }
        .overlay(alignment: .top) { ApprovalBar().animation(.snappy, value: approvals.pending) }
        .overlay(alignment: .bottom) { if app.page != .home { FloatingDictationStrip() } }
        .onOpenURL { url in WidgetFeed.open(url, app: app) }
        .overlay(alignment: .bottom) {
            if let toast = app.toast {
                Text(toast)
                    .padding(.horizontal, Grid.l)
                    .padding(.vertical, Grid.s)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, Grid.xl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: app.toast)
        .sheet(isPresented: $app.showPalette) {
            CommandPalette()
        }
        .sheet(item: $app.editing) { task in
            TaskEditor(task: task)
        }
        .sheet(isPresented: Binding(get: { !setupDone }, set: { if !$0 { setupDone = true } })) {
            SetupView()
        }
        .sheet(item: $editApp) { p in
            AppEditor(panel: p) { saved in
                panels.upsert(saved)
                app.page = .panel(saved.id)
            }
        }
        .onAppear {
            let open = openWindow
            AppDelegate.openMain = { open(id: "main") }
            bridge.app = app
            bridge.tasks = tasks
            bridge.agents = agents
            bridge.calendar = calendar
            bridge.mail = mail
            bridge.hub = hub
            bridge.projects = projectCatalog
            bridge.skills = skillCatalog
            bridge.start()
            approvals.bridge = bridge
            approvals.start()
            live.start()
            if !Self.restored {
                Self.restored = true
                _ = Usage.shared   // Verbrauch gleich im Hintergrund einlesen
                _ = ExtensionDiscovery.shared   // täglich neue, geprüfte Erweiterungen suchen
                _ = ModelCatalog.shared
                _ = CLIFlags.shared   // Startoptionen der installierten CLIs lesen (aktualisiert sich nach Updates)
                Secrets.prime()
                Awake.shared.agents = agents   // „Wach bleiben“: automatisch, solange Agents arbeiten
                DesktopWidgets.shared.attach(app: app, agents: agents, tasks: tasks, calendar: calendar, approvals: approvals)
                NightShift.shared.attach(agents: agents, projects: projects)
                Steward.shared.attach(agents: agents, hub: hub, tasks: tasks, projects: projects)
                WidgetFeed.start(agents: agents, approvals: approvals)
                RemindersSync.shared.attach(tasks)
                _ = LocalFirst.shared   // Internet beobachten, lokale Modelle einlesen
                _ = LocalCatalog.shared // Empfehlungen für lokale Modelle (täglich aktualisiert)
                ModStore.shared.attach(agents: agents, hub: hub, app: app)
                let a = agents, h = hub, m = app
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = Persist.tmux   // einmal suchen (nicht im Hauptthread)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { a.restore(hub: h, app: m) }
                }
            }
            let store = tasks, model = app, mgr = agents, mcp = hub
            agents.onFinish = { s in
                let mid = s.id.uuidString
                if s.kind == .ollama { LocalStats.record(s) }
                // Startoption, die die installierte CLI nicht (mehr) kennt? Merken und einmal ohne sie neu starten.
                if !s.succeeded, let text = s.resultTail(maxChars: 4000), !s.isOSAgent,
                   let flag = CLIFlags.shared.learn(s.kind, from: text),
                   let rec = MissionStore.shared.mission(mid), rec.outcome != "flagretry" {
                    MissionStore.shared.setOutcome(mid, "flagretry")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {   // kurz warten, bis die Hilfe neu gelesen ist
                        Handoff.continueMission(rec, message: L("Starte den Auftrag bitte noch einmal und erledige ihn vollständig."),
                                                target: s.kind.rawValue, agents: mgr, hub: mcp,
                                                note: "\(s.kind.title): " + L("Option") + " \(flag) " + L("gibt es nicht mehr – neu gestartet")) { n in
                            model.show("↻ \(s.kind.title) " + L("kennt") + " \(flag) " + L("nicht mehr – automatisch ohne neu gestartet"))
                            if model.page == .chat(mid) { model.page = .chat(n.id.uuidString) }
                        }
                    }
                    return
                }
                // Lokales Modell kam nicht zurecht (Absturz, zu wenig Speicher, Werkzeuge nicht verstanden)?
                // Dann übernimmt einmal automatisch Claude – sofern Internet da ist. Der Auftrag scheitert nicht still.
                if !s.succeeded, s.kind == .ollama, s.mode == .autonom, LocalFirst.shared.isOnline, !LocalFirst.shared.localOnly,
                   let rec = MissionStore.shared.mission(mid), rec.outcome != "localfallback" {
                    MissionStore.shared.setOutcome(mid, "localfallback")
                    LocalStats.recordFallback()
                    Handoff.continueMission(rec, message: L("Das lokale Modell hat den Auftrag nicht geschafft. Erledige ihn bitte vollständig – prüfe zuerst, was schon geändert wurde."),
                                            target: AgentKind.claude.rawValue, agents: mgr, hub: mcp,
                                            note: L("Lokal nicht geschafft → Claude übernimmt")) { n in
                        model.show("↻ " + L("Lokales Modell kam nicht zurecht – Claude übernimmt"))
                        if model.page == .chat(mid) { model.page = .chat(n.id.uuidString) }
                    }
                    return
                }
                // Agent nicht angemeldet (z. B. Kimi ohne /login)? Hinweis geben und ein anderer Agent übernimmt.
                if !s.succeeded, s.mode == .autonom, !s.isOSAgent, let text = s.resultTail(maxChars: 4000),
                   AgentHealth.learn(s.kind, from: text), let rec = MissionStore.shared.mission(mid), rec.outcome != "login" {
                    MissionStore.shared.setOutcome(mid, "login")
                    model.show("🔑 \(s.kind.title) " + L("ist nicht angemeldet – einmal anmelden:") + " \(AgentHealth.hint(s.kind))")
                    if let alt = Usage.alternatives(s.kind).first(where: { OpenModels.available($0) && !Usage.shared.isTight($0) }) {
                        Handoff.continueMission(rec, message: L("Der vorherige Agent war nicht angemeldet. Erledige den Auftrag bitte an seiner Stelle vollständig."),
                                                target: alt.rawValue, agents: mgr, hub: mcp,
                                                note: "\(s.kind.title) " + L("nicht angemeldet") + " → \(alt.title)") { n in
                            if model.page == .chat(mid) { model.page = .chat(n.id.uuidString) }
                        }
                    }
                    return
                }
                if s.succeeded, !s.isOSAgent { AgentHealth.clear(s.kind) }
                // Limit erkannt? Dann übernimmt automatisch ein anderer Agent.
                if !s.succeeded, s.mode == .autonom, let text = s.resultTail(maxChars: 4000),
                   Usage.shared.noteOutput(s.isOSAgent ? .claude : s.kind, text: text),
                   Usage.shared.autoSwitch, let rec = MissionStore.shared.mission(mid), rec.outcome != "limit" {
                    MissionStore.shared.setOutcome(mid, "limit")
                    let installed = Set(AgentKind.allCases.filter { OpenModels.available($0) })
                    if let alt = Usage.alternatives(s.isOSAgent ? .claude : s.kind).first(where: { installed.contains($0) && !Usage.shared.isTight($0) }), !s.isOSAgent {
                        Usage.shared.record(from: s.kind.title, to: alt.title, why: L("Limit erreicht"))
                        Handoff.continueMission(rec, message: L("Der vorherige Agent hat sein Nutzungslimit erreicht. Mach bitte an seiner Stelle weiter und erledige den Auftrag vollständig."),
                                                target: alt.rawValue, agents: mgr, hub: mcp, note: "\(s.kind.title) " + L("im Limit") + " → \(alt.title)") { n in
                            model.show("⚡︎ \(s.kind.title) " + L("im Limit – \(alt.title) macht weiter"))
                            if model.page == .chat(mid) { model.page = .chat(n.id.uuidString) }
                        }
                        return
                    }
                }
                // Prüfschleife für Coding-Aufträge mit eigener Arbeitskopie.
                if s.succeeded, s.mode == .autonom, s.worktree != nil, Verifier.autoRun {
                    Verifier.run(mid) { report in
                        guard report.passed == false, Verifier.autoFix,
                              let rec = MissionStore.shared.mission(mid), (rec.fixRound ?? 0) < 1, rec.archived != true else {
                            if let p = report.passed, Focus.isOn == false || !p {
                                model.show(p ? "✓ " + L("Geprüft – alles grün: ") + s.label : "✗ " + L("Prüfung fehlgeschlagen: ") + s.label)
                            }
                            if let p = report.passed {
                                Notifier.push(p ? L("Geprüft – bereit zum Übernehmen") : L("Prüfung rot"), s.label, priority: p ? 3 : 4,
                                              tags: p ? "white_check_mark" : "x")
                            }
                            return
                        }
                        Verifier.fix(rec, agents: mgr, hub: mcp) { n in
                            model.show("↻ " + L("Prüfung rot – Agent bessert nach: ") + s.label)
                            if model.page == .chat(mid) { model.page = .chat(n.id.uuidString) }
                        }
                    }
                }
                if s.mode == .autonom, s.worktree == nil || !s.succeeded {
                    Notifier.push(s.succeeded ? "✓ \(s.displayName) " + L("fertig") : "✗ \(s.displayName) " + L("abgebrochen"),
                                  s.label, priority: s.succeeded ? 3 : 4, tags: s.succeeded ? "white_check_mark" : "warning")
                }
                if s.mode == .autonom, s.succeeded, let rec = MissionStore.shared.mission(mid) {
                    if Digest.worth(rec) { Digest.make(mid) }   // Ergebnis-Karte: Zusammenfassung + Vorschläge zum Umsetzen
                    ModStore.shared.fire(.missionFinished, rec: rec, result: s.resultTail(maxChars: 1500) ?? "")
                }
                guard let id = s.taskID else { return }
                store.finish(taskID: id, agent: s.kind, autonomous: s.mode == .autonom,
                             success: s.succeeded, summary: s.resultTail())
                Obsidian.journal(agent: s.kind.title, title: s.label,
                                 text: s.resultTail(maxChars: 1500) ?? "Interaktive Sitzung beendet (Aufgabe \(id)).", ok: s.succeeded)
                if s.mode == .autonom {
                    NSSound(named: s.succeeded ? "Glass" : "Basso")?.play()
                    NSApp.requestUserAttention(.informationalRequest)
                    model.show(s.succeeded ? "✓ \(s.kind.title) fertig: \(s.label)" : "✗ \(s.kind.title) abgebrochen: \(s.label)")
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch app.page ?? .cockpit {
        case .cockpit: CockpitView()
        case .projects: ProjectsView()
        case .usage: UsageView()
        case .nightshift: NightShiftView()
        case .stewards: StewardsView()
        case .steward(let id): StewardProjectView(id: id).id(id)
        case .recap: RecapView()
        case .help: HelpView()
        case .extensions: ExtensionsView()
        case .mods: ModsView()
        case .mission: MissionView()
        case .history: HistoryView()
        case .live(let path): LiveTranscriptPage(path: path).id(path)
        case .wissen: ObsidianView()
        case .home: HomeView()
        case .chat(let id): ConversationView(id: id).id(id)
        case .mcpApp(let id):
            if let s = hub.all.first(where: { $0.id == id }) {
                MCPAppPage(connection: hub.connection(for: s)).id(id)
            } else {
                ContentUnavailableView("Integration nicht gefunden", systemImage: "questionmark.square.dashed")
            }
        case .mcp: MCPHubView()
        case .mail: MailView()
        case .calendar: CalendarView()
        case .tasks: TasksView()
        case .agents: AgentsView()
        case .connectors: ConnectorsView()
        case .panel(let id):
            if let p = panels.panel(id) {
                WebPanelView(panel: p)
            } else {
                ContentUnavailableView("Panel nicht gefunden", systemImage: "questionmark.square.dashed")
            }
        }
    }
}

// MARK: - Befehlspalette (⌘K)

struct PaletteItem: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let symbol: String
    let run: () -> Void
}

struct CommandPalette: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var tasks: TaskStore
    @EnvironmentObject private var panels: PanelStore
    @EnvironmentObject private var agents: AgentManager
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    private var items: [PaletteItem] {
        var list: [PaletteItem] = [
            PaletteItem(title: "Cockpit", subtitle: "Seite", symbol: "square.grid.2x2") { app.page = .cockpit },
            PaletteItem(title: "Mission Control", subtitle: L("Auftrag an KI, laufende Agents"), symbol: "dot.radiowaves.left.and.right") { app.page = .mission },
            PaletteItem(title: "Mail", subtitle: "Alle Konten", symbol: "envelope") { app.page = .mail },
            PaletteItem(title: "Kalender", subtitle: L("Alle Kalender"), symbol: "calendar") { app.page = .calendar },
            PaletteItem(title: "MCP-Hub", subtitle: L("Server, Katalog, Tools"), symbol: "point.3.connected.trianglepath.dotted") { app.page = .mcp },
            PaletteItem(title: "Aufgaben", subtitle: "Seite", symbol: "checklist") { app.page = .tasks },
            PaletteItem(title: "Agents", subtitle: "Seite", symbol: "terminal") { app.page = .agents },
            PaletteItem(title: "Connectors", subtitle: "Seite", symbol: "puzzlepiece.extension") { app.page = .connectors },
        ]
        for kind in AgentKind.allCases {
            list.append(PaletteItem(title: "\(kind.title) starten", subtitle: L("Neue Sitzung im zuletzt genutzten Ordner"), symbol: kind.symbol) {
                agents.start(kind)
                app.page = .agents
            })
        }
        for p in panels.panels {
            list.append(PaletteItem(title: p.title, subtitle: p.group, symbol: p.symbol) { app.page = .panel(p.id) })
        }
        for t in tasks.open {
            list.append(PaletteItem(title: t.title, subtitle: "Aufgabe · \(t.company.title) · \(t.status.title)", symbol: "checkmark.circle") {
                app.editing = t
            })
        }
        list.append(PaletteItem(title: "Wissen", subtitle: L("Obsidian-Vault, Lage, Journal"), symbol: "books.vertical") { app.page = .wissen })
        list.append(PaletteItem(title: L("Obsidian-Vault öffnen"), subtitle: Obsidian.name, symbol: "books.vertical") { Launcher.openObsidian() })
        return list
    }

    private var filtered: [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(items.prefix(12)) }
        return Array(items.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.subtitle.localizedCaseInsensitiveContains(q) }.prefix(12))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Grid.s) {
                Image(systemName: "command").foregroundStyle(.secondary)
                TextField("Springen, starten oder neue Aufgabe mit + …", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit(submit)
            }
            .padding(Grid.l)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    if query.hasPrefix("+") {
                        let draft = QuickCapture.parse(String(query.dropFirst()))
                        row(PaletteItem(title: "Neue Aufgabe: \(draft.title)", subtitle: "\(draft.company.title) · \(draft.status.title)", symbol: "plus.circle", run: submit))
                    }
                    ForEach(filtered) { item in row(item) }
                }
                .padding(Grid.s)
            }
            .frame(height: 360)
        }
        .frame(width: 560)
        .onAppear { focused = true }
        .onExitCommand { dismiss() }
    }

    private func row(_ item: PaletteItem) -> some View {
        Button {
            item.run()
            dismiss()
        } label: {
            HStack(spacing: Grid.m) {
                Image(systemName: item.symbol).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).lineLimit(1)
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, Grid.s)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func submit() {
        if query.hasPrefix("+") {
            let t = QuickCapture.parse(String(query.dropFirst()))
            tasks.add(t)
            app.show("Aufgabe angelegt: \(t.title)")
        } else if let first = filtered.first {
            first.run()
        }
        dismiss()
    }
}
