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
        knowledge(tmp)
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
        var t = StewardTask(title: "x"); t.missionID = nil
        check("Aufgabe ohne Auftrag gilt als rot", Steward.outcome(t, agents: nil)?.state == .red)
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
