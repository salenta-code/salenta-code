import AgenticOSKit
import Foundation

// Erfolgsquote im echten Einsatz (nur Entwickler-Build): wertet die Aufträge der letzten Tage aus –
// wie viele erfolgreich endeten, woran die übrigen scheiterten, je Agent. Ohne Auftragstexte. Ergebnis: logs/success.txt.

enum SuccessReport {
    static func write(days: Int = 14) -> URL {
        let since = Date().addingTimeInterval(-Double(days) * 86400)
        let all = MissionStore.shared.missions.filter { $0.started >= since }
        // Weitergeführte Aufträge (Nachbesserung, Übergabe, Weitermachen) zählen über ihr letztes Glied – das Endergebnis zählt.
        let continued = Set(MissionStore.shared.missions.filter { $0.delegated != true }.compactMap(\.parent))
        let done = all.filter { $0.ended != nil && !continued.contains($0.id) }
        func success(_ m: MissionRecord) -> Bool? {
            if let o = m.outcome {
                if ["merged", "pr"].contains(o) { return true }
                if ["stopped", "dropped", "discarded"].contains(o) { return nil }   // bewusst beendet – zählt nicht
                return false
            }
            if m.verify?.passed == false { return false }
            return m.ok
        }
        let rated = done.compactMap { m in success(m).map { (m, $0) } }
        let good = rated.filter { $0.1 }.count
        var out = "Salenta Code – Erfolgsquote der letzten \(days) Tage (\(DateCoding.stamp(Date())))\n\n"
        out += "Aufträge: \(all.count), davon weitergeführt: \(all.filter { continued.contains($0.id) }.count), Endergebnisse: \(done.count), bewertbar: \(rated.count)\n"
        out += rated.isEmpty ? "Erfolgsquote: – (noch keine bewertbaren Aufträge)\n"
            : String(format: "Erfolgsquote: %.0f %% (%d von %d)\n", Double(good) / Double(rated.count) * 100, good, rated.count)
        out += "\nJe Agent:\n"
        for (agent, list) in Dictionary(grouping: rated, by: { $0.0.agent }).sorted(by: { $0.key < $1.key }) {
            out += "  \(agent): \(list.filter { $0.1 }.count)/\(list.count)\n"
        }
        out += "\nAusgänge: " + Dictionary(grouping: done, by: { $0.outcome ?? ($0.ok == true ? "ok" : $0.ok == false ? "fehler" : "offen") })
            .map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", ") + "\n"
        let failed = rated.filter { !$0.1 }.map(\.0)
        if !failed.isEmpty {
            out += "\nNicht erfolgreich:\n"
            for m in failed {
                let checks = (m.verify?.checks ?? []).filter { $0.ok == false }.map(\.name).joined(separator: ", ")
                out += "  \(m.id)  \(m.agent)  Ausgang: \(m.outcome ?? "-")  Prüfung: \(m.verify?.passed.map { $0 ? "grün" : "rot" } ?? "-")"
                    + (checks.isEmpty ? "" : "  rot: \(checks)") + (m.verify?.review?.ok == false ? "  Review: rot" : "")
                    + (m.fixRound.map { "  Nachbesserungen: \($0)" } ?? "") + "\n"
                // Art der Geheimnis-Funde (ohne Werte): Typ und Dateiendung
                if let sec = m.verify?.checks.first(where: { $0.name == L("Geheimnisse") && $0.ok == false }) {
                    let kinds = sec.output.split(separator: "\n").map { line -> String in
                        let parts = line.components(separatedBy: ": ")
                        let ext = (parts.first.map { ($0 as NSString).pathExtension } ?? "")
                        let kind = parts.dropFirst().joined(separator: ": ").components(separatedBy: " – ").first ?? ""
                        return "\(kind) (.\(ext))"
                    }
                    out += "      Geheimnis-Funde: " + Set(kinds).sorted().joined(separator: ", ") + "\n"
                }
            }
        }
        let url = Paths.source.appendingPathComponent("logs/success.txt")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? out.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// Einmaliger automatischer Neuversuch nach unerklärtem Abbruch – nie für einen Lauf, der selbst schon ein Neuversuch war.
enum AutoRetry {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "missions.autoRetry") as? Bool ?? true }

    static func allowed(_ rec: MissionRecord, store: MissionStore) -> Bool {
        guard enabled, rec.delegated != true else { return false }
        var cur = rec, depth = 0
        while let p = cur.parent, let parent = store.mission(p), depth < 10 {
            if parent.outcome == "retried" { return false }
            cur = parent; depth += 1
        }
        return true
    }
}
