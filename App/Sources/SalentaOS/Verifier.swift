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

    /// Salenta Code legt nie etwas im Code des Nutzers ab: die eigenen Einstellungen pro Projekt liegen in den App-Daten.
    /// Eine .salenta-os.json, die jemand bewusst selbst ins Repo gelegt hat (z. B. fürs Team), wird nur gelesen.
    static func privateFile(for dir: String) -> URL {
        let root = ProjectMemory.root(of: Git.root(of: dir) ?? dir)
        let d = Paths.data.appendingPathComponent("projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let name = (root as NSString).lastPathComponent.replacingOccurrences(of: " ", with: "-")
        return d.appendingPathComponent("\(name)-\(ProjectMemory.stableHash(root)).json")
    }

    static func load(_ dir: String) -> ProjectConfig? {
        let dec = JSONDecoder()
        if let d = try? Data(contentsOf: privateFile(for: dir)), let c = try? dec.decode(ProjectConfig.self, from: d) { return c }
        let repo = file(in: dir)
        guard FileManager.default.fileExists(atPath: repo.path), let d = try? Data(contentsOf: repo) else { return nil }
        return try? dec.decode(ProjectConfig.self, from: d)
    }

    static func save(_ cfg: ProjectConfig, dir: String) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        if let d = try? enc.encode(cfg) { try? d.write(to: privateFile(for: dir), options: .atomic) }
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
        for (k, v) in Accounts.shared.env() where env[k] == nil { env[k] = v }   // aktives Zusatz-Abo
        for (k, v) in extra { env[k] = v }
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return ("Start fehlgeschlagen: \(error.localizedDescription)", -1) }
        // Prüfungen, Tests und Hilfsaufrufe laufen mit niedrigerer Priorität: die Oberfläche bleibt auch unter Volllast flüssig
        setpriority(PRIO_PROCESS, id_t(p.processIdentifier), 10)
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

    static func hasCI(_ dir: String) -> Bool {
        var d = dir
        for _ in 0..<4 {
            if FileManager.default.fileExists(atPath: (d as NSString).appendingPathComponent(".github/workflows")) { return true }
            let up = (d as NSString).deletingLastPathComponent
            if up == d || up.isEmpty { break }
            d = up
        }
        return false
    }

    /// Testbefehl auf die von der Änderung betroffenen Tests eingrenzen (vitest --changed, jest --changedSince).
    /// Nur mit GitHub-CI – die prüft vor dem Merge ohnehin alles. Unbekannte Test-Werkzeuge bleiben unverändert.
    static func scopedTests(_ command: String, dir: String, base: String) -> String {
        guard !base.isEmpty, hasCI(dir), !command.contains("--changed") else { return command }
        var runner = command
        let scriptRun = command.range(of: #"^(npm|pnpm|yarn|bun) run test"#, options: .regularExpression) != nil
        if scriptRun, let d = FileManager.default.contents(atPath: (dir as NSString).appendingPathComponent("package.json")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let s = (j["scripts"] as? [String: String])?["test"] { runner = s }
        let sep = scriptRun && command.hasPrefix("npm") && !command.contains(" -- ") ? " -- " : " "
        if runner.contains("vitest") { return command + sep + "--changed " + base + " --passWithNoTests" }
        if runner.contains("jest") { return command + sep + "--changedSince=" + base + " --passWithNoTests" }
        return command
    }

    /// Rot sind nur Tests in Dateien, die der Auftrag gar nicht anfasst (lokal oft Zeitlimit, fehlende Datenbank oder Umgebung)?
    /// Dann blockiert das nicht – vorausgesetzt, GitHub-CI prüft das Projekt ohnehin vor dem Merge.
    /// Sonst „reparieren“ Helfer stundenlang Tests, die gar nicht kaputt sind.
    static func unrelatedTestFailure(name: String, output: String, dir: String, changed: [String]) -> String? {
        guard name == L("Tests"),
              FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".github/workflows")),
              let re = try? NSRegularExpression(pattern: "(?m)^\\s*(?:FAIL|×|✗|❯)\\s+([^\\s>]+\\.(?:test|spec)\\.[cm]?[jt]sx?)") else { return nil }
        let ns = output as NSString
        var files = Set<String>()
        for m in re.matches(in: output, range: NSRange(location: 0, length: ns.length)) { files.insert(ns.substring(with: m.range(at: 1))) }
        guard !files.isEmpty else { return nil }
        func stem(_ p: String) -> String {
            var s = (p as NSString).lastPathComponent
            for x in [".test.", ".spec."] { if let r = s.range(of: x) { s = String(s[..<r.lowerBound]) } }
            return (s as NSString).deletingPathExtension
        }
        let stems = Set(changed.map(stem))
        let related = files.filter { f in changed.contains(where: { $0.hasSuffix(f) || f.hasSuffix($0) }) || stems.contains(stem(f)) }
        guard related.isEmpty else { return nil }
        return String(format: L("Nicht blockierend: Rot sind nur Tests, die dieser Auftrag nicht anfasst (%@). Lokal meist Zeitlimit oder fehlende Umgebung – die GitHub-CI prüft das vor dem Merge."), files.sorted().prefix(4).joined(separator: ", "))
    }

    // MARK: Ausgangsstand

    private static var baseCache: [String: (code: Int32, out: String)] = [:]
    private static let baseLock = NSLock()

    /// Fehlerzeilen einer Prüfausgabe (für den Vergleich vorher/nachher).
    static func errorCount(_ out: String) -> Int {
        out.split(separator: "\n").filter { l in
            let t = l.lowercased()
            return t.contains("error") || t.contains("fehler") || t.contains("✗") || t.hasPrefix("fail") || t.contains(" fail ")
        }.count
    }

    /// War die Prüfung schon vor dem Auftrag genauso rot? Dann ist sie kein Fehler dieses Auftrags.
    /// Mehr Fehler als vorher bleiben rot – der Auftrag darf nichts verschlechtern.
    static func preexisting(baseCode: Int32, baseOut: String, out: String) -> Bool {
        baseCode != 0 && baseCode != 124 && errorCount(out) <= max(errorCount(baseOut), 1)
    }

    /// Führt dieselbe Prüfung auf dem Ausgangsstand aus (eigene, saubere Arbeitskopie; Abhängigkeiten verlinkt). Ergebnis je Stand zwischengespeichert.
    static func baseline(_ command: String, dir: String, fork: String, tag: String) -> (code: Int32, out: String)? {
        guard !fork.isEmpty else { return nil }
        let key = fork + "\u{1}" + command
        baseLock.lock(); if let c = baseCache[key] { baseLock.unlock(); return c }; baseLock.unlock()
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("salenta-base-" + String(fork.prefix(12)) + "-" + String(UUID().uuidString.prefix(6)))
        guard Git.run(["worktree", "add", "--detach", tmp, fork], in: dir, timeout: 120).code == 0 else { return nil }
        defer { _ = Git.run(["worktree", "remove", "--force", tmp], in: dir, timeout: 60); try? FileManager.default.removeItem(atPath: tmp) }
        for dep in ["node_modules", ".venv", "venv", "vendor", "Pods"] {
            let src = (dir as NSString).appendingPathComponent(dep)
            if FileManager.default.fileExists(atPath: src) { try? FileManager.default.createSymbolicLink(atPath: (tmp as NSString).appendingPathComponent(dep), withDestinationPath: src) }
        }
        let r = Proc.zsh("exec \(PowerProfile.shellPrefix)nice -n 15 /bin/zsh -c " + Shell.quote(command), in: tmp, timeout: 900, tag: tag)
        let res = (code: r.code, out: String(r.out.suffix(6000)))
        baseLock.lock(); baseCache[key] = res; baseLock.unlock()
        return res
    }

    // MARK: Prüfen

    /// Führt die Prüfung für einen Auftrag mit Arbeitskopie aus (im Hintergrund, Fortschritt live im Auftrag).
    static func run(_ id: String, completion: ((VerifyReport) -> Void)? = nil) {
        guard let rec = MissionStore.shared.mission(id), let wt = rec.worktree, !runningIDs.contains(id),
              rec.outcome != "stopped" else { return }   // gestoppte Läufe werden nie geprüft
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
            // Nur Doku/Bilder geändert? Dann keine schweren Prüfungen (spart Zeit und Strom).
            let docsOnly = !changes.isEmpty && changes.allSatisfy { f in
                let e = (f.path as NSString).pathExtension.lowercased()
                return ["md", "mdx", "txt", "png", "jpg", "jpeg", "gif", "svg", "webp", "pdf"].contains(e)
            }
            let failFast = UserDefaults.standard.object(forKey: "verify.failFast") as? Bool ?? true
            // 1. Build, Lint, Tests
            let fork = Worktrees.forkPoint(wt)
            var ranTests = false
            for c0 in (docsOnly ? [] : checks(for: dir)) {
                // Wie Claude Code oder Codex: lokal nur die Tests, die die Änderung betrifft – die volle Suite läuft in der CI.
                // Spart bei großen Projekten Minuten, Strom und Hitze; ohne CI läuft weiter alles.
                let isTestRun = c0.name == L("Tests") || c0.command.contains("vitest run") || c0.command.contains("jest")
                if isTestRun && ranTests && hasCI(dir) { continue }   // dieselbe Suite nicht zweimal (Tests + CI-Kopie)
                let scopedCmd = isTestRun ? scopedTests(c0.command, dir: dir, base: fork) : c0.command
                if isTestRun { ranTests = true }
                let c = (name: c0.name, command: scopedCmd)
                if isCancelled(id) { break }
                // Schon etwas rot? Dann die restlichen schweren Prüfungen sparen – der Agent prüft beim Nachbessern ohnehin alles.
                if failFast, report.checks.contains(where: { $0.ok == false }) {
                    report.checks.append(VerifyCheck(name: c.name, command: c.command))
                    report.checks[report.checks.count - 1].ok = nil
                    report.checks[report.checks.count - 1].output = L("übersprungen – vorher ist schon etwas rot")
                    continue
                }
                report.checks.append(VerifyCheck(name: c.name, command: c.command))
                publish()
                // Nicht mehr schwere Prüfungen gleichzeitig, als der Mac verträgt – und mit niedriger Priorität,
                // damit du weiterarbeiten kannst und der Mac nicht durchglüht.
                guard CheckGate.enter(cancelled: { isCancelled(id) }) else { break }
                let t0 = Date()
                var r = Proc.zsh("exec \(PowerProfile.shellPrefix)nice -n 10 /bin/zsh -c " + Shell.quote(c.command), in: dir, timeout: 600, tag: "verify-" + id)
                // Zeitüberschreitung ist oft kein Fehler im Code: unter Volllast und mit niedriger Priorität brauchen große Test-Suites
                // länger. Einmal mit mehr Zeit wiederholen – erst wenn es dann immer noch hängt, gilt die Prüfung als rot.
                if r.code == 124, !isCancelled(id) {
                    report.checks[report.checks.count - 1].output = L("Zeitüberschreitung nach 10 Minuten – wird mit mehr Zeit wiederholt …")
                    publish()
                    r = Proc.zsh("exec \(PowerProfile.shellPrefix)nice -n 5 /bin/zsh -c " + Shell.quote(c.command), in: dir, timeout: 1800, tag: "verify-" + id)
                }
                CheckGate.leave()
                let i = report.checks.count - 1
                report.checks[i].ok = r.code == 0
                report.checks[i].output = String(r.out.suffix(6000))
                report.checks[i].seconds = Date().timeIntervalSince(t0)
                if r.code != 0, let note = unrelatedTestFailure(name: isTestRun ? L("Tests") : c.name, output: r.out, dir: dir, changed: changes.map(\.path)) {
                    report.checks[i].ok = nil
                    report.checks[i].output = note + "\n\n" + report.checks[i].output
                } else if r.code != 0, r.code != 124, c.name != L("Installieren"), scopedCmd == c0.command, !isCancelled(id) {
                    // Schon vor dem Auftrag rot? Dann nicht dem Auftrag anlasten (und nicht endlos „reparieren“ lassen).
                    report.checks[i].output = L("Rot – prüfe, ob das schon vor dem Auftrag so war …") + "\n\n" + report.checks[i].output
                    publish()
                    if let b = baseline(c.command, dir: dir, fork: fork, tag: "verify-" + id), preexisting(baseCode: b.code, baseOut: b.out, out: r.out) {
                        report.checks[i].ok = nil
                        report.checks[i].output = String(format: L("Nicht blockierend: war schon vor diesem Auftrag rot (Ausgangsstand %@), die Änderung macht es nicht schlimmer."), String(fork.prefix(7)))
                            + "\n\n" + String(r.out.suffix(6000))
                    } else {
                        report.checks[i].output = String(r.out.suffix(6000))
                    }
                }
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
            // Übrig gebliebene Konfliktmarker (nach einem eingemischten Ziel-Branch) dürfen nie durchgehen
            let added = Worktrees.diff(wt).split(separator: "\n")
            // „=======“ allein kann eine Markdown-Unterstreichung sein – nur zusammen mit echten Anfangs-/Endmarkern zählen
            if added.contains(where: { $0.hasPrefix("+<<<<<<< ") }) && added.contains(where: { $0.hasPrefix("+>>>>>>> ") }) {
                report.checks.append(VerifyCheck(name: L("Konflikte"), command: L("Suche nach Konfliktmarkern"), ok: false,
                                                 output: L("Ungelöste Konfliktmarker gefunden – erst auflösen.")))
                publish()
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
        // Ein Review kostet wenig (Claude nimmt am Limit Sonnet) – lieber knapp am Limit als derselbe Agent prüft sich selbst.
        func usable(_ k: AgentKind) -> Bool {
            Detection.which(k.command) != nil && (Usage.shared.blocked[k.rawValue] ?? .distantPast) < Date() && !AgentHealth.needsLogin(k) && !Usage.isPaused(k)
        }
        if agent == "codex" { return usable(.claude) || !usable(.codex) ? .claude : .codex }
        if agent == "claude" { return usable(.codex) ? .codex : .claude }
        return usable(.codex) && !Usage.shared.isTight(.codex) ? .codex : (usable(.claude) ? .claude : .codex)
    }

    private static func review(rec: MissionRecord, diff: String, checks: [VerifyCheck], dir: String) -> VerifyReview? {
        // Nur lokal / offline: das Review macht das lokale Modell (über den Claude-Weg), nicht Codex in der Cloud
        let who = LocalFirst.shared.useLocal || LocalFirst.shared.localOnly ? AgentKind.claude : reviewer(for: rec.agent)
        let lang = Profile.languageCode == "de" ? "German" : "English"
        let checkText = checks.isEmpty ? "(no automatic checks)" : checks.map { "- \($0.name) `\($0.command)`: \($0.ok == true ? "passed" : $0.ok == false ? "FAILED" : ($0.output.hasPrefix(L("Nicht blockierend")) ? "not blocking – it already failed before this change, or only tests in files this change doesn't touch failed locally; CI runs the full suite" : "skipped"))" }.joined(separator: "\n")
        let rules = (ProjectConfig.load(dir)?.rules ?? []) + Rules.global
        let prompt = """
        You are a strict senior reviewer. Another AI agent (\(rec.agentTitle)) made the changes below for this task.
        Decide if the change is correct and complete – above all: does it do what the task asks? If the task contains a \
        "Fertig, wenn:" / "Done when:" line, check that exact criterion against the diff and fail if it is not met.
        After your review the pipeline itself runs the full test suite in GitHub CI, pushes the branch and opens the pull request – \
        never fail a change because a full test run, CI result, push or PR is not shown here; only the affected tests run locally.
        Only flag real problems: bugs, regressions, missing parts of the task,
        security issues, broken rules, leftover debug code. Ignore style preferences.
        Agents never receive API keys, passwords, tokens or hosting/deployment settings, and must not deploy. If something can only be \
        finished by the owner (e.g. adding an API key in the hosting environment, logging in to a service, buying a domain, a live \
        delivery test against a real account), do NOT fail the change for it – set ok to true if the code side is done correctly and \
        list those items under "owner".

        Task:
        \"\"\"\(rec.request.prefix(3000))\"\"\"
        \(rules.isEmpty ? "" : "\nProject rules (must be followed):\n" + rules.map { "- " + $0 }.joined(separator: "\n") + "\n")
        Automatic checks:
        \(checkText)

        Diff:
        ```diff
        \(diff.prefix(70_000))
        ```

        Answer ONLY with JSON: {"ok": true|false, "summary": "one sentence in \(lang)", "issues": ["file:line – problem (in \(lang))"], "owner": ["what only the owner can do (in \(lang))"]}
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
            // 4 Runden reichten bei großen Änderungen nicht („maximum number of turns“) – dann lief alles ungeprüft durch.
            // Jetzt 12 Runden; scheitert es trotzdem, ein zweiter Versuch nur mit dem Diff im Prompt (ohne Werkzeuge).
            var r = Proc.zsh(LocalFirst.cliEnv() + "claude -p --model \(model) --output-format json --max-turns 12 --allowedTools Read,Grep,Glob --strict-mcp-config < \(Shell.quote(file.path))", in: dir, timeout: 600)
            if claudeResult(r.out) == nil {
                r = Proc.zsh(LocalFirst.cliEnv() + "claude -p --model \(model) --output-format json --max-turns 2 --strict-mcp-config < \(Shell.quote(file.path))", in: dir, timeout: 420)
            }
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
        // Was nur du erledigen kannst (Schlüssel, Anmeldung, Live-Test) – sichtbar im Ergebnis, aber kein Grund für eine Korrekturrunde
        let owner = (j["owner"] as? [String] ?? []).filter { !$0.isEmpty }
        let summary = (j["summary"] as? String) ?? ""
        return VerifyReview(agent: who == .codex ? "Codex" : "Claude",
                            ok: j["ok"] as? Bool ?? true,
                            summary: owner.isEmpty ? summary : summary + " · " + L("Braucht dich:") + " " + owner.joined(separator: "; "),
                            issues: (j["issues"] as? [String]) ?? [])
    }

    /// `claude -p --output-format json` → Feld "result" (Login-Shell-Ausgaben davor werden übersprungen).
    static func claudeResult(_ out: String) -> String? {
        guard let j = claudeEnvelope(out) else { return nil }
        if j["is_error"] as? Bool == true { return nil }
        return j["result"] as? String
    }

    /// Das Ergebnis-Objekt von `claude -p --output-format json` – robust gegen Hook-/Plugin-Ausgaben davor und danach.
    static func claudeEnvelope(_ out: String) -> [String: Any]? {
        for line in out.split(separator: "\n").reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("{"), let j = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any],
                  j["type"] as? String == "result" || j["result"] != nil || j["is_error"] != nil else { continue }
            return j
        }
        guard let s = out.firstIndex(of: "{"), let e = out.lastIndex(of: "}"), s < e,
              let j = try? JSONSerialization.jsonObject(with: Data(out[s...e].utf8)) as? [String: Any] else { return nil }
        return j
    }

    /// Kurzer, verständlicher Grund, warum ein `claude -p`-Aufruf nichts geliefert hat.
    static func claudeFailure(_ out: String, code: Int32) -> String {
        let low = out.lowercased()
        if code == 3 && low.contains("nur lokal") { return L("„Nur lokal“ ist an, aber kein lokales Modell bereit") }
        if low.contains("usage limit") || low.contains("rate limit") || low.contains("limit reached") || low.contains("429") { return L("Claude ist im Limit") }
        if low.contains("not logged in") || low.contains("please run /login") || low.contains("invalid api key") || low.contains("authentication") { return L("Claude ist nicht angemeldet") }
        if low.contains("could not resolve host") || low.contains("network") || low.contains("enotfound") || low.contains("econnrefused") { return L("keine Internetverbindung") }
        if code == 124 || code == 137 || low.contains("timed out") || low.contains("zeitüberschreitung") { return L("Zeitüberschreitung") }
        if let j = claudeEnvelope(out) {
            if j["subtype"] as? String == "error_max_turns" { return L("Claude wollte mehr Schritte als erlaubt") }
            if j["is_error"] as? Bool == true { return L("Claude meldet einen Fehler: ") + String((j["result"] as? String ?? "").prefix(140)) }
            return L("Antwort war kein lesbarer Plan")
        }
        if Detection.which("claude") == nil { return L("Claude Code ist nicht installiert") }
        let tail = out.split(separator: "\n").last.map(String.init) ?? ""
        return L("keine Antwort von Claude") + (tail.isEmpty ? "" : " (" + String(tail.prefix(120)) + ")")
    }

    // MARK: Diagnose: warum rot, und wer es behebt

    /// Sofort und ohne KI: typische Fehlerbilder erkennen und den passenden Agent vorschlagen.
    static func heuristicDiagnosis(rec: MissionRecord, report: VerifyReport) -> VerifyDiagnosis {
        let failed = report.checks.filter { $0.ok == false }
        let installed = AgentKind.coders.filter { OpenModels.available($0) && Billing.autoOK($0) }
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
        // Kostenschutz und Abschalter gelten auch für Korrektur-Vorschläge der KI
        let installed = AgentKind.coders.filter { OpenModels.available($0) && Billing.autoOK($0) }
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
        let r = Proc.zsh(HelperLLM.command(model: "haiku", maxTurns: 3, file: file.path), in: dir, timeout: 120)
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
                                note: String? = nil, model forcedModel: String? = nil, defaultModel: Bool = false, completion: @escaping (AgentSession) -> Void) {
        var before = (try? String(contentsOfFile: rec.log, encoding: .utf8))?
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression) ?? ""
        if before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let tr = rec.transcript {
            before = Transcript.read(URL(fileURLWithPath: tr)).filter { $0.role != .tool }.suffix(12)
                .map { ($0.role == .user ? "\(Profile.name): " : "Agent: ") + $0.text }.joined(separator: "\n\n")
        }
        let handoff = target != rec.agent
            ? "Übergabe: Bisher hat \(rec.agentTitle) daran gearbeitet, jetzt übernimmst du."
            : "Fortsetzung des Auftrags."
        // Übergabe-Paket: was schon geändert ist und wie der letzte Prüfstand war
        var state = ""
        if let wt = rec.worktree {
            let stat = Git.run(["diff", "--stat", Worktrees.baseRef(wt) + "...HEAD"], in: Worktrees.top(wt), timeout: 15).out
            let open = Git.run(["status", "--short"], in: Worktrees.top(wt), timeout: 10).out
            let files = (stat + "\n" + open).trimmingCharacters(in: .whitespacesAndNewlines)
            if !files.isEmpty { state += "\nGeänderte Dateien bisher:\n" + String(files.suffix(1500)) + "\n" }
        }
        if let v = rec.verify, let p = v.passed {
            state += "\nLetzte automatische Prüfung: " + (p ? "grün" : "rot") + (p ? "" : "\n" + v.failures.prefix(5).map { "- " + String($0.prefix(300)) }.joined(separator: "\n")) + "\n"
        }
        let coding = target != "os" && AgentKind(rawValue: target).map { AgentKind.coders.contains($0) } ?? false
        let prompt = """
        \(message)

        ---
        \(handoff) Auftrag „\(rec.title)“. Ursprünglicher Auftrag:
        \(rec.request)

        \(state)
        Bisheriger Verlauf (Ende):
        \(String(before.suffix(4000)))
        \(coding ? "" : Obsidian.promptContext.map { "\n" + $0 } ?? "")
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
        let chosen = defaultModel ? "" : (forcedModel ?? ModelCatalog.selected(for: kind))
        let inherited: String? = defaultModel ? nil : rec.cleanModel
        // Gleicher Agent (Claude) und Sitzung bekannt: dieselbe Sitzung fortsetzen – nur die neue Nachricht und der Prüfstand,
        // kein erneutes Einlesen von Verlauf, Regeln und Projektwissen (spart viele Tokens, Kontext bleibt vollständig).
        if SessionReuse.enabled, kind == .claude, target == rec.agent, !rec.isOSAgent, let sid = SessionReuse.id(for: rec) {
            let short = message + (state.isEmpty ? "" : "\n\n---" + state)
            let s = agents.start(kind, in: rec.directory, prompt: short, taskID: rec.taskID, mode: .autonom, label: rec.title,
                                 model: chosen.isEmpty ? inherited : chosen, effort: rec.effort, continueSession: sid)
            done(s)
            return
        }
        let s = agents.start(kind, in: rec.isOSAgent ? (agents.directories.first ?? rec.directory) : rec.directory,
                             prompt: prompt, taskID: rec.taskID, mode: .autonom, label: rec.title,
                             model: chosen.isEmpty ? (kind.rawValue == rec.agent ? inherited : nil) : chosen,
                             effort: (kind == .codex || kind == .claude) ? (rec.effort ?? rec.legacyEffort) : nil)
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
                                if c.ok == nil, r.finished != nil || !c.output.isEmpty {
                                    Image(systemName: "minus.circle").foregroundStyle(.tertiary).help(c.output)
                                } else if c.ok == nil { ProgressView().controlSize(.mini) } else {
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
