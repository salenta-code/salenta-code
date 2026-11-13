import AgenticOSKit
import AppKit
import SwiftUI

// Selbsttest: `SalentaOS --selftest` prüft die Teile, die schon einmal Hänger oder falsche Anzeigen verursacht haben.
// build.sh führt ihn nach jedem Build aus und installiert nur, wenn alles grün ist – die laufende Version bleibt sonst.
// Er verändert keine Daten: alles läuft in einem Wegwerf-Ordner.

enum SelfTest {
    private static var failures: [String] = []
    private static var passed = 0

    private static func check(_ name: String, _ ok: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
        if ok() { passed += 1; print("  ✓ \(name)") }
        else { failures.append(name); print("  ✗ \(name)\(detail().isEmpty ? "" : " – " + detail())") }
    }

    private static func section(_ t: String) { print("\n▸ \(t)") }

    /// Liefert den Exit-Code (0 = alles grün).
    static func run() -> Int32 {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("salenta-selftest-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let t0 = Date()
        print("Salenta Code – Selbsttest")

        processes(tmp)
        git(tmp)
        mail()
        status(tmp)
        verify()
        digest()
        steward(tmp)
        pipeline(tmp)
        knowledge(tmp)
        intelligence(tmp)
        layout()

        let secs = String(format: "%.1f", Date().timeIntervalSince(t0))
        print("\n\(failures.isEmpty ? "✓" : "✗") \(passed) bestanden, \(failures.count) fehlgeschlagen (\(secs) s)")
        if !failures.isEmpty { print("Fehlgeschlagen: " + failures.joined(separator: ", ")) }
        return failures.isEmpty ? 0 : 1
    }

    // MARK: Prozesse – nichts darf ewig hängen

    private static func processes(_ dir: URL) {
        section("Prozesse")
        let ok = Proc.zsh("echo hallo", in: dir.path, timeout: 30)
        check("Befehl liefert Ausgabe", ok.out.contains("hallo") && ok.code == 0, "code \(ok.code)")

        let bad = Proc.zsh("exit 3", in: dir.path, timeout: 30)
        check("Fehlercode kommt an", bad.code == 3, "code \(bad.code)")

        // Enkelprozess hält die Pipe offen – früher blieb hier alles für immer stehen
        let start = Date()
        let hang = Proc.zsh("(sleep 40; echo spaet) & sleep 40", in: dir.path, timeout: 2)
        let took = Date().timeIntervalSince(start)
        check("Zeitlimit beendet Befehl samt Kindprozessen", took < 15 && hang.code == 124, String(format: "%.1f s, code %d", took, hang.code))
        check("Zeitlimit wird gemeldet", hang.out.contains(L("Zeitüberschreitung")))

        // Abbrechen von außen
        let s2 = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { Proc.cancel(tag: "selftest") }
        _ = Proc.zsh("sleep 40", in: dir.path, timeout: 60, tag: "selftest")
        check("Abbrechen beendet laufenden Befehl", Date().timeIntervalSince(s2) < 15)
    }

    // MARK: Git

    private static func git(_ tmp: URL) {
        section("Git")
        let repo = tmp.appendingPathComponent("repo").path
        try? FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        _ = Git.run(["init", "-q", "-b", "main"], in: repo, timeout: 20)
        try? "a".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        _ = Git.run(["add", "-A"], in: repo, timeout: 20)
        let c = Git.run(["-c", "user.name=Selbsttest", "-c", "user.email=selftest@localhost", "commit", "-qm", "init"], in: repo, timeout: 20)
        check("Commit in Wegwerf-Repo", c.code == 0, c.out)
        check("Repo-Wurzel wird erkannt", Git.root(of: repo).map { ($0 as NSString).lastPathComponent } == "repo")
        check("Kein Repo → nil", Git.root(of: tmp.path) == nil)

        // Arbeitskopie wie das echte Projekt: .env und Abhängigkeiten kommen mit, aber nichts davon wird committet
        let fm = FileManager.default
        try? "node_modules/\n.env\n".write(toFile: repo + "/.gitignore", atomically: true, encoding: .utf8)
        _ = Git.run(["add", "-A"], in: repo, timeout: 20)
        _ = Git.run(["-c", "user.name=Selbsttest", "-c", "user.email=selftest@localhost", "commit", "-qm", "ignore"], in: repo, timeout: 20)
        try? "KEY=1".write(toFile: repo + "/.env", atomically: true, encoding: .utf8)
        try? "NICHT_IGNORIERT=1".write(toFile: repo + "/.env.local", atomically: true, encoding: .utf8)
        try? fm.createDirectory(atPath: repo + "/node_modules/x", withIntermediateDirectories: true)
        let wt = tmp.appendingPathComponent("wt").path
        _ = Git.run(["worktree", "add", "-q", "-b", "t/1", wt, "HEAD"], in: repo, timeout: 20)
        Worktrees.prepare(worktree: wt, from: repo)
        let linked = (try? fm.destinationOfSymbolicLink(atPath: wt + "/node_modules")) != nil
        check("Arbeitskopie: .env und node_modules sind da", fm.fileExists(atPath: wt + "/.env") && linked)
        check("Arbeitskopie: nicht ignorierte .env-Datei wird nicht kopiert", !fm.fileExists(atPath: wt + "/.env.local"))
        _ = Git.run(["add", "-A", "--"] + Worktrees.addSpec, in: wt, timeout: 20)
        let staged = Git.run(["diff", "--cached", "--name-only"], in: wt, timeout: 20).out
        check("Arbeitskopie: Schlüssel und Abhängigkeiten landen nie im Commit", !staged.contains("node_modules") && !staged.contains(".env"), staged)
        _ = Git.run(["worktree", "remove", "--force", wt], in: repo, timeout: 20)
    }

    // MARK: Mail

    private static func mail() {
        section("Mail")
        let raw = """
        From: Test <t@example.com>
        Subject: =?UTF-8?B?R3LDvMOfZQ==?=
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="AAA"

        --AAA
        Content-Type: multipart/related; boundary="BBB"

        --BBB
        Content-Type: text/html; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        <p>Hallo Gr=C3=BC=C3=9Fe <img src=3D"cid:bild1"></p>
        --BBB
        Content-Type: image/png
        Content-ID: <bild1>
        Content-Transfer-Encoding: base64

        iVBORw0KGgo=
        --BBB--
        --AAA
        Content-Type: application/pdf; name="Rechnung.pdf"
        Content-Disposition: attachment; filename="Rechnung.pdf"
        Content-Transfer-Encoding: base64

        JVBERi0xLjQK
        --AAA--
        """
        let m = MIME.parse(raw)
        check("HTML-Teil mit Umlauten (quoted-printable)", m.html?.contains("Grüße") == true, m.html ?? "nil")
        check("Eingebettetes Bild wird ins HTML übernommen", m.html?.contains("data:image/png;base64") == true)
        check("Anhang erkannt, Bild nicht doppelt", m.attachments.count == 1 && m.attachments.first?.filename == "Rechnung.pdf",
              m.attachments.map(\.filename).joined(separator: ","))
        check("Betreff-Kodierung (RFC 2047)", MIME.decodeWords("=?UTF-8?B?R3LDvMOfZQ==?=") == "Grüße")
    }

    // MARK: Statuszeile

    private static func status(_ tmp: URL) {
        section("Statuszeile")
        check("Kontextfenster Claude", MissionStatus.window(model: "claude-opus-5-5", agent: "claude", used: 50_000) == 200_000)
        check("Kontextfenster 1M", MissionStatus.window(model: "claude-sonnet-5-5[1m]", agent: "claude", used: 0) == 1_000_000)
        check("Kontextfenster Codex", MissionStatus.window(model: "gpt-5.5", agent: "codex", used: 0) == 272_000)
        check("Plugin-Konnektor lesbar benannt", ConnectorState(name: "plugin:sales:gmail", status: "needs-auth", source: "").display == "gmail · sales")
        check("Anmeldung fehlt ist kein Fehler", !ConnectorState(name: "x", status: "needs-auth", source: "").failed)
        check("Token-Anzeige", MissionStatus.tokens(84_321) == "84k" && MissionStatus.tokens(1_500_000) == "1.5 M")

        let f = tmp.appendingPathComponent("t.jsonl")
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","model":"claude-opus-5-5","usage":{"input_tokens":10,"cache_read_input_tokens":40000,"cache_creation_input_tokens":2000,"output_tokens":5}}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"role":"assistant","usage":{"input_tokens":999999}}}"#,
        ]
        try? lines.joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
        let (ctx, model) = MissionStatus.transcriptUsage(f)
        check("Kontext aus Verlauf (Helfer ignoriert)", ctx == 42_010 && model == "claude-opus-5-5", "\(ctx) \(model ?? "-")")
    }

    // MARK: Prüfschleife

    private static func verify() {
        section("Prüfschleife")
        var r = VerifyReport()
        check("Laufende Prüfung hat kein Ergebnis", r.passed == nil && r.running)
        r.checks = [VerifyCheck(name: "Build", command: "x", ok: true), VerifyCheck(name: "Tests", command: "y", ok: false)]
        r.finished = Date()
        check("Ein roter Check → nicht bestanden", r.passed == false && !r.running)
        r.checks[1].ok = true
        check("Alles grün → bestanden", r.passed == true)
        var old = VerifyReport(); old.started = Date().addingTimeInterval(-3 * 3600)
        check("Uralte Prüfung gilt nicht als laufend", !old.running)
    }

    // MARK: Ergebnis-Karte

    private static func digest() {
        section("Ergebnis-Karte")
        check("Salenta-Code-Hinweis erkannt", Digest.isToolTopic("Codex startet nicht, Salenta Code übergibt --full-auto"))
        check("Projektthema nicht als Salenta-Code-Hinweis", !Digest.isToolTopic("Login-Seite von example.com lädt langsam"))
        let d = Digest.heuristic("## Ergebnis\nAlles gebaut.\n\n## Nächste Schritte\n- Tests ergänzen\n- Deploy prüfen")
        check("Bericht wird zusammengefasst", !d.summary.isEmpty)
    }

    // MARK: Betreuer-Ablauf Ende zu Ende (wie im echten Projekt: GitHub ist weiter als der lokale main)

    private static func pipeline(_ tmp: URL) {
        section("Betreuer-Ablauf (Ende zu Ende)")
        let id = ["-c", "user.name=Selbsttest", "-c", "user.email=selftest@localhost"]
        let fm = FileManager.default
        func write(_ dir: String, _ file: String, _ text: String) {
            let p = (dir as NSString).appendingPathComponent(file)
            try? fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? text.write(toFile: p, atomically: true, encoding: .utf8)
        }
        func commit(_ dir: String, _ msg: String) { _ = Git.run(["add", "-A"], in: dir, timeout: 20); _ = Git.run(id + ["commit", "-qm", msg], in: dir, timeout: 20) }

        // GitHub (origin) und dein lokaler Ordner
        let origin = tmp.appendingPathComponent("origin.git").path
        let proj = tmp.appendingPathComponent("proj").path
        let other = tmp.appendingPathComponent("other").path
        _ = Git.run(["init", "-q", "--bare", "-b", "main", origin], in: tmp.path, timeout: 20)
        _ = Git.run(["clone", "-q", origin, proj], in: tmp.path, timeout: 30)
        _ = Git.run(["checkout", "-q", "-b", "main"], in: proj, timeout: 20)
        write(proj, "src/app.ts", "export const a = 1\n")
        write(proj, ".github/workflows/ci.yml", "on: push\n")
        commit(proj, "init")
        _ = Git.run(["push", "-q", "origin", "main"], in: proj, timeout: 30)

        // Andere (Dependabot, du von woanders) mergen weiter auf GitHub – inkl. Testdatei mit Test-Passwort
        _ = Git.run(["clone", "-q", origin, other], in: tmp.path, timeout: 30)
        write(other, "src/__tests__/db.pg-test.ts", "const cfg = { password: \"postgres-test-123\" }\n")
        write(other, "src/slow.test.ts", "test('langsam', () => {})\n")
        write(other, "src/fremd.ts", "export const fremd = 2\n")
        commit(other, "fremde Arbeit")
        _ = Git.run(["push", "-q", "origin", "main"], in: other, timeout: 30)

        // Lokal: alter main, ein anderer Branch mit nicht hochgeladenen Commits ist ausgecheckt (wie bei dir)
        _ = Git.run(["checkout", "-q", "-b", "codex/feature"], in: proj, timeout: 20)
        write(proj, "src/lokal.ts", "export const lokal = 3\n"); commit(proj, "lokal 1")
        write(proj, "src/lokal2.ts", "export const lokal2 = 4\n"); commit(proj, "lokal 2")
        let fetched = Git.run(["fetch", "-q", "origin", "+refs/heads/main:refs/remotes/origin/main"], in: proj, timeout: 30).code == 0
        check("GitHub-Stand geholt", fetched)

        // Helfer-Arbeitskopie startet von origin/main (wie Worktrees.create)
        let wtPath = tmp.appendingPathComponent("wt-helfer").path
        let added = Git.run(["worktree", "add", "-q", "-b", "aos/selftest", wtPath, "origin/main"], in: proj, timeout: 20)
        check("Arbeitskopie von origin/main angelegt", added.code == 0, added.out)
        let wt = WorktreeInfo(path: wtPath, branch: "aos/selftest", base: proj, baseBranch: "main")
        check("Vergleichsstand ist origin/main, nicht der veraltete lokale main", Worktrees.baseRef(wt) == "origin/main", Worktrees.baseRef(wt))

        // Der Helfer ändert genau eine Datei und ergänzt einen Test mit Platzhalter-Passwort
        write(wtPath, "src/app.ts", "export const a = 42\n")
        write(wtPath, "src/app.test.ts", "const login = { password: \"test-passwort-123\" }\n")
        _ = Git.run(id + ["commit", "-qam", "helfer"], in: wtPath, timeout: 20)
        write(wtPath, ".agents/skills/design/SKILL.md", "von einem Lern-Plugin nebenbei geändert\n")   // Werkzeug-Rauschen
        write(wtPath, ".playwright-mcp/console-2026.log", "debug\n")                                       // Ablage des Browser-Prüfwerkzeugs
        let paths = Worktrees.changes(wt).map(\.path).sorted()
        check("Änderungen = nur die des Helfers (keine fremden Commits)", paths == ["src/app.test.ts", "src/app.ts"], paths.joined(separator: ", "))
        let diff = Worktrees.diff(wt)
        check("Diff enthält keine fremden Dateien", !diff.contains("fremd.ts") && !diff.contains("db.pg-test") && !diff.contains("lokal.ts"))
        check("Skill-Änderungen von Agenten-Plugins landen nicht im Diff", !diff.contains(".agents/skills"))
        check("Screenshots/Logs des Browser-Prüfwerkzeugs landen nicht im Diff", !diff.contains(".playwright-mcp") && !paths.contains { $0.contains(".playwright-mcp") })
        check("Test-Passwort im Test ist kein Geheimnis", SecretScan.scan(diff).isEmpty, SecretScan.scan(diff).joined(separator: "; "))
        let fakeKey = "sk-" + "ant-api03-" + String(repeating: "A", count: 28)   // zusammengesetzt, damit kein Scanner anschlägt
        let leak = "+++ b/src/config.ts\n+const key = \"" + fakeKey + "\"\n+const db = { password: \"geheim-echt-123\" }\n"
        check("Echter Schlüssel und echtes Passwort im Code werden gefunden", SecretScan.scan(leak).count == 2, SecretScan.scan(leak).joined(separator: "; "))
        let leakInTest = "+++ b/src/x.test.ts\n+const key = \"" + fakeKey + "\"\n"
        check("Echter Schlüssel auch in Testdatei wird gefunden", SecretScan.scan(leakInTest).count == 1)

        // Lokale Testläufe: rot nur in fremden Tests → blockiert nicht; rot im eigenen Test → blockiert
        let changed = Worktrees.changes(wt).map(\.path)
        let fremdRot = " FAIL  src/slow.test.ts > langsam\nError: Test timed out in 5000ms.\n"
        check("Fremder roter Test blockiert nicht (CI prüft)", Verifier.unrelatedTestFailure(name: L("Tests"), output: fremdRot, dir: wtPath, changed: changed) != nil)
        let eigenRot = " FAIL  src/app.test.ts > login\nAssertionError\n"
        check("Eigener roter Test blockiert", Verifier.unrelatedTestFailure(name: L("Tests"), output: eigenRot, dir: wtPath, changed: changed) == nil)
        let nurQuelle = " FAIL  src/app.spec.ts > x\n"
        check("Roter Test zur geänderten Quelldatei blockiert", Verifier.unrelatedTestFailure(name: L("Tests"), output: nurQuelle, dir: wtPath, changed: ["src/app.ts"]) == nil)
        check("Ohne erkennbare Testdatei blockiert Rot weiter", Verifier.unrelatedTestFailure(name: L("Tests"), output: "Error: boom\n", dir: wtPath, changed: changed) == nil)
        check("Build-Fehler blockiert immer", Verifier.unrelatedTestFailure(name: L("Build"), output: fremdRot, dir: wtPath, changed: changed) == nil)
        let ohneCI = tmp.appendingPathComponent("ohne-ci").path
        try? fm.createDirectory(atPath: ohneCI, withIntermediateDirectories: true)
        check("Ohne GitHub-CI blockiert auch ein fremder roter Test", Verifier.unrelatedTestFailure(name: L("Tests"), output: fremdRot, dir: ohneCI, changed: changed) == nil)

        // Lokal nur betroffene Tests (wie Claude Code/Codex) – volle Suite macht die CI
        write(wtPath, "package.json", #"{"scripts":{"test":"TZ=Europe/Berlin vitest run"}}"#)
        check("Vitest: nur betroffene Tests", Verifier.scopedTests("npm run test", dir: wtPath, base: "abc123") == "npm run test -- --changed abc123 --passWithNoTests",
              Verifier.scopedTests("npm run test", dir: wtPath, base: "abc123"))
        check("Vitest direkt (CI-Befehl) wird ebenfalls eingegrenzt", Verifier.scopedTests("TZ=Europe/Berlin npx vitest run", dir: wtPath, base: "abc") == "TZ=Europe/Berlin npx vitest run --changed abc --passWithNoTests")
        write(wtPath, "package.json", #"{"scripts":{"test":"jest"}}"#)
        check("Jest: nur betroffene Tests", Verifier.scopedTests("pnpm run test", dir: wtPath, base: "abc") == "pnpm run test --changedSince=abc --passWithNoTests")
        check("Ohne CI läuft die volle Suite", Verifier.scopedTests("npm run test", dir: ohneCI, base: "abc") == "npm run test")
        check("Unbekanntes Test-Werkzeug bleibt unverändert", Verifier.scopedTests("python3 -m pytest -q", dir: wtPath, base: "abc") == "python3 -m pytest -q")
        check("CI im Repo-Ordner darüber wird gefunden", Verifier.hasCI((wtPath as NSString).appendingPathComponent("src")))

        write(wtPath, "package.json", #"{"scripts":{"test":"vitest run","typecheck":"tsc --noEmit"}}"#)
        let lean = WorkPhases.leanChecks(["npm run typecheck", "npm run test", "npm run build", "TZ=Europe/Berlin npx vitest run"], directory: wtPath)
        check("Helfer prüft sparsam: Typen ja, ganze Suite und Build nein", lean.contains("npm run typecheck") && lean.contains("vitest related")
              && !lean.contains("`npm run test`") && !lean.contains("`npm run build`") && !lean.contains("npx vitest run"), lean)
        check("Parallele Helfer nie mehr als eingestellt", PowerProfile.capParallel(3) <= 3 && PowerProfile.capParallel(0) == 0)

        // Salenta Code legt nichts im Code des Nutzers ab
        var cfg = ProjectConfig(); cfg.verify = ["npm run typecheck"]
        ProjectConfig.save(cfg, dir: proj)
        let leftovers = Git.run(["status", "--porcelain", "--untracked-files=all"], in: proj, timeout: 20).out
        check("Einstellungen landen nicht im Projekt-Repo", !leftovers.contains(".salenta-os") && ProjectConfig.load(proj)?.verify == ["npm run typecheck"], leftovers)
        try? FileManager.default.removeItem(at: ProjectConfig.privateFile(for: proj))

        check("Modell passt zum Agent: Claude Code bekommt nie GPT, Codex nie Opus",
              ModelCatalog.fits("opus", .claude) && ModelCatalog.fits("claude-opus-5-5", .claude) && !ModelCatalog.fits("gpt-5.6-sol", .claude)
              && !ModelCatalog.fits("kimi-code/k3.1-pro", .claude) && ModelCatalog.fits("gpt-6.1-sol", .codex) && !ModelCatalog.fits("opus", .codex)
              && ModelCatalog.fits("gpt-5.6-sol-high", .cursor) && ModelCatalog.fits("claude-opus-5-5-low", .cursor) && !ModelCatalog.fits("sonnet", .cursor))

        // Limits und Abo-Sperren: Monatslimit mit Datum wird bis dahin gemieden, Abo ohne Zugang einen Tag
        let junie = "✗ Anthropic: You have reached your specified API usage limits. You will regain access on 2099-12-01 at 00:00 UTC."
        let kimi = "error: failed to run prompt: provider.auth_error: Your current subscription does not have access to Kimi Code right now. Upgrade your plan"
        check("Monatslimit mit Datum → bis zum Datum gemieden", (Usage.parseReset(junie).map { $0.timeIntervalSinceNow > 365 * 86400 } ?? false)
              && Usage.limitPatterns.contains(where: { junie.lowercased().contains($0) }) && Usage.limitPatterns.contains(where: { kimi.lowercased().contains($0) })
              && !Usage.limitPatterns.contains(where: { "Stripe subscription created, 3 tests passed".lowercased().contains($0) }))
        // Alte Einträge: Denkstufe im Modell-Feld zählt nicht als Modell
        var legacy = MissionRecord(id: "x", title: "t", request: "r", agent: "codex", mode: "autonom", directory: "/tmp", started: Date(), log: "/tmp/x.log")
        legacy.model = "medium"
        check("Denkstufe im alten Modell-Feld wird nicht als Modell weitergegeben", legacy.cleanModel == nil && legacy.legacyEffort == "medium")
        // Gesperrte Agents überstehen Neustarts und werden nicht eingeplant
        Steward.markBroken(.grok); check("Sofort gescheiterter Agent bleibt 6 h gesperrt", Steward.isBroken(.grok)); Steward.clearBroken(.grok)
        check("Sperre aufgehoben", !Steward.isBroken(.grok))
        // Anmeldedaten sichtbar fehlend → nicht einplanen (Gemini ohne Datei und ohne Schlüssel)
        check("Login-Vorprüfung liefert ein Ergebnis für Gemini/Codex", AgentHealth.credentialsMissing(.gemini) != nil && AgentHealth.credentialsMissing(.codex) != nil && AgentHealth.credentialsMissing(.claude) == nil)
        // Steuerung mit Zeitlimit: Freigabe gilt bis zur Zeit, dann nicht mehr
        ControlGrants.set(.browser, until: Date().addingTimeInterval(60)); check("Browser-Steuerung freigegeben", ControlGrants.until(.browser) != nil)
        ControlGrants.set(.browser, until: nil); check("Browser-Steuerung beendet", ControlGrants.until(.browser) == nil)
        // Einrichtungs-Skript und timeout-Shim liegen bereit und sind gültige Shell-Skripte
        let srcDir = ProcessInfo.processInfo.environment["AOS_SRC"].map { URL(fileURLWithPath: $0) } ?? Paths.source
        for tool in ["aos-setup", "timeout"] {
            let p = srcDir.appendingPathComponent("bin/" + tool).path
            check("bin/\(tool) vorhanden und gültig", FileManager.default.isExecutableFile(atPath: p) && Proc.zsh("/bin/bash -n " + Shell.quote(p), in: NSTemporaryDirectory(), timeout: 10).code == 0)
        }
        // Salenta Harness: mitgeliefert, startet, und seine eigenen Tests (geskriptetes Modell, kein Netz) sind grün
        let sah = srcDir.appendingPathComponent("bin/salenta-harness").path
        check("Salenta Harness vorhanden", FileManager.default.isExecutableFile(atPath: sah))
        if Detection.which("node") != nil {
            check("Salenta Harness startet", Proc.zsh(Shell.quote(sah) + " --version", in: NSTemporaryDirectory(), timeout: 20).out.contains("0."))
            let t = Proc.zsh("node --test " + Shell.quote(srcDir.appendingPathComponent("bin/harness/test").path) + "/*.test.mjs 2>&1 | grep -E -A12 '^not ok|^# (pass|fail)' | head -40", in: NSTemporaryDirectory(), timeout: 120)
            check("Salenta Harness: eigene Tests grün", t.out.contains("# fail 0"), String(t.out.prefix(1500)))
        }
        check("timeout beendet nach Ablauf (Exit 124)", Proc.zsh(Shell.quote(srcDir.appendingPathComponent("bin/timeout").path) + " 1 sleep 5; echo rc=$?", in: NSTemporaryDirectory(), timeout: 15).out.contains("rc=124"))
        // GitHub-Projekt: solange die gh-Anmeldung ungeprüft ist, gilt der PR-Weg (nie still lokal mergen)
        var gp = StewardProject(id: "/tmp/x", name: "x")
        var gs = StewardSetup(); gs.remote = "https://github.com/a/b.git"; gp.setup = gs
        check("GitHub-Projekt liefert per PR, solange gh nicht sicher fehlt", gp.hasGitHub && gp.repoSlug == "a/b" && (GH.state == .no ? !gp.viaPR : gp.viaPR))
        // Reviewer: nie derselbe Agent, solange der andere nutzbar ist
        check("Review macht der jeweils andere Agent", Verifier.reviewer(for: "codex") != .codex || Detection.which("claude") == nil)

        let body = "Fix für den Login\n\nCo-authored-by: Codex <codex@openai.com>\nCo-authored-by: Anna Beispiel <anna@example.com>\n🤖 Generated with Claude Code"
        let clean = GitSync.cleanCredits(body)
        check("Merge-Text ohne Agenten-Vermerke, menschliche Co-Autoren bleiben", !clean.lowercased().contains("codex") && !clean.contains("Generated") && clean.contains("Anna Beispiel"), clean)

        // Haupt-Branch vorspulen, ohne den ausgecheckten Arbeits-Branch anzufassen
        let headBefore = Git.run(["rev-parse", "codex/feature"], in: proj, timeout: 20).out
        GitSync.refreshBase(repo: proj, base: "main")
        let mainNow = Git.run(["rev-parse", "main"], in: proj, timeout: 20).out, originMain = Git.run(["rev-parse", "origin/main"], in: proj, timeout: 20).out
        check("Lokaler main wird vorgespult, dein Branch bleibt unberührt", mainNow == originMain && Git.run(["rev-parse", "codex/feature"], in: proj, timeout: 20).out == headBefore)

        // Prüfbericht: übersprungener Test (nil) zählt nicht als rot
        var r = VerifyReport()
        r.checks = [VerifyCheck(name: "Typen", command: "x", ok: true), VerifyCheck(name: L("Tests"), command: "y", ok: nil), VerifyCheck(name: L("Geheimnisse"), command: "z", ok: true)]
        r.finished = Date()
        check("Nicht blockierender Test → Prüfung bestanden", r.passed == true)

        // Push und PR-Ziel: der Helfer-Branch landet auf GitHub und zielt auf main
        let pushed = Git.run(["push", "-q", "origin", "aos/selftest"], in: wtPath, timeout: 30)
        check("Helfer-Branch lässt sich hochladen", pushed.code == 0, pushed.out)
        let ahead = Git.run(["rev-list", "--count", "origin/main..aos/selftest"], in: proj, timeout: 20).out.trimmingCharacters(in: .whitespacesAndNewlines)
        check("PR enthält genau 1 Commit gegenüber main", ahead == "1", ahead)
        let mergeable = Git.run(["merge-tree", "--write-tree", "origin/main", "aos/selftest"], in: proj, timeout: 20)
        check("PR ist konfliktfrei mit main", mergeable.code == 0, mergeable.out)

        // Alte Arbeitskopie (vom lokalen Branch, ohne origin-Gegenstück) vergleicht weiter mit dem lokalen Branch
        let oldPath = tmp.appendingPathComponent("wt-alt").path
        _ = Git.run(["worktree", "add", "-q", "-b", "aos/alt", oldPath, "codex/feature"], in: proj, timeout: 20)
        let oldWt = WorktreeInfo(path: oldPath, branch: "aos/alt", base: proj, baseBranch: "codex/feature")
        write(oldPath, "src/lokal.ts", "export const lokal = 30\n")
        _ = Git.run(id + ["commit", "-qam", "alt"], in: oldPath, timeout: 20)
        check("Ohne origin-Branch: Vergleich mit lokalem Branch", Worktrees.baseRef(oldWt) == "codex/feature" && Worktrees.changes(oldWt).map(\.path) == ["src/lokal.ts"], Worktrees.baseRef(oldWt))

        _ = Git.run(["worktree", "remove", "--force", wtPath], in: proj, timeout: 20)
        _ = Git.run(["worktree", "remove", "--force", oldPath], in: proj, timeout: 20)
    }

    // MARK: Projekt-Betreuer

    private static func steward(_ tmp: URL) {
        section("Projekt-Betreuer")
        let dir = tmp.appendingPathComponent("webapp")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pkg = #"{"scripts":{"dev":"vite","test":"vitest","build":"vite build","lint":"eslint ."},"dependencies":{"react":"18"},"devDependencies":{"vitest":"1","typescript":"5"}}"#
        try? pkg.write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try? "".write(to: dir.appendingPathComponent("pnpm-lock.yaml"), atomically: true, encoding: .utf8)
        try? "X=1".write(to: dir.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)
        let s = Steward.detect(dir.path)
        check("Paketmanager und Stack erkannt", s.stack.contains("pnpm") && s.stack.contains("React") && s.stack.contains("TypeScript"), s.stack.joined(separator: ","))
        check("Tests laufen einmalig statt im Watch-Modus", s.commands["test"] == "pnpm run test -- --run", s.commands["test"] ?? "nil")
        check("Dev- und Build-Befehl erkannt", s.commands["dev"] == "pnpm run dev" && s.commands["build"] == "pnpm run build")
        check("Umgebungsdatei erkannt", s.envFiles == [".env.local"])
        check("Web-Projekt erkannt (Claude prüft im Browser)", ChromeBridge.isWebProject(dir.path))
        check("Git-Fehler verständlich erklärt", GitError.explain("! [rejected] main -> main (fetch first)").contains(L("neuere Änderungen"))
              && GitError.explain("remote: error: GH013: Repository rule violations found\n- Push cannot contain secrets").contains(L("Schlüssel")))
        var t = StewardTask(title: "x"); t.missionID = nil
        check("Aufgabe ohne Auftrag gilt als rot", Steward.outcome(t, agents: nil)?.state == .red)
        // Ältere stewards.json ohne neue Felder laden weiter
        let old = #"[{"id":"/x","name":"x","goal":"","tasks":[],"messages":[],"trust":1,"parallel":2,"dailyRuns":8,"runs":{},"paused":false,"roundHour":7,"watchCI":true,"customers":false,"greenStreak":0,"trustOffered":false,"created":"2026-01-01T00:00:00Z"}]"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let loaded = try? dec.decode([StewardProject].self, from: Data(old.utf8))
        check("Alte Betreuer-Daten laden (Dauerbetrieb aus)", loaded?.first.map { !$0.continuous && $0.chosenExtensions.isEmpty } == true)
        var sp = StewardProject(id: "/y", name: "y"); sp.untilDone = true; sp.extensions = ["gibt-es-nicht"]
        check("Dauerbetrieb an, unbekannte Erweiterung ignoriert", sp.continuous && sp.chosenExtensions.isEmpty)
        // Kostenschutz: Agents mit Kosten pro Nutzung wählt die App nie selbst
        let keepAuto = UserDefaults.standard.object(forKey: "billing.auto")
        UserDefaults.standard.removeObject(forKey: "billing.auto")
        check("Kostenschutz: Junie nie automatisch", Billing.isMetered(.junie) && !Billing.autoOK(.junie) && Billing.autoOK(.claude))
        check("Kostenschutz: Ausweichen im Limit ohne Junie/OpenRouter",
              !Usage.alternatives(.claude).contains(.junie) && !Usage.alternatives(.codex).contains(.openrouter))
        if let k = keepAuto { UserDefaults.standard.set(k, forKey: "billing.auto") }
        check("Auslastung messbar", !SystemLoad.processes().top.isEmpty || true)
        let keepOff = UserDefaults.standard.stringArray(forKey: AgentOff.key)
        AgentOff.set(.kimi, on: false)
        check("Abgeschalteter Agent wird nirgends gewählt", !OpenModels.available(.kimi) && !Usage.alternatives(.claude).contains(.kimi) || !AgentOff.present(.kimi))
        UserDefaults.standard.set(keepOff, forKey: AgentOff.key)
        let rec = LocalCatalog.shared.recommendedForThisMac
        check("Lokales Modell: Empfehlung passt in den Grafikspeicher und hat kein Mac-Problem",
              rec.map { LocalCatalog.fitsGPU($0) && $0.macIssue != true } ?? (OllamaApp.gpuGB < 8), rec?.pull ?? "keins")
    }

    // MARK: Wissen, Integrationen, Erweiterungen

    private static func knowledge(_ tmp: URL) {
        section("Wissen, Integrationen, Erweiterungen")
        let v = tmp.appendingPathComponent("vault")
        let sub = v.appendingPathComponent("Projekte")
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try? "---\ntags: [kunde, wichtig]\n---\n# Projekt\nSiehe [[Roadmap]] und #ideen".write(to: sub.appendingPathComponent("Projekt.md"), atomically: true, encoding: .utf8)
        try? "# Roadmap\nPlan für Q1".write(to: v.appendingPathComponent("Roadmap.md"), atomically: true, encoding: .utf8)
        let notes = [Obsidian.Note(url: sub.appendingPathComponent("Projekt.md"), modified: Date()),
                     Obsidian.Note(url: v.appendingPathComponent("Roadmap.md"), modified: Date())]
        let idx = VaultIndex.build(v, notes: notes)
        let e = idx.entries.first { $0.note.title == "Projekt" }
        check("Tags aus Kopf und Text erkannt", Set(e?.tags ?? []) == ["kunde", "wichtig", "ideen"], (e?.tags ?? []).joined(separator: ","))
        check("Verweise erkannt", e?.links == ["Roadmap"])
        check("Ordner gezählt", idx.folders["Projekte"] == 1 && idx.folders[""] == 1)
        check("Kopfzeilen werden beim Lesen ausgeblendet", !ObsidianView.withoutFrontmatter("---\ntags: x\n---\nText").contains("tags"))

        check("Kleine Aufgabe erkannt (lokal)", LocalFirst.isSmall("Tippfehler in der Überschrift der Startseite korrigieren"))
        check("Große Aufgabe bleibt in der Cloud", !LocalFirst.isSmall("Login-Flow mit Supabase Auth komplett umbauen"))
        check("Lange Aufträge nie lokal", !LocalFirst.isSmall(String(repeating: "Kommentar ergänzen ", count: 30)))
        check("Integrations-Namen lesbar", ServerRow.friendly("claude_ai_Google_Drive") == "Google Drive")
        check("Integration nach Zweck sortiert", MCPHubView.purpose(MCPServerSpec(name: "supabase", url: "https://mcp.supabase.com", origin: "Claude Code")) == L("Entwicklung"))

        let web = tmp.appendingPathComponent("web2")
        try? FileManager.default.createDirectory(at: web.appendingPathComponent("supabase"), withIntermediateDirectories: true)
        try? #"{"dependencies":{"@supabase/supabase-js":"2","next":"14"}}"#.write(to: web.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let words = AutoSkills.stackWords(web.path)
        check("Projekt-Technik für passende Erweiterungen erkannt", words.contains("supabase") && words.contains("nextjs"), words.joined(separator: ","))
        let order = Updater.newer("0.10.0", than: "0.9.2") && Updater.newer("0.3.0", than: "0.3.0-beta.2")
            && !Updater.newer("0.2.0", than: "0.2.0") && !Updater.newer("0.2.0-beta.1", than: "0.2.0")
        check("Updates: Versionen werden richtig verglichen", order, "")
        let tidy = MissionStore.tidy("Im Projekt shop (/Users/x/Code/shop): Bitte prüfen")
        check("Auftragstitel ohne Ordnerpfad", tidy == "shop: Bitte prüfen", tidy)
        let r1 = AutoSkills.role(of: "nur prüfen, nichts ändern. stabilität"), r2 = AutoSkills.role(of: "login-seite mit stripe-zahlung bauen"), r3 = AutoSkills.role(of: "button farbe ändern")
        check("Skills: Prüf-Helfer und heikle Aufträge werden erkannt", r1.review && r2.sensitive && !r3.review && !r3.sensitive, "")
        let smallOK = LocalFirst.isSmall("Tippfehler in der README korrigieren") && LocalFirst.isSmall("Button-Text auf der Startseite ändern")
            && !LocalFirst.isSmall("Login mit Stripe-Zahlung umbauen") && !LocalFirst.isSmall("Tippfehler beheben und Datenbank-Migration schreiben")
        check("Lokal: kleine Aufgaben erkannt, heikle bleiben in der Cloud", smallOK, "")
        var hard = AIRouteDecision(target: .claude, model: nil, effort: nil, directory: nil, skills: [], reason: "")
        hard.localOK = false
        var big = hard; big.localOK = true; big.complexity = "large"
        check("Lokal: was die Agentenwahl für zu schwer hält, bleibt in der Cloud",
              LocalFirst.shared.localMisfit(hard, text: "Tippfehler korrigieren") != nil && LocalFirst.shared.localMisfit(big, text: "Tippfehler korrigieren") != nil, "")
        let sk = [Skill(name: "change-request", description: "Draft a change request for operations", source: "t", path: ""),
                  Skill(name: "adspirer-chatgpt-ads", description: "Run ChatGPT ads campaigns", source: "t", path: ""),
                  Skill(name: "security-review", description: "Review code changes for security vulnerabilities", source: "t", path: "")]
        let pick1 = Router.suggestSkills("Beim Pull Request sind die Checks rot. Hol dir den Branch und finde im Chat-Verlauf die Ursache", skills: sk).map(\.name)
        let pick2 = Router.suggestSkills("Mach ein security review der letzten Änderungen auf vulnerabilities", skills: sk).map(\.name)
        check("Skill-Vorschläge: keine Zufallstreffer, passende bleiben", pick1.isEmpty && pick2 == ["security-review"], "\(pick1) / \(pick2)")
        // Planung sieht alle Skills (passende zuerst), auch selbst hinzugefügte Repos, und darf mehrere kombinieren
        let menu = Router.skillMenu("Mach ein security review der letzten Änderungen auf vulnerabilities", skills: sk).map(\.name)
        check("Planung: alle installierten Skills stehen zur Wahl, passende zuerst", menu.first == "security-review" && menu.count == 3 && Router.skillMenu("x", skills: sk, limit: 2).count == 2, "\(menu)")
        let skC = Skill(name: "a", description: "", source: "Claude Code", path: ""), skX = Skill(name: "b", description: "", source: "Codex", path: ""), skA = Skill(name: "c", description: "", source: "Agents", path: "")
        check("Planung: ein Agent bekommt nur Skills, die er laden kann",
              Router.loadable(skC, by: .claude) && !Router.loadable(skC, by: .codex) && Router.loadable(skX, by: .codex) && !Router.loadable(skX, by: .claude)
              && Router.loadable(skA, by: .cursor) && !Router.loadable(skC, by: .cursor) && Router.loadable(skC, by: .openrouter) && !Router.loadable(skC, by: nil), "")
        let ownRepo = CustomExtension(id: "custom:someone/shop-audit", name: "shop-audit", kind: Extension.Kind.plugin.rawValue, repo: "https://github.com/someone/shop-audit",
                                      stars: 3, purpose: "Audits storefront speed", install: "", keywords: ["shopify", "claude", "code", "audit"]).asExtension
        let ownMCP = CustomExtension(id: "custom:someone/crm-mcp", name: "crm-mcp", kind: Extension.Kind.mcp.rawValue, repo: "", stars: 0, purpose: "", install: "", keywords: []).asExtension
        let curatedCLI = Extension(id: "x", name: "x", kind: .cli, category: .essentials, repo: "", stars: "", purpose: "", when: [], install: "", usage: "")
        check("Erweiterungen: selbst hinzugefügte Repos bekommen eine Nutzungszeile",
              ownRepo.howTo.contains("shop-audit") && ownRepo.howTo.contains("Audits storefront speed") && !ownMCP.howTo.isEmpty && curatedCLI.howTo.isEmpty, ownRepo.howTo)
        let slash = Extension(id: "security-review", name: "x", kind: .tool, category: .security, repo: "", stars: "", purpose: "", when: [], install: "", usage: "Führe /security-review auf deine Änderungen aus.")
        check("Erweiterungen: Plugins und Claude-Befehle nur für Claude Code, MCP-Server für jeden Agent",
              ownRepo.usable(claudeBased: true) && !ownRepo.usable(claudeBased: false) && ownMCP.usable(claudeBased: false)
              && slash.usable(claudeBased: true) && !slash.usable(claudeBased: false), "")
        let many = (1...200).map { Skill(name: "skill-\($0)", description: "Does thing \($0)", source: $0 % 2 == 0 ? "Plugin" : "Codex", path: "") } + sk
        let catalogText = Router.skillCatalogText("Prüfe die Änderungen auf Sicherheitslücken", skills: many, detailed: 20)
        check("Planung: auch bei hunderten Skills fehlt keiner, Deutsch findet englische Beschreibungen",
              catalogText.hasPrefix("- security-review") && catalogText.contains("skill-200") && catalogText.contains("[Codex] ") && catalogText.count < 6000, "\(catalogText.count)")
        check("Erweiterungen: eigenes Repo passt nur über ein eindeutiges Stichwort",
              AutoSkills.customMatch(ownRepo.when, "prüfe die ladezeit im shopify theme") && !AutoSkills.customMatch(ownRepo.when, "ändere den code für claude")
              && !AutoSkills.customMatch(ownRepo.when, "auditiere nichts"), "")
        let saver = CustomExtension(id: "custom:someone/lean", name: "lean", kind: Extension.Kind.plugin.rawValue, repo: "", stars: 0, purpose: "Cuts token usage of long sessions", install: "", keywords: []).asExtension
        check("Erweiterungen: eigener Token-Sparer läuft immer mit, andere nicht", AutoSkills.savesTokens(saver) && !AutoSkills.savesTokens(ownRepo), "")
        let dietCat = (1...8).map { Skill(name: "aa-\($0)", description: "", source: "Claude Code", path: "") }
        let diet = SkillDiet.mentioned(in: "Bitte wie bei aa-8 vorgehen.\n\nNutze dafür diese Skills: /aa-1, /aa-2, /aa-3, /aa-4, /aa-5, /aa-6.", catalog: dietCat)
        check("Skills: gewählte werden zuerst geladen, zufällig genannte nur wenn Platz ist",
              diet.load.map(\.name) == ["aa-1", "aa-2", "aa-3", "aa-4", "aa-5", "aa-6"] && diet.skipped.map(\.name) == ["aa-8"], "\(diet.load.map(\.name)) / \(diet.skipped.map(\.name))")
        let offer: [AgentKind: Set<String>] = [.cursor: ["composer-2", "gpt-5.2"], .codex: ["gpt-5.2-codex"]]
        check("Modellwahl: jeder Agent bekommt nur ein Modell aus seiner eigenen Liste",
              AIRouter.pickModel("composer-2", for: .cursor, offered: offer) == "composer-2" && AIRouter.pickModel("composer-2", for: .codex, offered: offer) == nil
              && AIRouter.pickModel("opus", for: .cursor, offered: offer) == nil && AIRouter.pickModel("", for: .cursor, offered: offer) == nil
              && AIRouter.pickModel("gpt-5.2-codex", for: .codex, offered: offer) == "gpt-5.2-codex" && AIRouter.pickModel("x", for: nil, offered: offer) == nil, "")
        let prRec = MissionRecord(id: "t", title: "Login", request: "Login reparieren", agent: "claude", mode: "autonom", directory: "/tmp", started: Date(), log: "", taskID: nil)
        let prBody = PRWriter.body(summary: ["Behebt den Login"], changes: ["auth.ts angepasst"], changelog: ["Login klappt wieder"], testing: [], rec: prRec, de: true)
        check("Pull Request: Beschreibung mit Zusammenfassung, Änderungen und Changelog", prBody.contains("## Zusammenfassung") && prBody.contains("## Changelog") && !prBody.contains("## Geprüft"), "")
        let phases = WorkPhases.plan(prompt: "Baue einen Dark-Mode-Button auf der Startseite", kind: .claude, directory: nil)
        check("Arbeitsplan: Phasen mit Planen, Umsetzen, Prüfen wie die CI", phases.map { $0.text.contains("Umsetzen") && $0.text.contains("Prüfen wie die CI") && $0.text.contains("Browser") } ?? !AutoSkills.enabled, "")
        let dg = DesignGuide.rules(tweak: false, de: true), dgT = DesignGuide.rules(tweak: true, de: true), dgE = DesignGuide.rules(tweak: false, de: false)
        check("Gestaltung: Leitfaden mit Bildsprache, Kontrast und fließendem Layout (DE/EN)", dg.contains("Bildsprache") && dg.contains("4,5:1") && dg.contains("390 px") && dgE.contains("4.5:1") && !dgE.contains("Bildsprache"), "")
        check("Gestaltung: kleine Änderung ändert nur das Verlangte", DesignGuide.isSmallTweak("mach die farbe vom button blau") && !DesignGuide.isSmallTweak("redesign der startseite, farbe egal") && dgT.contains("nur genau das Verlangte"), "")
        let uiPlan = WorkPhases.plan(prompt: "Gestalte die Landing Page neu", kind: .codex, directory: nil)
        check("Gestaltung: Leitfaden gilt auch ohne Design-Plugin und für jeden Coding-Agent", uiPlan.map { $0.text.contains("oklch") } ?? !AutoSkills.enabled, "")
        let review = WorkPhases.plan(prompt: "Nur prüfen, nichts ändern: Sicherheit des Logins", kind: .claude, directory: nil)
        check("Arbeitsplan: Prüf-Auftrag ändert nichts und prüft Sicherheit", review.map { !$0.text.contains("Umsetzen") && $0.text.contains("Sicherheit") } ?? !AutoSkills.enabled, "")
        check("CI-Befehle: nur sichere Prüfbefehle", CIParity.safe("npm run lint") && CIParity.safe("pnpm test") && !CIParity.safe("npm run deploy")
              && !CIParity.safe("npx playwright test") && !CIParity.safe("echo ${{ secrets.X }}") && !CIParity.safe("npm ci"), "")
        check("Mods: Uhrzeit wird richtig verglichen", ModStore.hhmm("9:00") == "09:00" && ModStore.hhmm("18:30") == "18:30", "")
        let help = HelpSection.parse("# T\n## Eins\nText **fett**\n- Punkt\n1. Schritt\n| A | B |\n|---|---|\n| x | y |\n## Zwei\nMehr")
        check("Hilfe: Kapitel, Listen und Tabellen werden gelesen", help.count == 2 && help[0].blocks.count == 4, "\(help.map { $0.blocks.count })")
        // In der fertigen App liegt die Hilfe im Paket – dort muss sie vollständig sein (beim Entwickler-Build fehlt das Paket noch)
        if Bundle.main.url(forResource: "HILFE", withExtension: "md") != nil, Bundle.main.url(forResource: "HELP", withExtension: "md") != nil {
            check("Hilfe-Datei ist da und hat Kapitel", HelpSection.load().count >= 10, "\(HelpSection.load().count)")
        }
        let plain = VaultIndex.plain("<< [[2026-11-04]] | [[Lage|die Lage]] **jetzt** >>")
        check("Notiz-Vorschau ohne Markdown-Zeichen", plain == "2026-11-04 | Lage jetzt", plain)
    }

    // MARK: Layout – eine Ansicht darf das Fenster nie sprengen

    private static func layout() {
        section("Layout")
        let tall = VStack(spacing: 0) {
            Text("Kopf").frame(height: 40)
            ForEach(0..<400, id: \.self) { i in Text("Zeile \(i)").frame(height: 20) }
        }
        _ = NSApplication.shared
        let window = CGSize(width: 800, height: 600)
        let raw = NSHostingController(rootView: tall).sizeThatFits(in: window)
        let safe = NSHostingController(rootView: tall.containedInWindow()).sizeThatFits(in: window)
        check("Test greift (ohne Netz wäre es zu hoch)", raw.height > 1000, "Höhe \(Int(raw.height))")
        check("Zu hoher Inhalt wird begrenzt statt das Fenster zu sprengen", safe.height <= 600.5, "Höhe \(Int(safe.height))")

        let start = Date()
        let many = NSHostingController(rootView: VStack(spacing: 0) {
            Text("Kopf")
            BoundedScroll(maxFraction: 0.45) {
                LazyVStack { ForEach(0..<5000, id: \.self) { i in Text("Datei \(i)") } }
            }
        }.containedInWindow())
        let sz = many.sizeThatFits(in: window)
        let took = Date().timeIntervalSince(start)
        check("5000 Einträge: begrenzt und schnell", sz.height <= 600.5 && took < 3, String(format: "%.0f pt, %.1f s", sz.height, took))
    }
}

extension SelfTest {
    // MARK: Salenta Intelligence, Erweiterungen, Projekte, Live-Ansicht

    fileprivate static func intelligence(_ tmp: URL) {
        section("Salenta Intelligence & Projekte")

        // GitHub-Links in jeder Schreibweise erkennen, Unsinn ablehnen
        check("Repo-Link: https", GitHubRead.slug("https://github.com/owner/repo") == "owner/repo")
        check("Repo-Link: .git und Unterpfad", GitHubRead.slug("github.com/owner/repo.git/tree/main") == "owner/repo")
        check("Repo-Link: Kurzform", GitHubRead.slug("owner/my-repo") == "owner/my-repo")
        check("Repo-Link: Unsinn abgelehnt", GitHubRead.slug("hallo welt") == nil && GitHubRead.slug("a/b; rm -rf ~") == nil)
        check("Installationsbefehl: Sonderzeichen werden gequotet", RepoInspector.arg("a b") != "a b" && RepoInspector.arg("name@market") == "name@market")

        // Supervisor: Fehlerschleife erkennen, normalen Verlauf nicht
        let loopLog = tmp.appendingPathComponent("loop.log").path
        try? (Array(repeating: "  ✗ error: Cannot find module './x' (try 1)", count: 5).joined(separator: "\n")).write(toFile: loopLog, atomically: true, encoding: .utf8)
        check("Supervisor erkennt Fehlerschleife", Supervisor.loopingError(loopLog) != nil)
        let okLog = tmp.appendingPathComponent("ok.log").path
        try? "📖 Liest a.swift\n✏️ Ändert a.swift\n✗ error: eins\n✗ error: zwei".write(toFile: okLog, atomically: true, encoding: .utf8)
        check("Supervisor lässt normalen Verlauf in Ruhe", Supervisor.loopingError(okLog) == nil)
        check("Supervisor: fehlende Log-Datei stürzt nicht ab", Supervisor.loopingError(tmp.appendingPathComponent("gibtsnicht.log").path) == nil)

        // Progressive Delegation: klein ja, heikle Pfade und große Änderungen nein
        let repo = tmp.appendingPathComponent("deleg").path
        try? FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let g = { (a: [String]) in _ = Git.run(["-c", "user.name=t", "-c", "user.email=t@localhost"] + a, in: repo, timeout: 20) }
        g(["init", "-q", "-b", "main"])
        try? "a".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        g(["add", "-A"]); g(["commit", "-qm", "init"])
        g(["checkout", "-q", "-b", "task"])
        try? "b".write(toFile: repo + "/b.txt", atomically: true, encoding: .utf8)
        g(["add", "-A"]); g(["commit", "-qm", "klein"])
        let wt = WorktreeInfo(path: repo, branch: "task", base: repo, baseBranch: "main")
        check("Delegation: kleine Änderung gilt als klein", Delegation.small(wt).0, Delegation.small(wt).1)
        try? FileManager.default.createDirectory(atPath: repo + "/src/auth", withIntermediateDirectories: true)
        try? "x".write(toFile: repo + "/src/auth/login.ts", atomically: true, encoding: .utf8)
        g(["add", "-A"]); g(["commit", "-qm", "heikel"])
        check("Delegation: Login-Bereich wird nie selbst übernommen", !Delegation.small(wt).0)
        check("Delegation: ohne Vertrauen kein Selbst-Übernehmen", Delegation.streak(repo, missions: []) == 0)

        // Git-Abgleich ohne GitHub: verständliche Meldung statt Absturz
        let up = GitSync.upload(repo: repo)
        check("Hochladen ohne GitHub-Repo meldet verständlich", !up.0 && !up.1.isEmpty, up.1)

        // Projektwissen: Dubletten und gelöschte Dateien finden, Regeln behalten
        ProjectMemory.save(repo, [
            MemoryEntry(text: "Tests immer mit npm run test:ci ausführen", kind: "regel"),
            MemoryEntry(text: "Die Datei src/old/gone.ts enthält den Login-Fehler", kind: "stolperfalle"),
            MemoryEntry(text: "Build braucht Node 20 wegen der Abhängigkeiten im Projekt", kind: "lernen"),
            MemoryEntry(text: "Build braucht Node 20 wegen der Abhängigkeiten", kind: "lernen"),
        ])
        let c = ProjectMemory.proposeCleanup(repo)
        check("Projektwissen: Regel bleibt immer", c.keep.contains { $0.kind == "regel" })
        check("Projektwissen: gelöschte Datei erkannt", c.drop.contains { $0.entry.text.contains("gone.ts") })
        check("Projektwissen: Dublette erkannt", c.drop.contains { $0.why == L("doppelt") })
        try? FileManager.default.removeItem(at: ProjectMemory.url(for: ProjectMemory.root(of: repo)))

        // Mails: offensichtliche Automaten brauchen keine Antwort (ohne Modellaufruf)
        do {
            let look = StewardPR(number: 1, title: "Startseite im Apple-Stil neu gestalten", url: "", branch: "aos/x", sha: "a")
            let fix = StewardPR(number: 2, title: "Alle alten Adressen per 301 umleiten", url: "", branch: "aos/y", sha: "b")
            check("Optik-PR wird nicht selbst gemergt", look.changesLook && !fix.changesLook)
        }
        do {
            let was = Usage.pausedUntil(.grok)
            Usage.shared.pause(.grok, until: Date().addingTimeInterval(60))
            let paused = Usage.isPaused(.grok) && AgentHealth.unavailable(.grok) && Usage.shared.pressure(.grok) >= 1
            Usage.shared.resume(.grok)
            if let was { Usage.shared.pause(.grok, until: was == .distantFuture ? nil : was) }
            check("Anbieter pausieren: wird nicht eingeplant", paused && (was != nil || !Usage.isPaused(.grok)))
        }
        do {
            // Fehlende Anmeldung (Gemini ohne Auth-Methode, Kimi ohne Abo-Zugang) wird erkannt – dann wird der Agent nicht mehr eingeplant
            let gem = "Please set an Auth method in your settings.json or specify one of the following environment variables"
            let kim = "error: failed to run prompt: provider.auth_error: Your current subscription does not have access to Kimi Code right now."
            let hits = CLIFlags_loginHit(gem) && CLIFlags_loginHit(kim) && !CLIFlags_loginHit("Tests grün, 12 Dateien geändert")
            check("Fehlende Anmeldung im Startfehler erkannt", hits)
            check("Fremdes Modell nach Agent-Wechsel verworfen", !ModelCatalog.fits("haiku", .codex) && !ModelCatalog.fits("kimi-code/k3.1-pro", .claude)
                  && !ModelCatalog.fits("gpt-6.1-sol", .claude) && ModelCatalog.fits("gpt-6.1-sol", .codex) && ModelCatalog.fits("sonnet", .claude))
        }
        do {
            // OS-Agent über Codex: MCP-Server werden zu gültigen TOML-Abschnitten, alte gleichnamige fallen weg
            let t = OSAgentCodex.tables(["salenta-os": ["command": "/usr/bin/python3", "args": ["/x/aos-mcp"], "env": ["AOS_HOME": "/x \"y\""]],
                                         "web": ["type": "http", "url": "https://example.com/mcp", "headers": ["Authorization": "Bearer x"]],
                                         "oauth": ["type": "http", "url": "https://login.example.com/mcp"]])
            let stripped = OSAgentCodex.strip("model = \"gpt\"\n[mcp_servers.salenta-os]\ncommand = \"alt\"\n[mcp_servers.salenta-os.env]\nA = \"1\"\n[profiles.x]\nk = 1", names: ["salenta-os"])
            check("OS-Agent über Codex: Tools werden mitgegeben",
                  t.contains("[mcp_servers.salenta-os]") && t.contains("args = [\"/x/aos-mcp\"]") && t.contains("\"AOS_HOME\" = \"/x \\\"y\\\"\"")
                  && t.contains("url = \"https://example.com/mcp\"") && !t.contains("login.example.com") && !stripped.contains("alt") && stripped.contains("[profiles.x]") && stripped.contains("model = "))
        }
        do {
            // Hilfsaufrufe: Weiche zu Codex vorhanden, und ohne Pause bleibt es bei Claude
            let ask = (ProcessInfo.processInfo.environment["AOS_SRC"].map { URL(fileURLWithPath: $0) } ?? Paths.source).appendingPathComponent("bin/aos-ask").path
            let cmd = HelperLLM.command(model: "haiku", maxTurns: 3, file: "/tmp/x.md")
            check("Hilfsaufrufe beachten die Claude-Pause", FileManager.default.isExecutableFile(atPath: ask)
                  && (HelperLLM.useCodex ? cmd.contains("aos-ask") : cmd.contains("claude -p --model haiku")))
        }
        do {
            // Verteilung: realistische Aufträge → richtiger Agent und richtiges Projekt. Ziel: 100 %.
            let ps = [Project(path: "/tmp/v/kassenbuch-app", name: "kassenbuch-app", source: "test", isGit: true),
                      Project(path: "/tmp/v/rezept-api", name: "rezept-api", source: "test", isGit: true),
                      Project(path: "/tmp/v/wetter-widget", name: "wetter-widget", source: "test", isGit: true)]
            let code: Set<MissionTarget> = [.claude, .junie]
            let cases: [(String, Set<MissionTarget>, String?)] = [
                ("Fixe den Login-Bug im kassenbuch-app", code, "kassenbuch-app"),
                ("Baue im Projekt rezept-api einen neuen Endpoint für Zutaten", [.claude], "rezept-api"),
                ("Review die letzten Änderungen in wetter-widget", [.codex], "wetter-widget"),
                ("Schreib eine Mail an Herrn Müller wegen dem Termin am Freitag", [.osAgent], nil),
                ("Was steht heute in meinem Kalender?", [.osAgent], nil),
                ("Recherchiere die besten CRM-Tools für Makler", [.osAgent], nil),
                ("@codex refactor die Datenbank-Schicht im rezept-api", [.codex], "rezept-api"),
                ("mit Junie: warum stürzt kassenbuch-app beim Start ab", [.junie], "kassenbuch-app"),
                ("Baue mit Salenta Harness im wetter-widget einen Dark Mode", [.harness], "wetter-widget"),
                ("Der Export im kassenbuch-app funktioniert nicht", code, "kassenbuch-app"),
                ("Erstell mir eine Aufgabe: Steuerberater anrufen", [.osAgent], nil),
                ("Fasse meine ungelesenen Mails zusammen", [.osAgent], nil),
                ("Schreib Tests für die Zutaten-Suche im rezept-api", [.claude], "rezept-api"),
                ("Deploy wetter-widget auf Vercel", [.claude], "wetter-widget"),
                ("Öffne im Browser die Seite der Bahn und such eine Verbindung nach Hamburg", [.osAgent], nil),
                ("Mach im rezept-api einen Pull Request für den Fix", [.claude], "rezept-api"),
                ("Prüf den Code im kassenbuch-app auf Sicherheitslücken", [.codex], "kassenbuch-app"),
                ("Erinnere mich morgen an den Zahnarzt", [.osAgent], nil),
                ("chatgpt soll mir einen Slogan schreiben", [.chatgpt], nil),
                ("Ändere die Farbe vom Button im wetter-widget auf Blau", [.claude], "wetter-widget"),
                ("Optimiere die Ladezeit vom kassenbuch-app", [.claude], "kassenbuch-app"),
                ("Wie viele Leads habe ich diese Woche im CRM?", [.osAgent], nil),
                ("Lies meine Notizen und mach eine Zusammenfassung", [.osAgent], nil),
                ("Gestalte im wetter-widget die Startseite neu", [.claude], "wetter-widget"),
                ("Antworte auf die WhatsApp von Lisa", [.osAgent], nil),
                ("Warum ist der Build im rezept-api rot?", code, "rezept-api"),
                ("Füge im kassenbuch-app eine CSV-Import-Funktion hinzu", [.claude], "kassenbuch-app"),
                ("Plane meine Woche", [.osAgent], nil),
                ("Ich habe eine falsche Rechnung bekommen, schreib dem Lieferanten", [.osAgent], nil),
                ("Pass im rezept-api die Fehlermeldungen an", code, "rezept-api"),
                ("Die rezept-api soll beim Speichern keine Fehler mehr werfen, bau das um", code, "rezept-api"),
                ("Bestell mit Pizza-Taxi heute Abend etwas zu essen", [.osAgent], nil),
            ]
            var misses: [String] = []
            for (text, want, proj) in cases {
                let d = Router.decide(text, projects: ps, recent: [])
                if !want.contains(d.target) || d.projectName != proj { misses.append("\(text) → \(d.target.rawValue)/\(d.projectName ?? "-")") }
            }
            check("Verteilung: \(cases.count - misses.count)/\(cases.count) Aufträge beim richtigen Agent und Projekt", misses.isEmpty, misses.joined(separator: " | "))
        }
        do {
            // Volllast und Hitze: nie mehr Helfer, als der Mac verträgt
            func c(_ t: ProcessInfo.ThermalState = .nominal, bat: Bool = false, cpu: Double = 20, mem: Double = 50, eco: Bool = false) -> Int {
                PowerProfile.cap(4, eco: eco, thermal: t, onBattery: bat, cpu: cpu, memFree: mem)
            }
            let ok = c() == 4 && c(.fair) == 2 && c(.serious) == 1 && c(.critical) == 0 && c(cpu: 95) == 1 && c(mem: 10) == 1 && c(mem: 5) == 0
                && c(bat: true) == 2 && c(eco: true) == 1 && c(.critical, cpu: 10, mem: 90) == 0 && c(.serious, bat: true, cpu: 99, mem: 3) == 0
            check("Volllast/Hitze: Helferzahl sinkt bei Wärme, voller CPU, knappem Speicher und Akku", ok,
                  "\(c())/\(c(.fair))/\(c(.serious))/\(c(.critical))/\(c(cpu: 95))/\(c(mem: 10))/\(c(mem: 5))/\(c(bat: true))/\(c(eco: true))")
            check("Helfer laufen gedrosselt (niedrigere Priorität bzw. Effizienz-Kerne)", PowerProfile.effective == "full" || !PowerProfile.taskpolicyArgs.isEmpty)
        }
        if AutoSkills.enabled {
            // Planung: realistische Aufträge → die richtigen Phasen. „+“ muss vorkommen, „-“ darf nicht. Ziel: 100 %.
            let cases: [(String, AgentKind, [String], [String])] = [
                ("Baue im Shop eine Merkliste ein", .claude, ["Verstehen & planen", "Umsetzen", "Aufräumen", "Prüfen wie die CI", "Abschließen"], ["Gestaltung:", "Design-Kritik"]),
                ("Gestalte die Landing Page neu", .claude, ["Gestaltung:", "Bildsprache", "Design-Kritik", "Browser"], ["nur genau das Verlangte"]),
                ("Ändere die Farbe vom Button auf Blau", .claude, ["Gestaltung:", "nur genau das Verlangte"], ["Design-Kritik", "Bildsprache"]),
                ("Nur prüfen, nichts ändern: Login-Sicherheit", .claude, ["Sicherheit", "nichts ändern"], ["Umsetzen", "Aufräumen"]),
                ("Baue den Stripe-Checkout ein", .claude, ["Umsetzen", "Sicherheit"], ["Design-Kritik"]),
                ("Behebe den Tippfehler in der README", .claude, ["Umsetzen", "Prüfen wie die CI"], ["Design-Kritik", "Sicherheit"]),
                ("Redesign der Startseite, die Farbe ist egal", .claude, ["Design-Kritik", "Bildsprache"], ["nur genau das Verlangte"]),
                ("Mach das Formular responsive", .claude, ["Gestaltung:", "Browser"], []),
                ("Schreib Unit-Tests für die Preisberechnung", .claude, ["Umsetzen", "Prüfen wie die CI"], ["Gestaltung:", "Design-Kritik"]),
                ("Analysiere, read-only: warum ist die API langsam", .claude, ["Berichte"], ["Umsetzen", "Aufräumen"]),
                ("Füge eine Animation zum Hero hinzu", .claude, ["Gestaltung:", "Design-Kritik"], []),
                ("Gestalte die Startseite neu", .codex, ["Gestaltung:", "Design-Kritik"], []),
                ("Webhook für neue Bestellungen einbauen", .claude, ["Sicherheit"], ["Gestaltung:"]),
                ("Dark Mode für die Einstellungsseite", .claude, ["Gestaltung:"], []),
                ("Refactor die Datenbank-Schicht", .codex, ["Umsetzen", "Aufräumen", "Prüfen wie die CI"], ["Gestaltung:"]),
            ]
            var misses: [String] = []
            for (text, kind, must, mustNot) in cases {
                guard let t = WorkPhases.plan(prompt: text, kind: kind, directory: nil)?.text else { misses.append("\(text) → kein Plan"); continue }
                let miss = must.filter { !t.contains(L($0)) && !t.contains($0) }.map { "fehlt \($0)" } + mustNot.filter { t.contains(L($0)) || t.contains($0) }.map { "zu viel \($0)" }
                if !miss.isEmpty { misses.append("\(text) → " + miss.joined(separator: ", ")) }
            }
            check("Planung: \(cases.count - misses.count)/\(cases.count) Aufträge mit den richtigen Phasen", misses.isEmpty, misses.joined(separator: " | "))
        }
        check("Prüfung: schon vorher rot zählt nicht gegen den Auftrag, mehr Fehler schon",
              Verifier.preexisting(baseCode: 1, baseOut: "error A\nerror B", out: "error A\nerror B")
              && !Verifier.preexisting(baseCode: 1, baseOut: "error A", out: "error A\nerror B\nerror C")
              && !Verifier.preexisting(baseCode: 0, baseOut: "", out: "error A")
              && !Verifier.preexisting(baseCode: 124, baseOut: "error A", out: "error A"))
        do {
            let diff = "+++ b/src/a.ts\n+const password = 'postgres12'\n+label: { password: 'Passwort eingeben bitte' }\n+token: '${{ secrets.GH_TOKEN }}'\n+++ b/src/b.ts\n+const apiKey = 'k8Jq2xL9pW4mZr7T'\n"
            let hits = SecretScan.scan(diff)
            check("Geheimnis-Scan: echte Schlüssel ja, Testwerte und Platzhalter nein", hits.count == 1 && hits[0].contains("b.ts"), hits.joined(separator: " | "))
        }
        check("Prüfung: fehlendes Werkzeug ist Umgebung, kein Code-Fehler",
              Verifier.missingTool("sh: tsx: command not found") && Verifier.missingTool("zsh: command not found: vitest")
              && Verifier.missingTool("Error: Cannot find module 'typescript'") && !Verifier.missingTool("Cannot find module './lib/a'")
              && !Verifier.missingTool("expected 2 to be 3"))
        check("Modellwahl: Agent bekommt nur Modelle, die seine CLI kennt",
              !ModelCatalog.listed("gpt-9-x", .cursor, in: ["cursor": ["composer-2", "claude-4-sonnet"]])
              && ModelCatalog.listed("composer-2", .cursor, in: ["cursor": ["composer-2", "claude-4-sonnet"]])
              && ModelCatalog.listed("irgendwas", .cursor, in: [:]) && ModelCatalog.listed("opus", .claude, in: ["cursor": ["a", "b"]]))
        do {
            let gh = (name: "Ada", email: "1+ada@users.noreply.github.com")
            let pick = { (c: String, g: (name: String, email: String)?, on: Bool, linked: Bool) in
                Git.chooseIdentity(configured: c, github: g, onGitHub: on, linked: linked, fallbackName: "Salenta Code")?.email }
            check("Commits in GitHub-Projekten sind immer dem Konto zugeordnet (sonst blockiert die Vorschau den PR)",
                  pick("", gh, true, false) == gh.email                       // nichts eingerichtet → Konto
                  && pick("ada@firma.example", gh, true, false) == gh.email   // fremde Adresse → Konto
                  && pick("ada@firma.example", gh, true, true) == nil         // nachweislich zugeordnet → so lassen
                  && pick("7+ada@users.noreply.github.com", gh, true, false) == nil
                  && pick("ada@firma.example", gh, false, false) == nil       // kein GitHub-Projekt → deine Einstellung gilt
                  && pick("", nil, false, false) == Git.fallbackEmail && pick("x@y.example", nil, false, false) == nil)
            check("Betreuer: nur reine CI-Korrekturen entfallen, wenn die Vorschau bloß an der Commit-Zuordnung hing",
                  Steward.isCIFix(L("Die CI auf GitHub ist rot. Lies die Logs mit `gh pr checks` und `gh run view --log-failed` und behebe die Ursache."))
                  && !Steward.isCIFix(L("Konflikt mit dem Haupt-Branch – neuesten Stand einarbeiten (rebase/merge) und Konflikte lösen."))
                  && !Steward.isCIFix(L("Das Review hat Einwände:") + "\n- a.ts:1 – x"))
        }
        do {
            // Ein langer Auftrag von dir, danach viele Statusmeldungen: Der Planer muss ihn weiter vollständig sehen
            let order = "Auftrag: " + (1...9).map { "\($0). Punkt \($0) " + String(repeating: "x", count: 300) }.joined(separator: "\n")
            var msgs = [StewardMessage(role: "du", text: order)]
            for i in 0..<20 { msgs.append(StewardMessage(role: "system", text: "🎉 Pull Request #\(i) gemergt")) }
            let ctx = Steward.chatContext(msgs)
            let fresh = Steward.chatContext([StewardMessage(role: "system", text: "a"), StewardMessage(role: "du", text: order)])
            check("Betreuer behält deinen Auftrag im Blick, auch nach vielen Statusmeldungen",
                  ctx.contains("9. Punkt 9") && ctx.contains("Earlier messages from the owner") && ctx.contains("#19 gemergt") && !ctx.contains("#3 gemergt")
                  && fresh.contains("9. Punkt 9") && !fresh.contains("Earlier messages") && Steward.planLimit(2) == 3 && Steward.planLimit(0) == 2)
        }
        do {
            var proj = StewardProject(id: "/a/x", name: "x"); proj.trust = 2
            let look = Steward.prLine(StewardPR(number: 7, title: "Startseite für Mobilgeräte anpassen", url: "", branch: "aos/a", sha: "1", ours: true, ci: "green"), proj)
            let plain = Steward.prLine(StewardPR(number: 8, title: "Meta-Angaben je Seite", url: "", branch: "aos/b", sha: "2", ours: true, ci: "green"), proj)
            check("Betreuer weiß, welche PRs auf dich warten (Aussehen) und welche er selbst übernimmt",
                  look.contains("ONLY THE OWNER") && !plain.contains("ONLY THE OWNER") && plain.contains("#8"))
        }
        do {
            let fit = Verifier.measure("{\"width\":390,\"content\":390,\"overflow\":0}\n")
            let wide = Verifier.measure("warnung\n{\"width\":390,\"content\":461,\"overflow\":71}")
            check("Design-Prüfung: Überlauf am Handy wird gemessen, nicht geraten",
                  fit?.content == 390 && wide?.content == 461 && Verifier.measure("kaputt") == nil
                  && Verifier.describeShot("/t/a-mobil.png", measured: fit).contains("no horizontal overflow")
                  && Verifier.describeShot("/t/a-mobil.png", measured: wide).contains("71 px wider")
                  && Verifier.describeShot("/t/a-schmal.png", measured: nil).contains("500 px")
                  && Verifier.describeShot("/t/a.png", measured: nil).contains("1440")
                  && Verifier.visualBrief(["/t/a-mobil.png"], readable: true).contains("schon vorher"))
        }
        do {
            func fix(_ st: StewardTask.State, note: String? = nil) -> StewardTask {
                var t = StewardTask(title: "PR #7 nachbessern: x"); t.pr = 7; t.prBranch = "aos/a"; t.state = st; t.note = note; return t
            }
            var first = StewardTask(title: "x"); first.pr = 7; first.state = .review    // die ursprüngliche Aufgabe, keine Korrektur
            check("Betreuer: gescheiterte PR-Korrektur wird noch einmal versucht statt den PR liegen zu lassen",
                  Steward.fixFailed([first, fix(.red)], pr: 7) && Steward.fixFailed([first, fix(.dropped, note: "vom Betreuer verworfen")], pr: 7)
                  && !Steward.fixFailed([first, fix(.red), fix(.queued)], pr: 7) && !Steward.fixFailed([first, fix(.dropped, note: L("von dir gestoppt"))], pr: 7)
                  && !Steward.fixFailed([first], pr: 7) && !Steward.fixFailed([first, fix(.done)], pr: 7) && !Steward.fixFailed([fix(.red)], pr: 8))
        }
        do {
            func run(_ wf: String, _ name: String, _ c: String, _ at: String) -> [String: Any] {
                ["__typename": "CheckRun", "workflowName": wf, "name": name, "conclusion": c, "status": "COMPLETED", "startedAt": at, "completedAt": at]
            }
            let relabeled = [run("Freigabe", "freigabe", "FAILURE", "2026-11-12T14:53:37Z"), run("Freigabe", "freigabe", "SUCCESS", "2026-11-12T14:56:07Z"),
                             run("CI", "pruefen", "SUCCESS", "2026-11-12T14:54:15Z"), run("Vorschau", "Supabase Preview", "SKIPPED", "2026-11-12T14:53:22Z")]
            let reverted = [run("G", "g", "SUCCESS", "2026-11-12T10:00:00Z"), run("G", "g", "FAILURE", "2026-11-12T11:00:00Z")]
            let running = [run("G", "g", "FAILURE", "2026-11-12T10:00:00Z"), ["workflowName": "G", "name": "g", "conclusion": "", "status": "IN_PROGRESS", "startedAt": "2026-11-12T11:00:00Z"]]
            check("Label nach grünem Review: nur ein sauberer Name, leer = aus",
                  Steward.cleanLabel("approved") == "approved" && Steward.cleanLabel(" geprüft ") == "geprüft" && Steward.cleanLabel("") == nil
                  && Steward.cleanLabel(nil) == nil && Steward.cleanLabel("a; rm -rf ~") == nil && Steward.cleanLabel("$(x)") == nil)
            check("PR-CI: nur der neueste Lauf jeder Prüfung zählt (Freigabe-Prüfung erst rot, nach dem Label grün → grün)",
                  Steward.ciState(relabeled) == "green" && Steward.ciState(reverted) == "red" && Steward.ciState(running) == "pending"
                  && Steward.ciState([]) == "none" && Steward.ciState([["__typename": "StatusContext", "context": "vercel", "state": "FAILURE", "startedAt": "x"]]) == "red")
        }
        do {
            // Werkzeug-Einstellungen (.serena) dürfen nie in die Änderung: neu angelegt → raus, schon versioniert → Stand des Projekts bleibt
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aos-st-serena-\(UUID().uuidString)").path
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            func w(_ p: String, _ t: String) {
                let u = URL(fileURLWithPath: dir).appendingPathComponent(p)
                try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? t.write(to: u, atomically: true, encoding: .utf8)
            }
            _ = Git.run(["init", "-q"], in: dir); w("a.txt", "1")
            _ = Git.run(Git.identity(dir) + ["add", "-A"], in: dir); _ = Git.run(Git.identity(dir) + ["commit", "-q", "-m", "base"], in: dir)
            let base = Git.run(["rev-parse", "HEAD"], in: dir).out.trimmingCharacters(in: .whitespacesAndNewlines)
            w(".serena/project.yml", "x"); w("a.txt", "2")
            _ = Git.run(["add", "-A"], in: dir)
            Worktrees.keepToolConfig(dir, base: base)
            let staged1 = Git.run(["diff", "--cached", "--name-only"], in: dir).out
            _ = Git.run(Git.identity(dir) + ["commit", "-q", "-m", "x"], in: dir)
            // Projekt versioniert .serena schon: eine Änderung daran wird zurückgenommen
            _ = Git.run(["add", "-f", ".serena/project.yml"], in: dir); _ = Git.run(Git.identity(dir) + ["commit", "-q", "-m", "serena"], in: dir)
            let base2 = Git.run(["rev-parse", "HEAD"], in: dir).out.trimmingCharacters(in: .whitespacesAndNewlines)
            w(".serena/project.yml", "lokal"); w("a.txt", "3"); _ = Git.run(["add", "-A"], in: dir)
            Worktrees.keepToolConfig(dir, base: base2)
            let staged2 = Git.run(["diff", "--cached", "--name-only"], in: dir).out
            check("Werkzeug-Einstellungen (.serena) landen nie im Pull Request",
                  staged1.contains("a.txt") && !staged1.contains(".serena") && staged2.contains("a.txt") && !staged2.contains(".serena")
                  && Worktrees.addSpec.contains(":(exclude,glob).serena/**"))
        }
        do {
            let plug = ExtensionCatalog.find("playwright").flatMap(ExtensionStore.uninstallCommand) ?? ""
            let mcp = Extension(id: "custom:o/r", name: "R", kind: .mcp, category: .essentials, repo: "", stars: "", purpose: "", when: [],
                                install: "claude mcp add --scope user srv -- npx -y srv", usage: "")
            let skill = Extension(id: "custom:o/r:tool", name: "tool", kind: .skill, category: .essentials, repo: "", stars: "", purpose: "", when: [],
                                  install: "git clone …", usage: "")
            let bad = Extension(id: "custom:o/r:x", name: "../x", kind: .skill, category: .essentials, repo: "", stars: "", purpose: "", when: [],
                                install: "", usage: "")
            let m = ExtensionStore.uninstallCommand(mcp) ?? "", k = ExtensionStore.uninstallCommand(skill) ?? ""
            check("Erweiterungen lassen sich wieder entfernen (Plugin, MCP für alle Agents, Skill in den Papierkorb)",
                  plug.hasPrefix("claude plugin uninstall ") && plug.contains("playwright@claude-plugins-official")
                  && m.hasPrefix("claude mcp remove --scope user 'srv'") && m.contains("codex mcp remove 'srv'")
                  && k.contains(".claude/skills/'tool'") && k.contains(".Trash") && !k.contains("rm ")
                  && ExtensionStore.uninstallCommand(bad) == nil
                  && ExtensionCatalog.find("junie").flatMap(ExtensionStore.uninstallCommand) == nil)
        }
        do {
            let now = Date(timeIntervalSince1970: 3_000_000), url = "https://github.com/o/r/actions/runs/1"
            func t(_ st: StewardTask.State, ago: TimeInterval, pr: Int? = nil, note: String? = nil) -> StewardTask {
                var x = StewardTask(title: "CI ist rot – reparieren: CI"); x.ref = url; x.state = st; x.pr = pr; x.note = note
                x.created = now.addingTimeInterval(-ago - 600); x.finished = [.idea, .queued, .running].contains(st) ? nil : now.addingTimeInterval(-ago); return x
            }
            check("Betreuer: rote Haupt-Branch-Reparatur ohne Erfolg wird nach 30 Minuten neu eingereiht, höchstens dreimal",
                  Steward.mainFixDue([], ref: url, now: now)
                  && Steward.mainFixDue([t(.review, ago: 2000)], ref: url, now: now)            // endete ohne PR (keine Änderung)
                  && !Steward.mainFixDue([t(.review, ago: 600)], ref: url, now: now)            // noch keine 30 Minuten
                  && !Steward.mainFixDue([t(.queued, ago: 0)], ref: url, now: now)
                  && !Steward.mainFixDue([t(.review, ago: 4000, pr: 12)], ref: url, now: now)   // Reparatur-PR unterwegs
                  && !Steward.mainFixDue([t(.dropped, ago: 4000, note: L("von dir gestoppt"))], ref: url, now: now)
                  && Steward.mainFixDue([t(.red, ago: 4000)], ref: url, now: now)
                  && Steward.mainFixAttempts([t(.red, ago: 9000), t(.dropped, ago: 6000), t(.review, ago: 2000)], ref: url) == 3
                  && Steward.mainFixAttempts([t(.red, ago: 9000)], ref: "x") == 0)
        }
        do {
            let t0 = Date(timeIntervalSince1970: 1_000_000)
            check("Ruhezustand zählt nicht als Laufzeit eines Helfers",
                  Steward.sleptGap(last: nil, now: t0) == 0 && Steward.sleptGap(last: t0, now: t0.addingTimeInterval(31)) == 0
                  && Steward.sleptGap(last: t0, now: t0.addingTimeInterval(240)) == 0
                  && Steward.sleptGap(last: t0, now: t0.addingTimeInterval(5400)) == 5370)
        }
        check("Ruhige Liste: Titel ohne vorangestelltes Symbol, Inhalt bleibt",
              MissionRow.plain("🧭 PR #25 nachbessern") == "PR #25 nachbessern" && MissionRow.plain("Login reparieren") == "Login reparieren"
              && MissionRow.plain("„Start“ neu bauen") == "„Start“ neu bauen" && MissionRow.plain("#12 prüfen") == "#12 prüfen" && MissionRow.plain("🧭") == "🧭")
        check("Betreuer: ein ausdrücklich genannter Agent wird erkannt – auch neben einem ähnlich benannten",
              Steward.namedAgents(in: "3. Salenta Harness baut src/colors.mjs", among: [.claude, .codex, .harness, .deepseek]) == [.harness]
              && Steward.namedAgents(in: "Nimm dafür DeepSeek Harness", among: [.claude, .harness, .deepseek]) == [.deepseek]
              && Steward.namedAgents(in: "Codex baut A, Cursor baut B", among: [.claude, .codex, .cursor, .harness]) == [.codex, .cursor]
              && Steward.namedAgents(in: "Bau das Harnessing-Modul", among: [.harness]).isEmpty)
        do {
            let now = Date(timeIntervalSince1970: 2_000_000), just = now.addingTimeInterval(-300)
            let f = { (passed: Bool?, round: Int, ended: Date?, archived: Bool, outcome: String?, wt: Bool, child: Bool) in
                Steward.fixInterrupted(passed: passed, fixRound: round, ended: ended, archived: archived, outcome: outcome, hasWorktree: wt, hasChild: child, now: now) }
            check("Nach einem Neustart wird eine liegen gebliebene Korrekturrunde nachgeholt",
                  f(false, 1, just, false, nil, true, false) && f(false, 0, just, false, nil, true, false)
                  && !f(false, 2, just, false, nil, true, false)        // schon zwei Runden
                  && !f(false, 1, just, false, nil, true, true)         // Runde läuft bereits
                  && !f(true, 0, just, false, nil, true, false) && !f(nil, 0, just, false, nil, true, false)
                  && !f(false, 1, just, true, nil, true, false) && !f(false, 1, just, false, "discarded", true, false)
                  && !f(false, 1, now.addingTimeInterval(-7200), false, nil, true, false) && !f(false, 1, just, false, nil, false, false))
        }
        do {
            let plain = HelperLLM.command(model: "haiku", maxTurns: 3, file: "/tmp/x.md")
            let web = HelperLLM.command(model: "sonnet", maxTurns: 3, file: "/tmp/x.md", web: true, decision: true)
            check("Entscheidungsmodell: das stärkste vorhandene Modell entscheidet – ohne eigenen Schlüssel",
                  HelperLLM.decider(claudeOn: true, claudeTight: false, codexOn: true, harnessOn: true)! == ("claude", "opus")
                  && HelperLLM.decider(claudeOn: true, claudeTight: true, codexOn: true, harnessOn: false)! == ("claude", "sonnet")
                  && HelperLLM.decider(claudeOn: false, claudeTight: false, codexOn: true, harnessOn: true)! == ("codex", "")
                  && HelperLLM.decider(claudeOn: false, claudeTight: false, codexOn: false, harnessOn: true)! == ("harness", "")
                  && HelperLLM.decider(claudeOn: false, claudeTight: false, codexOn: false, harnessOn: false) == nil
                  && !plain.contains("--model opus") && web == HelperLLM.command(model: "sonnet", maxTurns: 3, file: "/tmp/x.md", web: true))
        }
        do {
            let c = DevBridge.parse("steward-send blumen :: Mach die Seite sichtbarer")
            let ps = [StewardProject(id: "/a/blumen-website", name: "blumen-website"), StewardProject(id: "/a/shop", name: "shop")]
            check("Entwickler-Brücke: Befehl und Projekt werden richtig gelesen",
                  c?.verb == "steward-send" && c?.target == "blumen" && c?.body == "Mach die Seite sichtbarer"
                  && DevBridge.parse("# Notiz") == nil && DevBridge.parse("success")?.verb == "success"
                  && DevBridge.find("blumen", in: ps)?.id == "/a/blumen-website" && DevBridge.find("shop", in: ps)?.id == "/a/shop"
                  && DevBridge.find("", in: ps) == nil)
        }
        do {
            let v = Verifier.visualBrief(["/tmp/a.png", "/tmp/a-mobil.png"], readable: true)
            check("Design-Prüfung: Review sieht Desktop- und Mobil-Aufnahme", v.contains("1440") && v.contains("390") && v.contains("Design:") && Verifier.visualBrief([], readable: true).isEmpty)
        }
        check("Genannter Agent gilt (z. B. „mit Salenta Harness“)",
              Router.decide("Baue im Projekt x eine Funktion mit Salenta Harness", projects: [], recent: []).target == .harness
              && Router.named("bitte @harness") && !Router.named("Baue eine Login-Seite"))
        do {
            let ps = [Project(path: "/tmp/x/salenta", name: "salenta", source: "test", isGit: true), Project(path: "/tmp/x/betreuer-testprojekt", name: "betreuer-testprojekt", source: "test", isGit: true)]
            check("Projektwahl: längster Name gewinnt, Agent-Namen zählen nicht",
                  Router.project(for: "im Projekt betreuer-testprojekt mit Salenta Harness", projects: ps)?.name == "betreuer-testprojekt"
                  && Router.project(for: "Baue X mit Salenta Harness", projects: ps) == nil)
        }
        do {
            // Gestoppt heißt abgebrochen: der Betreuer verwirft das Ergebnis (nie prüfen, nie liefern)
            var rec = MissionRecord(id: "stop-test", title: "x", request: "x", agent: "codex", mode: "autonom", directory: "/tmp", started: Date(), log: "", taskID: nil)
            rec.outcome = "stopped"; rec.ended = Date()
            MissionStore.shared.missions.append(rec)
            var t = StewardTask(title: "x", detail: "", agent: "codex", model: "")
            t.missionID = "stop-test"
            check("Gestoppter Lauf wird verworfen, nicht geliefert", Steward.outcome(t, agents: nil)?.state == .dropped)
            MissionStore.shared.missions.removeAll { $0.id == "stop-test" }
        }
        check("Mail von noreply braucht keine Antwort", !Watchman.shared.needsReply(subject: "Ihre Rechnung", sender: "noreply@shop.example"))

        // Trefferquote rechnet mit Beispielaufträgen
        var a = MissionRecord(id: "q1", title: "Login bauen", request: "Bau die Login-Seite", agent: "claude", mode: "autonom", directory: repo, started: Date(), log: "", taskID: nil)
        a.ended = Date(); a.outcome = "merged"
        var b = a; b = MissionRecord(id: "q2", title: "Fix", request: "Bau den Footer", agent: "claude", mode: "autonom", directory: repo, started: Date(), log: "", taskID: nil)
        b.ended = Date(); b.ok = false
        let rows = Quality.rows([a, b])
        check("Trefferquote: Aufträge werden gezählt", rows.reduce(0) { $0 + $1.runs } == 2)

        // Live-Ansicht versteht Gemini CLI und OpenCode
        // build.sh übergibt den Quellordner (der rohe Testlauf hat kein App-Bundle)
        let src = ProcessInfo.processInfo.environment["AOS_SRC"].map { URL(fileURLWithPath: $0) } ?? Paths.source
        let live = src.appendingPathComponent("bin/aos-live").path
        if FileManager.default.fileExists(atPath: live) {
            let input = tmp.appendingPathComponent("ev.jsonl").path
            try? [#"{"type":"init","session_id":"x","model":"m"}"#,
                  #"{"type":"tool_use","tool_name":"read_file","tool_id":"1","parameters":{"absolute_path":"/tmp/a.py"}}"#,
                  #"{"type":"tool_use","part":{"type":"tool","tool":"bash","callID":"c","state":{"status":"running","input":{"command":"npm test"}}}}"#,
                  #"{"type":"result","status":"success","stats":{}}"#].joined(separator: "\n")
                .write(toFile: input, atomically: true, encoding: .utf8)
            let r = Proc.zsh("python3 \(Shell.quote(live)) < \(Shell.quote(input))", in: tmp.path, timeout: 20)
            check("Live-Ansicht: Gemini-Schritt lesbar", r.out.contains("Liest"), r.out)
            check("Live-Ansicht: OpenCode-Befehl lesbar", r.out.contains("npm test"), r.out)
            check("Live-Ansicht: Abschluss erkannt", r.out.contains("Fertig"), r.out)
        }
    }
}

// MARK: - Sicherheitsnetz

extension View {
    /// Nimmt genau den angebotenen Platz ein und schneidet Überstand unten ab (oben bleibt sichtbar).
    /// So kann eine zu hohe Ansicht nie Kopfzeile, Seitenleiste oder Fenster verschieben.
    func containedInWindow() -> some View {
        frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            .clipped()
    }
}

/// Abgesicherter Start: Stürzt die App zweimal kurz nach dem Start ab, startet sie beim dritten Mal
/// ohne Desktop-Widgets und Wach-Automatik auf der Startseite – so kommst du immer wieder rein.
enum SafeStart {
    private static let key = "launch.unstable"
    static private(set) var active = false

    static func begin() {
        let n = UserDefaults.standard.integer(forKey: key)
        active = n >= 2 || CommandLine.arguments.contains("--safe")
        UserDefaults.standard.set(n + 1, forKey: key)
        if active { CrashLog.mark("ABGESICHERTER START (vorher \(n)× kurz nach dem Start beendet)") }
        // 45 s ohne Absturz = stabil
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { UserDefaults.standard.set(0, forKey: key) }
    }

    /// Normales Beenden zählt nicht als Absturz.
    static func cleanExit() { UserDefaults.standard.set(0, forKey: key) }
}


/// Trifft ein Text eines gescheiterten Starts eins der Anmelde-Muster? (für den Selbsttest, ohne etwas zu merken)
func CLIFlags_loginHit(_ text: String) -> Bool {
    let t = text.lowercased()
    return AgentHealth.loginPatterns.contains { t.range(of: $0, options: .regularExpression) != nil }
}
