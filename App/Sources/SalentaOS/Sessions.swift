import AgenticOSKit
import AppKit
import SwiftUI

// Sitzungen überleben das Schließen: Jeder Agent läuft in einer eigenen tmux-Sitzung (eigener Socket "salenta").
// Beim Start hängt sich Salenta Code wieder an alle an. Ohne tmux werden Dialog-Sitzungen fortgesetzt
// (claude --resume / codex resume) und unterbrochene selbstständige Aufträge ab dem letzten Stand weitergeführt.

enum Persist {
    static let socket = "salenta"
    private static var tmuxPath: String??

    static var tmux: String? {
        if let t = tmuxPath { return t }
        let found = Detection.which("tmux") ?? ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) }
        tmuxPath = .some(found)
        return found
    }

    static func recheck() { tmuxPath = nil }

    static var enabled: Bool { (UserDefaults.standard.object(forKey: "sessions.persist") as? Bool ?? true) && tmux != nil }

    static var dir: URL {
        let d = Paths.support.appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func name(_ id: UUID) -> String { "aos-" + id.uuidString.prefix(8).lowercased() }
    static func scriptFile(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).zsh") }
    static func exitFile(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).exit") }

    static var conf: URL {
        let f = dir.appendingPathComponent("tmux.conf")
        let text = """
        set -g status off
        set -g mouse on
        set -g history-limit 50000
        set -g default-terminal "xterm-256color"
        set -g escape-time 0
        set -g remain-on-exit off
        set -g destroy-unattached off
        set -ga terminal-overrides ",xterm-256color:Tc"
        """
        if (try? String(contentsOf: f, encoding: .utf8)) != text { try? text.write(to: f, atomically: true, encoding: .utf8) }
        return f
    }

    @discardableResult
    private static func tmuxRun(_ args: [String]) -> Int32 {
        guard let t = tmux else { return 1 }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: t)
        p.arguments = ["-L", socket] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return 1 }
        while p.isRunning { usleep(20_000) }  // kein waitUntilExit: das dreht den RunLoop und kann SwiftUI mitten im Zeichnen abstürzen lassen
        return p.terminationStatus
    }

    static func alive(_ id: UUID) -> Bool { tmuxRun(["has-session", "-t", name(id)]) == 0 }

    /// Text in eine Hintergrund-Sitzung tippen (z. B. „continue“ nach einem Netzausfall).
    static func sendKeys(_ id: UUID, _ text: String, enter: Bool) {
        guard alive(id) else { return }
        tmuxRun(["send-keys", "-t", name(id), "-l", text])
        if enter { tmuxRun(["send-keys", "-t", name(id), "Enter"]) }
    }

    static func kill(_ id: UUID) {
        tmuxRun(["kill-session", "-t", name(id)])
        cleanup(id)
    }

    static func exitCode(_ id: UUID) -> Int32? {
        guard let t = try? String(contentsOf: exitFile(id), encoding: .utf8) else { return nil }
        return Int32(t.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
    }

    static func cleanup(_ id: UUID) {
        try? FileManager.default.removeItem(at: exitFile(id))
        try? FileManager.default.removeItem(at: scriptFile(id))
    }
}

/// Was beim Beenden offen war – damit beim Start alles wiederkommt.
struct SavedSession: Codable, Hashable {
    let id: String
    let kind: String
    let mode: String
    let directory: String
    let label: String
    let taskID: String?
    let started: Date
    let model: String?
    let effort: String?
    let os: Bool
    let persistent: Bool
}

extension AgentManager {
    static var savedURL: URL { Paths.data.appendingPathComponent("sessions.json") }

    /// Offene Sitzungen merken (bei jedem Start/Ende/Schließen).
    func saveOpen() {
        let list = sessions.filter(\.running).map { s in
            SavedSession(id: s.id.uuidString, kind: s.kind.rawValue, mode: s.mode.rawValue, directory: s.directory.path, label: s.label,
                         taskID: s.taskID, started: s.startedAt, model: s.model, effort: s.effort, os: s.isOSAgent, persistent: s.persistent)
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try? enc.encode(list).write(to: Self.savedURL, options: .atomic)
    }

    private func loadSaved() -> [SavedSession] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: Self.savedURL), let l = try? dec.decode([SavedSession].self, from: d) { return l }
        // Erster Start mit dieser Version: offene Aufträge der letzten 24 Stunden aus der Auftragsliste.
        let from = Date().addingTimeInterval(-86400)
        return MissionStore.shared.missions.filter { $0.ended == nil && $0.archived != true && $0.started >= from }.map { m in
            SavedSession(id: m.id, kind: m.isOSAgent ? "claude" : m.agent, mode: m.mode, directory: m.directory, label: m.title,
                         taskID: m.taskID, started: m.started, model: m.model, effort: nil, os: m.isOSAgent, persistent: false)
        }
    }

    /// Beim Start: an laufende Hintergrund-Sitzungen anhängen, fertige abschließen, unterbrochene fortsetzen.
    func restore(hub: MCPHub, app: AppModel) {
        let saved = loadSaved()
        guard !saved.isEmpty else { return }
        var resumed = 0, attached = 0
        for e in saved {
            guard let uuid = UUID(uuidString: e.id), !sessions.contains(where: { $0.id == uuid }),
                  let kind = AgentKind(rawValue: e.kind) else { continue }
            let mode = RunMode(rawValue: e.mode) ?? .autonom
            let rec = MissionStore.shared.mission(e.id)
            if rec?.archived == true { continue }
            let dirURL = URL(fileURLWithPath: e.directory, isDirectory: true)

            // 1. Läuft noch im Hintergrund → wieder anhängen.
            if Persist.tmux != nil && Persist.alive(uuid) {
                let s = AgentSession(kind: kind, mode: mode, directory: dirURL, prompt: nil, taskID: e.taskID, label: e.label,
                                     osAgentConfig: e.os ? OSAgent.aosOnlyConfig : nil, model: e.model, effort: e.effort,
                                     id: uuid, startedAt: e.started, attach: true)
                s.worktree = rec?.worktree
                adopt(s)
                attached += 1
                continue
            }
            // 2. Während die App zu war fertig geworden → abschließen (und prüfen).
            if let code = Persist.exitCode(uuid) {
                Persist.cleanup(uuid)
                MissionStore.shared.finish(id: e.id, ok: code == 0)
                if code == 0, rec?.worktree != nil, Verifier.autoRun { Verifier.run(e.id) }
                continue
            }
            guard let rec else {
                if kind == .shell { start(.shell, in: e.directory) }
                continue
            }
            // 3. Unterbrochen (ohne tmux): Dialog fortsetzen bzw. Auftrag ab dem letzten Stand weiterführen.
            if mode == .interaktiv, kind == .claude || kind == .codex, let tr = rec.transcript {
                let file = TranscriptFile(url: URL(fileURLWithPath: tr), agent: kind, modified: Date())
                let s = AgentSession(kind: kind, mode: .interaktiv, directory: dirURL, prompt: nil, taskID: rec.taskID, label: rec.title,
                                     resumeID: Transcript.sessionID(of: file), id: uuid, startedAt: e.started)
                s.worktree = rec.worktree
                MissionStore.shared.reopen(e.id)
                adopt(s)
                resumed += 1
            } else if mode == .autonom, rec.ended == nil {
                MissionStore.shared.finish(id: e.id, ok: false)
                let msg = L("Salenta Code wurde zwischendurch beendet und dein Lauf unterbrochen. Prüfe kurz den aktuellen Stand im Ordner (git status, letzte Änderungen) und mach genau dort weiter, bis der Auftrag erledigt ist.")
                Handoff.continueMission(rec, message: msg, target: rec.agent, agents: self, hub: hub,
                                        note: L("Nach Neustart fortgesetzt")) { _ in }
                resumed += 1
            }
        }
        saveOpen()
        if attached + resumed > 0 {
            app.show("↺ " + (attached > 0 ? "\(attached) " + L("Sitzung(en) wieder verbunden") : "")
                     + (attached > 0 && resumed > 0 ? " · " : "") + (resumed > 0 ? "\(resumed) " + L("fortgesetzt") : ""))
        }
    }

    /// Eine wiederhergestellte Sitzung aufnehmen.
    private func adopt(_ s: AgentSession) {
        s.onFinish = { [weak self] x in
            MissionStore.shared.finish(x)
            self?.onFinish?(x)
            self?.saveOpen()
        }
        sessions.append(s)
    }
}

extension MissionStore {
    func finish(id: String, ok: Bool) {
        guard let i = missions.firstIndex(where: { $0.id == id }) else { return }
        missions[i].ended = Date()
        missions[i].ok = ok
        persist()
    }

    func reopen(_ id: String) {
        guard let i = missions.firstIndex(where: { $0.id == id }) else { return }
        missions[i].ended = nil
        missions[i].ok = nil
        persist()
    }
}
