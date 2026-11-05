import AgenticOSKit
import AppKit
import SwiftUI

/// Claude Code, Codex, Junie und Shells als echte Terminals in einem Fenster.
struct AgentsView: View {
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var system: SystemStatus
    @EnvironmentObject private var app: AppModel
    @State private var directory: String = ""

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)
            Group {
                if let s = agents.current {
                    TerminalPane(session: s)
                        .id(s.id)
                } else {
                    emptyState
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Agents")
        .navigationSubtitle(agents.current.map { "\($0.kind.title) · \($0.directory.path)" } ?? "")
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    ForEach(agents.directories, id: \.self) { d in
                        Button(d.replacingOccurrences(of: Paths.home.path, with: "~")) { directory = d }
                    }
                    Divider()
                    Button("Ordner wählen …") { if let d = agents.chooseDirectory() { directory = d } }
                } label: {
                    Label(shortDir, systemImage: "folder")
                }
                .help("Arbeitsordner für neue Sitzungen")
                ForEach(AgentKind.allCases) { k in
                    Button { agents.start(k, in: currentDir) } label: { Label(k.title, systemImage: k.symbol) }
                        .help("\(k.title) in \(shortDir) starten")
                        .disabled(system.cliChecked && !system.installed(k))
                }
            }
        }
        .onAppear { if directory.isEmpty { directory = agents.directories.first ?? Paths.root.path } }
    }

    private var currentDir: String { directory.isEmpty ? (agents.directories.first ?? Paths.root.path) : directory }
    private var shortDir: String { (currentDir as NSString).lastPathComponent }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $agents.selected) {
                Section("Sitzungen") {
                    ForEach(agents.sessions) { s in
                        SessionRow(session: s).tag(s.id)
                            .contextMenu {
                                Button("Beenden und schließen", role: .destructive) { agents.close(s.id) }
                            }
                    }
                }
                Section("Installiert") {
                    ForEach([AgentKind.claude, .codex, .junie]) { k in
                        HStack(spacing: Grid.s) {
                            Image(systemName: system.installed(k) ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(system.installed(k) ? Color.green : Color.orange)
                            Text(k.title)
                            Spacer()
                        }
                        .help(system.cliPaths[k] ?? "Nicht gefunden. Installieren: \(k.installHint)")
                    }
                }
                Section {
                    SessionHistoryList()
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Kein Agent offen", systemImage: "terminal")
        } description: {
            Text("Starte Claude Code, Codex oder Junie. Jede Sitzung läuft als echtes Terminal und bleibt offen, wenn du die Seite wechselst. Aufgaben übergibst du per Rechtsklick im Board.")
        } actions: {
            HStack {
                ForEach([AgentKind.claude, .codex, .junie]) { k in
                    Button { agents.start(k, in: currentDir) } label: { Label(k.title, systemImage: k.symbol) }
                        .disabled(system.cliChecked && !system.installed(k))
                }
            }
            .controlSize(.large)
        }
    }
}

struct SessionRow: View {
    @ObservedObject var session: AgentSession

    var body: some View {
        HStack(spacing: Grid.s) {
            Image(systemName: session.kind.symbol).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.label == session.kind.title ? session.title : session.label).lineLimit(1)
                Text(session.kind.title + " · " + session.mode.title + " · " + session.directory.lastPathComponent)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Circle().fill(session.running ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
        }
    }
}

struct TerminalPane: View {
    @ObservedObject var session: AgentSession
    @EnvironmentObject private var agents: AgentManager

    var body: some View {
        VStack(spacing: 0) {
            TerminalContainer(session: session)
            if !session.running {
                HStack {
                    Label("Beendet\(session.exitCode.map { " (Code \($0))" } ?? "")", systemImage: "stop.circle")
                    Spacer()
                    Button("Neu starten") {
                        let kind = session.kind, dir = session.directory.path
                        agents.close(session.id)
                        agents.start(kind, in: dir)
                    }
                    Button("Schließen") { agents.close(session.id) }
                }
                .padding(Grid.s)
                .background(.bar)
            }
        }
        .background(Color(hex: 0x141418))
    }
}
