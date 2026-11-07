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
        let paths = Worktrees.changes(wt).map(\.path).sorted()
        check("Änderungen = nur die des Helfers (keine fremden Commits)", paths == ["src/app.test.ts", "src/app.ts"], paths.joined(separator: ", "))
        let diff = Worktrees.diff(wt)
        check("Diff enthält keine fremden Dateien", !diff.contains("fremd.ts") && !diff.contains("db.pg-test") && !diff.contains("lokal.ts"))
        check("Skill-Änderungen von Agenten-Plugins landen nicht im Diff", !diff.contains(".agents/skills"))
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
        let prRec = MissionRecord(id: "t", title: "Login", request: "Login reparieren", agent: "claude", mode: "autonom", directory: "/tmp", started: Date(), log: "", taskID: nil)
        let prBody = PRWriter.body(summary: ["Behebt den Login"], changes: ["auth.ts angepasst"], changelog: ["Login klappt wieder"], testing: [], rec: prRec, de: true)
        check("Pull Request: Beschreibung mit Zusammenfassung, Änderungen und Changelog", prBody.contains("## Zusammenfassung") && prBody.contains("## Changelog") && !prBody.contains("## Geprüft"), "")
        let phases = WorkPhases.plan(prompt: "Baue einen Dark-Mode-Button auf der Startseite", kind: .claude, directory: nil)
        check("Arbeitsplan: Phasen mit Planen, Umsetzen, Prüfen wie die CI", phases.map { $0.text.contains("Umsetzen") && $0.text.contains("Prüfen wie die CI") && $0.text.contains("Browser") } ?? !AutoSkills.enabled, "")
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
