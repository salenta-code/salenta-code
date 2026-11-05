import AgenticOSKit
import AppKit
import SwiftUI

// Desktop-Widgets: kleine Karten direkt auf dem Schreibtisch (wie die macOS-Widgets), live und anklickbar.
// Liegen über den Schreibtisch-Symbolen und unter deinen Fenstern, auf allen Spaces; verschieben per Ziehen.

enum WidgetKind: String, CaseIterable, Identifiable {
    case agents, usage, today, awake
    var id: String { rawValue }
    var title: String {
        switch self {
        case .agents: L("Agents")
        case .usage: L("Verbrauch")
        case .today: L("Heute")
        case .awake: L("Wach bleiben")
        }
    }
    var size: CGSize {
        switch self {
        case .agents, .today: CGSize(width: 344, height: 164)
        case .usage, .awake: CGSize(width: 164, height: 164)
        }
    }
    var defaultsKey: String { "widget.\(rawValue)" }
}

final class DesktopWidgets: NSObject, NSWindowDelegate {
    static let shared = DesktopWidgets()
    private var panels: [WidgetKind: NSPanel] = [:]
    weak var app: AppModel?
    weak var agents: AgentManager?
    weak var tasks: TaskStore?
    weak var calendar: CalendarService?
    weak var approvals: ApprovalCenter?

    func attach(app: AppModel, agents: AgentManager, tasks: TaskStore, calendar: CalendarService, approvals: ApprovalCenter) {
        self.app = app; self.agents = agents; self.tasks = tasks; self.calendar = calendar; self.approvals = approvals
        if SafeStart.active { return }   // abgesicherter Start: keine Widgets
        apply()
    }

    static func isOn(_ k: WidgetKind) -> Bool { UserDefaults.standard.bool(forKey: k.defaultsKey) }
    static var onTop: Bool { UserDefaults.standard.bool(forKey: "widget.onTop") }

    static func set(_ k: WidgetKind, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: k.defaultsKey)
        shared.apply()
    }

    func apply() {
        guard let app, let agents, let tasks, let calendar, let approvals else { return }
        for (i, k) in WidgetKind.allCases.enumerated() {
            if Self.isOn(k) {
                if let p = panels[k] { p.level = level; continue }
                let p = makePanel(k, index: i)
                let root = WidgetShell(kind: k)
                    .environmentObject(app).environmentObject(agents).environmentObject(tasks)
                    .environmentObject(calendar).environmentObject(approvals)
                p.contentView = NSHostingView(rootView: root)
                p.orderFront(nil)
                panels[k] = p
            } else if let p = panels.removeValue(forKey: k) {
                p.orderOut(nil)
            }
        }
    }

    private var level: NSWindow.Level {
        Self.onTop ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }

    private func makePanel(_ k: WidgetKind, index: Int) -> NSPanel {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: screen.maxX - k.size.width - 24, y: screen.maxY - 24 - CGFloat(index + 1) * (k.size.height + 16))
        if let s = UserDefaults.standard.string(forKey: k.defaultsKey + ".pos") {
            let p = NSPointFromString(s)
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -20, dy: -20).contains(p) }) { origin = p }
        }
        let p = NSPanel(contentRect: NSRect(origin: origin, size: k.size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = level
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.identifier = NSUserInterfaceItemIdentifier("widget." + k.rawValue)
        p.delegate = self
        return p
    }

    func windowDidMove(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, let id = w.identifier?.rawValue else { return }
        UserDefaults.standard.set(NSStringFromPoint(w.frame.origin), forKey: id + ".pos")
    }

    /// Hauptfenster auf einer Seite öffnen.
    func open(_ page: Page) {
        app?.page = page
        AppDelegate.showMainWindow()
    }
}

// MARK: - Rahmen (Glas, abgerundet, Kontextmenü)

struct WidgetShell: View {
    let kind: WidgetKind
    var body: some View {
        ZStack {
            VisualEffectBlur()
            Group {
                switch kind {
                case .agents: AgentsWidget()
                case .usage: UsageWidget()
                case .today: TodayWidget()
                case .awake: AwakeWidget()
                }
            }
            .padding(14)
        }
        .frame(width: kind.size.width, height: kind.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .contextMenu {
            Button(L("Salenta Code öffnen")) { AppDelegate.showMainWindow() }
            Toggle(L("Immer im Vordergrund"), isOn: Binding(get: { DesktopWidgets.onTop },
                                                             set: { UserDefaults.standard.set($0, forKey: "widget.onTop"); DesktopWidgets.shared.apply() }))
            Divider()
            Button(L("Widget entfernen")) { DesktopWidgets.set(kind, false) }
        }
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: - Inhalte

private struct WidgetHeader: View {
    let title: String
    var active = false
    var trailing: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            LiveMark(size: 16, active: active)
            Text(title).font(.system(size: 12, weight: .semibold))
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
        }
    }
}

struct AgentsWidget: View {
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var approvals: ApprovalCenter
    @ObservedObject private var missions = MissionStore.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { _ in
            let att = Insights.attention(missions: missions.missions, sessions: agents.sessions, approvals: approvals.pending)
            let needs = att.filter { $0.kind != .ready }.count
            let open = missions.open.prefix(3)
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: L("Agents"), active: agents.runningCount > 0,
                             trailing: agents.runningCount > 0 ? "\(agents.runningCount) " + L("aktiv") : nil)
                if open.isEmpty {
                    Spacer()
                    Text(L("Nichts offen")).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ForEach(Array(open)) { m in
                        let ph = m.phase(session: agents.sessions.first { $0.id.uuidString == m.id })
                        Button { DesktopWidgets.shared.open(.chat(m.id)) } label: {
                            HStack(spacing: 6) {
                                PhaseBadge(phase: ph)
                                Text(m.title).font(.system(size: 12)).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(ph.title).font(.system(size: 10)).foregroundStyle(ph.color).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                if needs > 0 {
                    Button { DesktopWidgets.shared.open(.cockpit) } label: {
                        Label(needs == 1 ? L("1 braucht dich") : String(format: L("%d brauchen dich"), needs), systemImage: "person.crop.circle.badge.exclamationmark")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                }
            }
            .animation(.snappy, value: open.map(\.id))
        }
    }
}

struct UsageWidget: View {
    @ObservedObject private var usage = Usage.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(title: L("Verbrauch"))
            HStack(spacing: 14) {
                ring("Claude", usage.pressure(.claude))
                ring("Codex", usage.pressure(.codex))
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { DesktopWidgets.shared.open(.usage) }
    }

    private func ring(_ name: String, _ p: Double) -> some View {
        let c: Color = p >= 0.9 ? .red : p >= 0.6 ? .orange : .green
        return VStack(spacing: 4) {
            ZStack {
                ProgressRing(value: p, color: c, lineWidth: 7)
                Text("\(Int((p * 100).rounded()))").font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    .contentTransition(.numericText())
            }
            .frame(width: 54, height: 54)
            Text(name).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

struct TodayWidget: View {
    @EnvironmentObject private var calendar: CalendarService
    @EnvironmentObject private var tasks: TaskStore
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            WidgetHeader(title: L("Heute"), trailing: Date().formatted(.dateTime.weekday(.abbreviated).day().month()))
            if let n = calendar.next {
                Button { DesktopWidgets.shared.open(.calendar) } label: {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.blue).frame(width: 3, height: 26)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(n.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(n.start.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            ForEach(tasks.focus.prefix(calendar.next == nil ? 4 : 2)) { t in
                Button { tasks.toggleDone(t.id) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "circle").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(t.title).font(.system(size: 12)).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .help(L("Klicken = erledigt"))
            }
            if calendar.next == nil && tasks.focus.isEmpty {
                Text(L("Nichts geplant")).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

struct AwakeWidget: View {
    @ObservedObject private var awake = Awake.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(title: L("Wach"))
            Spacer(minLength: 0)
            HStack {
                Image(systemName: awake.active ? "eye.fill" : "eye.slash")
                    .font(.system(size: 26)).foregroundStyle(awake.active ? .orange : .secondary)
                    .symbolEffect(.pulse, isActive: awake.active)
                if let e = awake.endAt {
                    Text(Awake.remaining(e)).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if awake.active {
                    Button("+1 h") { awake.extend(3600) }
                    Button(L("Aus")) { awake.stop() }
                } else {
                    Button("1 h") { awake.start(for: 3600) }
                    Button(L("bis 8")) { awake.start(until: AwakeButton.tomorrow8) }
                }
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }
}

// MARK: - Menü „Fenster › Desktop-Widgets“

struct WidgetCommands: View {
    @State private var tick = 0
    var body: some View {
        let _ = tick
        Menu {
            ForEach(WidgetKind.allCases) { k in
                Toggle(k.title, isOn: Binding(get: { DesktopWidgets.isOn(k) }, set: { DesktopWidgets.set(k, $0); tick += 1 }))
            }
            Divider()
            Toggle(L("Immer im Vordergrund"), isOn: Binding(get: { DesktopWidgets.onTop },
                                                             set: { UserDefaults.standard.set($0, forKey: "widget.onTop"); DesktopWidgets.shared.apply(); tick += 1 }))
        } label: {
            Label(L("Desktop-Widgets"), systemImage: "square.grid.2x2")
        }
    }
}
