import AgenticOSKit
import AppKit
import SwiftUI

// Eigene Arbeitskopie pro Coding-Auftrag (git worktree): mehrere Agents arbeiten parallel im selben Repo,
// ohne sich gegenseitig Dateien zu überschreiben. Am Ende entscheidest du: übernehmen, Pull Request oder verwerfen.

enum Git {
    /// Ist in git kein Name/keine E-Mail eingerichtet, scheitern Commits („Author identity unknown“).
    /// Dann nur für diesen Befehl eine Identität mitgeben – an deiner Git-Konfiguration ändert sich nichts.
    static func identity(_ dir: String) -> [String] {
        hasIdentity(dir) ? [] : ["-c", "user.name=\(fallbackName)", "-c", "user.email=\(fallbackEmail)"]
    }
    static var fallbackName: String { Profile.name.isEmpty ? "Salenta Code" : Profile.name }
    static let fallbackEmail = "salenta-os@localhost"
    private static var identityCache: Bool?
    static func hasIdentity(_ dir: String) -> Bool {
        if let c = identityCache { return c }
        let ok = !run(["config", "user.email"], in: dir).out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        identityCache = ok
        return ok
    }

    @discardableResult
    static func run(_ args: [String], in dir: String, timeout: TimeInterval = 60) -> (out: String, code: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: dir, isDirectory: true)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return ("git: \(error.localizedDescription)", 1) }
        var data = Data()
        let reader = DispatchQueue(label: "git.read")
        let done = DispatchSemaphore(value: 0)
        reader.async { data = pipe.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return ("git: Zeitüberschreitung", 1) }
        while p.isRunning { usleep(20_000) }  // kein waitUntilExit: das dreht den RunLoop und kann SwiftUI mitten im Zeichnen abstürzen lassen
        return (String(decoding: data, as: UTF8.self), p.terminationStatus)
    }

    /// Wurzel des Repos, falls `dir` darin liegt.
    static func root(of dir: String) -> String? {
        let r = run(["rev-parse", "--show-toplevel"], in: dir, timeout: 10)
        let path = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.code == 0 && path.hasPrefix("/") ? path : nil
    }
}

struct WorktreeInfo: Codable, Hashable {
    let path: String
    let branch: String
    let base: String        // Repo, aus dem die Kopie stammt
    let baseBranch: String  // Branch, auf dem die Kopie beruht
}

enum Worktrees {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "coding.worktree") as? Bool ?? true }

    /// Ohne Leerzeichen im Pfad („Application Support“ bricht Tests und Skripte, die Pfade aus URLs bauen: %20).
    static var root: URL {
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".salenta-os/worktrees", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    /// Frühere Ablage – bestehende Arbeitskopien dort bleiben gültig.
    static var legacyRoot: URL { Paths.support.appendingPathComponent("worktrees", isDirectory: true) }

    static func isWorktree(_ dir: String) -> Bool { dir.hasPrefix(root.path) || dir.hasPrefix(legacyRoot.path) }

    /// Legt eine Arbeitskopie an. nil = kein Git-Repo, ausgeschaltet oder fehlgeschlagen (dann im Original arbeiten).
    static func create(for dir: String, id: String) -> WorktreeInfo? {
        guard enabled, !isWorktree(dir), let repo = Git.root(of: dir) else { return nil }
        let baseBranch = Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = String(id.prefix(8)).lowercased()
        let name = (repo as NSString).lastPathComponent.replacingOccurrences(of: " ", with: "-")
        let path = root.appendingPathComponent("\(name)-\(short)").path
        let branch = "aos/\(short)"
        let r = Git.run(["worktree", "add", "-b", branch, path, "HEAD"], in: repo)
        guard r.code == 0 else { return nil }
        prepare(worktree: path, from: repo)
        // Unterordner beibehalten (Auftrag galt z. B. für repo/app)
        let rel = String(dir.dropFirst(repo.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let work = rel.isEmpty ? path : (path as NSString).appendingPathComponent(rel)
        return WorktreeInfo(path: work, branch: branch, base: repo, baseBranch: baseBranch.isEmpty ? "main" : baseBranch)
    }

    /// Eine frische Arbeitskopie enthält nur, was in git ist. Damit Bauen und Testen dort genauso klappt wie im
    /// Projektordner (so wie bei Claude Code direkt im Repo), kommt das Lokale mit:
    ///  • .env-Dateien, CLAUDE.local.md, .claude/settings.local.json und alles aus .worktreeinclude → als Kopie (APFS-Klon, sofort)
    ///  • node_modules → verlinkt statt neu installiert (Wurzel und apps/*, packages/*)
    static func prepare(worktree: String, from repo: String) {
        let fm = FileManager.default
        var copy = [".env", ".env.local", ".env.development", ".env.development.local", ".env.test", ".env.test.local",
                    "CLAUDE.local.md", ".claude/settings.local.json", ".dev.vars"]
        if let inc = try? String(contentsOfFile: (repo as NSString).appendingPathComponent(".worktreeinclude"), encoding: .utf8) {
            copy += inc.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        // .env* in Unterordnern der ersten Ebene (z. B. apps/web/.env.local) – ohne tief zu suchen
        for top in ["", "apps", "packages", "supabase", "web", "app", "frontend", "backend", "server"] {
            let base = top.isEmpty ? repo : (repo as NSString).appendingPathComponent(top)
            let dirs = top.isEmpty ? [""] : ((try? fm.contentsOfDirectory(atPath: base)) ?? []).map { top + "/" + $0 } + [top]
            for d in dirs {
                let full = d.isEmpty ? repo : (repo as NSString).appendingPathComponent(d)
                for f in (try? fm.contentsOfDirectory(atPath: full)) ?? [] where f.hasPrefix(".env") && !f.hasSuffix(".example") && !f.hasSuffix(".sample") {
                    copy.append(d.isEmpty ? f : d + "/" + f)
                }
            }
        }
        var done = Set<String>()
        for rel in copy where done.insert(rel).inserted {
            let src = (repo as NSString).appendingPathComponent(rel), dst = (worktree as NSString).appendingPathComponent(rel)
            guard fm.fileExists(atPath: src), !fm.fileExists(atPath: dst) else { continue }
            // nur, was git ohnehin ignoriert – sonst könnte ein Schlüssel versehentlich mit committet werden
            guard Git.run(["check-ignore", "-q", rel], in: repo).code == 0 else { continue }
            try? fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            _ = Proc.zsh("/bin/cp -c -R \(Shell.quote(src)) \(Shell.quote(dst)) 2>/dev/null || /bin/cp -R \(Shell.quote(src)) \(Shell.quote(dst))",
                         in: repo, timeout: 60)
        }
        // Abhängigkeiten verlinken
        var nm = ["node_modules"]
        for group in ["apps", "packages"] {
            for sub in (try? fm.contentsOfDirectory(atPath: (repo as NSString).appendingPathComponent(group))) ?? [] { nm.append("\(group)/\(sub)/node_modules") }
        }
        for rel in nm {
            let src = (repo as NSString).appendingPathComponent(rel), dst = (worktree as NSString).appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src, isDirectory: &isDir), isDir.boolValue, !fm.fileExists(atPath: dst),
                  fm.fileExists(atPath: (dst as NSString).deletingLastPathComponent) else { continue }
            try? fm.createSymbolicLink(atPath: dst, withDestinationPath: src)
        }
    }

    /// Verlinkte Abhängigkeiten nie mit committen (ein Link ist für git eine Datei – „node_modules/“ greift da nicht).
    static let addSpec = [".", ":(exclude)node_modules", ":(exclude,glob)**/node_modules"]

    static func top(_ wt: WorktreeInfo) -> String { Git.root(of: wt.path) ?? wt.path }

    struct FileChange: Identifiable, Hashable {
        var id: String { path }
        let path: String
        let added: Int
        let removed: Int
    }

    /// Änderungen gegenüber dem Ausgangsstand (eigene Commits + noch nicht committete Dateien).
    static func changes(_ wt: WorktreeInfo) -> [FileChange] {
        let dir = top(wt)
        Git.run(["add", "-A", "--intent-to-add", "--"] + Self.addSpec, in: dir)
        let base = Git.run(["merge-base", "HEAD", wt.baseBranch], in: dir).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = Git.run(["diff", "--numstat", base.isEmpty ? "HEAD" : base], in: dir)
        return r.out.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard p.count == 3 else { return nil }
            return FileChange(path: p[2], added: Int(p[0]) ?? 0, removed: Int(p[1]) ?? 0)
        }
    }

    static func diff(_ wt: WorktreeInfo, file: String? = nil) -> String {
        let dir = top(wt)
        let base = Git.run(["merge-base", "HEAD", wt.baseBranch], in: dir).out.trimmingCharacters(in: .whitespacesAndNewlines)
        var args = ["diff", "--no-color", base.isEmpty ? "HEAD" : base]
        if let file { args += ["--", file] }
        return Git.run(args, in: dir).out
    }

    private static func commitAll(_ wt: WorktreeInfo, message: String) {
        let dir = top(wt)
        Git.run(["add", "-A", "--"] + Self.addSpec, in: dir)
        let staged = Git.run(["diff", "--cached", "--quiet"], in: dir).code != 0
        if staged { Git.run(Git.identity(dir) + ["commit", "-m", message], in: dir) }
    }

    /// In den Ausgangs-Branch übernehmen. Bei Konflikt wird abgebrochen und nichts verändert.
    static func merge(_ wt: WorktreeInfo, message: String) -> (Bool, String) {
        commitAll(wt, message: message)
        let current = Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: wt.base).out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current == wt.baseBranch else {
            return (false, L("Im Repo ist gerade ein anderer Branch ausgecheckt – bitte als Pull Request übernehmen."))
        }
        let r = Git.run(Git.identity(wt.base) + ["merge", "--no-ff", "--no-edit", wt.branch], in: wt.base)
        if r.code != 0 {
            Git.run(["merge", "--abort"], in: wt.base)
            return (false, L("Konflikt mit neueren Änderungen – bitte als Pull Request übernehmen."))
        }
        discard(wt, keepBranch: false)
        return (true, L("Übernommen"))
    }

    /// Übernommene Commits auf GitHub hochladen – normaler Push, nie --force. Nur nach deinem Klick.
    static func push(repo: String, branch: String) -> (Bool, String) {
        let r = Git.run(["push", "origin", branch], in: repo, timeout: 180)
        if r.code == 0 { return (true, L("Auf GitHub hochgeladen") + " (\(branch))") }
        if r.out.contains("rejected") || r.out.contains("non-fast-forward") {
            return (false, L("GitHub hat neuere Änderungen – erst holen (Pull), dann erneut hochladen."))
        }
        if r.out.contains("protected") { return (false, L("Branch ist auf GitHub geschützt – bitte als Pull Request übernehmen.")) }
        return (false, String(r.out.suffix(300)))
    }

    static func aheadCount(repo: String, branch: String) -> Int {
        // Gegen den eingestellten Upstream zählen (der Branch auf GitHub kann anders heißen); sonst origin/<branch>
        let up = Git.run(["rev-list", "--count", "@{u}..HEAD"], in: repo, timeout: 10)
        if up.code == 0 { return Int(up.out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        return Int(Git.run(["rev-list", "--count", "origin/\(branch)..\(branch)"], in: repo, timeout: 10).out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Nachfragen und hochladen (läuft auf dem Hauptthread, Push im Hintergrund).
    static func offerPush(repo: String, branch: String, app: AppModel) {
        let n = aheadCount(repo: repo, branch: branch)
        guard n > 0, Git.run(["remote", "get-url", "origin"], in: repo, timeout: 5).code == 0 else { return }
        let a = NSAlert()
        a.messageText = L("Auch auf GitHub hochladen?")
        a.informativeText = String(format: L("Die Änderungen sind lokal in „%@“ übernommen. %d Commit(s) sind noch nicht auf GitHub (%@)."),
                                   branch, n, (repo as NSString).lastPathComponent)
        a.addButton(withTitle: L("Hochladen (Push)")); a.addButton(withTitle: L("Später"))
        guard a.runModal() == .alertFirstButtonReturn else {
            app.show(L("Lokal übernommen – hochladen geht später unter Projekte (Pfeil nach oben)."))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let (ok, msg) = GitSync.upload(repo: repo)
            DispatchQueue.main.async { app.show(ok ? "✓ " + msg : msg) }
        }
    }

    /// Branch pushen und Pull Request erstellen (GitHub CLI).
    static func pullRequest(_ wt: WorktreeInfo, title: String, body: String) -> (Bool, String) {
        commitAll(wt, message: title)
        let dir = top(wt)
        let push = Git.run(["push", "-u", "origin", wt.branch], in: dir, timeout: 120)
        guard push.code == 0 else { return (false, push.out) }
        let gh = Detection.which("gh") ?? "/opt/homebrew/bin/gh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gh)
        p.arguments = ["pr", "create", "--head", wt.branch, "--base", wt.baseBranch, "--title", title, "--body", body]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (false, "gh: \(error.localizedDescription)") }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        while p.isRunning { usleep(20_000) }
        if p.terminationStatus == 0 { discard(wt, keepBranch: true) }
        return (p.terminationStatus == 0, out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func discard(_ wt: WorktreeInfo, keepBranch: Bool) {
        Git.run(["worktree", "remove", "--force", top(wt)], in: wt.base)
        if !keepBranch { Git.run(["branch", "-D", wt.branch], in: wt.base) }
    }
}

/// Merkt sich, bei welchen Aufträgen der Agent nichts geändert hat – damit „Wie geht's weiter?“ dann kein „Schritt 2“ ist.
final class ChangeState: ObservableObject {
    static let shared = ChangeState()
    @Published var empty: Set<String> = []
}

/// "Änderungen": was der Agent im Repo geändert hat – mit Übernehmen, Pull Request, Verwerfen.
struct ChangesPanel: View {
    let rec: MissionRecord
    let wt: WorktreeInfo
    @ObservedObject private var store = MissionStore.shared
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var tasks: TaskStore
    @EnvironmentObject private var hub: MCPHub
    @State private var files: [Worktrees.FileChange] = []
    @State private var open: String?
    @State private var diffText = ""
    @State private var busy = false
    @State private var loaded = false
    @State private var showPreview = false
    @State private var fileLimit = 40
    @State private var points: [Checkpoints.Point] = []
    @ObservedObject private var preview = PreviewServer.shared

    @State private var showFiles = false
    @State private var showPR = false

    private var red: Bool { rec.verify?.passed == false }
    private var checking: Bool { rec.verify?.running == true }

    /// Ein Satz, der sagt, wo du stehst – statt Fachbegriffen.
    private var statusLine: String {
        if files.isEmpty { return L("Änderungen werden geladen …") }
        if checking { return L("Wird gerade automatisch geprüft (Build, Tests, Review) …") }
        if red { return L("Die Prüfung hat Probleme gefunden. Lass sie zuerst beheben – dann übernehmen.") }
        if rec.verify?.passed == true { return L("Geprüft, alles in Ordnung. Ein Klick auf „Übernehmen“ und die Änderungen sind in deinem Projekt.") }
        return L("Noch nicht geprüft. Du kannst es vorher ausprobieren oder direkt übernehmen.")
    }

    var body: some View {
        if loaded && files.isEmpty && rec.pr == nil { nothingChanged } else { changed }
    }

    /// Der Agent hat nichts geändert: nichts zu übernehmen – nur abschließen.
    private var nothingChanged: some View {
        HStack(alignment: .top, spacing: Grid.s) {
            Image(systemName: "checkmark.seal").font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nichts zu übernehmen").font(.headline)
                Text("Der Agent hat keine Datei geändert – dein Projekt ist unverändert. Lies oben seine Antwort; unten findest du Vorschläge, falls du weitermachen willst.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                act("discarded") { Worktrees.discard(wt, keepBranch: false); return (true, L("Auftrag abgeschlossen")) }
            } label: { Label(L("Abschließen"), systemImage: "checkmark") }
            .help(L("Leere Arbeitskopie aufräumen und den Auftrag schließen"))
        }
        .padding(Grid.l)
        .background(RoundedRectangle(cornerRadius: 14).fill(.background.secondary))
        .frame(maxWidth: 780)
        .padding(.horizontal, Grid.l)
        .onAppear { ChangeState.shared.empty.insert(rec.id) }
    }

    private var changed: some View {
        VStack(alignment: .leading, spacing: Grid.m) {
            // Kopf: Schritt 1 – was jetzt zu tun ist
            HStack(alignment: .top, spacing: Grid.s) {
                StepBadge(number: 1, done: false, tint: red ? .orange : (rec.verify?.passed == true ? .green : .accentColor))
                VStack(alignment: .leading, spacing: 2) {
                    Text(red ? "Erst beheben, dann übernehmen" : "Änderungen übernehmen").font(.headline)
                    Text(statusLine).font(.callout).foregroundStyle(red ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }

            if !files.isEmpty || rec.verify != nil {
                VerifyStrip(rec: rec) { agent, model in
                    Verifier.fix(rec, agents: agents, hub: hub, agent: agent, model: model) { s in app.page = .chat(s.id.uuidString) }
                }
                ParallelCompare(rec: rec)
            }

            if let pr = rec.pr {
                // PR ist offen: weitere Änderungen landen mit einem Klick im selben PR
                HStack(spacing: Grid.s) {
                    Image(systemName: "arrow.triangle.pull").foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("Pull Request ist offen")).font(.callout.weight(.semibold))
                        Link(pr.replacingOccurrences(of: "https://github.com/", with: ""), destination: URL(string: pr) ?? URL(string: "https://github.com")!).font(.caption)
                    }
                    Spacer()
                    Button { act(nil) { Worktrees.amendPR(wt, message: L("Nachtrag: ") + rec.title, newBody: nil) } } label: {
                        Label(L("Nachschieben"), systemImage: "arrow.up.circle")
                    }
                    .help(L("Neue Änderungen dieses Auftrags committen und in denselben Pull Request hochladen"))
                    Button {
                        act(nil) {
                            let d = PRWriter.generate(rec: rec, wt: wt, base: wt.baseBranch)
                            return Worktrees.amendPR(wt, message: L("Nachtrag: ") + rec.title, newBody: d.body)
                        }
                    } label: { Label(L("Mit neuer Beschreibung"), systemImage: "sparkles") }
                    .help(L("Nachschieben und die PR-Beschreibung samt Changelog neu schreiben lassen"))
                    Button {
                        let w = wt, id = rec.id
                        DispatchQueue.global(qos: .userInitiated).async {
                            Worktrees.discard(w, keepBranch: true)
                            DispatchQueue.main.async {
                                PreviewServer.shared.stop(id)
                                store.clearWorktree(id)
                                store.archive(id, agents: agents, tasks: tasks)
                                app.show("✓ " + L("Auftrag abgeschlossen – der Pull Request bleibt auf GitHub"))
                                app.page = .home
                            }
                        }
                    } label: { Label(L("Abschließen"), systemImage: "checkmark") }
                    .help(L("Arbeitskopie aufräumen und den Auftrag schließen – der PR und sein Branch bleiben auf GitHub"))
                }
                .padding(Grid.m)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.08)))
            }

            // Aktionen: eine klare Hauptaktion, der Rest unter „Mehr“
            HStack(spacing: Grid.s) {
                if rec.pr == nil {
                Button { act("merged") { Worktrees.merge(wt, message: rec.title) } } label: {
                    Label(L("Übernehmen"), systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent).tint(.green).controlSize(.large)
                .disabled(files.isEmpty || checking || red)
                .help(red ? L("Erst die roten Punkte beheben lassen – oder unter „Mehr“ trotzdem übernehmen")
                          : L("Die Änderungen kommen in dein Projekt (Branch") + " \(wt.baseBranch))")
                Button { showPR = true } label: { Label(L("Pull Request …"), systemImage: "arrow.triangle.pull") }
                    .controlSize(.large)
                    .disabled(files.isEmpty || checking)
                    .help(L("Ein Klick: committen, pushen und Pull Request mit fertigem Titel, Beschreibung und Changelog öffnen"))
                }
                Button {
                    PreviewServer.shared.start(id: rec.id, dir: Worktrees.top(wt), base: wt.base, track: wt.baseBranch) { u in if u == nil { app.show(L("Kein Dev-Server gefunden – \"dev\" in .salenta-os.json eintragen")) } }
                    showPreview = true
                } label: { Label(preview.running[rec.id] != nil ? L("Vorschau läuft") : L("Vorher ausprobieren"), systemImage: "play.display") }
                    .controlSize(.large)
                    .help(L("Startet die App mit den Änderungen und zeigt sie live – dein Projekt bleibt unverändert"))
                Spacer()
                Menu {
                    if red { Button(L("Trotzdem übernehmen")) { act("merged") { Worktrees.merge(wt, message: rec.title) } } }
                    Button(L("Als Pull Request auf GitHub …")) { showPR = true }
                        .disabled(files.isEmpty || rec.pr != nil)
                    Menu(L("Auf früheren Stand zurück")) {
                        if points.isEmpty { Text("Noch keine Checkpoints") }
                        ForEach(points) { p in
                            Button("\(p.title)\(p.age.isEmpty ? "" : " · " + p.age)") {
                                let a = NSAlert()
                                a.messageText = L("Arbeitskopie auf diesen Stand zurücksetzen?")
                                a.informativeText = L("Der aktuelle Stand wird vorher als Checkpoint gesichert. Dein Repo bleibt unberührt.")
                                a.addButton(withTitle: L("Zurücksetzen")); a.addButton(withTitle: L("Abbrechen"))
                                guard a.runModal() == .alertFirstButtonReturn else { return }
                                act(nil) { Checkpoints.restore(wt, to: p.sha) ? (true, L("Zurückgesetzt auf ") + p.sha) : (false, L("Zurücksetzen fehlgeschlagen")) }
                            }
                        }
                    }
                    Divider()
                    Button(L("Änderungen verwerfen"), role: .destructive) {
                        let a = NSAlert()
                        a.messageText = L("Alle Änderungen dieses Auftrags verwerfen?")
                        a.informativeText = L("Dein Projekt bleibt, wie es ist. Die Arbeitskopie wird gelöscht.")
                        a.addButton(withTitle: L("Verwerfen")); a.addButton(withTitle: L("Abbrechen"))
                        guard a.runModal() == .alertFirstButtonReturn else { return }
                        act("discarded") { Worktrees.discard(wt, keepBranch: false); return (true, L("Verworfen")) }
                    }
                } label: { Label(L("Mehr"), systemImage: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }

            // Dateien: zugeklappt – wer will, schaut rein
            if !files.isEmpty {
                DisclosureGroup(isExpanded: $showFiles) {
                    LazyVStack(alignment: .leading, spacing: 0) { ForEach(files.prefix(fileLimit)) { f in
                        VStack(alignment: .leading, spacing: 0) {
                            Button {
                                open = open == f.path ? nil : f.path
                                if let o = open { DispatchQueue.global().async { let d = Worktrees.diff(wt, file: o); DispatchQueue.main.async { diffText = d } } }
                            } label: {
                                HStack {
                                    Image(systemName: open == f.path ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 10)
                                    Text(f.path).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text("+\(f.added)").foregroundStyle(.green).font(.caption.monospacedDigit())
                                    Text("−\(f.removed)").foregroundStyle(.red).font(.caption.monospacedDigit())
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if open == f.path { DiffText(text: diffText).padding(.top, 4) }
                        }
                    } }
                    if files.count > fileLimit {
                        HStack {
                            Text("\(files.count - fileLimit) " + L("weitere Dateien")).font(.caption).foregroundStyle(.secondary)
                            Button(L("40 mehr zeigen")) { fileLimit += 40 }.buttonStyle(.link)
                        }
                    }
                } label: {
                    Text("\(files.count) \(files.count == 1 ? L("Datei geändert") : L("Dateien geändert"))  ")
                        + Text("+\(files.map(\.added).reduce(0, +)) −\(files.map(\.removed).reduce(0, +))").foregroundColor(.secondary)
                }
                .font(.callout)
            }
            Text(rec.pr == nil
                 ? "Der Agent hat in einer eigenen Kopie gearbeitet. „Vorher ausprobieren“ startet die App mit den Änderungen, ohne dein Projekt anzufassen. „Übernehmen“ schreibt sie in dein Projekt. „Pull Request“ schickt sie zur Prüfung auf GitHub."
                 : "Der Agent hat in einer eigenen Kopie gearbeitet. Dein Projekt ändert sich erst, wenn der Pull Request gemergt wird.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Grid.l)
        .background(RoundedRectangle(cornerRadius: 14).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder((red ? Color.orange : Color.secondary).opacity(0.25)))
        .frame(maxWidth: 780)
        .padding(.horizontal, Grid.l)
        .task(id: rec.id) { reload() }
        .sheet(isPresented: $showPreview) { PreviewSheet(id: rec.id, title: rec.title) }
        .sheet(isPresented: $showPR) {
            PRSheet(rec: rec, wt: wt, files: files) { ok, msg in
                guard ok else { app.show(msg); return }
                store.setPR(rec.id, msg)
                store.setOutcome(rec.id, "pr")
                ModStore.shared.fire(.prCreated, rec: rec, result: msg)
                Learning.record(rec, outcome: "pr")
                app.show("✓ " + L("Pull Request geöffnet"))
                if let u = URL(string: msg) { NSWorkspace.shared.open(u) }
            }
        }
        .onChange(of: rec.verify?.finished) { _, _ in reload() }
    }

    /// Beschreibung für den Pull Request: Auftrag plus Prüfergebnis.
    private var prBody: String {
        var b = rec.request
        if let v = rec.verify, v.finished != nil {
            b += "\n\n---\n" + (v.passed == true ? "✅ " : "⚠️ ") + L("Automatisch geprüft") + ":\n"
            b += v.checks.map { "- \($0.ok == true ? "✅" : "❌") \($0.name): `\($0.command)`" }.joined(separator: "\n")
            if let r = v.review { b += "\n- \(r.ok ? "✅" : "❌") Review (\(r.agent)): \(r.summary)" + r.issues.map { "\n  - " + $0 }.joined() }
        }
        return b + "\n\n" + L("Erstellt mit Salenta Code")
    }

    private func reload() {
        DispatchQueue.global(qos: .userInitiated).async {
            let f = Worktrees.changes(wt)
            let pts = Checkpoints.list(wt)
            DispatchQueue.main.async {
                files = f; points = pts; loaded = true
                if f.isEmpty { ChangeState.shared.empty.insert(rec.id) } else { ChangeState.shared.empty.remove(rec.id) }
            }
        }
    }

    private func act(_ outcome: String?, _ work: @escaping () -> (Bool, String)) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let (ok, msg) = work()
            DispatchQueue.main.async {
                busy = false
                app.show(ok ? "✓ " + msg : msg)
                guard let outcome else { if ok { reload() }; return }   // Checkpoint: nur neu laden
                if ok {
                    PreviewServer.shared.stop(rec.id)
                    if outcome == "merged" {
                        ModStore.shared.fire(.merged, rec: rec)
                        let repo = wt.base, branch = wt.baseBranch
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Worktrees.offerPush(repo: repo, branch: branch, app: app) }
                    }
                    if outcome == "pr" { ModStore.shared.fire(.prCreated, rec: rec, result: msg) }
                    store.setOutcome(rec.id, outcome)
                    Learning.record(rec, outcome: outcome)
                    store.clearWorktree(rec.id)
                    store.archive(rec.id, agents: agents, tasks: tasks)
                    app.page = .home
                }
            }
        }
    }
}

struct DiffText: View {
    let text: String
    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).prefix(800).enumerated()), id: \.offset) { _, line in
                    Text(String(line).isEmpty ? " " : String(line))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(line.hasPrefix("+") && !line.hasPrefix("+++") ? Color.green
                                         : line.hasPrefix("-") && !line.hasPrefix("---") ? Color.red
                                         : line.hasPrefix("@@") ? Color.blue : Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Grid.s)
        }
        .frame(maxHeight: 320)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }
}


/// Nummer eines Schritts (1, 2 …) – zeigt die Reihenfolge: erst übernehmen, dann weitermachen.
struct StepBadge: View {
    let number: Int
    var done = false
    var tint: Color = .accentColor
    var body: some View {
        ZStack {
            Circle().fill(done ? Color.green : tint.opacity(0.18))
            if done { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white) }
            else { Text("\(number)").font(.callout.weight(.bold)).foregroundStyle(tint) }
        }
        .frame(width: 26, height: 26)
    }
}
