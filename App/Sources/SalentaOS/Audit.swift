import AgenticOSKit
import Foundation

// Effizienz-Bericht (nur Entwickler-Version): Kennzahlen zu Planung, Delegation, Modellen, Tokens, Prüfungen und Nacharbeit –
// als JSON in logs/efficiency.json im Quellordner. Keine Inhalte von Aufträgen, nur Zahlen, Titel und Agent/Modell.

enum EfficiencyAudit {
    static func write() -> URL {
        let store = MissionStore.shared
        let since = Date().addingTimeInterval(-3 * 86400)
        let recent = store.missions.filter { $0.started >= since }
        let runs = Paths.root.appendingPathComponent("logs/runs", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: runs.path)) ?? []

        func tokens(_ m: MissionRecord) -> (ctx: Int, out: Int, steps: Int) {
            let suffix = "-\(m.agent)-\(m.id.prefix(6)).log.json"
            guard let f = files.first(where: { $0.hasSuffix(suffix) }),
                  let d = try? Data(contentsOf: runs.appendingPathComponent(f)),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return (0, 0, 0) }
            return (j["context"] as? Int ?? 0, j["output"] as? Int ?? 0, j["steps"] as? Int ?? 0)
        }

        var missions: [[String: Any]] = []
        for m in recent.sorted(by: { $0.started < $1.started }) {
            let t = tokens(m)
            let steward = Steward.shared.owner(ofMission: m.id)?.name
            var row: [String: Any] = [:]
            row["id"] = String(m.id.prefix(6)); row["title"] = String(m.title.prefix(80))
            row["agent"] = m.agent; row["model"] = m.model ?? ""
            row["steward"] = steward ?? ""
            row["parent"] = m.parent.map { String($0.prefix(6)) } ?? ""
            row["delegated"] = m.delegated == true
            row["fixRound"] = m.fixRound ?? 0
            row["outcome"] = m.outcome ?? ""
            let okText: String = m.ok == nil ? "open" : (m.ok == true ? "yes" : "no")
            row["ok"] = okText
            let v: String = m.verify == nil ? "none" : (m.verify?.passed == nil ? "running" : (m.verify?.passed == true ? "green" : "red"))
            row["verify"] = v
            let checks: [VerifyCheck] = m.verify?.checks ?? []
            row["failedChecks"] = checks.filter { $0.ok == false }.map(\.name)
            row["skippedChecks"] = checks.filter { $0.ok == nil }.count
            let rv: VerifyReview? = m.verify?.review
            row["reviewOK"] = rv.map { $0.ok ? "yes" : "no" } ?? ""
            row["reviewBy"] = rv?.agent ?? ""
            let rvText: String = rv.map { $0.summary + " | " + $0.issues.prefix(3).joined(separator: " | ") } ?? ""
            row["review"] = String(rvText.prefix(500))
            let notes: [String] = checks.filter { $0.ok == nil && $0.output.hasPrefix(L("Nicht blockierend")) }.map(\.name)
            row["nonBlocking"] = notes
            let secs: Double = checks.reduce(0.0) { $0 + $1.seconds }
            row["checkSeconds"] = Int(secs)
            let mins: Int = m.ended.map { Int($0.timeIntervalSince(m.started) / 60) } ?? -1
            row["minutes"] = mins
            row["promptChars"] = m.request.count
            row["contextTokens"] = t.ctx; row["outputTokens"] = t.out; row["steps"] = t.steps
            row["auto"] = m.auto ?? []
            row["reason"] = String((m.routeReason ?? "").prefix(120))
            row["plan"] = m.plan == true
            row["resumed"] = FileManager.default.fileExists(atPath: m.log + ".sid")
            // Nicht grün? Dann das Ende des Protokolls (ohne Schlüssel) – so lässt sich die Ursache ohne die Rohdaten finden
            if m.ok != true, let text = try? String(contentsOfFile: m.log, encoding: .utf8) {
                let clean = text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
                row["tail"] = clean.split(separator: "\n").suffix(30).map { String($0.prefix(300)) }.joined(separator: "\n")
                    .replacingOccurrences(of: #"(sk-[A-Za-z0-9_-]{8})[A-Za-z0-9_-]+|(gh[pousr]_)[A-Za-z0-9]+|(Bearer )\S+"#, with: "$1$2$3•••", options: .regularExpression)
                row["directory"] = (m.directory as NSString).lastPathComponent
                row["worktree"] = m.worktree != nil
            }
            missions.append(row)
        }

        var stewards: [[String: Any]] = []
        for p in Steward.shared.projects {
            let byState = Dictionary(grouping: p.tasks, by: { $0.state.rawValue }).mapValues(\.count)
            let byAgent = Dictionary(grouping: p.tasks.filter { $0.state != .idea && $0.state != .queued }, by: { $0.agent + "/" + ($0.model.isEmpty ? "-" : $0.model) }).mapValues(\.count)
            let titles = p.tasks.map { $0.title.lowercased() }
            let dupTitles = Dictionary(grouping: titles, by: { $0 }).filter { $0.value.count > 1 }.map { "\($0.key.prefix(70)) ×\($0.value.count)" }
            let planner = p.messages.filter { $0.role == "betreuer" }.count
            let fails = p.messages.filter { $0.text.contains(L("Der Betreuer konnte gerade nicht nachdenken")) }.count
            let reviews = p.messages.filter { $0.text.contains("geprüft:") }.count
            var st: [String: Any] = [:]
            st["name"] = p.name
            st["folder"] = (p.id as NSString).deletingLastPathComponent.components(separatedBy: "/").last ?? ""
            st["trust"] = p.trust; st["parallel"] = p.parallel; st["dailyRuns"] = p.dailyRuns; st["continuous"] = p.continuous
            st["tasksByState"] = byState; st["agentsUsed"] = byAgent; st["duplicateTitles"] = Array(dupTitles.prefix(15))
            // Warum Aufgaben verworfen wurden (Notiz-Anfang) – zeigt, ob der Betreuer zu viel plant oder nur aufräumt
            st["droppedWhy"] = Dictionary(grouping: p.tasks.filter { $0.state == .dropped }, by: { String(($0.note ?? "–").prefix(40)) }).mapValues(\.count)
            st["sources"] = Dictionary(grouping: p.tasks, by: { $0.source }).mapValues(\.count)
            st["plannerReplies"] = planner; st["plannerFailures"] = fails; st["prReviewsPosted"] = reviews
            let prs: [StewardPR] = p.prs ?? []
            st["openPRs"] = prs.count
            st["prsWithFixLimit"] = prs.filter { ($0.fixCount ?? 0) >= 2 }.count
            let sk: [[String]] = p.tasks.compactMap(\.skills)
            let ex: [[String]] = p.tasks.compactMap(\.exts)
            st["skillsPicked"] = sk.flatMap { $0 }.count
            st["extensionsPicked"] = ex.flatMap { $0 }.count
            st["githubWatcher"] = Steward.shared.isGitHubWatcher(p.id)
            st["runsPerDay"] = p.runs
            stewards.append(st)
        }

        // Fehlersuche: die letzten Zeilen der App-Protokolle (Betreuer, Verbrauch, Abstürze …) – Schlüssel und Tokens werden ausgeblendet
        var logs: [String: [String]] = [:]
        let logDir = Paths.root.appendingPathComponent("logs", isDirectory: true)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: logDir.path)) ?? [] where name.hasSuffix(".log") {
            guard let text = try? String(contentsOf: logDir.appendingPathComponent(name), encoding: .utf8) else { continue }
            logs[name] = text.split(separator: "\n").suffix(60).map { line in
                String(line).replacingOccurrences(of: #"(sk-[A-Za-z0-9_-]{8})[A-Za-z0-9_-]+|(gh[pousr]_)[A-Za-z0-9]+|(Bearer )\S+"#, with: "$1$2$3•••", options: .regularExpression)
            }
        }
        var report: [String: Any] = [
            "created": ISO8601DateFormatter().string(from: Date()),
            "window": "last 3 days",
            "settings": ["power": PowerProfile.mode, "energySaving": Energy.saving, "sessionReuse": SessionReuse.enabled,
                         "failFast": UserDefaults.standard.object(forKey: "verify.failFast") as? Bool ?? true,
                         "chrome": ChromeBridge.mode, "chromeConnected": ChromeBridge.hostInstalled,
                         "meteredAuto": Billing.autoAllowed, "local": LocalFirst.shared.model ?? "none"],
            "missions": missions, "stewards": stewards,
        ]
        report["logs"] = logs
        // Betreuer-Dateien: ob sie sich laden lassen (nur Dateiname, Größe, Zeit, Anzahl, Namen und Fehlerstelle – keine Inhalte)
        var stewardFiles: [[String: Any]] = []
        let dataDir = Paths.data
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: dataDir.path)) ?? []).filter({ $0.hasPrefix("stewards") }).sorted() {
            let u = dataDir.appendingPathComponent(name)
            var f: [String: Any] = ["name": name]
            let attrs = try? FileManager.default.attributesOfItem(atPath: u.path)
            f["bytes"] = attrs?[.size] as? Int ?? 0
            f["modified"] = (attrs?[.modificationDate] as? Date).map { ISO8601DateFormatter().string(from: $0) } ?? ""
            if let d = try? Data(contentsOf: u) {
                let raw = (try? JSONSerialization.jsonObject(with: d) as? [[String: Any]]) ?? []
                f["items"] = raw.count
                f["names"] = raw.compactMap { $0["name"] as? String }
                do { _ = try dec.decode([StewardProject].self, from: d); f["decodes"] = true }
                catch { f["decodes"] = false; f["error"] = String(String(describing: error).prefix(600)) }
            }
            stewardFiles.append(f)
        }
        report["stewardFiles"] = stewardFiles
        report["stewardsLoaded"] = Steward.shared.projects.count
        let dir = Paths.source.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("efficiency.json")
        if let d = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: url, options: .atomic) }
        return url
    }
}
