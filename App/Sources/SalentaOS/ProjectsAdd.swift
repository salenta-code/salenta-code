import AgenticOSKit
import AppKit
import SwiftUI

// Projekt hinzufügen – bewusst statt automatisch: einen Ordner wählen, ein GitHub-Repo verbinden oder ein neues anlegen.
// Dazu „Grundlagen“: was ein frischer Mac braucht (Homebrew, Git, GitHub CLI + Anmeldung, Node), mit einem Klick installierbar.

struct AddProjectSheet: View {
    @EnvironmentObject private var catalog: ProjectCatalog
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var essentials = Essentials.shared
    @State private var tab = 0
    @State private var search = ""
    @State private var base = UserDefaults.standard.string(forKey: "projects.base") ?? Paths.home.appendingPathComponent("Code").path
    @State private var busy: String?
    @State private var error: String?
    @State private var newName = ""
    @State private var onGitHub = true
    @State private var isPrivate = true
    @State private var found: [Project] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.m) {
            HStack {
                Text("Projekt hinzufügen").font(.title2.weight(.semibold))
                Spacer()
                Button("Fertig") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("", selection: $tab) {
                Label("Von GitHub", systemImage: "arrow.down.circle").tag(0)
                Label("Ordner auf dem Mac", systemImage: "folder").tag(1)
                Label("Neues Projekt", systemImage: "plus.square").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden()

            switch tab {
            case 0: github
            case 1: folder
            default: create
            }

            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red).lineLimit(3) }
        }
        .padding(Grid.l)
        .frame(width: 640, height: 560)
        .onAppear { essentials.check(); catalog.loadGitHub() }
    }

    private var baseRow: some View {
        HStack {
            Text("Speichern in").foregroundStyle(.secondary)
            Text(base.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.callout.monospaced()).lineLimit(1)
            Spacer()
            Button("Ändern …") {
                let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                if p.runModal() == .OK, let u = p.url { base = u.path; UserDefaults.standard.set(base, forKey: "projects.base") }
            }
        }
        .font(.callout)
    }

    // MARK: GitHub

    @ViewBuilder private var github: some View {
        if !essentials.ghInstalled || !essentials.ghLoggedIn {
            VStack(alignment: .leading, spacing: Grid.s) {
                Text("Mit GitHub verbinden").font(.headline)
                Text("Einmalig: Salenta Code nutzt dafür die offizielle GitHub CLI. Die Anmeldung läuft im Browser – kein Passwort in Salenta Code.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    if !essentials.ghInstalled {
                        Button("GitHub CLI installieren") { essentials.install(.gh) }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Bei GitHub anmelden") { essentials.loginGitHub() }.buttonStyle(.borderedProminent)
                    }
                    Button("Erneut prüfen") { essentials.check(); catalog.loadGitHub(force: true) }
                }
            }
            Spacer()
        } else {
            baseRow
            TextField("Repo suchen …", text: $search).textFieldStyle(.roundedBorder)
            List {
                if catalog.loadingGitHub { HStack { ProgressView().controlSize(.small); Text("Lade deine Repos …") } }
                ForEach(catalog.github.filter { search.isEmpty || $0.fullName.localizedCaseInsensitiveContains(search) }) { r in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.fullName).fontWeight(.medium)
                            Text(L("geändert ") + r.updated).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let have = catalog.local.first(where: { ($0.path as NSString).lastPathComponent == r.fullName.components(separatedBy: "/").last }) {
                            Label("in der Liste", systemImage: "checkmark").font(.caption).foregroundStyle(.green).help(have.path)
                        } else if busy == r.fullName {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Verbinden") { clone(r) }.disabled(busy != nil)
                                .help(L("Klont das Repo nach ") + base + L(" und nimmt es in die Projekte auf"))
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func clone(_ r: RemoteRepo) {
        busy = r.fullName; error = nil
        catalog.clone(r, into: base) { path, err in
            busy = nil
            if let path { app.show("✓ " + r.fullName + L(" ist verbunden")); _ = path } else { error = err }
        }
    }

    // MARK: Ordner

    private var folder: some View {
        VStack(alignment: .leading, spacing: Grid.m) {
            Button {
                let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.prompt = L("Als Projekt nehmen")
                if p.runModal() == .OK, let u = p.url { catalog.add(u.path, source: "Ordner"); app.show("✓ " + u.lastPathComponent + L(" hinzugefügt")) }
            } label: { Label("Ordner wählen …", systemImage: "folder.badge.plus") }
            .buttonStyle(.borderedProminent).controlSize(.large)
            Text("Jeder Ordner geht – mit oder ohne Git. Ohne Git arbeiten die Agents direkt im Ordner (keine eigene Arbeitskopie).")
                .font(.caption).foregroundStyle(.secondary)
            if !found.isEmpty {
                Divider()
                Text("Auf diesem Mac gefunden (zum Übernehmen)").font(.headline)
                List(found) { p in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).fontWeight(.medium)
                            Text(p.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Hinzufügen") { catalog.add(p.path, source: "Ordner"); found.removeAll { $0.path == p.path } }
                    }
                }
                .listStyle(.inset)
            }
        }
        .task {
            let c = catalog
            found = await Task.detached { c.suggestions() }.value
        }
    }

    // MARK: Neu

    private var create: some View {
        VStack(alignment: .leading, spacing: Grid.m) {
            TextField("Name, z. B. kunden-portal", text: $newName).textFieldStyle(.roundedBorder)
            baseRow
            Toggle("Auch auf GitHub anlegen", isOn: $onGitHub).disabled(!essentials.ghLoggedIn)
            if onGitHub { Toggle("Privat", isOn: $isPrivate).padding(.leading, Grid.l) }
            if !essentials.ghLoggedIn { Text("Für GitHub erst unter „Von GitHub“ verbinden.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                if busy == "new" { ProgressView().controlSize(.small) }
                Button("Anlegen") {
                    busy = "new"; error = nil
                    catalog.create(name: newName, in: base, onGitHub: onGitHub && essentials.ghLoggedIn, isPrivate: isPrivate) { path, err in
                        busy = nil
                        if let path { app.show("✓ " + (path as NSString).lastPathComponent + L(" angelegt")); if err == nil { dismiss() } }
                        error = err
                    }
                }
                .buttonStyle(.borderedProminent).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || busy != nil)
            }
            Spacer()
        }
    }
}

// MARK: - Grundlagen für einen frischen Mac

final class Essentials: ObservableObject {
    static let shared = Essentials()
    enum Tool: String, CaseIterable, Identifiable {
        case brew, git, gh, node, claude, codex, tmux, ollama
        var id: String { rawValue }
        var title: String {
            switch self {
            case .brew: "Homebrew"
            case .git: "Git"
            case .gh: "GitHub CLI"
            case .node: "Node.js"
            case .claude: "Claude Code"
            case .codex: "Codex"
            case .tmux: "tmux"
            case .ollama: "Ollama (lokale Modelle)"
            }
        }
        var why: String {
            switch self {
            case .brew: L("Paketverwaltung – installiert den Rest")
            case .git: L("Versionen und Arbeitskopien")
            case .gh: L("GitHub-Repos verbinden, Pull Requests")
            case .node: L("Web-Projekte und der Browser der Agents")
            case .claude: L("Haupt-Agent (Pflicht)")
            case .codex: L("zweiter Agent und zweite Meinung")
            case .tmux: L("Agents laufen weiter, wenn die App zu ist")
            case .ollama: L("offline und kostenlos arbeiten")
            }
        }
        var required: Bool { self == .brew || self == .git || self == .claude }
        var install: String {
            switch self {
            case .brew: return #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#
            case .git: return "xcode-select --install"
            case .gh: return "brew install gh && gh auth login --web --git-protocol https"
            case .node: return "brew install node"
            case .claude: return "curl -fsSL https://claude.ai/install.sh | bash"
            case .codex: return "brew install codex || npm install -g @openai/codex"
            case .tmux: return "brew install tmux"
            case .ollama: return "brew install ollama && brew services start ollama"
            }
        }
    }

    @Published private(set) var found: [Tool: Bool] = [:]
    @Published private(set) var ghLoggedIn = false
    var ghInstalled: Bool { found[.gh] == true }
    var missingRequired: [Tool] { Tool.allCases.filter { $0.required && found[$0] == false } }

    func check() {
        DispatchQueue.global(qos: .userInitiated).async {
            var f: [Tool: Bool] = [:]
            for t in Tool.allCases {
                let cmd = t == .brew ? "brew" : t.rawValue
                f[t] = Proc.zsh("command -v \(cmd) >/dev/null", in: NSTemporaryDirectory(), timeout: 10).code == 0
            }
            // git über Xcode-Werkzeuge: „command -v git“ findet den Platzhalter auch ohne Installation
            if f[.git] == true { f[.git] = Proc.zsh("xcode-select -p >/dev/null 2>&1 || command -v brew >/dev/null && brew list git >/dev/null 2>&1", in: NSTemporaryDirectory(), timeout: 10).code == 0 }
            let logged = f[.gh] == true && Proc.zsh("gh auth status >/dev/null 2>&1", in: NSTemporaryDirectory(), timeout: 15).code == 0
            DispatchQueue.main.async { self.found = f; self.ghLoggedIn = logged }
        }
    }

    func install(_ t: Tool) { Detection.runInTerminal(t.install + " ; echo; echo '✓ Fertig – zurück zu Salenta Code und „Erneut prüfen“.'") }

    /// Alles Fehlende in einem Rutsch (Terminal zeigt jeden Schritt).
    func installMissing() {
        let missing = Tool.allCases.filter { found[$0] == false && $0 != .codex && $0 != .ollama }
        guard !missing.isEmpty else { return }
        var steps: [String] = []
        if missing.contains(.brew) { steps.append(Tool.brew.install + " && eval \"$(/opt/homebrew/bin/brew shellenv)\"") }
        if missing.contains(.git) { steps.append("(xcode-select -p >/dev/null 2>&1 || xcode-select --install)") }
        let pkgNames: [Tool: String] = [.gh: "gh", .node: "node", .tmux: "tmux"]
        let brewPkgs = missing.compactMap { pkgNames[$0] }
        if !brewPkgs.isEmpty { steps.append("brew install " + brewPkgs.joined(separator: " ")) }
        if missing.contains(.claude) { steps.append(Tool.claude.install) }
        if missing.contains(.gh) || !ghLoggedIn { steps.append("gh auth login --web --git-protocol https") }
        Detection.runInTerminal(steps.joined(separator: " && ") + " ; echo; echo '✓ Fertig – zurück zu Salenta Code und „Erneut prüfen“.'")
    }

    func loginGitHub() { Detection.runInTerminal("gh auth login --web --git-protocol https && gh auth setup-git ; echo '✓ Verbunden – zurück zu Salenta Code.'") }
}

/// Übersicht für die Einrichtung (erster Start) und die Einstellungen.
struct EssentialsView: View {
    @ObservedObject private var e = Essentials.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.s) {
            HStack {
                Text("Grundlagen").font(.headline)
                Spacer()
                Button("Erneut prüfen") { e.check() }.controlSize(.small)
                if Essentials.Tool.allCases.contains(where: { e.found[$0] == false && $0 != .codex && $0 != .ollama }) {
                    Button("Fehlendes installieren") { e.installMissing() }.buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            ForEach(Essentials.Tool.allCases) { t in
                HStack(spacing: Grid.s) {
                    Image(systemName: e.found[t] == true ? "checkmark.circle.fill" : (t.required ? "exclamationmark.circle" : "circle.dashed"))
                        .foregroundStyle(e.found[t] == true ? .green : (t.required ? .orange : .secondary))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(t.title + (t.required ? "" : " " + L("(optional)")))
                        Text(t.why).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if t == .gh, e.found[.gh] == true {
                        if e.ghLoggedIn { Text("verbunden").font(.caption).foregroundStyle(.green) }
                        else { Button("Anmelden") { e.loginGitHub() }.controlSize(.small) }
                    } else if e.found[t] == false {
                        Button("Installieren") { e.install(t) }.controlSize(.small)
                    }
                }
            }
        }
        .onAppear { e.check() }
    }
}
