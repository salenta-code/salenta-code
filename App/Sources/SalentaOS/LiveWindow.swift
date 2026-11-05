import AgenticOSKit
import AppKit
import SwiftUI

/// Eigenes Fenster "Live": alles, was gerade arbeitet, groß und in Echtzeit –
/// Claude Code, Codex, Junie im OS, Claude-Code-/Codex-Sitzungen aus anderen Fenstern.
/// Öffnet sich automatisch, wenn du einen Auftrag startest.
struct LiveWindow: View {
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var live: LiveMonitor
    @EnvironmentObject private var app: AppModel
    @AppStorage("live.selected") private var selected = ""
    @AppStorage("live.onTop") private var onTop = false

    /// Sitzungen im OS: laufende und die der letzten Stunde.
    private var sessions: [AgentSession] {
        agents.sessions.filter { $0.kind != .shell && ($0.running || ($0.endedAt ?? .distantFuture) > Date().addingTimeInterval(-3600)) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Sitzungen aus anderen Fenstern (Terminal, Cursor …), die nicht schon im OS laufen.
    private var external: [TranscriptFile] { live.active }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { selected.isEmpty ? nil : selected }, set: { selected = $0 ?? "" })) {
                Section("Im Salenta Code") {
                    if sessions.isEmpty { Text("Gerade nichts").foregroundStyle(.tertiary) }
                    ForEach(sessions) { s in
                        LiveSessionRow(session: s).tag("s:" + s.id.uuidString)
                    }
                }
                Section("Andere Fenster") {
                    if external.isEmpty { Text("Gerade nichts").foregroundStyle(.tertiary) }
                    ForEach(external, id: \.url.path) { f in
                        HStack(spacing: Grid.s) {
                            Image(systemName: f.agent.symbol).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Transcript.title(of: f.url)).lineLimit(1)
                                Text("\(f.agent.title) · aktiv").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                        }
                        .tag("t:" + f.url.path)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 230, ideal: 270)
        } detail: {
            detail
        }
        .navigationTitle("Live")
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $onTop) { Label("Immer im Vordergrund", systemImage: onTop ? "pin.fill" : "pin") }
                    .help("Live-Fenster über allen anderen Fenstern halten")
            }
        }
        .background(WindowLevel(floating: onTop))
        .onAppear(perform: pickDefault)
        .onChange(of: agents.sessions.count) { _, _ in pickNewest() }
    }

    @ViewBuilder private var detail: some View {
        if selected.hasPrefix("s:"), let s = agents.sessions.first(where: { "s:" + $0.id.uuidString == selected }) {
            LiveSessionDetail(session: s)
        } else if selected.hasPrefix("t:"), let f = live.transcripts.first(where: { "t:" + $0.url.path == selected }) {
            TranscriptView(file: f)
        } else {
            ContentUnavailableView("Nichts ausgewählt", systemImage: "dot.radiowaves.left.and.right",
                                   description: Text("Starte einen Auftrag – er erscheint hier sofort und du siehst live, was gerade passiert."))
        }
    }

    private func pickDefault() {
        let valid = sessions.map { "s:" + $0.id.uuidString } + external.map { "t:" + $0.url.path }
        if selected.isEmpty || !valid.contains(selected) { pickNewest() }
    }

    private func pickNewest() {
        if let s = sessions.first(where: \.running) ?? sessions.first { selected = "s:" + s.id.uuidString }
        else if let f = external.first { selected = "t:" + f.url.path }
    }
}

struct LiveSessionRow: View {
    @ObservedObject var session: AgentSession

    var body: some View {
        HStack(spacing: Grid.s) {
            Image(systemName: session.kind.symbol).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.label == session.kind.title ? session.title : session.label).lineLimit(1)
                Text("\(session.kind.title) · \(session.mode.title) · \(session.directory.lastPathComponent)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if session.running { ProgressView().controlSize(.small) } else {
                Image(systemName: session.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(session.succeeded ? Color.green : Color.orange)
            }
        }
    }
}

/// Großer Live-Blick auf eine Sitzung: genau das, was im Terminal steht, jede halbe Sekunde aktualisiert.
struct LiveSessionDetail: View {
    @ObservedObject var session: AgentSession
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Grid.m) {
                Image(systemName: session.kind.symbol).font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.label).font(.headline).lineLimit(1)
                    Text("\(session.kind.title) · \(session.mode.title) · \(session.directory.path.replacingOccurrences(of: Paths.home.path, with: "~"))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(status).font(.callout.weight(.medium)).foregroundStyle(session.running ? Color.green : .secondary)
                }
                Button {
                    agents.selected = session.id
                    app.page = .agents
                    AppDelegate.showMainWindow()
                } label: { Label(session.mode == .interaktiv ? "Antworten" : "Im Terminal öffnen", systemImage: "terminal") }
                if session.running {
                    Button(role: .destructive) { agents.close(session.id) } label: { Label("Stoppen", systemImage: "stop.fill") }
                }
            }
            .padding(Grid.m)
            .background(.bar)

            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(screen)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(Color(hex: 0xE7E7EA))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Grid.l)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                    .onChange(of: screen) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            .background(Color(hex: 0x141418))
        }
    }

    /// Autonome Läufe: die komplette lesbare Mitschrift; interaktive: der Terminal-Bildschirm.
    private var screen: String {
        if session.mode == .autonom, let all = session.resultTail(maxChars: 60_000), !all.isEmpty { return all }
        let lines = session.screenTail(500).joined(separator: "\n")
        return lines.isEmpty ? "Startet …" : lines
    }

    private var status: String {
        let secs = Int((session.endedAt ?? Date()).timeIntervalSince(session.startedAt))
        let time = String(format: "%d:%02d", secs / 60, secs % 60)
        if session.running { return "● arbeitet · \(time)" }
        return session.succeeded ? "Fertig · \(time)" : "Beendet · \(time)"
    }
}

/// Hält das Fenster auf Wunsch über allen anderen.
struct WindowLevel: NSViewRepresentable {
    let floating: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { v.window?.level = floating ? .floating : .normal }
    }
}
