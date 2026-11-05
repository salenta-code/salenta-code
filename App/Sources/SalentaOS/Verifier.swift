import AgenticOSKit
import AppKit
import SwiftUI

// Prüfschleife: Wenn ein Coding-Agent fertig ist, baut und testet Salenta Code die Arbeitskopie selbst,
// macht bei UI-Änderungen einen Screenshot und lässt ein zweites Modell den Diff prüfen.
// Erst danach entscheidest du – grün heißt: gebaut, getestet, gegengelesen.

struct VerifyCheck: Codable, Hashable, Identifiable {
    var id: String { name }
    let name: String
    let command: String
    var ok: Bool?
    var output: String = ""
    var seconds: Double = 0
}

struct VerifyReview: Codable, Hashable {
    var agent: String
    var ok: Bool
    var summary: String
    var issues: [String]
}

/// Warum etwas rot ist – in einfachen Worten – und wer es mit welchem Modell am besten behebt.
struct VerifyDiagnosis: Codable, Hashable {
    var why: String
    var points: [String] = []
    var fix: String
    var agent: String
    var model: String = ""
    var reason: String = ""
    var byAI = false
}

struct VerifyReport: Codable, Hashable {
    var started = Date()
    var finished: Date?
    var checks: [VerifyCheck] = []
    var review: VerifyReview?
    var screenshot: String?
    var note: String?
    var diagnosis: VerifyDiagnosis?
    var diagnosing: Bool?

    /// Läuft gerade (eine Prüfung, die seit über 40 Minuten nicht fertig wurde, gilt als abgebrochen).
    var running: Bool { finished == nil && started > Date().addingTimeInterval(-2400) }
    var passed: Bool? {
        guard finished != nil else { return nil }
        return checks.allSatisfy { $0.ok != false } && (review?.ok ?? true)
    }
    var failures: [String] {
        var out = checks.filter { $0.ok == false }.map { "\($0.name) (\($0.command)) schlägt fehl:\n\(String($0.output.suffix(2500)))" }
        if let r = review, !r.ok { out += r.issues.isEmpty ? [r.summary] : r.issues }
        return out
    }
}

/// Projekt-Einstellungen im Repo: .salenta-os.json (oder .aos.json)
/// { "verify": ["npm run lint", "npm test"], "rules": ["Nie ins veröffentlichte Theme schreiben"],
///   "dev": "npm run dev", "url": "http://localhost:5173" }
struct ProjectConfig: Codable, Hashable {
    var verify: [String]?
    var rules: [String]?
    var dev: String?
    var url: String?
    var block: [BlockRule]?

    static let names = [".salenta-os.json", ".aos.json"]

    static func file(in dir: String) -> URL {
        let root = Git.root(of: dir) ?? dir
        for n in names {
            let u = URL(fileURLWithPath: root).appendingPathComponent(n)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return URL(fileURLWithPath: root).appendingPathComponent(names[0])
    }

    static func load(_ dir: String) -> ProjectConfig? {
        guard let d = try? Data(contentsOf: file(in: dir)) else { return nil }
        return try? JSONDecoder().decode(ProjectConfig.self, from: d)
    }

    static func save(_ cfg: ProjectConfig, dir: String) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        if let d = try? enc.encode(cfg) { try? d.write(to: file(in: dir), options: .atomic) }
    }
}

enum Proc {
    /// Befehl in einer Login-Shell (PATH wie im Terminal), mit Zeitlimit. Liefert Ausgabe (gekürzt) und Exit-Code.
    /// Laufende Prozesse je Kennung (z. B. Auftrag) – damit „Abbrechen“ sie samt Kindprozessen beenden kann.
    private static var running: [String: Process] = [:]
    private static let runLock = NSLock()

    /// Beendet einen Prozess mit allen Kindprozessen (npm → node → vitest …). Sonst halten Enkel die Pipe offen und alles hängt.
    static func killTree(_ pid: Int32) {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid="]
        let pipe = Pipe(); ps.standardOutput = pipe; ps.standardError = FileHandle.nullDevice
        var children: [Int32: [Int32]] = [:]
        if (try? ps.run()) != nil {
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            for line in out.split(separator: "\n") {
                let f = line.split(separator: " ").compactMap { Int32($0) }
                if f.count == 2 { children[f[1], default: []].append(f[0]) }
            }
        }
        var all: [Int32] = []
        var queue = [pid]
        while let p = queue.popLast() { all.append(p); queue += children[p] ?? [] }
        for p in all.reversed() { kill(p, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { for p in all { kill(p, SIGKILL) } }
    }

    static func cancel(tag: String) {
        runLock.lock(); let p = running[tag]; runLock.unlock()
        if let p, p.isRunning { killTree(p.processIdentifier) }
    }

    static func zsh(_ command: String, in dir: String, timeout: TimeInterval = 900, env extra: [String: String] = [:], tag: String? = nil) -> (out: String, code: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-i", "-c", command]
        p.currentDirectoryURL = URL(fileURLWithPath: dir, isDirectory: true)
        var env = ProcessInfo.processInfo.environment
        env["CI"] = "1"
        env["FORCE_COLOR"] = "0"
        env["NO_COLOR"] = "1"
        for (k, v) in extra { env[k] = v }
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return ("Start fehlgeschlagen: \(error.localizedDescription)", -1) }
        if let tag { runLock.lock(); running[tag] = p; runLock.unlock() }
        defer { if let tag { runLock.lock(); if running[tag] === p { running[tag] = nil }; runLock.unlock() } }
        var data = Data()
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }   // Dateiende: abmelden, sonst Dauerschleife
            lock.lock(); data.append(chunk); if data.count > 400_000 { data = data.suffix(200_000) }; lock.unlock()
        }
        let end = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < end { usleep(100_000) }
        var timedOut = false
        if p.isRunning { killTree(p.processIdentifier); timedOut = true; usleep(300_000) }
        let hardEnd = Date().addingTimeInterval(5)
        while p.isRunning && Date() < hardEnd { usleep(20_000) }  // kein waitUntilExit: das dreht den RunLoop und kann SwiftUI mitten im Zeichnen abstürzen lassen
        usleep(100_000)
        // Nicht bis Dateiende lesen: hält ein übrig gebliebener Kindprozess die Pipe offen, würde das ewig blockieren.
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock(); let all = data; lock.unlock()
        var text = String(decoding: all, as: UTF8.self)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        if timedOut { text += "\n" + L("Zeitüberschreitung – abgebrochen.") }
        return (text, timedOut ? 124 : (p.isRunning ? 124 : p.terminationStatus))
    }
}

enum Verifier {
    static var autoRun: Bool { UserDefaults.standard.object(forKey: "verify.auto") as? Bool ?? true }
    static var autoFix: Bool { UserDefaults.standard.object(forKey: "verify.autofix") as? Bool ?? true }
    static var reviewOn: Bool { UserDefaults.standard.object(forKey: "verify.review") as? Bool ?? true }
    static var screenshotOn: Bool { UserDefaults.standard.object(forKey: "verify.screenshot") as? Bool ?? true }
    private static var runningIDs = Set<String>()
    private static var cancelled = Set<String>()
    private static let cancelLock = NSLock()

    static func isCancelled(_ id: String) -> Bool { cancelLock.lock(); defer { cancelLock.unlock() }; return cancelled.contains(id) }

    /// Prüfung abbrechen – beendet den laufenden Befehl samt Kindprozessen.
    static func cancel(_ id: String) {
        cancelLock.lock(); cancelled.insert(id); cancelLock.unlock()
        Proc.cancel(tag: "verify-" + id)
    }

    // MARK: Welche Prüfungen passen zum Projekt?

    static func checks(for dir: String) -> [(name: String, command: String)] {
        if let v = ProjectConfig.load(dir)?.verify, !v.isEmpty {
            return v.map { (String($0.split(separator: " ").prefix(3).joined(separator: " ")), $0) }
        }
        let fm = FileManager.default
        func has(_ f: String) -> Bool { fm.fileExists(atPath: (dir as NSString).appendingPathComponent(f)) }
        var out: [(String, String)] = []
        if has("Package.swift") {
            out.append((L("Build"), "swift build"))
            if has("Tests") { out.append((L("Tests"), "swift test")) }
        }
        if has("package.json"), let d = fm.contents(atPath: (dir as NSString).appendingPathComponent("package.json")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            let scripts = j["scripts"] as? [String: String] ?? [:]
            let pm = has("pnpm-lock.yaml") ? "pnpm" : has("yarn.lock") ? "yarn" : has("bun.lockb") || has("bun.lock") ? "bun" : "npm"
            if !has("node_modules") {
                let install = switch pm {
                case "pnpm": "pnpm install --frozen-lockfile"
                case "yarn": "yarn install --frozen-lockfile"
                case "bun": "bun install"
                default: has("package-lock.json") ? "npm ci --no-audit --no-fund" : "npm install --no-audit --no-fund"
                }
                out.append((L("Installieren"), install))
            }
            for (key, name) in [("typecheck", L("Typen")), ("lint", L("Lint")), ("test", L("Tests")), ("build", L("Build"))] {
                guard let s = scripts[key], !s.contains("no test specified") else { continue }
                if key == "test", s.contains("--watch") || s == "vitest" { out.append((name, "\(pm) run test -- --run")); continue }
                out.append((name, "\(pm) run \(key)"))
            }
        }
        if has("Cargo.toml") { out += [(L("Build"), "cargo build"), (L("Tests"), "cargo test")] }
        if has("go.mod") { out += [(L("Build"), "go build ./..."), (L("Tests"), "go test ./...")] }
        if (has("pyproject.toml") || has("setup.py") || has("requirements.txt")) && (has("tests") || has("pytest.ini")) {
            out.append((L("Tests"), "python3 -m pytest -q"))
        }
        if has("layout/theme.liquid") && has("config/settings_schema.json") {
            out.append((L("Theme-Check"), "shopify theme check --fail-level error"))
        }
        // Was die CI auf GitHub zusätzlich prüft (nur sichere, lokale Prüfbefehle) – damit der Push gleich grün ist
        let have = Set(out.map { $0.1.replacingOccurrences(of: " -- --run", with: "") })
        for c in CIParity.commands(dir) where !have.contains(c) && !have.contains(where: { c.hasPrefix($0) }) {
            out.append(("CI: " + c.split(separator: " ").prefix(3).joined(separator: " "), c))
            if out.count >= 8 { break }
        }
        return out
    }

    // MARK: Prüfen

    /// Führt die Prüfung für einen Auftrag mit Arbeitskopie aus (im Hintergrund, Fortschritt live im Auftrag).
    static func run(_ id: String, completion: ((VerifyReport) -> Void)? = nil) {
        guard let rec = MissionStore.shared.mission(id), let wt = rec.worktree, !runningIDs.contains(id) else { return }
        runningIDs.insert(id)
        cancelLock.lock(); cancelled.remove(id); cancelLock.unlock()
        var report = VerifyReport()
        MissionStore.shared.setVerify(id, report)
        let store = MissionStore.shared
        func publish() { let r = report; DispatchQueue.main.async { store.setVerify(id, r) } }

        DispatchQueue.global(qos: .userInitiated).async {
            let dir = Worktrees.top(wt)
            let changes = Worktrees.changes(wt)
            if changes.isEmpty {
                report.note = L("Keine Änderungen – nichts zu prüfen.")
                report.finished = Date()
                publish()
                DispatchQueue.main.async { runningIDs.remove(id); completion?(report) }
                return
            }
            // 1. Build, Lint, Tests
            for c in checks(for: dir) {
                if isCancelled(id) { break }
                report.checks.append(VerifyCheck(name: c.name, command: c.command))
                publish()
                let t0 = Date()
                let r = Proc.zsh(c.command, in: dir, timeout: c.name == L("Installieren") ? 600 : 600, tag: "verify-" + id)
                let i = report.checks.count - 1
                report.checks[i].ok = r.code == 0
                report.checks[i].output = String(r.out.suffix(6000))
                report.checks[i].seconds = Date().timeIntervalSince(t0)
                publish()
                if r.code != 0 && c.name == L("Installieren") { break }
            }
            if isCancelled(id) {
                // abgebrochen: offene Prüfungen nicht als grün werten
                for i in report.checks.indices where report.checks[i].ok == nil { report.checks[i].ok = false; report.checks[i].output += "\n" + L("Abgebrochen.") }
                report.note = L("Prüfung abgebrochen.")
                report.finished = Date()
                publish()
                DispatchQueue.main.async { runningIDs.remove(id); completion?(report) }
                return
            }
            // Geheimnisse (API-Keys, Tokens, .env) dürfen nicht ins Repo
            let secrets = SecretScan.scan(Worktrees.diff(wt))
            report.checks.append(VerifyCheck(name: L("Geheimnisse"), command: L("Scan auf Keys, Tokens, Passwörter, .env"),
                                             ok: secrets.isEmpty, output: secrets.isEmpty ? L("Nichts gefunden.") : secrets.joined(separator: "\n")))
            publish()
            if report.checks.count == 1 { report.note = L("Keine Build- oder Testbefehle erkannt – lege sie in .salenta-os.json unter \"verify\" fest.") }

            // 2. Screenshot bei UI-Änderungen
            let uiExt = ["tsx", "jsx", "vue", "svelte", "css", "scss", "html", "liquid", "astro"]
            if screenshotOn, changes.contains(where: { uiExt.contains(($0.path as NSString).pathExtension.lowercased()) }) {
                if let shot = screenshot(dir: dir, id: id) { report.screenshot = shot; publish() }
            }

            // 3. Zweite Meinung: ein anderes Modell liest den Diff
            if reviewOn && !isCancelled(id) {
                let diff = Worktrees.diff(wt)
                report.review = review(rec: rec, diff: diff, checks: report.checks, dir: dir)
            }
            report.finished = Date()
            // 4. Ist etwas rot: erst sofort eine Einschätzung nach Regeln, dann genauer per KI
            if report.passed == false {
                report.diagnosis = heuristicDiagnosis(rec: rec, report: report)
                report.diagnosing = true
                publish()
                if let ai = aiDiagnosis(rec: rec, report: report, dir: dir) { report.diagnosis = ai }
                report.diagnosing = nil
            }
            publish()
            DispatchQueue.main.async {
                runningIDs.remove(id)
                Learning.recordVerify(id, passed: report.passed == true)
                if let p = report.passed, let r = MissionStore.shared.mission(id) {
                    ModStore.shared.fire(p ? .verifyPassed : .verifyFailed, rec: r, result: report.failures.joined(separator: "\n"))
                }
                completion?(report)
            }
        }
    }

    // MARK: Screenshot (Dev-Server starten, mit Chrome headless fotografieren)

    private static func screenshot(dir: String, id: String) -> String? {
        let cfg = ProjectConfig.load(dir)
        let chrome = ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                      "/Applications/Chromium.app/Contents/MacOS/Chromium",
                      "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let chrome else { return nil }
        let fm = FileManager.default
        var devCmd = cfg?.dev
        if devCmd == nil, let d = fm.contents(atPath: (dir as NSString).appendingPathComponent("package.json")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let scripts = j["scripts"] as? [String: String], scripts["dev"] != nil {
            devCmd = fm.fileExists(atPath: (dir as NSString).appendingPathComponent("pnpm-lock.yaml")) ? "pnpm run dev" : "npm run dev"
        }
        guard let devCmd else { return nil }

        let log = fm.temporaryDirectory.appendingPathComponent("aos-dev-\(id.prefix(8)).log")
        fm.createFile(atPath: log.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "exec \(devCmd)"]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        env["BROWSER"] = "none"
        env["PORT"] = "4\(Int.random(in: 100...899))"
        p.environment = env
        if let h = try? FileHandle(forWritingTo: log) { p.standardOutput = h; p.standardError = h }
        guard (try? p.run()) != nil else { return nil }
        defer {
            if let port = port(in: (try? String(contentsOf: log, encoding: .utf8)) ?? "") {
                _ = Proc.zsh("lsof -ti tcp:\(port) | xargs kill 2>/dev/null", in: dir, timeout: 10)
            }
            if p.isRunning { p.terminate() }
        }
        // Auf die Adresse warten (max. 90 s)
        var url = cfg?.url
        let end = Date().addingTimeInterval(90)
        while url == nil && Date() < end && p.isRunning {
            usleep(500_000)
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            if let r = text.range(of: "https?://(localhost|127\\.0\\.0\\.1|\\[::1\\]):[0-9]+[^\\s]*", options: .regularExpression) {
                url = String(text[r]).replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            }
        }
        guard let url else { return nil }
        usleep(2_500_000)
        let dirShots = Paths.support.appendingPathComponent("screens", isDirectory: true)
        try? fm.createDirectory(at: dirShots, withIntermediateDirectories: true)
        let out = dirShots.appendingPathComponent("\(id.prefix(8))-\(Int(Date().timeIntervalSince1970)).png").path
        let profile = fm.temporaryDirectory.appendingPathComponent("aos-shot-profile").path
        _ = Proc.zsh("\(Shell.quote(chrome)) --headless=new --disable-gpu --hide-scrollbars --no-first-run --user-data-dir=\(Shell.quote(profile)) --window-size=1440,900 --virtual-time-budget=5000 --screenshot=\(Shell.quote(out)) \(Shell.quote(url))",
                     in: dir, timeout: 60)
        return fm.fileExists(atPath: out) ? out : nil
    }

    private static func port(in text: String) -> String? {
        guard let r = text.range(of: "(localhost|127\\.0\\.0\\.1):[0-9]+", options: .regularExpression) else { return nil }
        return String(text[r]).components(separatedBy: ":").last
    }

    // MARK: Review durch ein zweites Modell

    /// Wer prüft: nie derselbe Agent, der gebaut hat – und möglichst einer mit freiem Kontingent.
    static func reviewer(for agent: String) -> AgentKind {
        let codexOK = Detection.which("codex") != nil && !Usage.shared.isTight(.codex)
        let claudeOK = Detection.which("claude") != nil && !Usage.shared.isTight(.claude)
        if agent == "codex" { return claudeOK || !codexOK ? .claude : .codex }
        if codexOK { return .codex }
        return .claude
    }

    private static func review(rec: MissionRecord, diff: String, checks: [VerifyCheck], dir: String) -> VerifyReview? {
        // Nur lokal / offline: das Review macht das lokale Modell (über den Claude-Weg), nicht Codex in der Cloud
        let who = LocalFirst.shared.useLocal || LocalFirst.shared.localOnly ? AgentKind.claude : reviewer(for: rec.agent)
        let lang = Profile.languageCode == "de" ? "German" : "English"
        let checkText = checks.isEmpty ? "(no automatic checks)" : checks.map { "- \($0.name) `\($0.command)`: \($0.ok == true ? "passed" : "FAILED")" }.joined(separator: "\n")
        let rules = (ProjectConfig.load(dir)?.rules ?? []) + Rules.global
        let prompt = """
        You are a strict senior reviewer. Another AI agent (\(rec.agentTitle)) made the changes below for this task.
        Decide if the change is correct and complete. Only flag real problems: bugs, regressions, missing parts of the task,
        security issues, broken rules, leftover debug code. Ignore style preferences.

        Task:
        \"\"\"\(rec.request.prefix(3000))\"\"\"
        \(rules.isEmpty ? "" : "\nProject rules (must be followed):\n" + rules.map { "- " + $0 }.joined(separator: "\n") + "\n")
        Automatic checks:
        \(checkText)

        Diff:
        ```diff
        \(diff.prefix(70_000))
        ```

        Answer ONLY with JSON: {"ok": true|false, "summary": "one sentence in \(lang)", "issues": ["file:line – problem (in \(lang))"]}
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("aos-review-\(UUID().uuidString).md")
        try? prompt.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        var answer = ""
        if who == .codex {
            let outFile = FileManager.default.temporaryDirectory.appendingPathComponent("aos-review-\(UUID().uuidString).txt")
            let F = CLIFlags.shared
            let oFlag = F.pick(.codex, sub: "exec", ["-o", "--output-last-message"])
            let opts = F.pick(.codex, sub: "exec", ["-s read-only", "--sandbox read-only"]) + F.pick(.codex, sub: "exec", ["--skip-git-repo-check"])
                + (oFlag.isEmpty ? "" : oFlag + " " + Shell.quote(outFile.path))
            let r = Proc.zsh("codex exec\(opts) -c model_reasoning_effort=high - < \(Shell.quote(file.path))",
                             in: dir, timeout: 600)
            answer = (try? String(contentsOf: outFile, encoding: .utf8)) ?? r.out
            try? FileManager.default.removeItem(at: outFile)
            if answer.isEmpty || !answer.contains("{") {
                Usage.shared.noteOutput(.codex, text: r.out)
                return VerifyReview(agent: "Codex", ok: true, summary: L("Review nicht möglich: ") + String(r.out.suffix(200)), issues: [])
            }
        } else {
            let model = Usage.shared.isTight(.claude) ? "sonnet" : "opus"
            let r = Proc.zsh(LocalFirst.cliEnv() + "claude -p --model \(model) --output-format json --max-turns 1 --strict-mcp-config < \(Shell.quote(file.path))", in: dir, timeout: 600)
            if let res = claudeResult(r.out) {
                answer = res
            } else {
                Usage.shared.noteOutput(.claude, text: r.out)
                return VerifyReview(agent: "Claude", ok: true, summary: L("Review nicht möglich: ") + String(r.out.suffix(200)), issues: [])
            }
        }
        guard let s = answer.firstIndex(of: "{"), let e = answer.lastIndex(of: "}"),
              let j = try? JSONSerialization.jsonObject(with: Data(answer[s...e].utf8)) as? [String: Any] else {
            return VerifyReview(agent: who.title, ok: true, summary: String(answer.prefix(300)), issues: [])
        }
        return VerifyReview(agent: who == .codex ? "Codex" : "Claude",
                            ok: j["ok"] as? Bool ?? true,
                            summary: (j["summary"] as? String) ?? "",
                            issues: (j["issues"] as? [String]) ?? [])
    }

    /// `claude -p --output-format json` → Feld "result" (Login-Shell-Ausgaben davor werden übersprungen).
    static func claudeResult(_ out: String) -> String? {
        guard let s = out.firstIndex(of: "{"), let e = out.lastIndex(of: "}"), s < e,
              let j = try? JSONSerialization.jsonObject(with: Data(out[s...e].utf8)) as? [String: Any] else { return nil }
        if j["is_error"] as? Bool == true { return nil }
        return j["result"] as? String
    }

    // MARK: Diagnose: warum rot, und wer es behebt

    /// Sofort und ohne KI: typische Fehlerbilder erkennen und den passenden Agent vorschlagen.
    static func heuristicDiagnosis(rec: MissionRecord, report: VerifyReport) -> VerifyDiagnosis {
        let failed = report.checks.filter { $0.ok == false }
        let installed = AgentKind.coders.filter { OpenModels.available($0) }
        func pick(_ prefs: [AgentKind]) -> AgentKind { prefs.first { installed.contains($0) && !Usage.shared.isTight($0) } ?? prefs.first { installed.contains($0) } ?? .claude }
        var points: [String] = []
        var agent = AgentKind.claude, model = "sonnet", reason = L("solide für normale Korrekturen")
        var fix = L("Fehlermeldung lesen, die Ursache im Code beheben und die Prüfung erneut laufen lassen.")
        for c in failed {
            let n = c.name.lowercased(), out = c.output.lowercased()
            if c.name == L("Geheimnisse") {
                points.append(L("Geheimnisse: In den Änderungen steht ein Schlüssel, Token oder Passwort im Klartext – das darf nie ins Repo."))
                fix = L("Den Wert aus dem Code entfernen, über eine Umgebungsvariable (.env, nicht eingecheckt) oder den Schlüsselbund laden und .env in .gitignore eintragen.")
                agent = .claude; model = "sonnet"; reason = L("sorgfältig bei Sicherheitsthemen")
            } else if c.name == L("Installieren") || out.contains("npm err") || out.contains("err_pnpm") || out.contains("could not resolve dependency") {
                points.append(L("Installieren: Die Abhängigkeiten lassen sich nicht installieren (Versionskonflikt oder fehlendes Paket)."))
                fix = L("package.json und Lockfile prüfen, Versionen angleichen oder das fehlende Paket ergänzen.")
                agent = pick([.claude, .codex]); model = agent == .claude ? "sonnet" : ""; reason = L("kennt Paketmanager gut")
            } else if n.contains("typ") || n.contains("tsc") || out.contains("error ts") || out.contains("type error") || out.contains("is not assignable") {
                points.append(c.name + ": " + L("TypeScript meldet Typfehler – Werte passen nicht zu den erwarteten Typen."))
                fix = L("Die gemeldeten Stellen (Datei:Zeile) anpassen, Typen korrekt setzen statt mit any zu überdecken.")
                agent = pick([.codex, .claude]); model = agent == .claude ? "sonnet" : ""; reason = L("präzise bei Typfehlern")
            } else if n.contains("test") || out.contains("failed") && out.contains("expect") {
                points.append(c.name + ": " + L("Mindestens ein Test schlägt fehl – das Verhalten weicht vom Erwarteten ab."))
                fix = L("Den fehlschlagenden Test lesen, die Ursache im Code finden und beheben (den Test nur ändern, wenn er selbst falsch ist).")
                agent = pick([.junie, .codex, .claude]); model = agent == .claude ? "sonnet" : ""; reason = L("stark beim Fehlersuchen und Testen")
            } else if n.contains("lint") || out.contains("eslint") || out.contains("prettier") {
                points.append(c.name + ": " + L("Der Linter bemängelt Stil- oder Qualitätsregeln."))
                fix = L("Die gemeldeten Regeln beheben, wo möglich automatisch (z. B. lint --fix).")
                agent = pick([.claude, .codex]); model = agent == .claude ? "haiku" : ""; reason = L("einfache Korrektur – schnelles, günstiges Modell reicht")
            } else if n.contains("build") || out.contains("build failed") || out.contains("cannot find module") || out.contains("module not found") {
                points.append(c.name + ": " + L("Der Build bricht ab – meist ein fehlender Import, eine falsche Datei oder ein Syntaxfehler."))
                fix = L("Die erste Fehlermeldung im Build-Log beheben (Import/Pfad/Syntax) und neu bauen.")
                agent = pick([.claude, .codex]); model = agent == .claude ? "sonnet" : ""; reason = L("gut bei Build-Problemen")
            } else {
                points.append(c.name + ": " + L("Der Befehl endet mit einem Fehler") + " (`\(c.command)`).")
            }
        }
        if let r = report.review, !r.ok {
            points.append(L("Review: ") + (r.summary.isEmpty ? L("Das zweite Modell hat Probleme im Code gefunden.") : r.summary))
            if failed.isEmpty {
                fix = L("Die Punkte aus dem Review umsetzen.")
                agent = pick([AgentKind(rawValue: rec.agent) ?? .claude, .claude]); model = agent == .claude ? "opus" : ""
                reason = L("inhaltliche Punkte – stärkeres Modell")
            }
        }
        let why = points.count == 1 ? points[0] : String(format: L("%d Prüfungen sind rot."), points.count)
        return VerifyDiagnosis(why: why, points: points, fix: fix, agent: agent.rawValue, model: model, reason: reason)
    }

    /// Genauer per Haiku: liest die Fehlerausgaben, erklärt kurz und schlägt Agent + Modell aus den installierten vor.
    static func aiDiagnosis(rec: MissionRecord, report: VerifyReport, dir: String) -> VerifyDiagnosis? {
        guard Detection.which("claude") != nil, Usage.shared.cachedPressure(.claude) < 1.0 else { return nil }
        let lang = Profile.languageCode == "de" ? "German (informal du)" : "English"
        let installed = AgentKind.coders.filter { OpenModels.available($0) }
        // Modell-Listen auf dem Hauptthread lesen (der Katalog wird dort aktualisiert)
        var models: [AgentKind: [String]] = [:]
        // nie main.sync (kann sich festfahren) – kurz auf den Hauptthread warten, sonst ohne Modellliste weiter
        let sem = DispatchSemaphore(value: 0)
        var fetched: [AgentKind: [String]] = [:]
        DispatchQueue.main.async { for a in installed { fetched[a] = ModelCatalog.shared.latest(for: a, limit: 6).map(\.value) }; sem.signal() }
        if sem.wait(timeout: .now() + 3) == .success { models = fetched }
        let options = installed.map { a -> String in
            let ms = models[a] ?? []
            return "- \(a.rawValue) (\(a.title)): \(a.strength)\(ms.isEmpty ? "" : " · models: " + ms.joined(separator: ", "))\(Usage.shared.isTight(a) ? " · NEARLY AT LIMIT, avoid" : "")"
        }.joined(separator: "\n")
        let prompt = """
        Automatic checks of an AI agent's code changes failed. Explain briefly for a non-expert why, and propose the fix.
        Task: \(rec.title)
        Failures:
        \(report.failures.map { String($0.prefix(1800)) }.joined(separator: "\n\n"))

        Available coding agents (pick the best one to fix THIS problem; prefer cheap/fast models for trivial fixes, strong ones for hard logic):
        \(options)

        Answer ONLY with JSON in \(lang):
        {"why":"1 short sentence, plain words","points":["one short line per failed check: what is wrong"],"fix":"1-2 sentences: what to change","agent":"<agent id from the list>","model":"<model from that agent's list or empty>","reason":"max 8 words why this agent/model"}
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("aos-diag-\(UUID().uuidString).md")
        try? prompt.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let r = Proc.zsh(LocalFirst.cliEnv() + "claude -p --model haiku --output-format json --max-turns 1 --strict-mcp-config < \(Shell.quote(file.path))", in: dir, timeout: 120)
        guard let res = claudeResult(r.out), let a = res.firstIndex(of: "{"), let b = res.lastIndex(of: "}"),
              let j = try? JSONSerialization.jsonObject(with: Data(res[a...b].utf8)) as? [String: Any],
              let why = j["why"] as? String, let fix = j["fix"] as? String else { return nil }
        var agent = (j["agent"] as? String ?? "").lowercased()
        if AgentKind(rawValue: agent).map({ installed.contains($0) }) != true { agent = heuristicDiagnosis(rec: rec, report: report).agent }
        var model = j["model"] as? String ?? ""
        if let k = AgentKind(rawValue: agent), !model.isEmpty, !(models[k] ?? []).contains(model) { model = "" }
        return VerifyDiagnosis(why: why, points: (j["points"] as? [String]) ?? [], fix: fix, agent: agent, model: model,
                               reason: j["reason"] as? String ?? "", byAI: true)
    }

    // MARK: Probleme beheben lassen

    /// Startet eine Folgerunde im selben Arbeitskopie-Branch mit allen Fehlern als Auftrag.
    static func fix(_ rec: MissionRecord, agents: AgentManager, hub: MCPHub, agent: String? = nil, model: String? = nil,
                    completion: @escaping (AgentSession) -> Void) {
        guard let report = rec.verify else { return }
        let problems = report.failures.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n\n")
        let d = report.diagnosis
        let prompt = """
        Die automatische Prüfung deiner Änderungen hat Probleme gefunden. Behebe sie bitte vollständig – \
        ohne den ursprünglichen Auftrag aus den Augen zu verlieren:

        \(problems)
        \(d.map { "\nEinschätzung: \($0.why)\nVorgeschlagene Lösung: \($0.fix)\n" } ?? "")
        Führe die fehlgeschlagenen Befehle danach selbst erneut aus, bis sie grün sind.
        """
        let fallback = AgentKind.coders.contains(rec.agentKind) && !rec.isOSAgent ? rec.agentKind : .claude
        let chosen = agent ?? d?.agent
        let kind = chosen.flatMap { AgentKind(rawValue: $0) }.flatMap { OpenModels.available($0) ? $0 : nil } ?? fallback
        let m = model ?? (kind.rawValue == d?.agent ? d?.model : nil)
        Handoff.continueMission(rec, message: prompt, target: kind.rawValue, agents: agents, hub: hub,
                                model: (m ?? "").isEmpty ? nil : m) { s in
            MissionStore.shared.setFixRound(s.id.uuidString, (rec.fixRound ?? 0) + 1)
            completion(s)
        }
    }
}

// MARK: - Weitermachen / Übergeben (gemeinsam für Chat, Prüfschleife und Limit-Wechsel)

enum Handoff {
    static func continueMission(_ rec: MissionRecord, message: String, target: String, agents: AgentManager, hub: MCPHub,
                                note: String? = nil, model forcedModel: String? = nil, completion: @escaping (AgentSession) -> Void) {
        var before = (try? String(contentsOfFile: rec.log, encoding: .utf8))?
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression) ?? ""
        if before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let tr = rec.transcript {
            before = Transcript.read(URL(fileURLWithPath: tr)).filter { $0.role != .tool }.suffix(12)
                .map { ($0.role == .user ? "\(Profile.name): " : "Agent: ") + $0.text }.joined(separator: "\n\n")
        }
        let handoff = target != rec.agent
            ? "Übergabe: Bisher hat \(rec.agentTitle) daran gearbeitet, jetzt übernimmst du."
            : "Fortsetzung des Auftrags."
        let prompt = """
        \(message)

        ---
        \(handoff) Auftrag „\(rec.title)“. Ursprünglicher Auftrag:
        \(rec.request)

        Bisheriger Verlauf (Ende):
        \(String(before.suffix(4000)))
        \(Obsidian.promptContext.map { "\n" + $0 } ?? "")
        """
        let parentID = rec.id
        // Checkpoint: Stand vor dieser Runde sichern (zurückholbar unter "Änderungen › Checkpoints")
        var checkpoint: String?
        if let wt = rec.worktree {
            Checkpoints.save(wt, label: String(message.prefix(60)))
            let head = Git.run(["rev-parse", "HEAD"], in: Worktrees.top(wt), timeout: 10).out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !head.isEmpty { checkpoint = head }
        }
        let done: (AgentSession) -> Void = { s in
            MissionStore.shared.link(s.id.uuidString, parent: parentID, delegated: false)
            if let checkpoint { MissionStore.shared.setCheckpoint(s.id.uuidString, checkpoint) }
            if let note { MissionStore.shared.setReason(s.id.uuidString, note) }
            MissionStore.shared.supersede(parentID)
            completion(s)
        }
        if target == "os" {
            OSAgent.start(prompt, agents: agents, hub: hub, taskID: rec.taskID, label: rec.title, completion: done)
            return
        }
        let kind = AgentKind(rawValue: target) ?? rec.agentKind
        let chosen = forcedModel ?? ModelCatalog.selected(for: kind)
        let s = agents.start(kind, in: rec.isOSAgent ? (agents.directories.first ?? rec.directory) : rec.directory,
                             prompt: prompt, taskID: rec.taskID, mode: .autonom, label: rec.title,
                             model: chosen.isEmpty ? (kind.rawValue == rec.agent ? rec.model : nil) : chosen)
        done(s)
    }
}

// MARK: - Anzeige im Auftrag

struct VerifyStrip: View {
    let rec: MissionRecord
    /// (Agent, Modell) – nil = Empfehlung der Diagnose
    var onFix: (String?, String?) -> Void
    @State private var open: String?
    @State private var installed: [AgentKind] = []

    var body: some View {
        let r = rec.verify
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Grid.s) {
                if r?.running == true, let r {
                    ProgressView().controlSize(.small)
                    Text("Prüft: Build, Tests, Review …").font(.callout.weight(.medium))
                    Text(r.started, style: .timer).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else if let r, let passed = r.passed {
                    Image(systemName: passed ? "checkmark.seal.fill" : "xmark.seal.fill").foregroundStyle(passed ? .green : .red)
                    Text(passed ? L("Geprüft – alles grün") : L("Prüfung fehlgeschlagen")).font(.callout.weight(.semibold))
                    if let f = r.finished { Text(f, style: .relative).font(.caption).foregroundStyle(.tertiary) }
                } else {
                    Image(systemName: "seal").foregroundStyle(.secondary)
                    Text("Noch nicht geprüft").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if r?.running == true {
                    Button(role: .destructive) { Verifier.cancel(rec.id) } label: { Label(L("Abbrechen"), systemImage: "stop.circle") }
                        .help(L("Beendet die laufende Prüfung samt Testprozessen"))
                }
                if r?.running != true {
                    Button { Verifier.run(rec.id) } label: { Label(r == nil ? L("Jetzt prüfen") : L("Erneut prüfen"), systemImage: "arrow.clockwise") }
                }
            }
            if let note = r?.note { Text(note).font(.caption).foregroundStyle(.secondary) }
            if let r, r.passed == false {
                // ältere Prüfungen ohne gespeicherte Diagnose: Einschätzung nach Regeln sofort zeigen
                diagnosisCard(r.diagnosis ?? Verifier.heuristicDiagnosis(rec: rec, report: r), refining: r.diagnosing == true)
            }
            if let r {
                // Prüfliste: jede Prüfung eine Zeile mit kurzer Erklärung – keine Knöpfe, nur „Ausgabe“ zum Aufklappen.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(r.checks.enumerated()), id: \.offset) { n, c in
                        if n > 0 { Divider().opacity(0.5) }
                        HStack(spacing: Grid.s) {
                            Group {
                                if c.ok == nil { ProgressView().controlSize(.mini) } else {
                                    Image(systemName: c.ok == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(c.ok == true ? .green : .red)
                                }
                            }.frame(width: 16)
                            Text(c.name).font(.callout.weight(.medium)).lineLimit(1).fixedSize()
                            Text(Self.meaning(c.name)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: Grid.s)
                            if c.seconds > 0 { Text("\(Int(c.seconds)) s").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).fixedSize() }
                            if c.ok != nil {
                                Button { open = open == c.name ? nil : c.name } label: {
                                    Label(L("Ausgabe"), systemImage: open == c.name ? "chevron.down" : "chevron.right")
                                        .labelStyle(.titleAndIcon).font(.caption)
                                }
                                .buttonStyle(.link).fixedSize()
                            }
                        }
                        .padding(.vertical, 5)
                        .help(c.command)
                    }
                    if let rv = r.review {
                        Divider().opacity(0.5)
                        HStack(spacing: Grid.s) {
                            Image(systemName: rv.ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(rv.ok ? .green : .red).frame(width: 16)
                            Text("Review").font(.callout.weight(.medium)).fixedSize()
                            Text(String(format: L("%@ hat den Code gelesen"), rv.agent)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                        }.padding(.vertical, 5)
                    } else if r.running && r.checks.allSatisfy({ $0.ok != nil }) && Verifier.reviewOn {
                        Divider().opacity(0.5)
                        HStack(spacing: Grid.s) {
                            ProgressView().controlSize(.mini).frame(width: 16)
                            Text("Review").font(.callout.weight(.medium))
                            Text(L("ein zweiter Agent liest den Code …")).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }.padding(.vertical, 5)
                    }
                }
                .padding(.horizontal, Grid.m).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
                if let o = open, let c = r.checks.first(where: { $0.name == o }) {
                    ScrollView {
                        Text(c.output.isEmpty ? "…" : c.output).font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(Grid.s)
                    }
                    .frame(maxHeight: 220)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
                }
                if let rv = r.review {
                    VStack(alignment: .leading, spacing: 2) {
                        if !rv.summary.isEmpty { Text(rv.summary).font(.callout) }
                        ForEach(rv.issues, id: \.self) { i in
                            Label(i, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                if let shot = r.screenshot, let img = NSImage(contentsOfFile: shot) {
                    Image(nsImage: img).resizable().scaledToFit().frame(maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
                        .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: shot)) }
                        .help("Screenshot der laufenden App – klicken zum Vergrößern")
                }
            }
        }
    }
}


extension VerifyStrip {
    /// Was eine Prüfung bedeutet – in Alltagssprache.
    static func meaning(_ name: String) -> String {
        switch name.lowercased() {
        case "typen", "types", "typecheck": return L("passen alle Datentypen zusammen?")
        case "lint": return L("hält der Code die Stilregeln ein?")
        case "tests", "test": return L("laufen die automatischen Tests durch?")
        case "build": return L("lässt sich das Projekt bauen?")
        case "format", "prettier": return L("ist der Code einheitlich formatiert?")
        default: return L("Prüfbefehl des Projekts")
        }
    }

    /// Kurz erklärt, warum es rot ist, was zu tun ist – und ein Klick, um es mit dem passenden Agent und Modell beheben zu lassen.
    func diagnosisCard(_ d: VerifyDiagnosis, refining: Bool) -> some View {
        let kind = AgentKind(rawValue: d.agent) ?? .claude
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "stethoscope").foregroundStyle(.orange)
                Text(L("Warum rot")).font(.callout.weight(.semibold))
                if refining {
                    ProgressView().controlSize(.mini)
                    Text(L("wird genauer analysiert …")).font(.caption).foregroundStyle(.secondary)
                } else if d.byAI {
                    Text(L("KI-Analyse")).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if d.points.count > 1 {
                ForEach(d.points, id: \.self) { p in
                    Label(p, systemImage: "xmark.circle").font(.callout).foregroundStyle(.primary)
                        .labelStyle(.titleAndIcon)
                }
            } else {
                Text(d.why).font(.callout)
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lightbulb").foregroundStyle(.yellow)
                Text(d.fix).font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: Grid.s) {
                Button { onFix(d.agent, d.model.isEmpty ? nil : d.model) } label: {
                    Label(L("Beheben mit ") + kind.title + (d.model.isEmpty ? "" : " · " + d.model), systemImage: "wrench.and.screwdriver")
                }
                .buttonStyle(.borderedProminent).tint(.orange)
                if !d.reason.isEmpty { Text(d.reason).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                Menu(L("Anderer Agent")) {
                    ForEach(installed) { a in
                        Menu { 
                            Button(L("Standard-Modell")) { onFix(a.rawValue, nil) }
                            ForEach(ModelCatalog.shared.latest(for: a, limit: 8)) { o in Button(o.label) { onFix(a.rawValue, o.value) } }
                        } label: { Label(a.title, systemImage: a.symbol) }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
        .padding(Grid.m)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.25)))
        .task {
            guard installed.isEmpty else { return }
            installed = await Task.detached { AgentKind.coders.filter { OpenModels.available($0) } }.value
        }
    }
}
