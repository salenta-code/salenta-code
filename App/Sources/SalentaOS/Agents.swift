import AgenticOSKit
import AppKit
import SwiftTerm
import SwiftUI

/// Wie ein Agent arbeitet: im Dialog mit dir oder selbstständig bis zum Ergebnis.
enum RunMode: String, CaseIterable, Identifiable {
    case interaktiv, autonom
    var id: String { rawValue }
    var title: String { self == .interaktiv ? L("Interaktiv") : L("Autonom") }
    var symbol: String { self == .interaktiv ? "bubble.left.and.text.bubble.right" : "bolt.fill" }
}

/// Eine laufende Terminal-Sitzung: Claude Code, Codex, Junie oder eine Shell.
/// Die NSView bleibt am Leben, auch wenn du die Seite wechselst.
final class AgentSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id: UUID
    let kind: AgentKind
    let mode: RunMode
    let directory: URL
    let startedAt: Date
    /// Läuft in einer Hintergrund-Sitzung (tmux) und überlebt das Schließen der App.
    private(set) var persistent = false
    private(set) var onlyChosenSkills = false
    /// Wieder an eine laufende Hintergrund-Sitzung anhängen statt neu zu starten.
    let attach: Bool
    let taskID: String?
    /// Woran gearbeitet wird (Aufgabentitel oder Auftrag).
    let label: String
    @Published var title: String
    @Published var running = true
    @Published var exitCode: Int32?
    @Published var endedAt: Date?

    var onFinish: ((AgentSession) -> Void)?

    let view: LocalProcessTerminalView

    /// Eigener Agent im Salenta Code (MCP-Konfiguration mit allen Anbindungen + Browser).
    let osAgentConfig: URL?
    /// Zusätzliche Tools (MCP) für Coding-Läufe – nur die, die der Auftrag braucht.
    var codingConfig: URL?
    /// Eigene Arbeitskopie (git worktree) bei Coding-Aufträgen.
    var worktree: WorktreeInfo?
    /// Bestehende Claude-Code-/Codex-Sitzung fortsetzen (Sitzungs-ID).
    var resumeID: String?
    /// Selbstständige Folgerunde: dieselbe Claude-Sitzung im Hintergrund fortsetzen (`claude -p --resume`).
    var continueSession: String?
    /// Claude darf Chrome nutzen (Claude in Chrome) – z. B. um die gebaute Seite selbst zu testen.
    var chrome = false
    /// Modell (Claude: opus/sonnet/haiku, Codex: Modell-ID) und Denktiefe (Codex: low/medium/high). nil = Standard des Agents.
    let model: String?
    let effort: String?
    /// Nur planen, nichts ändern (Claude: --permission-mode plan, Codex: read-only).
    let planOnly: Bool
    /// Voller Zugriff (von dir pro Auftrag gewählt): Claude ohne Rückfragen, Codex ohne Sandbox.
    let fullAccess: Bool
    var isOSAgent: Bool { osAgentConfig != nil }
    var displayName: String { isOSAgent ? "OS-Agent" : kind.title }

    init(kind: AgentKind, mode: RunMode, directory: URL, prompt: String?, taskID: String?, label: String?, osAgentConfig: URL? = nil,
         resumeID: String? = nil, model: String? = nil, effort: String? = nil, codingConfig: URL? = nil,
         id: UUID = UUID(), startedAt: Date = Date(), attach: Bool = false, planOnly: Bool = false,
         continueSession: String? = nil, chrome: Bool = false, onlyChosenSkills: Bool = false, fullAccess: Bool = false) {
        self.planOnly = planOnly
        self.fullAccess = fullAccess && !planOnly
        self.onlyChosenSkills = onlyChosenSkills
        self.continueSession = continueSession
        self.chrome = chrome
        self.id = id
        self.startedAt = startedAt
        self.attach = attach
        self.codingConfig = codingConfig
        self.model = model?.isEmpty == true ? nil : model
        self.effort = effort?.isEmpty == true ? nil : effort
        self.osAgentConfig = osAgentConfig
        self.resumeID = resumeID
        self.kind = kind
        self.mode = mode
        self.directory = directory
        self.taskID = taskID
        self.label = label ?? kind.title
        self.title = kind.title
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        super.init()
        view.processDelegate = self
        view.font = NSFont(name: "SF Mono", size: 13.5) ?? NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
        view.nativeBackgroundColor = NSColor(hex: 0x16161B)
        view.nativeForegroundColor = NSColor(hex: 0xE7E7EA)
        view.optionAsMetaKey = false // damit @, €, [ ] auf der deutschen Tastatur funktionieren
        start(prompt: prompt)
    }

    /// Ausgabe autonomer Läufe (für die Zusammenfassung an der Aufgabe).
    var logFile: URL {
        let dir = Paths.root.appendingPathComponent("logs/runs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = DateCoding.day(startedAt)
        return dir.appendingPathComponent("\(stamp)-\(kind.rawValue)-\(id.uuidString.prefix(6)).log")
    }

    /// Die letzten Zeilen der Ausgabe eines autonomen Laufs.
    func resultTail(maxChars: Int = 1200) -> String? {
        guard mode == .autonom, let text = try? String(contentsOf: logFile, encoding: .utf8) else { return nil }
        // ANSI-Farbcodes entfernen
        let clean = text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count > maxChars ? "…" + String(clean.suffix(maxChars)) : clean
    }

    private func start(prompt: String?) {
        if attach {
            persistent = true
            reattach()
            return
        }
        // Die PID-Datei erlaubt sauberes Beenden.
        var command = "echo $$ > \(Shell.quote(pidFile.path)); cd \(Shell.quote(directory.path)) && " + Accounts.shared.exports()
        var promptArg = ""
        var promptFile = ""
        if let prompt, !prompt.isEmpty {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("aos-prompt-\(id.uuidString).md")
            try? prompt.write(to: file, atomically: true, encoding: .utf8)
            promptFile = Shell.quote(file.path)
            promptArg = " \"$(cat \(promptFile))\""
        }
        let hasPrompt = !promptArg.isEmpty
        // Modellwahl: Claude Code --model, Codex -m und Denktiefe.
        // Denkstufe passend zur Aufgabe – auch bei Claude (wenn die installierte Version sie kennt)
        // Lokal (Ollama) und OpenRouter: das Modell steht schon in der Umgebung (ANTHROPIC_MODEL) – ein --model mit
        // „qwen3-coder:latest“ lehnt Claude Code als unbekanntes Modell ab (unrecognized_model)
        let modelViaEnv = kind == .ollama || kind == .openrouter
        let claudeModel = (modelViaEnv ? "" : (model.map { " --model \(Shell.quote($0))" } ?? ""))
            + (kind.harness == .claude ? (effort.map { CLIFlags.shared.pick(.claude, ["--effort \($0)"]) } ?? "") : "")
        var codexOpts = model.map { " -m \(Shell.quote($0))" } ?? ""
        if let effort { codexOpts += " -c model_reasoning_effort=\(Shell.quote(effort))" }
        if kind == .codex, OpenModels.codexUsesAPIKey { codexOpts += " -c preferred_auth_method=\"apikey\"" }
        // Anbieter-Umgebung (OpenRouter/Ollama-Server, API-Schlüssel aus dem Schlüsselbund – nie im Klartext)
        // Nur lokal / offline: auch dein OS-Agent läuft über das lokale Modell
        if osAgentConfig != nil, LocalFirst.shared.useLocal, let lm = LocalFirst.shared.model {
            command += OpenModels.exports(for: .ollama, model: lm)
        } else {
            command += OpenModels.exports(for: osAgentConfig != nil ? .claude : kind, model: model)
        }
        // Nur lokal, aber kein lokales Modell: lieber nicht starten als heimlich die Cloud nutzen
        if LocalFirst.shared.localOnlyBlocked, kind != .shell, kind != .ollama, osAgentConfig != nil || LocalFirst.cloudKinds.contains(kind) {
            command += "echo '\(L("Nur lokal ist an, aber kein lokales Modell ist bereit. Einstellungen › Modelle › Lokal."))'; exit 3; "
        }
        let log = Shell.quote(logFile.path)
        let live = Shell.quote(Paths.root.appendingPathComponent("bin/aos-live").path)
        // Helfer-Befehle laufen in bash (zsh bricht bei Mustern ohne Treffer ab und teilt Variablen nicht auf) –
        // und bin/ liefert ein `timeout`, das macOS nicht mitbringt
        if mode == .autonom, osAgentConfig == nil {
            // Helfer mit niedrigerer Priorität (vererbt sich auf Tests, Builds, Worker): die Oberfläche bleibt flüssig
            command += "renice -n 10 -p $$ >/dev/null 2>&1; "
            command += "export SHELL=/bin/bash; export PATH=\(Shell.quote(Paths.root.appendingPathComponent("bin").path)):$PATH; "
            // Test-Runner drosseln: zwei Worker je Helfer reichen – bei vier Helfern wären es sonst 4×(alle Kerne) → Volllast und Hitze
            command += "export VITEST_MAX_THREADS=2 VITEST_MAX_FORKS=2 VITEST_MIN_THREADS=1 VITEST_MIN_FORKS=1 JEST_MAX_WORKERS=2 UV_THREADPOOL_SIZE=4; "
        }

        if let rid = resumeID {
            command += kind == .codex ? "exec codex resume \(Shell.quote(rid))" : "exec claude --resume \(Shell.quote(rid))"
        } else if let cfg = osAgentConfig, kind == .codex {
            // OS-Agent über Codex: eigene, private Codex-Konfiguration (Anmeldung wie gewohnt) plus die verbundenen MCP-Tools.
            // Keine Schlüssel auf der Befehlszeile – alles steht in einer Datei, die nur du lesen kannst.
            let home = OSAgentCodex.home(id: id, mcp: sessionConfig(cfg))
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("aos-os-codex-\(id.uuidString).md")
            try? (OSAgent.rules + "\n\n---\n\n" + (prompt ?? "")).write(to: file, atomically: true, encoding: .utf8)
            let json = CLIFlags.shared.pick(.codex, sub: "exec", ["--json", "--experimental-json"])
            command += "export CODEX_HOME=\(Shell.quote(home)); codex exec\(codexOpts) -s workspace-write -c sandbox_workspace_write.network_access=true\(CLIFlags.shared.pick(.codex, sub: "exec", ["--skip-git-repo-check"]))\(json) - < \(Shell.quote(file.path))"
                + " 2>>\(Shell.quote(logFile.path + ".stderr")) | python3 -u \(live) --log \(log); exit ${pipestatus[1]}"   // Codex-Protokoll getrennt, die Ansicht bleibt lesbar
        } else if let cfg = osAgentConfig {
            let rules = FileManager.default.temporaryDirectory.appendingPathComponent("aos-rules-\(id.uuidString).md")
            try? OSAgent.rules.write(to: rules, atomically: true, encoding: .utf8)
            let allowed = Shell.quote(OSAgent.allowedTools.joined(separator: ","))
            command += "claude -p\(claudeModel) --output-format stream-json --verbose --mcp-config \(Shell.quote(sessionConfig(cfg).path))"
                + " --permission-prompt-tool mcp__salenta-os__freigabe --allowedTools \(allowed)"
                + " --append-system-prompt \"$(cat \(Shell.quote(rules.path)))\" < \(promptFile)"
                + " 2>&1 | python3 -u \(live) --log \(log); exit ${pipestatus[1]}"
        } else {
        // Optionen so, wie die installierte CLI-Version sie kennt (liest --help, aktualisiert sich nach Updates)
        let F = CLIFlags.shared
        switch (kind.harness, mode) {
        case (.shell, _):
            command += "exec zsh -l"
        case (.claude, .interaktiv):
            command += "exec claude\(claudeModel)\(ApprovalMode.isAuto ? F.pick(.claude, ["--dangerously-skip-permissions", "--permission-mode bypassPermissions"]) : "")\(promptArg)"
        case (.codex, .interaktiv):
            command += "exec codex\(codexOpts)\(ApprovalMode.isAuto ? F.pick(.codex, ["--dangerously-bypass-approvals-and-sandbox", "--yolo"]) : "")\(promptArg)"
        case (.junie, .interaktiv):
            command += hasPrompt ? "exec junie --prompt\(promptArg)" : "exec junie"
        case (.claude, .autonom):
            // Live-Strom statt "nichts bis zum Ende": jeder Schritt wird lesbar angezeigt.
            // Dateien ändern darf er direkt; Befehle wie git push oder Löschen fragen dich über die Freigabe-Leiste.
            let cont = continueSession.map { " --resume " + Shell.quote($0) } ?? ""
            let browser = chrome ? F.pick(.claude, ["--chrome"]) : ""
            // Nur die gewählten Skills: alle anderen bleiben ungeladen (ihre Beschreibungen kosten sonst bei jedem Start Kontext)
            let diet = self.onlyChosenSkills ? F.pick(.claude, ["--disable-slash-commands"]) : ""
            command += "claude -p\(claudeModel)\(cont)\(browser)\(diet)\(F.pick(.claude, ["--permission-mode \(planOnly ? "plan" : fullAccess ? "bypassPermissions" : "acceptEdits")"])) --output-format stream-json --verbose"
                + " --mcp-config \(Shell.quote(sessionConfig(codingConfig ?? OSAgent.aosOnlyConfig).path)) --permission-prompt-tool mcp__salenta-os__freigabe"
                + " --allowedTools 'mcp__salenta-os'"
                + " < \(promptFile) 2>&1 | python3 -u \(live) --log \(log); exit ${pipestatus[1]}"
        case (.codex, .autonom):
            let sandbox = planOnly ? F.pick(.codex, sub: "exec", ["--sandbox read-only", "-s read-only"])
                : fullAccess ? F.pick(.codex, sub: "exec", ["--sandbox danger-full-access", "-s danger-full-access"])
                : F.pick(.codex, sub: "exec", ["--full-auto", "--sandbox workspace-write", "-s workspace-write"])
            let json = F.pick(.codex, sub: "exec", ["--json", "--experimental-json"])
            // In einer Arbeitskopie liegt das Git-Verzeichnis im Haupt-Repo – ohne Freigabe kann Codex dort nicht einmal committen
            var addDir = ""
            if !planOnly, Worktrees.isWorktree(directory.path) {
                let common = Git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory.path, timeout: 10).out.trimmingCharacters(in: .whitespacesAndNewlines)
                if !common.isEmpty, F.supports(.codex, "--add-dir", sub: "exec") == true { addDir = " --add-dir " + Shell.quote(common) }
                // Zusätzlich über die Konfiguration (wirkt auch, wenn die Option in der Hilfe fehlt): Git-Verzeichnis beschreibbar,
                // und lokale Testserver (Dev-Server, Deno.serve) erlaubt – sonst gelten Tests fälschlich als rot
                if !common.isEmpty {
                    addDir += " -c " + Shell.quote("sandbox_workspace_write.writable_roots=[\"\(common)\"]")
                }
                addDir += " -c sandbox_workspace_write.network_access=true"
            }
            command += "codex exec\(codexOpts)\(sandbox)\(addDir)\(json)\(promptArg) 2>&1 | python3 -u \(live) --log \(log); exit ${pipestatus[1]}"
        case (.junie, .autonom):
            command += "junie\(F.pick(.junie, ["--skip-update-check"]))\(F.pick(.junie, ["--output-format json-stream"]))\(promptArg) 2>&1 | python3 -u \(live) --log \(log); exit ${pipestatus[1]}"
        // Weitere Coding-Agents
        case (.cursor, .interaktiv):
            command += "exec \(Agents.cursorBin)\(claudeModel)\(ApprovalMode.isAuto ? F.pick(.cursor, ["--force", "--yolo"]) : "")\(promptArg)"
        case (.cursor, .autonom):
            command += "\(Agents.cursorBin) -p\(F.pick(.cursor, ["--force", "--yolo"]))\(F.pick(.cursor, ["--output-format stream-json"]))\(claudeModel)\(promptArg) 2>&1 | python3 -u \(live) --log \(log); exit ${pipestatus[1]}"
        case (.opencode, .interaktiv):
            command += hasPrompt ? "exec opencode\(claudeModel) --prompt\(promptArg)" : "exec opencode\(claudeModel)"
        case (.opencode, .autonom):
            command += "opencode run\(claudeModel)\(F.pick(.opencode, sub: "run", ["--format json"]))\(promptArg) 2>&1 | python3 -u \(live) --log \(log); exit ${pipestatus[1]}"
        case (.gemini, .interaktiv):
            command += "exec gemini\(claudeModel)\(ApprovalMode.isAuto ? F.pick(.gemini, ["--yolo", "--approval-mode yolo"]) : "")\(hasPrompt ? F.pick(.gemini, ["-i", "--prompt-interactive"]) + promptArg : "")"
        case (.gemini, .autonom):
            command += "gemini\(claudeModel)\(F.pick(.gemini, ["--yolo", "--approval-mode yolo"]))\(F.pick(.gemini, ["--output-format stream-json"])) -p\(promptArg) 2>&1 | python3 -u \(live) --log \(log); exit ${pipestatus[1]}"
        case (.grok, .interaktiv):
            command += "exec grok\(claudeModel)\(ApprovalMode.isAuto ? F.pick(.grok, ["--always-approve", "--yolo"]) : "")\(promptArg)"
        case (.grok, .autonom):
            command += "grok -p\(promptArg)\(claudeModel)\(F.pick(.grok, ["--always-approve", "--yolo"])) 2>&1 | python3 -u \(live) --log \(log); exit ${pipestatus[1]}"
        case (.kiro, .interaktiv):
            command += "exec kiro-cli chat\(claudeModel)\(ApprovalMode.isAuto ? F.pick(.kiro, sub: "chat", ["--trust-all-tools"]) : "")\(promptArg)"
        case (.kiro, .autonom):
            command += "kiro-cli chat\(F.pick(.kiro, sub: "chat", ["--no-interactive"]))\(F.pick(.kiro, sub: "chat", ["--trust-all-tools"]))\(claudeModel)\(promptArg) 2>&1 | python3 -u \(live) --log \(log); exit ${pipestatus[1]}"
        case (.pi, .interaktiv):
            command += "exec pi\(claudeModel)\(promptArg)"
        case (.pi, .autonom):
            command += "pi -p\(claudeModel)\(promptArg) 2>&1 | python3 -u \(live) --log \(log); exit ${pipestatus[1]}"
        // Kimi Code: Startauftrag läuft im Print-Modus, danach geht's in derselben Sitzung interaktiv weiter
        case (.kimi, .interaktiv):
            let approve = ApprovalMode.isAuto ? F.pick(.kimi, ["--yolo", "--auto"]) : ""
            command += hasPrompt ? "kimi\(claudeModel) -p\(promptArg); exec kimi --continue\(claudeModel)\(approve)" : "exec kimi\(claudeModel)\(approve)"
        case (.kimi, .autonom):
            command += "kimi -p\(promptArg)\(claudeModel)\(F.pick(.kimi, ["--output-format text"])) 2>&1 | python3 -u \(live) --log \(log); exit ${pipestatus[1]}"
        // DeepSeek Harness: ein Auftrag läuft im Headless-Profil (Ergebnis wird ausgegeben); interaktiv danach eine Shell im Projekt
        case (.deepseek, .interaktiv):
            command += hasPrompt ? "dsh --profile headless\(promptArg); exec zsh -l" : "exec zsh -l"
        // Salenta Harness: eigener Agent. Zugriffsstufe wird im Harness selbst erzwungen; JSON-Strom → Live-Ansicht.
        case (.harness, _):
            let access = planOnly ? "read" : fullAccess ? "full" : "project"
            let h = Shell.quote(Paths.root.appendingPathComponent("bin/salenta-harness").path)
            command += HarnessSetup.exports() + "\(h) --json --access \(access)\(model.map { " --model " + Shell.quote($0) } ?? "")\(promptArg) 2>&1 | python3 -u \(live) --log \(log); "
                + (mode == .interaktiv ? "exec zsh -l" : "exit ${pipestatus[1]}")
        case (.deepseek, .autonom):
            command += "dsh --profile headless\(promptArg) 2>&1 | python3 -u \(live) --log \(log); exit ${pipestatus[1]}"
        default:
            command += "exec zsh -l"
        }
        }

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["AOS_HOME"] = Paths.root.path
        env["AOS_SOURCE"] = kind.rawValue
        env["TERM_PROGRAM"] = "AgenticOS"
        env["SHELL_SESSIONS_DISABLE"] = "1"
        env["MCP_TOOL_TIMEOUT"] = "960000"
        env["AOS_MISSION_ID"] = id.uuidString   // Freigaben dürfen bis zu 15 Minuten warten
        if !Git.hasIdentity(directory.path) {
            // ohne eingerichtete Git-Identität würden Commits der Agents scheitern – nur für diese Sitzung setzen
            env["GIT_AUTHOR_NAME"] = Git.fallbackName; env["GIT_COMMITTER_NAME"] = Git.fallbackName
            env["GIT_AUTHOR_EMAIL"] = Git.fallbackEmail; env["GIT_COMMITTER_EMAIL"] = Git.fallbackEmail
        }
        env.removeValue(forKey: "TERM_SESSION_ID")
        if env["LANG"] == nil { env["LANG"] = "de_DE.UTF-8" }
        // Sparsame Suche für alle Agents (ripgrep ohne node_modules, Build-Ordner, große Dateien)
        if kind != .shell { env["RIPGREP_CONFIG_PATH"] = PowerProfile.ripgrepConfig.path }
        let envList = env.map { "\($0.key)=\($0.value)" }

        // Hintergrund-Sitzung: der Agent läuft in tmux weiter, auch wenn Salenta Code geschlossen wird.
        if Persist.enabled, let tmux = Persist.tmux {
            persistent = true
            var inner = command.replacingOccurrences(of: "&& exec ", with: "&& ")
            inner = inner.replacingOccurrences(of: "; exit ${pipestatus[1]}", with: "; __rc=${pipestatus[1]}")
            let keep = ["AOS_HOME", "AOS_SOURCE", "TERM_PROGRAM", "MCP_TOOL_TIMEOUT", "AOS_MISSION_ID", "LANG", "COLORTERM", "SHELL_SESSIONS_DISABLE"]
            let exports = keep.compactMap { k in env[k].map { "export \(k)=\(Shell.quote($0))" } }.joined(separator: "\n")
            // Leistungsprofil: diese Sitzung (und alles, was sie startet) auf die sparsamen Kerne
            let qos = kind == .shell || PowerProfile.taskpolicyArgs.isEmpty ? "" : "/usr/sbin/taskpolicy \(PowerProfile.taskpolicyArgs.joined(separator: " ")) -p $$ 2>/dev/null\n"
            let script = "\(exports)\nexport RIPGREP_CONFIG_PATH=\(Shell.quote(PowerProfile.ripgrepConfig.path))\nunset TMUX\n\(qos)\(inner)\n__rc=${__rc:-$?}\nprint -r -- $__rc > \(Shell.quote(Persist.exitFile(id).path))\n"
            let file = Persist.scriptFile(id)
            try? script.write(to: file, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: Persist.exitFile(id))
            let launch = "\(Shell.quote(tmux)) -L \(Persist.socket) -f \(Shell.quote(Persist.conf.path)) new-session -A -s \(Persist.name(id)) -x 200 -y 50 \(Shell.quote("/bin/zsh -li " + Shell.quote(file.path)))"
            view.startProcess(executable: "/bin/zsh", args: ["-l", "-c", launch], environment: envList, execName: "zsh")
            return
        }
        if kind != .shell, !PowerProfile.taskpolicyArgs.isEmpty, FileManager.default.isExecutableFile(atPath: "/usr/sbin/taskpolicy") {
            view.startProcess(executable: "/usr/sbin/taskpolicy", args: PowerProfile.taskpolicyArgs + ["/bin/zsh", "-l", "-i", "-c", command], environment: envList, execName: "zsh")
            return
        }
        view.startProcess(executable: "/bin/zsh", args: ["-l", "-i", "-c", command], environment: envList, execName: "zsh")
    }

    /// An die laufende Hintergrund-Sitzung anhängen (nach einem Neustart von Salenta Code).
    func reattach() {
        guard let tmux = Persist.tmux else { return }
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env.removeValue(forKey: "TMUX")
        let cmd = "\(Shell.quote(tmux)) -L \(Persist.socket) -f \(Shell.quote(Persist.conf.path)) attach-session -t \(Persist.name(id))"
        view.startProcess(executable: "/bin/zsh", args: ["-l", "-c", cmd], environment: env.map { "\($0.key)=\($0.value)" }, execName: "zsh")
    }

    /// Die letzten sichtbaren Zeilen des Terminals – für Live-Vorschauen.
    func screenTail(_ count: Int = 8) -> [String] {
        let t = view.getTerminal()
        var lines: [String] = []
        for r in 0..<t.rows {
            lines.append(t.getLine(row: r)?.translateToString(trimRight: true) ?? "")
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return Array(lines.suffix(count))
    }

    /// PID der Shell dieser Sitzung (für die Prozessübersicht).
    var shellPID: Int32? {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var pidFile: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("aos-\(id.uuidString).pid")
    }

    func terminate() {
        if persistent {
            Persist.kill(id)
            running = false
            return
        }
        if running,
           let text = try? String(contentsOf: pidFile, encoding: .utf8),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 {
            kill(pid, SIGHUP)
        }
        try? FileManager.default.removeItem(at: pidFile)
        running = false
    }

    /// Tippt Text ins Terminal (z. B. eine Folgeanweisung).
    func send(_ text: String) {
        view.send(txt: text)
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async {
            let t = title.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { self.title = t }
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// MCP-Konfiguration nur für diese Sitzung: Salenta Code weiß so, aus welchem Auftrag ein Tool-Aufruf kommt (Delegation).
    private var sessionConfigURL: URL { OSAgent.supportDir.appendingPathComponent("mcp-\(id.uuidString).json") }

    private func sessionConfig(_ base: URL) -> URL {
        guard let d = try? Data(contentsOf: base),
              var j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              var servers = j["mcpServers"] as? [String: Any],
              var aos = servers["salenta-os"] as? [String: Any] else { return base }
        var env = aos["env"] as? [String: String] ?? [:]
        env["AOS_MISSION_ID"] = id.uuidString
        aos["env"] = env
        servers["salenta-os"] = aos
        j["mcpServers"] = servers
        guard let out = try? JSONSerialization.data(withJSONObject: j, options: [.withoutEscapingSlashes]) else { return base }
        FileManager.default.createFile(atPath: sessionConfigURL.path, contents: out, attributes: [.posixPermissions: 0o600])
        return sessionConfigURL
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        if persistent {
            // Nur der Bildschirm (tmux-Client) ist weg? Dann läuft der Agent weiter – wieder anhängen.
            if let code = Persist.exitCode(id) {
                Persist.cleanup(id)
                try? FileManager.default.removeItem(at: sessionConfigURL)
                DispatchQueue.main.async {
                    guard self.endedAt == nil else { return }
                    self.running = false
                    self.exitCode = code
                    self.endedAt = Date()
                    self.onFinish?(self)
                }
            } else if Persist.alive(id), !AppDelegate.terminating {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.reattach() }
            } else if !AppDelegate.terminating {
                DispatchQueue.main.async {
                    guard self.endedAt == nil else { return }
                    self.running = false
                    self.exitCode = exitCode ?? 1
                    self.endedAt = Date()
                    self.onFinish?(self)
                }
            }
            return
        }
        try? FileManager.default.removeItem(at: sessionConfigURL)
        DispatchQueue.main.async {
            guard self.endedAt == nil else { return }
            self.running = false
            self.exitCode = exitCode
            self.endedAt = Date()
            self.onFinish?(self)
        }
    }

    var succeeded: Bool { !running && (exitCode ?? 1) == 0 }
}

/// Alle Sitzungen und die zuletzt genutzten Arbeitsordner.
final class AgentManager: ObservableObject {
    @Published var sessions: [AgentSession] = []
    @Published var selected: UUID?
    @Published var directories: [String] = []
    /// Wird aufgerufen, wenn eine Sitzung endet (setzt z. B. die Aufgabe auf erledigt).
    var onFinish: ((AgentSession) -> Void)?

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "aos.dirs") ?? []
        let defaults = [Paths.root.path] + ["Code", "Developer", "Projects"].map { Paths.home.appendingPathComponent($0).path }
        var list: [String] = []
        for d in saved + defaults where !list.contains(d) && FileManager.default.fileExists(atPath: d) {
            list.append(d)
        }
        directories = list
    }

    var runningCount: Int { sessions.filter(\.running).count }

    func session(forTask id: String) -> AgentSession? { sessions.last { $0.taskID == id } }

    var current: AgentSession? { sessions.first { $0.id == selected } ?? sessions.last }

    /// Claude darf gerade nicht arbeiten: von dir pausiert, nicht angemeldet oder hart im Limit.
    static var claudeOff: Bool { Usage.isPaused(.claude) || AgentHealth.unavailable(.claude) || Usage.shared.cachedPressure(.claude) >= 1 }

    /// Wer statt Claude arbeitet. Der OS-Agent braucht MCP-Tools – das kann außer Claude nur Codex.
    static func claudeStandIn(osAgent: Bool) -> AgentKind? {
        let order: [AgentKind] = osAgent ? [.codex] : [.codex] + AgentKind.coders.filter { $0 != .codex && $0 != .claude && $0 != .ollama }
        return order.first { OpenModels.available($0) && !AgentHealth.unavailable($0) && Usage.shared.cachedPressure($0) < 1 }
    }

    @discardableResult
    func start(_ kind: AgentKind, in directory: String? = nil, prompt: String? = nil, taskID: String? = nil,
               mode: RunMode = .interaktiv, label: String? = nil, osAgentConfig: URL? = nil,
               model: String? = nil, effort: String? = nil, codingConfig: URL? = nil, planOnly: Bool = false, fullAccess: Bool = false,
               worktree useWorktree: Bool = true, question: Bool = false, continueSession: String? = nil, baseRef: String? = nil,
               mergeIn: String? = nil) -> AgentSession {
        var kind = kind, model = model
        var offlineNote: String?
        // Kein Internet: Cloud-Agents gegen das lokale Modell tauschen – der Auftrag läuft weiter statt zu scheitern.
        if osAgentConfig == nil, let swap = LocalFirst.shared.offlineSwap(kind) {
            offlineNote = "\(kind.title) → \(L("lokal")) (\(swap.1)): " + (LocalFirst.shared.localOnly ? L("nur lokal eingestellt") : L("kein Internet"))
            kind = swap.0; model = swap.1
        }
        // Claude pausiert, im Limit oder abgemeldet: nichts darf trotzdem Claude starten – auch nicht der OS-Agent oder
        // „Projekt gewählt → Claude Code“. Dann übernimmt Codex (der OS-Agent bekommt dort dieselben verbundenen Tools).
        if kind == .claude, continueSession == nil, Self.claudeOff,
           let alt = Self.claudeStandIn(osAgent: osAgentConfig != nil) {
            offlineNote = (offlineNote.map { $0 + " · " } ?? "") + String(format: L("Claude ist pausiert oder nicht verfügbar – %@ übernimmt"), alt.title)
            kind = alt; model = nil
        }
        // Letztes Sicherheitsnetz: nie ein fremdes Modell an einen Agent geben (z. B. GPT an Claude Code) – dann dessen Standard
        if let m = model, !ModelCatalog.fits(m, kind) { model = nil }
        let base = directory ?? directories.first ?? Paths.root.path
        remember(base)
        var dir = base
        var prompt = prompt
        var wt: WorktreeInfo?
        // Folgeauftrag in einer bestehenden Arbeitskopie: gleiche Kopie weiterverwenden (Änderungen bleiben sichtbar).
        if Worktrees.isWorktree(base),
           let w = MissionStore.shared.missions.reversed().compactMap(\.worktree).first(where: { base == $0.path || base.hasPrefix($0.path + "/") }) {
            wt = w
        }
        // Projektregeln (.salenta-os.json + globale Regeln) gehen in jeden Coding-Auftrag.
        let resuming = continueSession != nil && kind == .claude
        if let p = prompt, kind != .shell, osAgentConfig == nil, !resuming {
            // Skills und Erweiterungen sind Werkzeuge für den Agenten – sie gehören nie in den Code des Nutzers
            let hygiene = L("Skills, Plugins, Erweiterungen und Agenten-Einstellungen nur benutzen – nie im Projekt installieren, anlegen oder ändern (keine Dateien unter .agents/, .claude/, .cursor/, .codex/ und kein `npx skills add`), außer der Auftrag verlangt das ausdrücklich.")
            let rules = (ProjectConfig.load(base)?.rules ?? []) + Rules.global + [hygiene]
            if !rules.isEmpty {
                prompt = p + "\n\n" + L("Regeln für dieses Projekt (immer einhalten):") + "\n" + rules.map { "- " + $0 }.joined(separator: "\n")
            }
        }
        // Automatisch: Token-Sparer und passende Skills/Erweiterungen – je nachdem, was installiert ist.
        var autoNames: [String] = []
        // Projektwissen: was frühere Aufträge (egal welcher Agent) in diesem Projekt gelernt haben
        if let p = prompt, !p.isEmpty, kind != .shell, !resuming, let mem = ProjectMemory.promptBlock(base) {
            prompt = p + "\n\n" + mem.text
            autoNames.append(String(format: L("Projektwissen (%d)"), mem.count))
        }
        if let p = prompt, !p.isEmpty, kind != .shell, !resuming {
            // Code-Aufträge, die allein laufen: Arbeitsplan in Phasen, je Phase die passenden installierten Werkzeuge
            if mode == .autonom, osAgentConfig == nil, !question, let plan = WorkPhases.plan(prompt: p, kind: kind, directory: base) {
                prompt = p + "\n\n" + plan.text
                autoNames += plan.names
                let pick = AutoSkills.pick(prompt: p, kind: kind, osAgent: false, directory: base, onlyIntegrations: true)
                if let block = AutoSkills.block(pick) { prompt = (prompt ?? "") + "\n\n" + block; autoNames += pick.names }
            } else {
                let pick = AutoSkills.pick(prompt: p, kind: kind, osAgent: osAgentConfig != nil, directory: base)
                if let block = AutoSkills.block(pick) { prompt = p + "\n\n" + block; autoNames += pick.names }
            }
        }
        // Coding-Aufträge, die allein laufen: eigene Arbeitskopie, damit parallele Agents sich nicht stören.
        if wt == nil, useWorktree, !question, mode == .autonom, osAgentConfig == nil, AgentKind.coders.contains(kind), prompt != nil,
           let w = Worktrees.create(for: base, id: UUID().uuidString, from: baseRef, mergeIn: mergeIn) {
            wt = w
            dir = w.path
            // Konflikte aus dem eingemischten Ziel-Branch? Dann zuerst diese lösen
            let unmerged = Git.run(["diff", "--name-only", "--diff-filter=U"], in: w.path, timeout: 15).out
                .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            if !unmerged.isEmpty {
                prompt = (prompt ?? "") + "\n\n" + L("Wichtig: In dieser Arbeitskopie ist der neueste Stand des Ziel-Branches schon eingemischt, aber diese Dateien haben Konflikte – löse zuerst alle Konfliktmarker (<<<<<<<, =======, >>>>>>>) sorgfältig und so, dass beide Seiten erhalten bleiben, wo sie zusammenpassen:") + "\n" + unmerged.map { "- " + $0 }.joined(separator: "\n")
            }
            prompt = (prompt ?? "") + "\n\n" + L("Hinweis: Du arbeitest in einer eigenen Arbeitskopie (Branch %@) dieses Repos. Du musst weder committen noch pushen und wechselst nicht den Branch – Salenta Code übernimmt Commit, Prüfung und Pull Request. Abhängigkeiten (node_modules) und lokale Einstellungen (.env) sind schon da. Ein `timeout`-Kommando ist vorhanden (z. B. `timeout 60 npm test`).").replacingOccurrences(of: "%@", with: w.branch)
        }
        // Claude in Chrome: bei Web-Projekten darf Claude die Seite selbst im Browser prüfen
        let chrome = kind == .claude && mode == .autonom && osAgentConfig == nil && !question && ChromeBridge.useFor(directory: dir)
        if chrome, let p = prompt { prompt = p + "\n\n" + L("Du kannst Chrome nutzen (Claude in Chrome): Starte den Dev-Server, öffne die Seite und prüfe deine Änderung selbst im Browser – Konsole, Darstellung, Klickwege. Keine Logins, Käufe oder Formulare auf fremden Seiten absenden.") }
        // Skill-Diät (Claude Code, selbstständig): statt alle installierten Skills zu laden, nur die für diesen Auftrag
        // gewählten – ihre Anleitung kommt direkt in den Auftrag. Spart bei vielen Skills viele tausend Tokens je Start.
        var diet = false
        if kind == .claude, mode == .autonom, osAgentConfig == nil, !resuming, SkillDiet.enabled,
           CLIFlags.shared.supports(.claude, "--disable-slash-commands") == true, let p = prompt {
            let (block, names) = SkillDiet.inline(for: p)
            prompt = p + (block.isEmpty ? "" : "\n\n" + block)
            diet = true
            if !names.isEmpty { autoNames.append(String(format: L("nur %d Skills geladen"), names.count)) }
        }
        let session = AgentSession(kind: kind, mode: kind == .shell ? .interaktiv : mode,
                                   directory: URL(fileURLWithPath: dir, isDirectory: true),
                                   prompt: prompt, taskID: taskID, label: label, osAgentConfig: osAgentConfig,
                                   model: model, effort: effort, codingConfig: codingConfig, planOnly: planOnly,
                                   continueSession: resuming ? continueSession : nil, chrome: chrome, onlyChosenSkills: diet, fullAccess: fullAccess)
        session.worktree = wt
        session.onFinish = { [weak self] s in
            MissionStore.shared.finish(s)
            self?.onFinish?(s)
            self?.saveOpen()
        }
        if let prompt, !prompt.isEmpty, kind != .shell {
            MissionStore.shared.record(session, prompt: prompt)
            if !autoNames.isEmpty { MissionStore.shared.setAuto(session.id.uuidString, autoNames) }
            if let offlineNote { MissionStore.shared.setReason(session.id.uuidString, offlineNote) }
        }
        sessions.append(session)
        selected = session.id
        saveOpen()
        return session
    }

    /// Eine Sitzung aus Claude Code oder Codex (auch aus anderen Fenstern) hier als Chat fortsetzen.
    @discardableResult
    func resume(_ file: TranscriptFile, in directory: String, title: String) -> AgentSession {
        remember(directory)
        let s = AgentSession(kind: file.agent, mode: .interaktiv, directory: URL(fileURLWithPath: directory, isDirectory: true),
                             prompt: nil, taskID: nil, label: title, resumeID: Transcript.sessionID(of: file))
        s.onFinish = { [weak self] x in
            MissionStore.shared.finish(x)
            self?.onFinish?(x)
            self?.saveOpen()
        }
        MissionStore.shared.recordResume(s, title: title, transcript: file.url.path)
        sessions.append(s)
        selected = s.id
        saveOpen()
        return s
    }

    /// Von dir gestoppt: abbrechen, nicht als fertig werten – nichts prüfen, nichts übernehmen, nichts hochladen.
    func stop(_ id: UUID) {
        MissionStore.shared.setOutcome(id.uuidString, "stopped")
        MissionStore.shared.markStopped(id.uuidString)
        close(id)
    }

    func close(_ id: UUID) {
        guard let s = sessions.first(where: { $0.id == id }) else { return }
        s.terminate()
        s.view.removeFromSuperview()
        sessions.removeAll { $0.id == id }
        if selected == id { selected = sessions.last?.id }
        saveOpen()
    }

    /// Beim Beenden der App: Hintergrund-Sitzungen laufen weiter, nur die anderen werden geschlossen.
    func closeAll() {
        saveOpen()
        for s in sessions where !s.persistent { s.terminate() }
    }

    func remember(_ dir: String) {
        var list = directories.filter { $0 != dir }
        list.insert(dir, at: 0)
        directories = Array(list.prefix(8))
        UserDefaults.standard.set(directories, forKey: "aos.dirs")
    }

    func chooseDirectory() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Als Arbeitsordner nutzen"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        remember(url.path)
        return url.path
    }
}

enum Agents {
    /// Cursor-CLI heißt je nach Version cursor-agent oder agent.
    static var cursorBin: String { Detection.which("cursor-agent") != nil ? "cursor-agent" : "agent" }

    /// Der Auftrag, den ein Agent mit einer Aufgabe bekommt.
    static func prompt(for task: TaskItem) -> String {
        var lines = [
            "Aufgabe aus meinem Salenta Code (ID \(task.id), Bereich \(task.company.title)):",
            "",
            task.title,
        ]
        if !task.notes.isEmpty { lines += ["", task.notes] }
        if let due = task.due { lines += ["", "Fällig: \(due.formatted(date: .abbreviated, time: .omitted))"] }
        lines += [
            "",
            "Wenn du fertig bist: setze in \(Paths.tasks.path) bei der Aufgabe \(task.id) \"status\" auf \"erledigt\"",
            "und schreib eine kurze Zusammenfassung ins Feld \"notes\" (oder nutze: \(Paths.root.path)/bin/aos done \(task.id) \"Zusammenfassung\").",
        ]
        if let ctx = Obsidian.promptContext { lines += ["", ctx] }
        return lines.joined(separator: "\n")
    }
}

/// Zeigt die NSView einer Sitzung in SwiftUI an, ohne sie neu zu erzeugen.
struct TerminalContainer: NSViewRepresentable {
    let session: AgentSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if session.view.superview !== container { attach(to: container) }
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        for v in container.subviews { v.removeFromSuperview() }
    }

    private func attach(to container: NSView) {
        let v = session.view
        v.removeFromSuperview()
        v.frame = container.bounds
        v.autoresizingMask = [.width, .height]
        container.addSubview(v)
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
    }
}


/// Zeigt live, was im Terminal einer Sitzung passiert (aktualisiert jede Sekunde).
struct LivePreview: View {
    @ObservedObject var session: AgentSession
    var lines = 6

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let text = session.screenTail(lines).joined(separator: "\n")
            Text(text.isEmpty ? "Startet …" : text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(hex: 0xD6D6DA))
                .lineLimit(lines)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Grid.s)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0x141418)))
        }
    }
}


/// Nur die Skills mitgeben, die der Auftrag wirklich braucht (vom Betreuer, der Agentenwahl oder dir gewählt).
enum SkillDiet {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "skills.onlyChosen") as? Bool ?? true }

    /// Findet die im Auftrag genannten Skills („/name“ oder „Skill: name“) und hängt ihre Anleitung an – ohne Kopfdaten, gekürzt.
    static func inline(for prompt: String) -> (String, [String]) {
        guard let catalog = SkillCatalog.current?.skills, !catalog.isEmpty else { return ("", []) }
        let byName = Dictionary(catalog.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var picked: [Skill] = []
        let ns = prompt as NSString
        let re = try? NSRegularExpression(pattern: #"(?:^|[\s,(])/?([A-Za-z0-9][A-Za-z0-9._:-]{2,60})"#)
        for m in re?.matches(in: prompt, range: NSRange(location: 0, length: ns.length)) ?? [] {
            let raw = ns.substring(with: m.range(at: 1)).lowercased()
            let name = raw.components(separatedBy: ":").last ?? raw
            let explicit = ns.substring(with: m.range).contains("/")
            guard let s = byName[raw] ?? byName[name], !picked.contains(s) else { continue }
            // nur ausdrücklich genannte Skills („/name“) oder Namen mit Bindestrich (kein gewöhnliches Wort)
            if explicit || name.contains("-") { picked.append(s) }
            if picked.count >= 4 { break }
        }
        guard !picked.isEmpty else {
            return (L("Skills: Für diesen Auftrag sind keine Skills geladen – arbeite direkt."), [])
        }
        var out = L("Skill-Anleitungen für diesen Auftrag (nur diese sind geladen – befolge sie):")
        for s in picked {
            guard var text = try? String(contentsOfFile: s.path, encoding: .utf8) else { continue }
            if text.hasPrefix("---"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
                text = String(text[end.upperBound...])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > 6000 { text = String(text.prefix(6000)) + "\n…" }
            out += "\n\n### " + s.name + "\n" + text
        }
        return (out, picked.map(\.name))
    }
}


/// Codex-Konfiguration für den OS-Agent: verweist auf deine normale Codex-Anmeldung und ergänzt die MCP-Server.
enum OSAgentCodex {
    static func home(id: UUID, mcp: URL) -> String {
        let fm = FileManager.default
        let src = Accounts.shared.env()["CODEX_HOME"] ?? (NSHomeDirectory() + "/.codex")
        let dir = fm.temporaryDirectory.appendingPathComponent("aos-codex-\(id.uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for item in (try? fm.contentsOfDirectory(atPath: src)) ?? [] where item != "config.toml" {
            try? fm.createSymbolicLink(atPath: dir.appendingPathComponent(item).path, withDestinationPath: src + "/" + item)
        }
        let servers = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: mcp))) as? [String: Any])?["mcpServers"] as? [String: Any] ?? [:]
        let base = (try? String(contentsOfFile: src + "/config.toml", encoding: .utf8)) ?? ""
        let toml = strip(base, names: Set(servers.keys)) + "\n\n" + tables(servers)
        let out = dir.appendingPathComponent("config.toml")
        fm.createFile(atPath: out.path, contents: Data(toml.utf8), attributes: [.posixPermissions: 0o600])
        return dir.path
    }

    /// TOML-Abschnitte für die MCP-Server (stdio: command/args/env, http: url/headers).
    static func tables(_ servers: [String: Any]) -> String {
        var out: [String] = []
        for name in servers.keys.sorted() {
            guard let s = servers[name] as? [String: Any], let key = bare(name) else { continue }
            // Web-Konnektoren mit Claude-Anmeldung (OAuth) kann Codex nicht nutzen – sie würden nur Fehler melden
            if s["command"] == nil, (s["headers"] as? [String: String] ?? [:]).isEmpty { continue }
            var lines = ["[mcp_servers.\(key)]"]
            if let c = s["command"] as? String { lines.append("command = " + q(c)) }
            if let a = s["args"] as? [String] { lines.append("args = [" + a.map(q).joined(separator: ", ") + "]") }
            if let u = s["url"] as? String { lines.append("url = " + q(u)) }
            if let h = s["headers"] as? [String: String], !h.isEmpty {
                lines.append("http_headers = { " + h.keys.sorted().map { q($0) + " = " + q(h[$0] ?? "") }.joined(separator: ", ") + " }")
            }
            if let e = s["env"] as? [String: String], !e.isEmpty {
                lines.append("[mcp_servers.\(key).env]")
                for k in e.keys.sorted() { lines.append(q(k) + " = " + q(e[k] ?? "")) }
            }
            out.append(lines.joined(separator: "\n"))
        }
        return out.joined(separator: "\n\n") + "\n"
    }

    /// Gleichnamige Server aus deiner Konfiguration entfernen (sonst wären die Abschnitte doppelt).
    static func strip(_ toml: String, names: Set<String>) -> String {
        var keep: [String] = [], skipping = false
        for line in toml.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") {
                skipping = names.contains { n in t == "[mcp_servers.\(n)]" || t.hasPrefix("[mcp_servers.\(n).") || t == "[mcp_servers.\"\(n)\"]" }
            }
            if !skipping { keep.append(line) }
        }
        return keep.joined(separator: "\n")
    }

    static func bare(_ n: String) -> String? { n.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil ? n : nil }

    /// TOML-Zeichenkette (Escape-Regeln wie JSON, ohne \\/).
    static func q(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]),
              let a = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(a.dropFirst().dropLast())
    }
}
