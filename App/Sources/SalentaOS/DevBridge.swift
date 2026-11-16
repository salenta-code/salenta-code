import AgenticOSKit
import Foundation

// Nur in der Entwickler-Version: Betreuer aus dem Quellcode-Ordner heraus ansprechen und beobachten,
// ohne die Oberfläche zu bedienen. Befehle stehen in logs/dev-command.txt (eine Zeile je Befehl),
// der Stand der beobachteten Projekte landet in logs/steward.txt.
//
//   steward-watch <Projektname>            Stand dieses Projekts ausführlich mitschreiben
//   steward-send <Projektname> :: <Text>   Nachricht an den Betreuer (wie im Gespräch getippt)
//   steward-pause <Projektname> :: on|off  Betreuer anhalten oder weiterlaufen lassen
//   success                                Erfolgsquote neu auswerten (logs/success.txt)
//   design-probe                           Sichtprüfung testen: echte Handy-Breite, gemessener Überlauf, Review (logs/design-check.txt)
//   heat <0-3|off>                         Hitze-Zustand für einen Test vorgeben (3 = kritisch): startet dann wirklich kein Helfer?
//   pr-review <Projektname> :: <Nummer>   einen offenen PR neu prüfen lassen
//   bench-setup                            Übungsprojekt „textwerk“ anlegen und in Betreuung geben (echte Testläufe ohne deine Projekte)
//   bench-budget <n>                       dem Übungsprojekt heute n zusätzliche Läufe geben
//   stress <Minuten>                       echter Hitze-Test: Volllast, bis der Mac „heiß“ meldet (höchstens 20 Minuten, nur am Strom)
//   sleep-test <Projektname>               Ruhezustand nachstellen: wird ein laufender Helfer danach fälschlich als „hing fest“ gestoppt?
//   decide [:: <Auftrag>]                  Entscheidungsmodell live prüfen: wer antwortet, wie schnell (logs/decide.txt)
//   route :: <Auftrag>                     Agentenwahl wie im Auftragsfeld, ohne etwas zu starten: Agent, Modell, Denktiefe,
//                                          Skills und Erweiterungen (logs/route.txt)
//   rebuild                                wie der Menüpunkt „Salenta Code neu bauen und starten“ (logs/rebuild.log)

enum DevBridge {
    private static var timer: Timer?
    private static var lastCommand = ""
    private static var beat = 0
    private static var watched: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "dev.bridge.watch") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "dev.bridge.watch") }
    }
    private static var logs: URL { Paths.source.appendingPathComponent("logs", isDirectory: true) }

    static func start() {
        guard Paths.isDevBuild, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            commands()
            beat += 1
            if beat % 6 == 1 { snapshot() }
        }
    }

    /// Übungsprojekt für echte Testläufe: ein kleines Node-Projekt mit Tests in den App-Daten, vom Betreuer betreut.
    /// So lassen sich Planung, Verteilung, Prüfung und Übernahme testen, ohne eines deiner Projekte anzufassen.
    static func benchSetup() -> String {
        let fm = FileManager.default
        let dir = Paths.root.appendingPathComponent("bench/textwerk", isDirectory: true)
        if !fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
            for d in ["src", "test"] { try? fm.createDirectory(at: dir.appendingPathComponent(d), withIntermediateDirectories: true) }
            let files: [String: String] = [
                "package.json": """
                {
                  "name": "textwerk",
                  "version": "0.1.0",
                  "private": true,
                  "type": "module",
                  "scripts": { "test": "node --test" }
                }

                """,
                "README.md": "# textwerk\n\nKleine Hilfsfunktionen für Text. Tests: `npm test`.\n\n- `slug(text)` – Text als Adress-Teil\n- `wordCount(text)` – Wörter zählen\n",
                ".gitignore": "node_modules/\n",
                "src/text.mjs": """
                // Hilfsfunktionen für Text.

                /** Text als Adress-Teil: klein, Umlaute ausgeschrieben, Wörter mit Bindestrich. */
                export function slug(text) {
                  return String(text)
                    .toLowerCase()
                    .replace(/ä/g, 'ae').replace(/ö/g, 'oe').replace(/ü/g, 'ue').replace(/ß/g, 'ss')
                    .replace(/[^a-z0-9]+/g, '-')
                    .replace(/^-+|-+$/g, '');
                }

                /** Zahl der Wörter. */
                export function wordCount(text) {
                  const words = String(text).trim().split(/\\s+/).filter(Boolean);
                  return words.length;
                }

                """,
                "test/text.test.mjs": """
                import test from 'node:test';
                import assert from 'node:assert/strict';
                import { slug, wordCount } from '../src/text.mjs';

                test('slug', () => {
                  assert.equal(slug('Grüße aus Köln!'), 'gruesse-aus-koeln');
                  assert.equal(slug('  Hallo   Welt  '), 'hallo-welt');
                });

                test('wordCount', () => {
                  assert.equal(wordCount('eins zwei  drei'), 3);
                  assert.equal(wordCount('   '), 0);
                });

                """,
            ]
            for (name, text) in files { try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
            Git.run(["init", "-q", "-b", "main"], in: dir.path)
            Git.run(["add", "-A"], in: dir.path)
            let who = Git.identity(dir.path)
            Git.run((who.isEmpty && Git.configuredEmail(dir.path).isEmpty ? ["-c", "user.name=Salenta Code", "-c", "user.email=\(Git.fallbackEmail)"] : who) + ["commit", "-q", "-m", "Start"], in: dir.path)
        }
        let s = Steward.shared
        let id = s.adopt(dir.path)
        s.update(id) { p in
            p.trust = 2; p.parallel = 2; p.dailyRuns = 12; p.watchCI = false
            if p.goal.isEmpty { p.goal = "Übungsprojekt mit kleinen Text-Hilfsfunktionen und Tests. Dient nur dazu, Salenta Code zu testen." }
        }
        watched.insert(id)
        return (dir.path as NSString).abbreviatingWithTildeInPath
    }

    /// Im Übungsprojekt direkt auf dem Haupt-Branch eine Änderung am Ende von Code- und Testdatei committen – so kollidiert ein
    /// gerade laufender Helfer beim Übernehmen garantiert. Prüft, dass der Konflikt ohne dich gelöst wird.
    static func benchCollide() -> String {
        let dir = Paths.root.appendingPathComponent("bench/textwerk", isDirectory: true)
        let code = dir.appendingPathComponent("src/text.mjs"), test = dir.appendingPathComponent("test/text.test.mjs")
        guard var c = try? String(contentsOf: code, encoding: .utf8), var t = try? String(contentsOf: test, encoding: .utf8) else { return "Übungsprojekt fehlt" }
        let n = Int(Date().timeIntervalSince1970) % 100000
        c += "\n/** Text in Großbuchstaben (Kollisionstest \(n)). */\nexport function shout\(n)(text) {\n  return String(text).toUpperCase() + '!';\n}\n"
        t = t.replacingOccurrences(of: "from '../src/text.mjs';", with: "from '../src/text.mjs';\nimport { shout\(n) } from '../src/text.mjs';", options: [], range: t.range(of: "from '../src/text.mjs';"))
        t += "\ntest('shout\(n)', () => {\n  assert.equal(shout\(n)('hallo'), 'HALLO!');\n});\n"
        try? c.write(to: code, atomically: true, encoding: .utf8)
        try? t.write(to: test, atomically: true, encoding: .utf8)
        Git.run(["add", "-A"], in: dir.path)
        let who = Git.identity(dir.path)
        let r = Git.run((who.isEmpty && Git.configuredEmail(dir.path).isEmpty ? ["-c", "user.name=Salenta Code", "-c", "user.email=\(Git.fallbackEmail)"] : who)
                        + ["commit", "-q", "-m", "Kollisionstest: shout\(n) am Dateiende"], in: dir.path)
        return r.code == 0 ? "shout\(n) auf dem Haupt-Branch committet" : "Commit fehlgeschlagen: " + String(r.out.suffix(120))
    }

    /// Aus dem Quellcode neu bauen und starten (dasselbe wie der Menüpunkt).
    static func rebuild() {
        let app = Paths.source.appendingPathComponent("App").path
        let log = Paths.source.appendingPathComponent("logs/rebuild.log").path
        Shell.spawn("mkdir -p \(Shell.quote((log as NSString).deletingLastPathComponent)) && cd \(Shell.quote(app)) && ./build.sh --open > \(Shell.quote(log)) 2>&1")
    }

    /// Projekt über seinen Namen finden (genau, sonst als Teil des Namens).
    static func find(_ name: String, in projects: [StewardProject]) -> StewardProject? {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !n.isEmpty else { return nil }
        return projects.first { $0.name.lowercased() == n } ?? projects.first { $0.name.lowercased().contains(n) }
    }

    /// „steward-send shop :: Text“ → („steward-send“, „shop“, „Text“)
    static func parse(_ line: String) -> (verb: String, target: String, body: String)? {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.hasPrefix("#") else { return nil }
        let head: String, body: String
        if let r = t.range(of: " :: ") { head = String(t[..<r.lowerBound]); body = String(t[r.upperBound...]) } else { head = t; body = "" }
        let parts = head.split(separator: " ", maxSplits: 1).map(String.init)
        return (parts[0].lowercased(), parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "", body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func commands() {
        let file = logs.appendingPathComponent("dev-command.txt")
        guard let text = try? String(contentsOf: file, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text != lastCommand else { return }
        lastCommand = text
        try? FileManager.default.removeItem(at: file)
        var out: [String] = []
        // Mehrzeilige Nachrichten: Folgezeilen ohne Befehlswort gehören zum Text davor
        var blocks: [String] = []
        for line in text.components(separatedBy: "\n") {
            let isCommand = ["steward-watch", "steward-send", "steward-pause", "success", "rebuild", "design-probe", "heat", "pr-review", "bench-setup", "bench-collide", "bench-budget", "stress", "sleep-test", "decide", "route", "#"].contains { line.lowercased().hasPrefix($0) }
            if isCommand || blocks.isEmpty { blocks.append(line) } else { blocks[blocks.count - 1] += "\n" + line }
        }
        for block in blocks {
            guard let c = parse(block) else { continue }
            let s = Steward.shared
            switch c.verb {
            case "success":
                out.append("success → " + SuccessReport.write().lastPathComponent)
            case "design-probe":
                Verifier.designProbe(); out.append("design-probe → gestartet (logs/design-check.txt)")
            case "heat":
                // Hitze nur vorgeben (0 normal … 3 kritisch, „off“ = echter Wert): prüft, dass die Verteilung dann wirklich bremst
                let v = c.target.lowercased()
                PowerProfile.testThermal = v == "off" || v.isEmpty ? nil : ProcessInfo.ThermalState(rawValue: Int(v) ?? 0)
                out.append("heat → \(PowerProfile.testThermal.map { "vorgegeben \($0.rawValue)" } ?? "echt") · parallel erlaubt \(PowerProfile.capParallel(4))/4")
                for p in s.projects where !p.paused { s.dispatch(p.id) }
            case "pr-review":
                // Einen offenen PR noch einmal prüfen lassen (z. B. nachdem das Review selbst verbessert wurde)
                guard let p = find(c.target, in: s.projects), let n = Int(c.body), p.prs?.contains(where: { $0.number == n }) == true else {
                    out.append("pr-review: Projekt oder offene PR-Nummer fehlt"); continue
                }
                s.setPR(p.id, n) { $0.reviewedSha = nil; $0.reviewOK = nil; $0.issues = nil; $0.summary = nil; $0.reviewing = nil }
                s.scanPRs(p.id, force: true)
                out.append("pr-review → \(p.name) #\(n)")
            case "bench-budget":
                // Nur das Übungsprojekt: zusätzliche Läufe für heute
                guard let p = find("textwerk", in: s.projects), p.id.contains("/bench/"), let n = Int(c.target), (1...20).contains(n) else {
                    out.append("bench-budget: Übungsprojekt fehlt oder Zahl 1–20 erwartet"); continue
                }
                s.update(p.id) { q in var e = q.extraToday ?? [:]; e[q.today] = n; q.extraToday = e }
                out.append("bench-budget → textwerk heute +\(n)")
            case "sleep-test":
                // Ruhezustand nachstellen: laufende Aufgaben des Projekts gelten als 100 Minuten alt, der Takt ebenso lange still
                guard let p = find(c.target, in: s.projects) else { out.append("sleep-test: Projekt fehlt"); continue }
                let n = s.testSleep(p.id, minutes: 100)
                out.append("sleep-test → \(p.name): \(n) laufende Aufgabe(n) um 100 Minuten zurückgestellt")
            case "decide":
                // Entscheidungsmodell live prüfen: dieselbe Frage-Strecke wie vor jedem Auftrag – wer hat geantwortet, wie schnell?
                let task = c.body.isEmpty ? "Benenne in einer kleinen Node-Bibliothek die Funktion slug in toSlug um und passe die Tests an." : c.body
                DispatchQueue.global(qos: .utility).async {
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("aos-decide-\(UUID().uuidString).txt")
                    let prompt = """
                    Decide how this coding task should be executed. Task: \(task)
                    Answer ONLY with JSON: {"agent":"claude|codex|cursor","model":"","effort":"low|medium|high","reason":"max 8 words"}
                    """
                    try? prompt.write(to: file, atomically: true, encoding: .utf8)
                    defer { try? FileManager.default.removeItem(at: file) }
                    let t0 = Date()
                    let r = Proc.zsh(HelperLLM.command(model: "haiku", maxTurns: 3, file: file.path, decision: true), in: NSTemporaryDirectory(), timeout: 60)
                    let env = Verifier.claudeEnvelope(r.out)
                    let text = "Entscheidungsmodell – \(DateCoding.stamp(Date()))\n"
                        + "Entscheidungsmodell: \(HelperLLM.harnessDecides ? "an – vorgesehen: " + HelperLLM.deciderLabel : "aus (kleines Modell entscheidet)")\n"
                        + "Geantwortet hat: \((env?["via"] as? String) ?? "Claude") \((env?["provider"] as? String) ?? "") \((env?["model"] as? String) ?? "")\((env?["modelUsage"] as? [String: Any]).map { " " + $0.keys.sorted().joined(separator: ", ") } ?? "")\n"
                        + String(format: "Dauer: %.1f s\n", Date().timeIntervalSince(t0))
                        + "Antwort: \(Verifier.claudeResult(r.out)?.prefix(300) ?? "– (keine)")\n"
                    try? text.write(to: logs.appendingPathComponent("decide.txt"), atomically: true, encoding: .utf8)
                }
                out.append("decide → läuft (logs/decide.txt)")
            case "route":
                // Die echte Agentenwahl für einen Auftrag – mit allem, was installiert ist. Startet nichts.
                let task = c.body.isEmpty ? c.target : c.body
                guard !task.isEmpty else { out.append("route: Auftrag fehlt (route :: <Auftrag>)"); continue }
                let projects = s.projects.map { Project(path: $0.id, name: $0.name, source: "", isGit: true) }
                let skills = SkillCatalog.current?.skills ?? []
                let installed = Set(AgentKind.coders.filter { OpenModels.available($0) && !AgentHealth.unavailable($0) })
                let tools = MCPHub.current.map { OSAgent.toolNames(hub: $0) } ?? []
                let exts = ExtensionStore.shared.installedList.filter { !$0.howTo.isEmpty }
                let auto = installed.filter { Billing.autoOK($0) }.map(\.rawValue).sorted()
                let paid = installed.filter { !Billing.autoOK($0) }.map(\.rawValue).sorted()
                let t0 = Date()
                AIRouter.decide(task, projects: projects, skills: skills, installed: installed, tools: tools,
                                fallback: Router.decide(task, projects: projects, recent: [])) { d in
                    let list = { (x: [String]) in x.isEmpty ? "–" : x.joined(separator: ", ") }
                    let text = "Agentenwahl – \(DateCoding.stamp(Date()))\n"
                        + "Auftrag: \(task.prefix(300))\n"
                        + "Zur Wahl: Agents \(list(auto))\(paid.isEmpty ? "" : " · nur auf Wunsch (Kosten pro Nutzung): " + list(paid))\n"
                        + "Zur Wahl: \(skills.count) Skills · \(exts.count) Erweiterungen, davon \(exts.filter { $0.id.hasPrefix("custom:") }.count) selbst hinzugefügt · \(tools.count) Anbindungen\n"
                        + "Entscheidung: \(d.target.rawValue) · Modell \(d.model ?? "Standard des Agents") · Denktiefe \(d.effort ?? "–") · Umfang \(d.complexity ?? "–")\n"
                        + "Projekt: \(d.directory.map { ($0 as NSString).lastPathComponent } ?? "–")\n"
                        + "Skills: \(list(d.skills))\n"
                        + "Erweiterungen: \(list((d.extensions ?? []).compactMap { ExtensionCatalog.find($0)?.name }))\n"
                        + "Anbindungen: \(list(d.tools ?? []))\n"
                        + "Würde helfen, fehlt: \(list(d.suggest ?? []))\n"
                        + "Fertig, wenn: \(d.doneWhen ?? "–")\n"
                        + "Grund: \(d.reason)\n"
                        + String(format: "Dauer: %.1f s\n", Date().timeIntervalSince(t0))
                    try? text.write(to: logs.appendingPathComponent("route.txt"), atomically: true, encoding: .utf8)
                }
                out.append("route → läuft (logs/route.txt)")
            case "stress":
                // Echter Hitze-Test: Volllast mit normaler Priorität, endet von selbst, sobald der Mac „heiß“ meldet. Nur am Strom.
                guard !SystemLoad.shared.onBattery else { out.append("stress: nur am Strom (Mac läuft am Akku)"); continue }
                let minutes = min(20, max(1, Int(c.target) ?? 10))
                StressTest.run(seconds: minutes * 60, heat: true)
                out.append("stress → \(minutes) Minuten Volllast gestartet (logs/stress.txt)")
            case "bench-setup":
                out.append("bench-setup → " + benchSetup())
            case "bench-collide":
                out.append("bench-collide → " + benchCollide())
            case "rebuild":
                rebuild(); out.append("rebuild → gestartet (logs/rebuild.log)")
            case "steward-watch":
                guard let p = find(c.target, in: s.projects) else { out.append("steward-watch: kein Projekt „\(c.target)“"); continue }
                watched.insert(p.id); out.append("steward-watch → \(p.name)")
            case "steward-send":
                guard let p = find(c.target, in: s.projects), !c.body.isEmpty else { out.append("steward-send: Projekt oder Text fehlt („\(c.target)“)"); continue }
                watched.insert(p.id)
                s.send(p.id, c.body)
                out.append("steward-send → \(p.name) (\(c.body.count) Zeichen)")
            case "steward-pause":
                guard let p = find(c.target, in: s.projects), ["on", "off"].contains(c.body.lowercased()) else { out.append("steward-pause: Projekt oder on/off fehlt"); continue }
                s.update(p.id) { $0.paused = c.body.lowercased() == "on" }
                out.append("steward-pause → \(p.name): \(c.body.lowercased())")
            default:
                out.append("unbekannt: \(c.verb)")
            }
        }
        let stamp = DateCoding.stamp(Date())
        let line = out.map { stamp + "  " + $0 }.joined(separator: "\n") + "\n"
        let result = logs.appendingPathComponent("dev-result.txt")
        let old = (try? String(contentsOf: result, encoding: .utf8)) ?? ""
        try? (String(old.suffix(4000)) + line).write(to: result, atomically: true, encoding: .utf8)
        snapshot()
    }

    /// Stand der Betreuer: alle als Zeile, beobachtete ausführlich.
    private static func snapshot() {
        let s = Steward.shared
        var out = "Betreuer – Stand \(DateCoding.stamp(Date()))\n"
        let load = SystemLoad.shared
        out += "Last: CPU \(Int(load.cpu)) % · Hitze \(PowerProfile.thermalNow.rawValue)\(PowerProfile.thermalNow != ProcessInfo.processInfo.thermalState ? " (vorgegeben)" : "") · RAM frei \(Int(load.memFree)) % · Akku \(load.onBattery ? "ja" : "nein")"
            + " · Modus \(PowerProfile.effective) · parallel erlaubt \(PowerProfile.capParallel(4))/4\n\n"
        for p in s.projects {
            out += "\(p.name): \(p.paused ? "pausiert" : "aktiv") · Vertrauen \(p.trust) · parallel \(p.parallel) · \(p.budgetText)"
                + " · wartend \(p.count(.queued)) · läuft \(p.count(.running)) · prüft \(p.count(.review)) · fertig \(p.count(.done)) · rot \(p.count(.red))\n"
        }
        for p in s.projects where watched.contains(p.id) {
            out += "\n===== \(p.name) =====\n"
            out += "Pfad: \(p.id)\n"
            out += "GitHub: \(p.github.map { $0 ? "an" : "aus" } ?? "automatisch") · selbst mergen: \(p.autoMerge.map { $0 ? "an" : "aus" } ?? "wie Vertrauen") · Ziel-Branch: \(p.prBase ?? "Standard")\n"
            out += "Dauerbetrieb: \(p.continuous ? "an" : "aus") · denkt gerade: \(p.thinking == true ? "ja" : "nein")\n"
            if !p.goal.isEmpty { out += "Ziel: \(p.goal.prefix(400))\n" }
            if let g = p.progress { out += "Fortschritt: \(g)\n" }
            if let b = p.blocked { out += "Braucht dich: \(b)\n" }
            let open = p.tasks.filter { ![.done, .dropped].contains($0.state) }
            let recent = p.tasks.filter { [.done, .dropped].contains($0.state) }.sorted { ($0.finished ?? $0.created) > ($1.finished ?? $1.created) }.prefix(12)
            out += "\nOffene Aufgaben (\(open.count)):\n"
            for t in open { out += row(t) }
            out += "\nZuletzt abgeschlossen:\n"
            for t in recent { out += row(t) }
            let older = p.messages.dropLast(8).suffix(40)
            if !older.isEmpty {
                out += "\nVerlauf davor (gekürzt):\n"
                for m in older { out += "[\(DateCoding.stamp(m.date).dropFirst(5).prefix(11)) \(m.role)] \(m.text.replacingOccurrences(of: "\n", with: " ").prefix(170))\n" }
            }
            out += "\nGespräch (letzte 8):\n"
            for m in p.messages.suffix(8) { out += "[\(DateCoding.stamp(m.date)) \(m.role)] \(m.text.prefix(900))\n" }
        }
        try? out.write(to: logs.appendingPathComponent("steward.txt"), atomically: true, encoding: .utf8)
    }

    private static func row(_ t: StewardTask) -> String {
        var s = "  [\(t.state.rawValue)] \(t.title.prefix(110)) · \(t.agent)\(t.model.isEmpty ? "" : "/" + t.model)"
        if let pr = t.pr { s += " · PR #\(pr)" }
        if t.prBranch != nil { s += " (Korrektur)" }
        if let a = t.started { s += " · Start " + DateCoding.stamp(a).dropFirst(11).prefix(5) }
        if let e = t.finished { s += " · Ende " + DateCoding.stamp(e).dropFirst(11).prefix(5) }
        if let r = t.prRetry, r > 0 { s += " · PR-Reparatur \(r)" }
        if t.offlineWT != nil { s += " · offline gesichert" }
        if let m = t.missionID { s += " · " + m.prefix(8) }
        if let sk = t.skills, !sk.isEmpty { s += " · Skills: " + sk.joined(separator: ", ") }
        if let ex = t.exts, !ex.isEmpty { s += " · Erweiterungen: " + ex.map { ExtensionCatalog.find($0)?.name ?? $0 }.joined(separator: ", ") }
        if let n = t.note, !n.isEmpty { s += "\n      ↳ \(n.prefix(260))" }
        return s + "\n"
    }
}
