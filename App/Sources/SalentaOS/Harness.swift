import AgenticOSKit
import ApplicationServices
import Foundation
import SwiftUI

// Salenta Harness anbinden: Schlüssel aus dem Schlüsselbund als Umgebungsvariablen (nie im Klartext in Dateien),
// Bereitschaft prüfen (Node + Schlüssel oder Ollama).
enum HarnessSetup {
    static var script: URL { Paths.root.appendingPathComponent("bin/salenta-harness") }

    static var hasKey: Bool { ["deepseek", "anthropic", "openai", "openrouter"].contains { Secrets.has($0) } }

    static var ready: Bool {
        FileManager.default.fileExists(atPath: script.path) && Detection.which("node") != nil && (hasKey || OllamaApp.installed)
    }

    static var status: String {
        if Detection.which("node") == nil { return L("Node.js fehlt – im Terminal: brew install node") }
        if !FileManager.default.fileExists(atPath: script.path) { return L("Salenta Harness fehlt im App-Paket – neu installieren") }
        if hasKey { return L("Bereit – nutzt den ersten eingetragenen Schlüssel (DeepSeek, Anthropic, OpenAI, OpenRouter)") }
        if OllamaApp.installed { return L("Bereit mit lokalem Modell (Ollama) – für bessere Ergebnisse einen Schlüssel eintragen") }
        return L("Noch kein Modell: Schlüssel eintragen oder Ollama einrichten")
    }

    /// Arbeitsweise: „auto“ = selbstständig (nur Heikles fragt nach), „ask“ = mit Freigabe (jeder verändernde Befehl wird vorgelegt;
    /// im Auto-Modus winkt Salenta Code durch und protokolliert).
    static var approval: String { UserDefaults.standard.string(forKey: "harness.approval") == "ask" ? "ask" : "auto" }
    /// Browser- und Computer-Steuerung für den Harness (jede Nutzung braucht zusätzlich deine Freigabe mit Zeitlimit).
    static var browser: Bool { UserDefaults.standard.object(forKey: "harness.browser") as? Bool ?? true }
    static var computer: Bool { UserDefaults.standard.object(forKey: "harness.computer") as? Bool ?? true }

    /// Braucht der Auftrag einen echten Browser? (Seite öffnen, im Web etwas nachsehen oder bedienen)
    static func wantsBrowser(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["browser", "webseite", "website", "im web", "öffne die seite", "öffne http", "http://", "https://", "klick dich", "formular ausfüllen", "einloggen", "screenshot"]
            .contains { t.contains($0) }
    }

    static let keys = [("deepseek", "DEEPSEEK_API_KEY"), ("anthropic", "ANTHROPIC_API_KEY"), ("openai", "OPENAI_API_KEY"), ("openrouter", "OPENROUTER_API_KEY")]

    /// Shell-Exports für den Start. Die Schlüssel werden erst beim Start aus dem Schlüsselbund gelesen – unabhängig davon,
    /// ob die App sie schon nachgesehen hat (sonst fiel ein frisch gestarteter Lauf still auf das lokale Modell zurück).
    /// Nur wenn wirklich kein Schlüssel da ist, nimmt der Harness das lokale Modell.
    static func exports() -> String {
        var s = ""
        for (acc, env) in keys { s += "export \(env)=\(Secrets.shellValue(acc)); " }
        if let m = LocalFirst.shared.model {
            s += "if [ -z \"$DEEPSEEK_API_KEY$ANTHROPIC_API_KEY$OPENAI_API_KEY$OPENROUTER_API_KEY\" ]; then export SALENTA_HARNESS_PROVIDER=ollama SALENTA_HARNESS_MODEL=\(Shell.quote(m)); fi; "
        }
        return s
    }
}

/// Bedienungshilfen-Freigabe von macOS: ohne sie kann die Computer-Steuerung keine Fenster lesen oder bedienen.
/// Erteilen kann sie nur der Besitzer – wir zeigen den Stand und öffnen auf Wunsch die Abfrage von macOS.
enum AccessibilityAccess {
    static var granted: Bool { AXIsProcessTrusted() }

    /// Zeigt die Abfrage von macOS (trägt Salenta Code in die Liste ein) und öffnet die passende Seite der Systemeinstellungen.
    static func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
}

/// Einstellungen › Modelle: wie der Harness arbeitet und was er steuern darf.
struct HarnessControlSettings: View {
    @AppStorage("harness.approval") private var approval = "auto"
    @AppStorage("harness.browser") private var browser = true
    @AppStorage("harness.computer") private var computer = true
    @AppStorage("harness.decides") private var decides = true
    @State private var checking = false
    @State private var result: [String] = []
    @State private var axGranted = AccessibilityAccess.granted

    var body: some View {
        Toggle("Entscheidungsmodell: wählt für jeden Auftrag Agent, Modell und Denktiefe", isOn: $decides)
        Text("Läuft dauerhaft mit und braucht keinen eigenen Schlüssel: Vor jedem Auftrag entscheidet das stärkste Modell, das du schon hast (Claude oder Codex, je nachdem, was gerade verfügbar ist), wer ihn am besten ausführt und wie gründlich – und wer eine rote Prüfung behebt. Ausgeschaltet entscheidet ein kleines, schnelles Modell.")
            .font(.caption).foregroundStyle(.secondary)
        Picker("Arbeitsweise", selection: $approval) {
            Text("Selbstständig – nur Heikles fragt nach").tag("auto")
            Text("Mit Freigabe – jeder verändernde Befehl fragt nach").tag("ask")
        }
        Text("Heikel sind z. B. git push, Deploy, Löschen und sudo. „Mit Freigabe“ legt dir zusätzlich jeden Befehl vor, der etwas verändern kann; im Auto-Modus winkt Salenta Code durch und protokolliert. Dateien im Projekt darf der Harness in beiden Fällen ändern.")
            .font(.caption).foregroundStyle(.secondary)
        Toggle("Browser-Steuerung (Seiten öffnen, lesen, klicken, tippen)", isOn: $browser)
        Toggle("Computer-Steuerung (Apps öffnen, Fenster lesen, klicken, tippen)", isOn: $computer)
        if computer {
            HStack(spacing: Grid.s) {
                Image(systemName: axGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(axGranted ? .green : .orange)
                Text(axGranted ? L("macOS erlaubt Salenta Code die Bedienungshilfen") : L("macOS erlaubt die Bedienungshilfen noch nicht – ohne sie kann der Harness keine Fenster lesen oder bedienen")).font(.caption)
                Spacer()
                if !axGranted { Button(L("Erlauben …")) { AccessibilityAccess.request() } }
                Button { axGranted = AccessibilityAccess.granted } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help(L("Stand neu prüfen"))
            }
            .onAppear { axGranted = AccessibilityAccess.granted }
        }
        Text("Vor der ersten Nutzung fragt Salenta Code, für wie lange (15 Minuten, 1 Stunde, ganzer Tag). Absenden, Kaufen, Bezahlen, Löschen und Posten fragen immer einzeln. Für die Computer-Steuerung muss Salenta Code in den Systemeinstellungen unter „Datenschutz & Sicherheit › Bedienungshilfen“ erlaubt sein.")
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            Button(checking ? L("Prüft …") : L("Harness prüfen")) {
                checking = true; result = []
                HarnessCheck.run { lines in result = lines; checking = false }
            }.disabled(checking || !HarnessSetup.ready)
            if checking { ProgressView().controlSize(.small) }
        }
        ForEach(result, id: \.self) { line in
            Text(line).font(.caption.monospaced()).foregroundStyle(line.hasPrefix("✗") ? .red : line.hasPrefix("–") ? .secondary : .primary)
                .textSelection(.enabled)
        }
    }
}

/// Prüft den Harness auf diesem Mac von Ende zu Ende: Schlüssel, eine echte Modell-Antwort, Dateien schreiben,
/// Werkzeug-Server (Salenta Code, Browser) und die Computer-Steuerung (nur lesend – verändert nichts).
enum HarnessCheck {
    static var running = false

    static func run(completion: (([String]) -> Void)? = nil) {
        guard !running else { return }
        running = true
        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [String] = []
            let h = Shell.quote(HarnessSetup.script.path)
            let env = HarnessSetup.exports()
            func sh(_ cmd: String, timeout: TimeInterval = 180, in dir: String = NSTemporaryDirectory()) -> (out: String, code: Int32) {
                Proc.zsh(env + cmd, in: dir, timeout: timeout)
            }
            func add(_ ok: Bool?, _ text: String) { lines.append((ok == true ? "✓ " : ok == false ? "✗ " : "– ") + text) }

            // 1. Anbieter und Schlüssel
            let doc = sh("\(h) doctor", timeout: 30)
            let chosen = doc.out.split(separator: "\n").last { $0.hasPrefix("Gewählt") }.map(String.init) ?? ""
            add(doc.code == 0 && !chosen.isEmpty, L("Anbieter:") + " " + (chosen.isEmpty ? String(doc.out.suffix(160)) : chosen))

            // 2. Echte Antwort vom Modell
            let hello = sh("\(h) --json --access read --max-steps 2 --preset minimal 'Antworte nur mit dem Wort OK.'", timeout: 120)
            let answered = hello.out.contains("\"status\":\"success\"")
            add(answered, answered ? L("Modell antwortet") : L("Modell antwortet nicht:") + " " + errorLine(hello.out))

            // 3. Dateien schreiben (in einem Wegwerf-Ordner)
            if answered {
                let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("salenta-harness-check-" + String(UUID().uuidString.prefix(6)))
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let w = sh("\(h) --json --access project --max-steps 6 --cwd \(Shell.quote(dir)) 'Lege die Datei hallo.txt mit genau dem Inhalt Hallo an. Danach bist du fertig.'", timeout: 180, in: dir)
                let made = (try? String(contentsOfFile: (dir as NSString).appendingPathComponent("hallo.txt"), encoding: .utf8))?.contains("Hallo") == true
                add(made, made ? L("Werkzeuge: Datei angelegt") : L("Werkzeuge: Datei nicht angelegt:") + " " + errorLine(w.out))
                try? FileManager.default.removeItem(atPath: dir)
            }

            // 4. Werkzeug-Server: Salenta Code (Freigaben) – ohne Modell
            let cfg = Shell.quote(OSAgent.aosOnlyConfig.path)
            let tools = sh("\(h) tools --mcp-config \(cfg)", timeout: 90)
            let hasApp = tools.out.contains("mcp__salenta-os__freigabe")
            add(hasApp, hasApp ? L("Freigaben über Salenta Code verbunden") : L("Salenta Code nicht verbunden:") + " " + String(tools.out.suffix(200)))

            // 4b. Ein echter Lauf wie aus der App: mit Freigabe arbeiten, ein Befehl geht über Salenta Code (harmlos: Ordner anlegen)
            if answered, hasApp {
                let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("salenta-harness-check-" + String(UUID().uuidString.prefix(6)))
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let r = sh("\(h) --json --access project --approval ask --mcp-config \(cfg) --max-steps 6 --cwd \(Shell.quote(dir)) 'Führe genau diesen Befehl aus: mkdir probe-ordner – danach bist du fertig.'", timeout: 150, in: dir)
                var isDir: ObjCBool = false
                let made = FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("probe-ordner"), isDirectory: &isDir) && isDir.boolValue
                add(made, made ? L("Mit Freigabe arbeiten: Befehl lief über Salenta Code") : L("Mit Freigabe arbeiten klappt nicht:") + " " + errorLine(r.out))
                try? FileManager.default.removeItem(atPath: dir)
            }

            // 5. Browser – nur wenn eingeschaltet
            if HarnessSetup.browser {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("salenta-harness-browser-\(UUID().uuidString.prefix(6)).json")
                let j: [String: Any] = ["mcpServers": ["browser": ["command": "/bin/zsh", "args": ["-lc", "npx -y @playwright/mcp@latest --headless"]]]]
                try? JSONSerialization.data(withJSONObject: j).write(to: file)
                let b = sh("\(h) tools --mcp-config \(Shell.quote(file.path))", timeout: 150)
                let n = b.out.split(separator: "\n").filter { $0.hasPrefix("mcp__browser__") }.count
                add(n > 0, n > 0 ? String(format: L("Browser-Steuerung: %d Werkzeuge"), n) : L("Browser-Steuerung nicht startbar (Node/npx nötig):") + " " + String(b.out.suffix(200)))
                try? FileManager.default.removeItem(at: file)
            } else { add(nil, L("Browser-Steuerung ist ausgeschaltet")) }

            // 6. Computer-Steuerung: Skripte übersetzen und laufende Apps lesen (verändert nichts)
            if HarnessSetup.computer {
                let c = sh("\(h) computer-check", timeout: 90)
                for l in c.out.split(separator: "\n") where l.hasPrefix("✓") || l.hasPrefix("✗") {
                    lines.append(String(l.prefix(1)) + " " + L("Computer-Steuerung:") + String(l.dropFirst(1)))
                }
                if c.out.isEmpty { add(false, L("Computer-Steuerung: Prüfung lief nicht")) }
            } else { add(nil, L("Computer-Steuerung ist ausgeschaltet")) }

            // 7. Entwickler-Build: die eigenen Tests des Harness
            let tests = Paths.source.appendingPathComponent("bin/harness/test/harness.test.mjs")
            if Paths.isDevBuild, FileManager.default.fileExists(atPath: tests.path) {
                let t = sh("node --test \(Shell.quote(tests.path)) 2>&1 | grep -E '^# (pass|fail)'", timeout: 240)
                add(t.out.contains("# fail 0"), L("Harness-Tests:") + " " + t.out.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "# ", with: ""))
            }

            let text = "Salenta Harness – Prüfung \(DateCoding.stamp(Date()))\n\n" + lines.joined(separator: "\n") + "\n"
            let url = (Paths.isDevBuild ? Paths.source : Paths.root).appendingPathComponent("logs/harness-check.txt")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
            DispatchQueue.main.async { running = false; completion?(lines) }
        }
    }

    /// Entwickler-Test: bedient wirklich eine App – öffnet den Rechner, klickt 7 + 8 = und prüft die Anzeige. Ergebnis: logs/computer-live.txt.
    static func live() {
        DispatchQueue.global(qos: .userInitiated).async {
            // Fehlt die Bedienungshilfen-Freigabe, die Abfrage von macOS zeigen – erteilen kann sie nur der Besitzer
            let trusted = AccessibilityAccess.granted
            if !trusted { DispatchQueue.main.async { AccessibilityAccess.request() } }
            var r = Proc.zsh("\(Shell.quote(HarnessSetup.script.path)) computer-check --live", in: NSTemporaryDirectory(), timeout: 240)
            r.out = (trusted ? "✓ Salenta Code hat die Bedienungshilfen-Freigabe" : "✗ Salenta Code hat die Bedienungshilfen-Freigabe noch nicht – die Abfrage von macOS wurde geöffnet") + "\n" + r.out
            let url = Paths.source.appendingPathComponent("logs/computer-live.txt")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? ("Computer-Steuerung live – \(DateCoding.stamp(Date()))\n\n" + r.out + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Entwickler-Test: der Harness bedient eine echte Seite im Browser – öffnen, tippen, klicken, Ergebnis lesen.
    /// Die Seite liegt nur auf diesem Mac (Wegwerf-Ordner, lokale Adresse). Ergebnis: logs/browser-live.txt.
    static func browserLive() {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("salenta-browser-live-" + String(UUID().uuidString.prefix(6)))
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let html = """
            <!doctype html><html lang="de"><head><meta charset="utf-8"><title>Probe</title></head><body>
            <h1>Probe</h1><label>Wort <input id="wort" aria-label="Wort"></label> <button id="los">Anzeigen</button><p id="aus"></p>
            <script>document.getElementById('los').onclick=function(){var w=document.getElementById('wort').value;document.getElementById('aus').textContent='Code: '+w.split('').reverse().join('')+'-7391'}</script>
            </body></html>
            """
            try? html.write(toFile: (dir as NSString).appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
            let port = Int.random(in: 41000...48999)
            let server = Process()
            server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            server.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1"]
            server.currentDirectoryURL = URL(fileURLWithPath: dir)
            server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
            try? server.run()
            defer { if server.isRunning { server.terminate() }; try? fm.removeItem(atPath: dir) }
            let cfg = (dir as NSString).appendingPathComponent("mcp.json")
            let j: [String: Any] = ["mcpServers": ["browser": ["command": "/bin/zsh", "args": ["-lc", "npx -y @playwright/mcp@latest --headless --isolated"]]]]
            try? JSONSerialization.data(withJSONObject: j).write(to: URL(fileURLWithPath: cfg))
            let task = "Öffne im Browser die Adresse http://127.0.0.1:\(port)/ . Tippe das Wort Salenta in das Textfeld, klicke den Knopf „Anzeigen“ und lies den Text, der darunter erscheint. Antworte nur mit genau diesem Text."
            // Freigaben erteilt hier ein Programm (immer ja) – es ist ein Test auf einer eigenen, lokalen Seite
            let r = Proc.zsh(HarnessSetup.exports() + "export SALENTA_APPROVE=/usr/bin/true; \(Shell.quote(HarnessSetup.script.path)) --json --access project --mcp-config \(Shell.quote(cfg)) --max-steps 16 --cwd \(Shell.quote(dir)) \(Shell.quote(task))",
                             in: dir, timeout: 420)
            let calls = r.out.components(separatedBy: "\"tool_name\":\"mcp__browser__").dropFirst().map { String($0.prefix(while: { $0 != "\"" })) }
            let ok = r.out.contains("atnelaS-7391")
            var lines = [(ok ? "✓ " : "✗ ") + (ok ? "Seite geöffnet, getippt, geklickt und das Ergebnis gelesen (Code stimmt)" : "Ergebnis nicht gelesen: " + errorLine(r.out))]
            lines.append("  Browser-Schritte: " + (calls.isEmpty ? "keine" : calls.joined(separator: " → ")))
            let url = Paths.source.appendingPathComponent("logs/browser-live.txt")
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? ("Browser-Steuerung live – \(DateCoding.stamp(Date()))\n\n" + lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Die Fehlermeldung aus dem Ereignisstrom – ohne Schlüssel oder lange Ausgaben.
    private static func errorLine(_ out: String) -> String {
        for line in out.split(separator: "\n").reversed() {
            guard let d = line.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if let m = j["message"] as? String, j["type"] as? String == "error" { return String(m.prefix(200)) }
            if j["type"] as? String == "result", let r = j["result"] as? String { return String(r.prefix(200)) }
        }
        return String(out.suffix(200)).replacingOccurrences(of: "\n", with: " ")
    }
}
