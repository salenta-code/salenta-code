import AgenticOSKit
import AppKit
import SwiftUI

// Salenta Code
//   AgenticOS                  die App (Fenster + Menüleiste)
//   AOS_HOME=<ordner> AgenticOS  anderer Datenordner (Standard: ~/Salenta Code)
//   ⌃⌥ Leertaste               Fenster holen / ausblenden (überall)
//   ⌘K                         Befehlspalette, "+ Text" legt eine Aufgabe an

@main
struct AgenticOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    @StateObject private var app = AppModel()
    @StateObject private var tasks = TaskStore()
    @StateObject private var panels = PanelStore()
    @StateObject private var agents = AgentManager()
    @StateObject private var calendar = CalendarService()
    @StateObject private var mail = MailService()
    @StateObject private var system = SystemStatus()
    @StateObject private var hub = MCPHub()
    @StateObject private var projects = ProjectCatalog()
    @StateObject private var skills = SkillCatalog()
    @StateObject private var bridge = Bridge()
    @StateObject private var live = LiveMonitor()
    @StateObject private var approvals = ApprovalCenter()

    init() {
        // Selbsttest (build.sh ruft ihn nach jedem Build auf): prüfen, Ergebnis ausgeben, beenden – ohne Fenster.
        if CommandLine.arguments.contains("--selftest") {
            setvbuf(stdout, nil, _IOLBF, 0)
            exit(SelfTest.run())
        }
        Paths.moveDevDataOutOfSource()   // persönliche Daten nie im Quellcode-Ordner
        AreaStore.bootstrap()   // Bereiche vor den Aufgaben laden
    }

    var body: some Scene {
        Window("Salenta Code", id: "main") {
            ContentView()
                .environmentObjects(app, tasks, panels, agents, calendar, mail, system)
                .environmentObject(hub)
                .environmentObject(projects)
                .environmentObject(skills)
                .environmentObject(bridge)
                .environmentObject(live)
                .environmentObject(approvals)
                .frame(minWidth: 1000, minHeight: 640)
                .overlay(SplashOverlay())
                .planetLook()
                .onAppear {
                    delegate.agents = agents
                    delegate.system = system
                    Updater.shared.start(agents: agents)
                }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(after: .windowList) {
                LiveWindowCommand()
                WidgetCommands()
            }
        }
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            CommandGroup(after: .appInfo) {
                if Paths.isDevBuild {
                    Button("Salenta Code neu bauen und starten") {
                        let app = Paths.source.appendingPathComponent("App").path
                        let log = Paths.source.appendingPathComponent("logs/rebuild.log").path
                        Shell.spawn("mkdir -p \(Shell.quote((log as NSString).deletingLastPathComponent)) && cd \(Shell.quote(app)) && ./build.sh --open > \(Shell.quote(log)) 2>&1")
                    }
                    Button("Effizienz-Bericht schreiben") { _ = EfficiencyAudit.write() }
                } else {
                    Button("Nach Updates suchen …") { Updater.shared.check(manual: true) }
                }
                Button("Leistung messen") {
                    PerfProbe.run { url in NSWorkspace.shared.open(url) }
                }
            }
            CommandGroup(replacing: .help) {
                Button("Salenta Code Hilfe") { app.page = .help; AppDelegate.showMainWindow() }.keyboardShortcut("?")
                Button("Fehler melden …") {
                    if let u = URL(string: "https://github.com/\(Updater.repo.isEmpty ? "salenta-code/salenta-code" : Updater.repo)/issues") { NSWorkspace.shared.open(u) }
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Neue Aufgabe") { app.editing = TaskItem(title: "", status: .heute) }
                    .keyboardShortcut("n")
            }
            CommandMenu("Gehe zu") {
                Button("Befehlspalette") { app.showPalette = true }.keyboardShortcut("k")
                Divider()
                Button("Cockpit") { app.page = .cockpit }.keyboardShortcut("1")
                Button("Mission Control") { app.page = .mission }.keyboardShortcut("0")
                Button("Aufgaben") { app.page = .tasks }.keyboardShortcut("2")
                Button("Agents") { app.page = .agents }.keyboardShortcut("3")
                Button("Connectors") { app.page = .connectors }.keyboardShortcut("4")
                Button("Mail") { app.page = .mail }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Kalender") { app.page = .calendar }.keyboardShortcut("k", modifiers: [.command, .shift])
                Button("MCP-Hub") { app.page = .mcp }
                Divider()
                Button("Claude") { app.page = .panel("claude") }.keyboardShortcut("5")
                Button("ChatGPT") { app.page = .panel("chatgpt") }.keyboardShortcut("6")
                Button("Gmail") { app.page = .panel("gmail") }.keyboardShortcut("7")
            }
            CommandMenu("Agents") {
                Button("Claude Code starten") { agents.start(.claude); app.page = .agents }
                    .keyboardShortcut("t")
                Button("Codex starten") { agents.start(.codex); app.page = .agents }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Junie starten") { agents.start(.junie); app.page = .agents }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
                Button("Terminal starten") { agents.start(.shell); app.page = .agents }
                Divider()
                Button("Aktuelle Sitzung schließen") {
                    if let s = agents.current { agents.close(s.id) }
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }
        }

        Window("Live", id: "live") {
            LiveWindow()
                .environmentObjects(app, tasks, panels, agents, calendar, mail, system)
                .environmentObject(hub)
                .environmentObject(live)
                .environmentObject(projects)
                .environmentObject(skills)
                .frame(minWidth: 760, minHeight: 460)
        }
        .defaultSize(width: 1000, height: 680)

        MenuBarExtra {
            MenuBarContent()
                .environmentObjects(app, tasks, panels, agents, calendar, mail, system)
                .environmentObject(hub)
                .environmentObject(approvals)
        } label: {
            AwakeMenuLabel()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .planetLook()
                .environmentObjects(app, tasks, panels, agents, calendar, mail, system)
                .environmentObject(hub)
                .environmentObject(approvals)
        }
    }
}

extension View {
    func environmentObjects(_ app: AppModel, _ tasks: TaskStore, _ panels: PanelStore, _ agents: AgentManager,
                            _ calendar: CalendarService, _ mail: MailService, _ system: SystemStatus) -> some View {
        environmentObject(app)
            .environmentObject(tasks)
            .environmentObject(panels)
            .environmentObject(agents)
            .environmentObject(calendar)
            .environmentObject(mail)
            .environmentObject(system)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// true, sobald die App beendet wird (Hintergrund-Sitzungen dann nicht neu anhängen).
    static var terminating = false
    weak var agents: AgentManager?
    weak var system: SystemStatus?
    private var hotKey: HotKey?

    func applicationWillFinishLaunching(_ notification: Notification) {
        Paths.prepareRuntime()   // fertige App: Werkzeuge und Ordner bereitlegen
        CrashLog.install()
        SafeStart.begin()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        CrashLog.mark("didFinishLaunching")
        CrashLog.startWatchdog()
        CrashLog.collectSystemReports()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        hotKey = HotKey { AppDelegate.toggleMainWindow() }
    }

    /// Fenster schließen beendet nicht: Agents laufen weiter, Menüleiste bleibt.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppDelegate.showMainWindow() }
        return true
    }

    /// Beenden ohne Rückfrage (z. B. für ein Update)
    static var quietQuit = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Helfer im Hintergrund (tmux) laufen sonst unsichtbar weiter – also fragen, statt still weiterzurechnen
        let background = agents?.sessions.filter { $0.running && $0.persistent } ?? []
        // Beenden von außen (Neu bauen, Update, Abmelden): nicht fragen – Hintergrund-Helfer laufen weiter wie bisher
        let external = NSAppleEventManager.shared().currentAppleEvent.map { $0.eventClass == AEEventClass(kCoreEventClass) && $0.eventID == AEEventID(kAEQuitApplication) } ?? false
        if !background.isEmpty, !external, !AppDelegate.quietQuit {
            let alert = NSAlert()
            alert.messageText = String(format: L("%d Helfer arbeiten noch"), background.count)
            alert.informativeText = L("Sie können im Hintergrund weiterarbeiten (Salenta Code holt die Ergebnisse beim nächsten Start ab) oder jetzt gestoppt werden. Im Hintergrund prüft und liefert niemand – das passiert erst, wenn Salenta Code wieder läuft.")
            alert.addButton(withTitle: L("Stoppen und beenden"))
            alert.addButton(withTitle: L("Weiterlaufen lassen"))
            alert.addButton(withTitle: L("Abbrechen"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                for s in background { s.terminate() }
            case .alertSecondButtonReturn:
                break
            default:
                return .terminateCancel
            }
        }
        let running = agents?.sessions.filter { $0.running && !$0.persistent }.count ?? 0
        guard running > 0 else { AppDelegate.terminating = true; SafeStart.cleanExit(); return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "\(running) Agent-Sitzung\(running == 1 ? "" : "en") läuft noch"
        alert.informativeText = Persist.tmux == nil
            ? "Beim Beenden werden diese Terminals geschlossen. Tipp: Mit tmux (brew install tmux) laufen Agents im Hintergrund weiter und kommen beim nächsten Start wieder."
            : "Diese Sitzungen laufen nicht im Hintergrund und werden geschlossen. Beim nächsten Start setzt Salenta Code sie fort."
        alert.addButton(withTitle: "Beenden")
        alert.addButton(withTitle: "Abbrechen")
        let quit = alert.runModal() == .alertFirstButtonReturn
        if quit { AppDelegate.terminating = true; SafeStart.cleanExit() }
        return quit ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.terminating = true
        Awake.shared.stopForQuit()   // Schlaf, Stromsparen, Ton und eingefrorene Apps zurücksetzen
        PreviewServer.shared.stopAll()
        agents?.closeAll()
        system?.stopOwnProcesses()
    }

    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
            ?? NSApp.windows.first { $0.canBecomeMain && $0.title == "Salenta Code" }
    }

    /// Wird von ContentView gesetzt: öffnet das Hauptfenster neu, wenn es geschlossen wurde.
    static var openMain: (() -> Void)?

    static func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = mainWindow, w.isVisible || w.isMiniaturized {
            w.deminiaturize(nil)
            w.makeKeyAndOrderFront(nil)
        } else {
            openMain?()
        }
    }

    static func toggleMainWindow() {
        if NSApp.isActive, let w = mainWindow, w.isVisible, w.isKeyWindow {
            NSApp.hide(nil)
        } else {
            showMainWindow()
        }
    }
}

struct LiveWindowCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Live-Fenster") { openWindow(id: "live") }.keyboardShortcut("l")
    }
}
