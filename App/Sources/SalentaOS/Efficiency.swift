import AgenticOSKit
import SwiftUI

// Was diese Version sparsamer und besser macht – angelehnt an gute Agent-Umgebungen:
//  • Folgerunden setzen dieselbe Claude-Sitzung fort statt bei null anzufangen (Kontext + Zwischenspeicher bleiben)
//  • Claude prüft Web-Änderungen selbst im Browser (Claude in Chrome)
//  • Prüfungen hören beim ersten roten Schritt auf und überspringen reine Doku-Änderungen

enum ChromeBridge {
    /// auto: nur bei Web-Projekten · always · off
    static var mode: String { UserDefaults.standard.string(forKey: "chrome.mode") ?? "auto" }

    /// Ist die Verbindung zwischen Claude Code und der Chrome-Erweiterung eingerichtet?
    static var hostInstalled: Bool {
        let base = NSHomeDirectory() + "/Library/Application Support/"
        let dirs = ["Google/Chrome", "Microsoft Edge", "BraveSoftware/Brave-Browser", "Arc/User Data", "Vivaldi"]
        return dirs.contains { FileManager.default.fileExists(atPath: base + $0 + "/NativeMessagingHosts/com.anthropic.claude_code_browser_extension.json") }
    }

    static func isWebProject(_ dir: String) -> Bool {
        let fm = FileManager.default
        func has(_ f: String) -> Bool { fm.fileExists(atPath: (dir as NSString).appendingPathComponent(f)) }
        if has("index.html") || has("layout/theme.liquid") { return true }
        if let d = fm.contents(atPath: (dir as NSString).appendingPathComponent("package.json")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let scripts = j["scripts"] as? [String: String] { return scripts["dev"] != nil || scripts["start"] != nil }
        return false
    }

    static func useFor(directory: String) -> Bool {
        guard mode != "off", hostInstalled, !OpenModels.claudeUsesAPIKey, !LocalFirst.shared.localOnly else { return false }
        if Energy.saving && mode != "always" { return false }       // Browser-Tests kosten Strom – am Akku weglassen
        return mode == "always" || isWebProject(directory)
    }
}

enum SessionReuse {
    /// Sitzungs-ID, die `aos-live` beim Lauf gemerkt hat.
    static func id(for rec: MissionRecord) -> String? {
        guard !rec.log.isEmpty else { return nil }
        let p = rec.log + ".sid"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: p),
              let m = attrs[.modificationDate] as? Date, Date().timeIntervalSince(m) < 2 * 86400,
              let s = try? String(contentsOfFile: p, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static var enabled: Bool { UserDefaults.standard.object(forKey: "session.reuse") as? Bool ?? true }
}

/// Einstellungen › Agent- und Modellwahl: Effizienz
struct EfficiencySettings: View {
    @AppStorage("session.reuse") private var reuse = true
    @AppStorage("chrome.mode") private var chrome = "auto"
    @AppStorage("verify.failFast") private var failFast = true

    var body: some View {
        Section("Effizienz & Qualität") {
            Toggle("Folgerunden in derselben Claude-Sitzung fortsetzen (spart Tokens, Claude behält den Zusammenhang)", isOn: $reuse)
            Toggle("Prüfung beim ersten roten Schritt beenden (spart Zeit und Strom)", isOn: $failFast)
            Picker("Claude prüft im Browser (Claude in Chrome)", selection: $chrome) {
                Text("Bei Web-Projekten").tag("auto")
                Text("Immer").tag("always")
                Text("Aus").tag("off")
            }
            if !ChromeBridge.hostInstalled {
                HStack {
                    Label(L("Chrome-Erweiterung noch nicht verbunden"), systemImage: "puzzlepiece.extension").foregroundStyle(.secondary)
                    Spacer()
                    Link(L("Erweiterung holen"), destination: URL(string: "https://chromewebstore.google.com/detail/claude/fcoeoabgfenejglbffodgkkbkcdhcgfn")!)
                }
                .font(.callout)
                Text("Einmalig: Erweiterung „Claude“ in Chrome installieren und mit deinem Claude-Konto anmelden. Danach verbindet sich Claude Code beim ersten Auftrag selbst.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Schlanke Auftragsliste

/// Fertiges schließt sich selbst: Was übernommen, verworfen oder sauber erledigt ist, verschwindet nach kurzer Zeit
/// aus der Seitenleiste (bleibt im Verlauf). Aufgaben des Projekt-Betreuers stehen nur auf seiner Tafel.
enum AutoClose {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "missions.autoClose") as? Bool ?? true }
    static var started = false
    static var minutes: Double { UserDefaults.standard.object(forKey: "missions.autoCloseMinutes") as? Double ?? 15 }

    static func run(agents: AgentManager, tasks: TaskStore, current: Page) {
        guard enabled else { return }
        let store = MissionStore.shared
        for m in store.open {
            guard let end = m.ended, current != .chat(m.id),
                  !agents.sessions.contains(where: { $0.id.uuidString == m.id && $0.running }),
                  Date().timeIntervalSince(end) > minutes * 60 else { continue }
            let decided = m.outcome == "merged" || m.outcome == "discarded"
            let bySteward = Steward.shared.owner(ofMission: m.id) != nil && m.worktree == nil
            let clean = m.ok == true && m.worktree == nil && m.plan != true && m.pr == nil && m.verify?.passed != false && m.group == nil
            let helper = m.delegated == true && m.ok == true
            if decided || bySteward || clean || helper { store.archive(m.id, agents: agents, tasks: tasks) }
        }
    }
}


// MARK: - Pull Request automatisch nachliefern

/// Scheitert „Pull Request erstellen“, bessert ein Agent nach – und ist die Prüfung danach grün, wird der PR selbst erstellt.
enum AutoPR {
    private static let key = "autopr.pending"
    static func mark(_ missionID: String, title: String) {
        var d = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        d[missionID] = title
        UserDefaults.standard.set(d, forKey: key)
    }
    /// Einmal abholen (danach vergessen)
    static func take(_ missionID: String) -> String? {
        var d = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        guard let t = d.removeValue(forKey: missionID) else { return nil }
        UserDefaults.standard.set(d, forKey: key)
        return t
    }
    static func fixMessage(_ why: String) -> String {
        L("Das Hochladen als Pull Request ist gescheitert:") + " " + why + "\n\n"
            + L("Behebe die Ursache in dieser Arbeitskopie (z. B. Schlüssel aus dem Code entfernen, neuesten Stand des Ziel-Branches einarbeiten und Konflikte lösen, zu große Dateien entfernen). Committe danach – nicht pushen, das übernimmt der Betreuer.")
    }
}
