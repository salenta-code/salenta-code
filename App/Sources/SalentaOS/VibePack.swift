import AgenticOSKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// Vibe-Coding-Werkzeuge: Screenshots/Dateien an Aufträge hängen, Geheimnis-Scan, Checkpoints,
// Live-Vorschau der Arbeitskopie, mehrere Agents parallel mit Vergleich, Push aufs Handy.

// MARK: - Anhänge (Screenshot einfügen, Datei ziehen)

enum Attachments {
    static var dir: URL {
        let d = Paths.support.appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Bild aus der Zwischenablage als PNG speichern (z. B. Screenshot mit ⌃⇧⌘4).
    static func fromPasteboard() -> URL? {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let u = urls.first {
            return u
        }
        guard let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = dir.appendingPathComponent("screenshot-\(Int(Date().timeIntervalSince1970)).png")
        return (try? png.write(to: url)) != nil ? url : nil
    }

    static func choose() -> [URL] {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.prompt = L("Anhängen")
        return p.runModal() == .OK ? p.urls : []
    }

    /// Text, der an den Auftrag angehängt wird – die Agents lesen Bilder und Dateien direkt über den Pfad.
    static func promptBlock(_ urls: [URL]) -> String {
        guard !urls.isEmpty else { return "" }
        return "\n\n" + L("Anhänge (lies/sieh dir diese Dateien an, Bilder sind Screenshots vom Problem oder vom gewünschten Aussehen):") + "\n"
            + urls.map { "- " + $0.path }.joined(separator: "\n")
    }
}

struct AttachmentChips: View {
    @Binding var items: [URL]
    var body: some View {
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items, id: \.self) { u in
                        HStack(spacing: 4) {
                            if let img = NSImage(contentsOf: u), ["png", "jpg", "jpeg", "heic", "gif", "tiff"].contains(u.pathExtension.lowercased()) {
                                Image(nsImage: img).resizable().scaledToFill().frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 4))
                            } else {
                                Image(systemName: "doc").font(.caption)
                            }
                            Text(u.lastPathComponent).font(.caption).lineLimit(1).frame(maxWidth: 140)
                            Button { items.removeAll { $0 == u } } label: { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain).help(L("Entfernen"))
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }
                }
            }
        }
    }
}

// MARK: - Geheimnis-Scan (keine Keys ins Repo)

enum SecretScan {
    static let patterns: [(String, String)] = [
        ("AWS Access Key", "AKIA[0-9A-Z]{16}"),
        ("Anthropic Key", "sk-ant-[A-Za-z0-9_-]{20,}"),
        ("OpenAI Key", "sk-(proj-)?[A-Za-z0-9_-]{32,}"),
        ("GitHub Token", "gh[pousr]_[A-Za-z0-9]{30,}"),
        ("Slack Token", "xox[baprs]-[A-Za-z0-9-]{10,}"),
        ("Google API Key", "AIza[0-9A-Za-z_-]{35}"),
        ("Shopify Token", "shp(at|ss|ca|pa)_[a-fA-F0-9]{32}"),
        ("Stripe Key", "(sk|rk)_live_[0-9a-zA-Z]{20,}"),
        ("Private Key", "-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
        ("JWT / Service-Role", "eyJ[A-Za-z0-9_-]{20,}\\.eyJ[A-Za-z0-9_-]{20,}\\.[A-Za-z0-9_-]{20,}"),
        ("Passwort im Code", "(password|passwort|passwd|secret|api_key|apikey|token)\\s*[:=]\\s*['\"][^'\"\\s]{8,}['\"]"),
    ]

    /// Sucht nur in hinzugefügten Zeilen des Diffs. Liefert Fundstellen (maskiert).
    static func scan(_ diff: String) -> [String] {
        var file = ""
        var hits: [String] = []
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("+++ b/") { file = String(line.dropFirst(6)); continue }
            guard line.hasPrefix("+"), !line.hasPrefix("+++") else { continue }
            if file.hasSuffix(".example") || file.contains(".env.example") || file.hasSuffix(".md") { continue }
            let isTest = file.contains("__tests__") || file.contains("/test/") || file.contains("/tests/") || file.hasPrefix("test/")
                || file.hasPrefix("tests/") || file.hasPrefix("e2e/") || file.contains(".test.") || file.contains(".spec.")
                || file.contains("fixture") || file.contains("pg-test")
            for (name, p) in patterns {
                // Test-Passwörter wie "postgres" oder "test-passwort-123" sind keine Geheimnisse – echte Schlüssel-Muster gelten weiter
                if isTest && name == "Passwort im Code" { continue }
                if let r = line.range(of: p, options: [.regularExpression, .caseInsensitive]) {
                    let hit = String(line[r])
                    let masked = String(hit.prefix(6)) + String(repeating: "•", count: max(0, min(hit.count - 6, 12)))
                    hits.append("\(file): \(name) – \(masked)")
                    break
                }
            }
        }
        // .env-Dateien gehören nie ins Repo
        for raw in diff.split(separator: "\n") where raw.hasPrefix("+++ b/") {
            let f = String(raw.dropFirst(6))
            let name = (f as NSString).lastPathComponent
            if name == ".env" || (name.hasPrefix(".env.") && !name.hasSuffix("example") && !name.hasSuffix("sample")) {
                hits.append("\(f): " + L(".env-Datei würde ins Repo kommen"))
            }
        }
        return Array(Set(hits)).sorted()
    }
}

// MARK: - Checkpoints in der Arbeitskopie

enum Checkpoints {
    struct Point: Identifiable, Hashable { var id: String { sha }; let sha: String; let title: String; let age: String }

    /// Vor jeder neuen Runde den aktuellen Stand sichern (Commit im Arbeitskopie-Branch).
    static func save(_ wt: WorktreeInfo, label: String) {
        let dir = Worktrees.top(wt)
        Git.run(["add", "-A", "--"] + Worktrees.addSpec, in: dir)
        if Git.run(["diff", "--cached", "--quiet"], in: dir).code != 0 {
            Git.run(["-c", "user.name=Salenta Code", "-c", "user.email=salenta-os@localhost", "commit", "-q", "-m", "Checkpoint: \(label)"], in: dir)
        }
    }

    static func list(_ wt: WorktreeInfo) -> [Point] {
        let dir = Worktrees.top(wt)
        let base = Worktrees.forkPoint(wt)
        guard !base.isEmpty else { return [] }
        let out = Git.run(["log", "--format=%h\t%s\t%cr", "\(base)..HEAD"], in: dir).out
        var pts = out.split(separator: "\n").compactMap { l -> Point? in
            let p = l.components(separatedBy: "\t")
            return p.count >= 3 ? Point(sha: p[0], title: p[1], age: p[2]) : nil
        }
        pts.append(Point(sha: String(base.prefix(7)), title: L("Ausgangsstand (vor dem Agent)"), age: ""))
        return pts
    }

    /// Arbeitskopie auf einen Stand zurücksetzen (nur die Kopie – dein Repo bleibt unberührt).
    static func restore(_ wt: WorktreeInfo, to sha: String) -> Bool {
        let dir = Worktrees.top(wt)
        save(wt, label: L("vor dem Zurücksetzen"))
        return Git.run(["reset", "--hard", sha], in: dir).code == 0
    }
}

// MARK: - Live-Vorschau der Arbeitskopie

final class PreviewServer: ObservableObject {
    static let shared = PreviewServer()
    struct Running { let process: Process; var url: String?; let dir: String; let log: URL }
    @Published private(set) var running: [String: Running] = [:]
    @Published private(set) var starting: Set<String> = []

    func url(_ id: String) -> String? { running[id]?.url }
    /// Ordner der Vorschau und das Original-Repo (für Vorher/Nachher)
    func info(_ id: String) -> (dir: String, base: String?)? { sources[id].map { ($0.dir, $0.base) } }

    /// Startet den Dev-Server in dir (Befehl aus .salenta-os.json "dev" oder package.json "dev") und wartet auf die Adresse.
    @Published private(set) var errors: [String: [String]] = [:]
    @Published private(set) var copiedEnv: [String: [String]] = [:]

    func reportError(_ id: String, _ text: String) {
        var e = errors[id] ?? []
        guard !e.contains(text) else { return }
        e.append(text); errors[id] = Array(e.suffix(8))
    }
    func clearErrors(_ id: String) { errors[id] = nil }

    /// Eine Arbeitskopie (git worktree) enthält keine ignorierten Dateien – .env & Co. fehlen, die App startet ohne Schlüssel
    /// und die Vorschau bleibt weiß. Darum die lokalen Umgebungsdateien aus dem Original-Repo übernehmen (nur lokal, nie ins Repo).
    static func copyEnvFiles(from base: String, to dir: String) -> [String] {
        let fm = FileManager.default
        guard base != dir, let names = try? fm.contentsOfDirectory(atPath: base) else { return [] }
        var copied: [String] = []
        for n in names where n == ".env" || n.hasPrefix(".env.") || n == ".dev.vars" {
            if n.hasSuffix(".example") || n.hasSuffix(".sample") || n.hasSuffix(".template") { continue }
            let src = (base as NSString).appendingPathComponent(n), dst = (dir as NSString).appendingPathComponent(n)
            guard !fm.fileExists(atPath: dst) else { continue }
            // nur, wenn git die Datei ignoriert – sonst wäre sie ohnehin in der Arbeitskopie
            guard Git.run(["check-ignore", "-q", n], in: base).code == 0 else { continue }
            if (try? fm.copyItem(atPath: src, toPath: dst)) != nil { copied.append(n) }
        }
        return copied
    }

    // MARK: Welchen Stand zeigt die Vorschau?

    /// Stand der Vorschau: Commit, Branch und wie weit er hinter dem Vergleichsstand (main bzw. Upstream) liegt.
    struct Freshness: Equatable {
        var sha = ""
        var branch = ""
        var target: String?      // z. B. origin/main
        var behind: Int?         // Commits, die in target fehlen
        var dirty = false
        var checking = true
    }
    @Published private(set) var freshness: [String: Freshness] = [:]
    @Published private(set) var updating: Set<String> = []
    /// Woher die Vorschau kommt: Ordner und – bei einer Arbeitskopie – der Branch, auf dem sie beruht.
    private var sources: [String: (dir: String, track: String?, base: String?)] = [:]

    /// Vergleichsstand: bei einer Arbeitskopie origin/<Basis-Branch> (sonst lokal), im Projekt der Upstream.
    private static func target(dir: String, track: String?) -> String? {
        if let track {
            for c in ["origin/\(track)", track] where Git.run(["rev-parse", "--verify", "-q", c], in: dir, timeout: 10).code == 0 { return c }
            return nil
        }
        let u = Git.run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: dir, timeout: 10)
        let s = u.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return u.code == 0 && !s.isEmpty ? s : nil
    }

    /// Holt den neuesten Stand von GitHub (nur fetch, ändert nichts) und rechnet aus, wie weit die Vorschau zurückliegt.
    func checkFreshness(_ id: String) {
        guard let src = sources[id] else { return }
        var f = freshness[id] ?? Freshness(); f.checking = true; freshness[id] = f
        DispatchQueue.global().async {
            let dir = src.dir
            var n = Freshness(checking: false)
            guard Git.root(of: dir) != nil else { DispatchQueue.main.async { self.freshness[id] = nil }; return }
            n.sha = Git.run(["rev-parse", "--short", "HEAD"], in: dir, timeout: 10).out.trimmingCharacters(in: .whitespacesAndNewlines)
            n.branch = Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: dir, timeout: 10).out.trimmingCharacters(in: .whitespacesAndNewlines)
            n.dirty = !Git.run(["status", "--porcelain", "--untracked-files=no"], in: dir, timeout: 15).out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            _ = Git.run(["fetch", "--quiet", "--no-tags", "origin"], in: dir, timeout: 25)
            if let t = Self.target(dir: dir, track: src.track) {
                n.target = t
                n.behind = Int(Git.run(["rev-list", "--count", "HEAD..\(t)"], in: dir, timeout: 15).out.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            DispatchQueue.main.async { self.freshness[id] = n }
        }
    }

    /// Bringt den Ordner der Vorschau auf den neuesten Stand und startet den Dev-Server neu.
    /// Arbeitskopie: Checkpoint, dann den Basis-Branch hineinmergen (bei Konflikt abbrechen, nichts geht verloren).
    /// Projekt: nur `git pull --ff-only` und nur ohne lokale Änderungen.
    func update(_ id: String, completion: @escaping (Bool, String) -> Void) {
        guard let src = sources[id] else { completion(false, L("Unbekannte Vorschau")); return }
        updating.insert(id)
        DispatchQueue.global().async {
            let dir = src.dir
            var ok = false, msg = ""
            _ = Git.run(["fetch", "--quiet", "--no-tags", "origin"], in: dir, timeout: 25)
            if src.track != nil {
                if let t = Self.target(dir: dir, track: src.track) {
                    Git.run(["add", "-A", "--"] + Worktrees.addSpec, in: dir)
                    if Git.run(["diff", "--cached", "--quiet"], in: dir).code != 0 {
                        Git.run(["-c", "user.name=Salenta Code", "-c", "user.email=salenta-os@localhost", "commit", "-q", "-m", "Checkpoint: vor dem Aktualisieren"], in: dir)
                    }
                    let r = Git.run(["-c", "user.name=Salenta Code", "-c", "user.email=salenta-os@localhost", "merge", "--no-edit", t], in: dir, timeout: 60)
                    if r.code == 0 { ok = true; msg = L("Auf aktuellen Stand gebracht: ") + t }
                    else { Git.run(["merge", "--abort"], in: dir); msg = L("Konflikt mit dem neuen Stand – nichts geändert. Bitte den Agent, die Änderungen von main zu übernehmen.") }
                } else { msg = L("Kein Vergleichsstand gefunden") }
            } else if Git.run(["status", "--porcelain", "--untracked-files=no"], in: dir).out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                msg = L("Lokale Änderungen im Projekt – erst sichern oder committen, dann aktualisieren.")
            } else {
                let r = Git.run(["pull", "--ff-only", "--quiet"], in: dir, timeout: 90)
                ok = r.code == 0
                msg = ok ? L("Neuester Stand geholt") : L("Aktualisieren fehlgeschlagen: ") + String(r.out.suffix(300))
            }
            DispatchQueue.main.async {
                self.updating.remove(id)
                if ok {
                    self.stop(id)
                    self.start(id: id, dir: dir, base: src.base, track: src.track) { _ in }
                } else { self.checkFreshness(id) }
                completion(ok, msg)
            }
        }
    }

    func start(id: String, dir: String, base: String? = nil, track: String? = nil, completion: @escaping (String?) -> Void) {
        sources[id] = (dir, track, base)
        // Läuft schon ein Server für genau diesen Ordner, wird er weiterbenutzt – aber nur, wenn er noch lebt.
        if let r = running[id] {
            if r.dir == dir, r.process.isRunning, let u = r.url { checkFreshness(id); completion(u); return }
            if r.dir == dir, r.process.isRunning, starting.contains(id) { return }
            stop(id)
        }
        checkFreshness(id)
        let fm = FileManager.default
        if let base {
            let c = Self.copyEnvFiles(from: base, to: dir)
            if !c.isEmpty { copiedEnv[id] = c }
        }
        errors[id] = nil
        let cfg = ProjectConfig.load(dir)
        var cmd = cfg?.dev
        if cmd == nil, let d = fm.contents(atPath: (dir as NSString).appendingPathComponent("package.json")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let s = j["scripts"] as? [String: String] {
            let pm = fm.fileExists(atPath: (dir as NSString).appendingPathComponent("pnpm-lock.yaml")) ? "pnpm" : fm.fileExists(atPath: (dir as NSString).appendingPathComponent("yarn.lock")) ? "yarn" : "npm"
            let install = fm.fileExists(atPath: (dir as NSString).appendingPathComponent("node_modules")) ? "" : "\(pm) install && "
            if s["dev"] != nil { cmd = install + "\(pm) run dev" } else if s["start"] != nil { cmd = install + "\(pm) run start" }
        }
        if cmd == nil, fm.fileExists(atPath: (dir as NSString).appendingPathComponent("index.html")) {
            cmd = "python3 -m http.server 4\(Int.random(in: 100...899))"
        }
        if cmd == nil, fm.fileExists(atPath: (dir as NSString).appendingPathComponent("layout/theme.liquid")) {
            cmd = "shopify theme dev"
        }
        guard let cmd else { completion(nil); return }
        let log = fm.temporaryDirectory.appendingPathComponent("aos-preview-\(id.prefix(8)).log")
        fm.createFile(atPath: log.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-i", "-c", cmd]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        env["BROWSER"] = "none"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        if let h = try? FileHandle(forWritingTo: log) { p.standardOutput = h; p.standardError = h }
        guard (try? p.run()) != nil else { completion(nil); return }
        running[id] = Running(process: p, url: cfg?.url, dir: dir, log: log)
        starting.insert(id)
        DispatchQueue.global().async {
            var url = cfg?.url
            let end = Date().addingTimeInterval(120)
            while url == nil && Date() < end && p.isRunning {
                usleep(500_000)
                let text = ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
                    .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
                if let r = text.range(of: "https?://(localhost|127\\.0\\.0\\.1|0\\.0\\.0\\.0|\\[::1\\]):[0-9]+[^\\s]*", options: .regularExpression) {
                    url = String(text[r]).replacingOccurrences(of: "0.0.0.0", with: "localhost")
                } else if let r = text.range(of: "port ([0-9]{4,5})", options: .regularExpression) {
                    url = "http://localhost:" + String(text[r]).components(separatedBy: " ").last!
                }
            }
            DispatchQueue.main.async {
                self.starting.remove(id)
                if let url { self.running[id]?.url = url } else { self.stop(id) }
                completion(url)
            }
        }
    }

    func stop(_ id: String) {
        guard let r = running[id] else { return }
        if let u = r.url, let port = u.components(separatedBy: ":").last?.components(separatedBy: "/").first {
            _ = Proc.zsh("lsof -ti tcp:\(port) | xargs kill 2>/dev/null", in: r.dir, timeout: 10)
        }
        if r.process.isRunning { r.process.terminate() }
        running[id] = nil
        starting.remove(id)
    }

    func stopAll() { for id in running.keys { stop(id) } }

    func logTail(_ id: String) -> String {
        guard let r = running[id] else { return "" }
        return String(((try? String(contentsOf: r.log, encoding: .utf8)) ?? "").suffix(1500))
    }
}

struct LiveWebView: NSViewRepresentable {
    let url: URL
    @Binding var reload: Int
    var id: String = ""
    var onBlank: ((Bool) -> Void)? = nil

    /// Fängt JavaScript-Fehler ab, damit statt einer weißen Seite gezeigt wird, was schiefgeht.
    static let errorScript = """
    (function(){
      function send(t){ try { window.webkit.messageHandlers.salentaError.postMessage(String(t).slice(0,600)); } catch(e){} }
      window.addEventListener('error', function(e){ send((e.message||'Fehler') + (e.filename ? ' – ' + e.filename.split('/').pop() + ':' + e.lineno : '')); });
      window.addEventListener('unhandledrejection', function(e){ send('Unbehandelt: ' + (e.reason && (e.reason.message || e.reason) || e)); });
      var ce = console.error; console.error = function(){ send(Array.prototype.map.call(arguments, function(a){ try { return a && a.message ? a.message : (typeof a === 'object' ? JSON.stringify(a) : String(a)); } catch(_) { return String(a); } }).join(' ')); return ce.apply(console, arguments); };
    })();
    """

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let uc = WKUserContentController()
        uc.addUserScript(WKUserScript(source: Self.errorScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        uc.add(context.coordinator, name: "salentaError")
        cfg.userContentController = uc
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = context.coordinator
        // Immer frisch vom Dev-Server laden, nie aus dem Zwischenspeicher – sonst zeigt die Vorschau einen alten Stand.
        v.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
        context.coordinator.lastURL = url
        return v
    }
    func updateNSView(_ v: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.lastURL != url {
            // Server neu gestartet (z. B. nach „Auf aktuellen Stand bringen“) – evtl. mit anderem Port
            context.coordinator.lastURL = url
            PreviewServer.shared.clearErrors(id)
            v.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
        } else if context.coordinator.lastReload != reload {
            context.coordinator.lastReload = reload
            PreviewServer.shared.clearErrors(id)
            v.reloadFromOrigin()
        }
    }
    static func dismantleNSView(_ v: WKWebView, coordinator: Coord) {
        v.configuration.userContentController.removeScriptMessageHandler(forName: "salentaError")
    }
    func makeCoordinator() -> Coord { Coord(self) }

    final class Coord: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: LiveWebView
        var lastReload = 0
        var lastURL: URL?
        init(_ p: LiveWebView) { parent = p }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            guard let t = m.body as? String, !t.isEmpty else { return }
            let id = parent.id
            DispatchQueue.main.async { PreviewServer.shared.reportError(id, t) }
        }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { report(e) }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { report(e) }
        private func report(_ e: Error) {
            let id = parent.id
            DispatchQueue.main.async { PreviewServer.shared.reportError(id, L("Seite lädt nicht: ") + e.localizedDescription) }
        }
        /// Nach dem Laden prüfen, ob überhaupt etwas zu sehen ist (weiße Seite erkennen).
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak w, weak self] in
                w?.evaluateJavaScript("(document.body ? document.body.innerText.trim().length + document.body.querySelectorAll('img,svg,canvas,video,input,button').length : 0)") { r, _ in
                    let blank = ((r as? Int) ?? 1) == 0
                    self?.parent.onBlank?(blank)
                }
            }
        }
    }
}

struct PreviewSheet: View {
    let id: String
    let title: String
    @ObservedObject private var server = PreviewServer.shared
    @Environment(\.dismiss) private var dismiss
    @State private var reload = 0
    @State private var width: CGFloat = 1280
    @State private var blank = false
    @State private var showLog = false
    @State private var updateMessage: String?
    /// Vorher/Nachher: links dein Projekt, rechts die Arbeitskopie – nebeneinander oder mit Schieberegler
    @State private var compare = false
    @State private var slider = false
    @State private var split: CGFloat = 0.5
    @State private var reloadBase = 0
    /// Bei jeder gespeicherten Datei neu laden (für Seiten ohne eigenes Hot-Reload)
    @AppStorage("preview.autoReload") private var autoReload = true
    @State private var signature = ""
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var hub: MCPHub
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Grid.s) {
                Image(systemName: "play.display")
                Text("Vorschau: \(title)").font(.headline).lineLimit(1)
                if let u = server.url(id) { Text(u).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                Spacer()
                Picker("", selection: $width) {
                    Text("Desktop").tag(CGFloat(1280))
                    Text("Tablet").tag(CGFloat(820))
                    Text("Handy").tag(CGFloat(390))
                }
                .pickerStyle(.segmented).fixedSize()
                if let base = server.info(id)?.base, !id.hasPrefix("proj:") {
                    Toggle(isOn: Binding(get: { compare }, set: { on in
                        compare = on
                        if on { server.start(id: "base:" + id, dir: base) { _ in } }
                    })) { Label(L("Vorher/Nachher"), systemImage: "rectangle.split.2x1") }
                        .toggleStyle(.button)
                        .help(L("Dein Projekt (vorher) und die Arbeitskopie des Agents (nachher) vergleichen"))
                    if compare {
                        Picker("", selection: $slider) {
                            Image(systemName: "rectangle.split.2x1").tag(false).help(L("Nebeneinander"))
                            Image(systemName: "slider.horizontal.below.rectangle").tag(true).help(L("Schieberegler"))
                        }.pickerStyle(.segmented).fixedSize()
                    }
                }
                Toggle(isOn: $autoReload) { Image(systemName: "bolt.horizontal.circle") }
                    .toggleStyle(.button)
                    .help(L("Live: neu laden, sobald der Agent eine Datei speichert"))
                Button { reload += 1; reloadBase += 1 } label: { Image(systemName: "arrow.clockwise") }.help(L("Neu laden"))
                if let u = server.url(id), let url = URL(string: u) {
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "safari") }.help(L("Im Browser öffnen"))
                }
                Button("Server stoppen") { server.stop(id); dismiss() }
                Button("Schließen") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(Grid.m)
            Divider()
            freshnessBar
            if let c = server.copiedEnv[id], !c.isEmpty {
                Label(L("Aus deinem Repo übernommen (fehlen in der Arbeitskopie): ") + c.joined(separator: ", "), systemImage: "key")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, Grid.m).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if server.url(id) != nil, !(server.errors[id] ?? []).isEmpty || blank { problemBar }
            if let u = server.url(id), let url = URL(string: u) {
                if compare {
                    compareView(after: url)
                } else {
                    LiveWebView(url: url, reload: $reload, id: id, onBlank: { b in blank = b })
                        .frame(width: width)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.2))
                }
            } else if server.starting.contains(id) {
                VStack(spacing: Grid.s) {
                    ProgressView()
                    Text("Startet den Dev-Server …").foregroundStyle(.secondary)
                    ScrollView { Text(server.logTail(id)).font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 200)
                }
                .padding(Grid.xl).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Keine Vorschau", systemImage: "play.slash",
                                       description: Text("Kein Dev-Server gefunden. Lege ihn in .salenta-os.json fest: \"dev\": \"npm run dev\", optional \"url\"."))
            }
        }
        .frame(minWidth: 1000, idealWidth: 1360, minHeight: 700, idealHeight: 860)
        .task(id: autoReload) { await watchChanges() }
        .onDisappear { server.stop("base:" + id) }
        .sheet(isPresented: $showLog) {
            VStack(alignment: .leading) {
                HStack { Text("Dev-Server-Ausgabe").font(.headline); Spacer(); Button("Schließen") { showLog = false } }
                ScrollView { Text(server.logTail(id)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }
            .padding().frame(width: 760, height: 480)
        }
    }

    // MARK: Vorher/Nachher

    @ViewBuilder private func compareView(after: URL) -> some View {
        let baseID = "base:" + id
        if let bu = server.url(baseID), let before = URL(string: bu) {
            GeometryReader { g in
                let w = g.size.width, h = g.size.height - 22
                VStack(spacing: 0) {
                    HStack {
                        Text(L("Vorher – dein Projekt")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Text(L("Nachher – Arbeitskopie des Agents")).font(.caption.weight(.semibold)).foregroundStyle(.green)
                    }
                    .padding(.horizontal, Grid.m).frame(height: 22)
                    if slider {
                        ZStack(alignment: .topLeading) {
                            LiveWebView(url: after, reload: $reload, id: id, onBlank: { b in blank = b })
                                .frame(width: w, height: h)
                            LiveWebView(url: before, reload: $reloadBase, id: baseID)
                                .frame(width: w, height: h)
                                .frame(width: max(1, w * split), height: h, alignment: .leading)
                                .clipped()
                            // Griff zum Verschieben
                            Rectangle().fill(Color.accentColor).frame(width: 2, height: h)
                                .overlay(Circle().fill(Color.accentColor).frame(width: 22, height: 22)
                                    .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)))
                                .frame(width: 24, height: h)
                                .contentShape(Rectangle())
                                .offset(x: w * split - 12)
                                .gesture(DragGesture(minimumDistance: 0).onChanged { v in split = min(0.98, max(0.02, (w * split + v.translation.width) / w)) })
                                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                                .help(L("Ziehen, um vorher und nachher zu vergleichen"))
                        }
                    } else {
                        HStack(spacing: 2) {
                            LiveWebView(url: before, reload: $reloadBase, id: baseID).frame(width: min(width, (w - 2) / 2), height: h)
                                .frame(maxWidth: .infinity)
                            LiveWebView(url: after, reload: $reload, id: id, onBlank: { b in blank = b }).frame(width: min(width, (w - 2) / 2), height: h)
                                .frame(maxWidth: .infinity)
                        }
                        .background(Color.black.opacity(0.2))
                    }
                }
            }
        } else {
            VStack(spacing: Grid.s) {
                ProgressView()
                Text(L("Startet die Vorschau deines Projekts zum Vergleich …")).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Live mitschauen: Ändert der Agent eine Datei in der Arbeitskopie, lädt die Vorschau neu (kurz gebündelt).
    private func watchChanges() async {
        guard autoReload, let dir = server.info(id)?.dir else { return }
        var last = ""
        var changedAt: Date?
        while !Task.isCancelled && autoReload {
            let sig = await Task.detached { () -> String in
                // geänderte Dateien + deren Änderungszeit + letzter Commit: erkennt jedes Speichern
                let status = Git.run(["status", "--porcelain"], in: dir, timeout: 5).out
                let fm = FileManager.default
                let times = status.split(separator: "\n").prefix(200).compactMap { line -> String? in
                    let path = String(line.dropFirst(3)).components(separatedBy: " -> ").last ?? ""
                    let full = (dir as NSString).appendingPathComponent(path)
                    return (try? fm.attributesOfItem(atPath: full)[.modificationDate] as? Date).map { String($0.timeIntervalSince1970) }
                }.joined(separator: ",")
                return status + times + Git.run(["log", "-1", "--format=%H"], in: dir, timeout: 5).out
            }.value
            if !last.isEmpty, sig != last { changedAt = Date() }
            // 1,5 s nach der letzten Änderung neu laden – nicht mitten in einer Folge von Schreibvorgängen
            if let c = changedAt, Date().timeIntervalSince(c) > 1.5 { reload += 1; changedAt = nil }
            last = sig
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Sagt klar, dass dies eine lokale Vorschau ist, welchen Stand sie zeigt und ob sie hinter main liegt.
    private var freshnessBar: some View {
        let f = server.freshness[id]
        let behind = f?.behind ?? 0
        let agentBusy: Bool = agents.sessions.first(where: { $0.id.uuidString == id })?.running == true
        var stand: String = ""
        if let f, !f.sha.isEmpty {
            stand = "· " + L("Stand") + " \(f.sha) (\(f.branch))"
            if f.dirty { stand += " · " + L("mit ungesicherten Änderungen") }
        }
        var aheadText: String = ""
        if let t = f?.target, let b = f?.behind {
            aheadText = b == 0 ? "· " + L("aktuell mit") + " \(t)" : "· \(b) " + (b == 1 ? L("Commit hinter") : L("Commits hinter")) + " \(t)"
        }
        let updateHelp: String = agentBusy ? L("Der Agent arbeitet gerade in dieser Kopie – warte, bis er fertig ist.")
                                           : L("Holt den neuesten Stand, übernimmt ihn in diese Kopie und startet die Vorschau neu")
        return HStack(spacing: Grid.s) {
            Image(systemName: behind > 0 ? "clock.badge.exclamationmark" : "desktopcomputer")
                .foregroundStyle(behind > 0 ? .orange : .secondary)
            Text(L("Lokale Vorschau – nicht die Live-Seite")).font(.caption.weight(.semibold))
            if !stand.isEmpty {
                Text(stand).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            if f?.checking == true {
                ProgressView().controlSize(.mini)
                Text(L("prüft auf neuen Stand …")).font(.caption).foregroundStyle(.secondary)
            } else if !aheadText.isEmpty {
                Text(aheadText).font(.caption.weight(behind > 0 ? .semibold : .regular)).foregroundStyle(behind > 0 ? .orange : .secondary)
            }
            Spacer()
            if let msg = updateMessage { Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            if server.updating.contains(id) { ProgressView().controlSize(.small) }
            if behind > 0 {
                Button(L("Auf aktuellen Stand bringen")) {
                    updateMessage = nil
                    server.update(id) { _, m in updateMessage = m }
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(server.updating.contains(id) || agentBusy)
                .help(updateHelp)
            }
            if f != nil {
                Button { server.checkFreshness(id) } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.borderless).controlSize(.small).help(L("Erneut auf neuen Stand prüfen"))
                    .disabled(f?.checking == true)
            }
        }
        .padding(.horizontal, Grid.m).padding(.vertical, Grid.xs)
        .background(behind > 0 ? Color.orange.opacity(0.12) : Color.secondary.opacity(0.06))
    }

    /// Statt einer stillen weißen Seite: zeigen, was die App meldet, und es mit einem Klick an den Agent geben.
    private var problemBar: some View {
        let errs = server.errors[id] ?? []
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Grid.s) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(errs.isEmpty ? L("Die Seite bleibt leer.") : L("Die App meldet einen Fehler:")).font(.callout.weight(.semibold))
                Spacer()
                Button(L("Server-Ausgabe")) { showLog = true }
                if let rec = MissionStore.shared.mission(id) {
                    Button(L("Agent soll es beheben")) {
                        let msg = L("Die Live-Vorschau zeigt nur eine weiße Seite.") + (errs.isEmpty ? "" : "\n" + L("Fehler im Browser:") + "\n- " + errs.joined(separator: "\n- "))
                            + "\n\n" + L("Ausgabe des Dev-Servers (Ende):") + "\n" + String(server.logTail(id).suffix(1200))
                            + "\n\n" + L("Finde die Ursache und behebe sie, sodass die App in der Vorschau sichtbar startet.")
                        Handoff.continueMission(rec, message: msg, target: rec.agent, agents: agents, hub: hub) { s in
                            app.page = .chat(s.id.uuidString); dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            ForEach(errs, id: \.self) { e in Text(e).font(.caption.monospaced()).lineLimit(2).textSelection(.enabled) }
            if errs.isEmpty {
                Text(L("Häufige Gründe: fehlende Umgebungsvariablen (.env, z. B. Supabase-URL/Schlüssel), die App braucht einen Login, oder der Dev-Server liefert eine andere Adresse."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Grid.m)
        .background(Color.orange.opacity(0.12))
    }
}

// MARK: - Mehrere Agents parallel: vergleichen und die beste Lösung nehmen

struct ParallelCompare: View {
    let rec: MissionRecord
    @ObservedObject private var store = MissionStore.shared
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var tasks: TaskStore
    @EnvironmentObject private var app: AppModel
    @State private var busy = false

    private var siblings: [MissionRecord] {
        guard let g = rec.group else { return [] }
        return store.missions.filter { $0.group == g }
    }

    var body: some View {
        if siblings.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "square.split.3x1").foregroundStyle(.secondary)
                    Text("Parallel gelöst – \(siblings.count) Agents").font(.headline)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                }
                ForEach(siblings) { s in
                    let session = agents.sessions.first { $0.id.uuidString == s.id }
                    HStack(spacing: Grid.s) {
                        Image(systemName: s.agentSymbol).frame(width: 16)
                        Text(s.agentTitle).font(.callout.weight(s.id == rec.id ? .semibold : .regular))
                        if session?.running == true { ProgressView().controlSize(.mini); Text("arbeitet …").font(.caption).foregroundStyle(.secondary) }
                        else if let v = s.verify {
                            if v.running { ProgressView().controlSize(.mini); Text("prüft …").font(.caption).foregroundStyle(.secondary) }
                            else if let p = v.passed { Label(p ? L("grün") : L("rot"), systemImage: p ? "checkmark.seal.fill" : "xmark.seal.fill").font(.caption).foregroundStyle(p ? .green : .red) }
                        } else if s.ok == false { Text("abgebrochen").font(.caption).foregroundStyle(.red) }
                        if let r = s.verify?.review, !r.summary.isEmpty { Text(r.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                        if s.id != rec.id { Button("Ansehen") { app.page = .chat(s.id) }.buttonStyle(.link).font(.caption) }
                        if s.worktree != nil, s.archived != true, session?.running != true {
                            Button("Diese nehmen") { pick(s) }.font(.caption)
                                .buttonStyle(.borderedProminent).tint(s.verify?.passed == true ? .green : .gray)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Gewählte Lösung übernehmen, die anderen Arbeitskopien verwerfen.
    private func pick(_ winner: MissionRecord) {
        guard let wt = winner.worktree else { return }
        busy = true
        let others = siblings.filter { $0.id != winner.id }
        DispatchQueue.global(qos: .userInitiated).async {
            let (ok, msg) = Worktrees.merge(wt, message: winner.title)
            if ok { for o in others { if let w = o.worktree { Worktrees.discard(w, keepBranch: false) } } }
            DispatchQueue.main.async {
                busy = false
                app.show(ok ? "✓ " + L("Lösung von ") + winner.agentTitle + L(" übernommen") : msg)
                guard ok else { return }
                ModStore.shared.fire(.merged, rec: winner)
                store.setOutcome(winner.id, "merged")
                Learning.record(winner, outcome: "merged")
                store.clearWorktree(winner.id)
                store.archive(winner.id, agents: agents, tasks: tasks)
                for o in others {
                    store.setOutcome(o.id, "discarded")
                    Learning.record(o, outcome: "discarded")
                    store.clearWorktree(o.id)
                    store.archive(o.id, agents: agents, tasks: tasks)
                }
                app.page = .home
            }
        }
    }
}

// MARK: - Plan zuerst

struct PlanBar: View {
    let rec: MissionRecord
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var hub: MCPHub
    @EnvironmentObject private var app: AppModel
    @State private var note = ""

    var body: some View {
        HStack(spacing: Grid.s) {
            Image(systemName: "list.bullet.clipboard").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Plan fertig – noch nichts geändert").font(.callout.weight(.semibold))
                HStack(spacing: 4) {
                    TextField("Optional: Änderungswünsche zum Plan …", text: $note).textFieldStyle(.roundedBorder).font(.caption)
                    MicButton { t in note += (note.isEmpty ? "" : " ") + t }
                }
            }
            Spacer()
            Button { go() } label: { Label("Plan umsetzen", systemImage: "hammer.fill") }
                .buttonStyle(.borderedProminent)
        }
        .padding(Grid.m)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.08)))
        .frame(maxWidth: 780)
        .padding(.horizontal, Grid.l)
    }

    private func go() {
        var msg = L("Setze jetzt deinen Plan vollständig um.") + (note.isEmpty ? "" : "\n\n" + L("Änderungen am Plan:") + " " + note)
        if let r = Research.shared.promptBlock(rec.id) { msg += "\n\n" + r }
        Handoff.continueMission(rec, message: msg, target: rec.agent, agents: agents, hub: hub, note: L("Plan wird umgesetzt")) { s in
            app.page = .chat(s.id.uuidString)
        }
    }
}

// MARK: - Push aufs Handy (ntfy.sh – kostenlose App für iOS/Android)

enum Notifier {
    static var topic: String { (UserDefaults.standard.string(forKey: "notify.ntfy") ?? "").trimmingCharacters(in: .whitespaces) }
    static var server: String {
        let s = (UserDefaults.standard.string(forKey: "notify.server") ?? "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "https://ntfy.sh" : s
    }

    /// Nur wenn ein Thema eingetragen ist. Im Fokus-Modus nur Wichtiges (priority ≥ 4).
    static func push(_ title: String, _ text: String, priority: Int = 3, tags: String = "robot") {
        guard !topic.isEmpty, UserDefaults.standard.object(forKey: "notify.push") as? Bool ?? true,
              var c = URLComponents(string: server + "/" + topic) else { return }
        if Focus.isOn && priority < 4 { return }
        // ntfy liest Titel, Priorität und Tags auch aus der URL (so klappen Umlaute im Titel)
        c.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "priority", value: String(priority)),
                        URLQueryItem(name: "tags", value: tags)]
        guard let url = c.url else { return }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.httpBody = Data(text.prefix(1500).utf8)
        URLSession.shared.dataTask(with: r).resume()
    }
}
