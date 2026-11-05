import AgenticOSKit
import ServiceManagement
import SwiftUI
import WidgetKit

// Menüleiste und Mac-Widgets.
//  • WidgetFeed: schreibt alle 30 s den Stand für die Schreibtisch-Widgets und lädt sie neu, wenn sich etwas ändert.
//  • MenuBarContent: das Fenster hinter dem Symbol oben rechts – Lage auf einen Blick und die wichtigen Schalter.
//  • Links aus Widgets (salentacode://…) öffnen die passende Seite.

enum WidgetFeed {
    private struct Run: Codable, Hashable { var id: String; var title: String; var agent: String; var since: Date }
    private struct Project: Codable, Hashable { var name: String; var running: Int; var review: Int; var red: Int; var queued: Int }
    private struct Feed: Codable, Hashable {
        var running: [Run]; var needsYou: Int; var approvals: Int; var finished: Int
        var claude: Double?; var codex: Double?; var awakeUntil: Date?; var projects: [Project]; var night: Int; var updated: Date
    }

    private static var timer: Timer?
    private static var last: Feed?
    private static var lastReload = Date.distantPast
    static var dir: URL {
        Paths.home.appendingPathComponent("Library/Application Support/ai.salenta.os/widget", isDirectory: true)
    }

    static func start(agents: AgentManager, approvals: ApprovalCenter) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in update(agents: agents, approvals: approvals) }
        timer?.tolerance = 5
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { update(agents: agents, approvals: approvals) }
        register()
    }

    /// Widgets beim System anmelden (falls der Build es nicht geschafft hat) und den Stand protokollieren.
    static func register() {
        let appex = Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/SalentaWidgets.appex").path
        let id = (Bundle.main.bundleIdentifier ?? "ai.salenta.os") + ".widgets"
        DispatchQueue.global(qos: .utility).async {
            let r = Proc.zsh("/usr/bin/pluginkit -a \(Shell.quote(appex)); sleep 2; /usr/bin/pluginkit -m -v -i \(id); /usr/bin/pluginkit -m -p com.apple.widgetkit-extension | grep -i salenta",
                             in: NSTemporaryDirectory(), timeout: 30)
            let line = "\(Date()) start\n\(r.out)\n"
            try? line.write(to: Paths.root.appendingPathComponent("logs/widgets-start.log"), atomically: true, encoding: .utf8)
        }
    }

    static func update(agents: AgentManager, approvals: ApprovalCenter) {
        let store = MissionStore.shared
        let running = agents.sessions.filter(\.running).prefix(10).map {
            Run(id: $0.id.uuidString, title: $0.label, agent: $0.displayName, since: $0.startedAt)
        }
        let open = store.open
        let finished = open.filter { $0.ended != nil && $0.ok == true && $0.archived != true }.count
        let red = open.filter { $0.verify?.passed == false }.count
        let steward = Steward.shared.projects
        let review = steward.reduce(0) { $0 + $1.count(.review) + $1.count(.red) }
        var feed = Feed(running: Array(running),
                        needsYou: approvals.pending.count + red + review,
                        approvals: approvals.pending.count,
                        finished: finished,
                        claude: OpenModels.available(.claude) ? Usage.shared.cachedPressure(.claude) : nil,
                        codex: OpenModels.available(.codex) ? Usage.shared.cachedPressure(.codex) : nil,
                        awakeUntil: Awake.shared.endAt,
                        projects: steward.map { Project(name: $0.name, running: $0.count(.running), review: $0.count(.review), red: $0.count(.red), queued: $0.count(.queued) + $0.count(.idea)) },
                        night: NightShift.shared.items.filter { $0.state == .queued }.count,
                        updated: Date())
        // nur schreiben und neu laden, wenn sich etwas Sichtbares geändert hat (Zeitstempel ausgenommen)
        var cmp = feed; cmp.updated = .distantPast
        if var l = last { l.updated = .distantPast; if l == cmp && Date().timeIntervalSince(lastReload) < 600 { return } }
        last = feed
        feed.updated = Date()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        let target = dir
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            if let d = try? enc.encode(feed) { try? d.write(to: target.appendingPathComponent("feed.json"), options: .atomic) }
            DispatchQueue.main.async {
                WidgetCenter.shared.reloadAllTimelines()
                lastReload = Date()
            }
        }
    }

    /// salentacode://cockpit · /mission · /usage · /stewards · /chat/<id>
    static func open(_ url: URL, app: AppModel) {
        guard url.scheme == "salentacode" else { return }
        let host = url.host ?? ""
        switch host {
        case "cockpit": app.page = .cockpit
        case "mission": app.page = .mission
        case "usage": app.page = .usage
        case "stewards": app.page = .stewards
        case "chat": if let id = url.pathComponents.dropFirst().first { app.page = .chat(id) }
        default: app.page = .home
        }
        AppDelegate.showMainWindow()
    }
}

/// Bei der Anmeldung am Mac starten (Anmeldeobjekte).
enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { CrashLog.mark("Anmeldeobjekt: \(error.localizedDescription)") }
    }
}

/// Das Fenster hinter dem Symbol in der Menüleiste.
struct MenuBarContent: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var tasks: TaskStore
    @EnvironmentObject private var calendar: CalendarService
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var approvals: ApprovalCenter
    @ObservedObject private var store = MissionStore.shared
    @ObservedObject private var steward = Steward.shared
    @ObservedObject private var night = NightShift.shared
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var localFirst = LocalFirst.shared
    @AppStorage("local.only") private var localOnly = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var capture = ""
    @State private var login = LoginItem.enabled
    @AppStorage("notify.push") private var push = true

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.m) {
            // Kopf
            HStack(spacing: Grid.s) {
                LiveMark(size: 22, active: agents.runningCount > 0)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Salenta Code").font(.headline)
                    Text(statusLine).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Date().formatted(.dateTime.weekday(.abbreviated).day().month())).font(.caption).foregroundStyle(.secondary)
            }

            // Was gerade los ist
            if !approvals.pending.isEmpty {
                Button { open(.cockpit) } label: {
                    Label("\(approvals.pending.count) " + L("Freigabe(n) warten auf dich"), systemImage: "hand.raised.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }
            let running = agents.sessions.filter(\.running)
            if !running.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(running.prefix(4)) { s in
                        Button { open(.chat(s.id.uuidString)) } label: {
                            HStack(spacing: 6) {
                                Circle().fill(.green).frame(width: 6, height: 6)
                                Text(s.label).lineLimit(1)
                                Spacer()
                                Text(s.startedAt, style: .relative).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            let review = steward.projects.reduce(0) { $0 + $1.count(.review) }
            if review > 0 {
                Button { open(.stewards) } label: {
                    Label("\(review) " + L("Ergebnisse vom Projekt-Betreuer zum Übernehmen"), systemImage: "safari").foregroundStyle(.green)
                }
                .buttonStyle(.plain)
            }

            TextField("Neuer Auftrag oder Notiz … (Enter = Aufgabe)", text: $capture)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    let text = capture.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { return }
                    tasks.add(QuickCapture.parse(text))
                    capture = ""
                }

            Divider()

            // Die wichtigen Schalter
            VStack(alignment: .leading, spacing: 8) {
                HStack { AwakeButton(); Spacer() }
                Toggle(isOn: Binding(get: { approvals.isAuto }, set: { on in approvals.setAuto(on ? Date().addingTimeInterval(3600) : nil) })) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Agents ohne Rückfrage arbeiten lassen")
                        Text(approvals.isAuto ? (approvals.autoUntil.map { L("bis") + " " + $0.formatted(date: .omitted, time: .shortened) } ?? L("dauerhaft")) : L("aus – sie fragen vor riskanten Schritten"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if night.items.contains(where: { $0.state == .queued }) {
                    Toggle(isOn: Binding(get: { night.scheduledAt != nil || night.active }, set: { on in if on { night.schedule() } else { night.stop() } })) {
                        Text(String(format: L("Nachtschicht heute Nacht (%d Aufgaben)"), night.items.filter { $0.state == .queued }.count))
                    }
                }
                Toggle(isOn: $localOnly) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(L("Nur lokal arbeiten"))
                        Text(localOnly ? (LocalFirst.shared.model.map { L("alles über ") + $0 } ?? L("kein lokales Modell bereit!"))
                                       : L("aus – Cloud-Modelle erlaubt"))
                            .font(.caption).foregroundStyle(localOnly && !LocalFirst.shared.ready ? .orange : .secondary)
                    }
                }
                .disabled(!LocalFirst.shared.ready && !localOnly)
                .help(L("Alle Agents nutzen nur das lokale Modell (Ollama) – nichts geht an eine Cloud-KI"))
                if !Notifier.topic.isEmpty { Toggle(L("Mitteilungen aufs Handy"), isOn: $push) }
                Toggle(L("Beim Anmelden starten"), isOn: Binding(get: { login }, set: { LoginItem.set($0); login = LoginItem.enabled }))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if let a = updater.available {
                HStack {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                    Text(L("Update ") + a.version + (updater.phase == .waitingForAgents ? L(" – wartet auf Agents") : "")).font(.callout)
                    Spacer()
                    Button(L("Installieren")) { updater.install(force: true) }.controlSize(.small)
                }
            }

            Divider()

            HStack {
                Button(L("Einstellungen …")) { NSApp.activate(ignoringOtherApps: true); openSettings() }
                Button(L("Leistung messen")) { PerfProbe.run { url in NSWorkspace.shared.open(url) } }
                Spacer()
                Button(L("Öffnen")) { openWindow(id: "main"); AppDelegate.showMainWindow() }
                    .keyboardShortcut(.defaultAction)
            }
            HStack {
                Text(L("Widgets: Schreibtisch rechtsklicken › Widgets bearbeiten › Salenta Code")).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button(L("Beenden")) { NSApp.terminate(nil) }.controlSize(.small)
            }
        }
        .padding(Grid.l)
        .frame(width: 360)
    }

    private var statusLine: String {
        let n = agents.runningCount
        if n == 0 { return L("Keine Agents aktiv") }
        return "\(n) " + (n == 1 ? L("Agent arbeitet") : L("Agents arbeiten"))
    }

    private func open(_ page: Page) {
        app.page = page
        openWindow(id: "main")
        AppDelegate.showMainWindow()
    }
}
